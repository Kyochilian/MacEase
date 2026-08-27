import Foundation
import Observation

/// Keeps the system media surface in step with playback, and turns the
/// commands it sends back into playback intents.
///
/// It owns no playback state. `snapshotProvider` reads the current projection
/// on demand and `performIntent` forwards an approved command to whoever owns
/// the queue, so this type cannot disagree with the controller — it has
/// nothing of its own to disagree with.
///
/// Commands are validated before dispatch. The system asks for what its UI
/// currently shows, which can be one state behind, so "pause" can arrive for
/// something already paused and "next" for a queue that just ended. Those are
/// answered `notPermitted` rather than forwarded, because dispatching them
/// would either do nothing while reporting success or start work the user did
/// not ask for.
@MainActor
package final class NowPlayingCoordinator {
  package typealias SnapshotProvider = @MainActor () -> PlaybackSnapshot
  /// Returns whether the intent was accepted. It must not perform a NetEase
  /// request of its own beyond what the equivalent in-app action performs.
  package typealias IntentHandler = @MainActor (SystemMediaCommand) -> Bool

  @ObservationIgnored private let surface: any SystemMediaControlling
  private let snapshotProvider: SnapshotProvider
  private let performIntent: IntentHandler
  private var lastPublished: PlaybackSnapshot?

  package init(
    surface: any SystemMediaControlling,
    snapshotProvider: @escaping SnapshotProvider,
    performIntent: @escaping IntentHandler
  ) {
    self.surface = surface
    self.snapshotProvider = snapshotProvider
    self.performIntent = performIntent
    surface.onCommand = { [weak self] command in
      guard let self else { return .noActionableItem }
      return self.handle(command)
    }
  }

  /// Publishes the current projection if it says anything new. Callers may
  /// invoke it on every playback change; the comparison, not the caller, is
  /// what stops a redraw per clock tick.
  package func refresh() {
    let snapshot = snapshotProvider()
    guard snapshot.requiresPublishing(comparedTo: lastPublished) else { return }
    lastPublished = snapshot
    if snapshot.hasActionableItem {
      surface.publish(snapshot)
    } else {
      // Nothing is loaded. Leaving the last track on the surface would let a
      // signed-out or stopped app keep advertising what it was playing.
      surface.clear()
    }
  }

  /// Removes MacEase from the system surface and forgets what was published,
  /// so the next `refresh` republishes from scratch. Used on stop and on any
  /// session identity change.
  package func clear() {
    lastPublished = nil
    surface.clear()
  }

  /// Republishes whenever anything `snapshotProvider` reads changes, and
  /// re-arms itself. Observation fires once per change, so this is what keeps
  /// the surface current without any coordinator having to remember to call
  /// `refresh` from each of its own mutation points.
  ///
  /// The clock ticks a few times a second and each tick wakes this, but
  /// `refresh` compares before publishing, so a tick costs one struct
  /// comparison rather than a system update.
  package func startObserving() {
    withObservationTracking {
      _ = snapshotProvider()
    } onChange: { [weak self] in
      // `onChange` runs before the new value is applied, so the read has to
      // happen on the next turn of the main actor.
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.refresh()
        self.startObserving()
      }
    }
  }

  private func handle(_ command: SystemMediaCommand) -> SystemMediaCommandResult {
    let snapshot = snapshotProvider()
    guard snapshot.hasActionableItem else { return .noActionableItem }

    let resolved: SystemMediaCommand
    switch command {
    case .play:
      guard snapshot.state == .paused else { return .notPermitted }
      resolved = .play
    case .pause:
      guard snapshot.state == .playing else { return .notPermitted }
      resolved = .pause
    case .toggle:
      // Resolved here so the intent handler never has to re-derive which of
      // the two the system meant.
      switch snapshot.state {
      case .playing: resolved = .pause
      case .paused: resolved = .play
      case .stopped: return .notPermitted
      }
    case .next:
      guard snapshot.canStepNext else { return .notPermitted }
      resolved = .next
    case .previous:
      guard snapshot.canStepPrevious else { return .notPermitted }
      resolved = .previous
    case .seek(let seconds):
      // Seeking needs a length to seek within. A scrubber can report a value
      // slightly past the end, so clamp rather than refuse.
      guard let duration = snapshot.durationSeconds, duration > 0 else {
        return .notPermitted
      }
      resolved = .seek(min(max(seconds, 0), duration))
    case .setLiked(let liked):
      // An unknown liked state means the toggle's starting position is a
      // guess. The command centre must not offer to flip a guess.
      guard snapshot.liked != .unknown else { return .notPermitted }
      resolved = .setLiked(liked)
    }

    let accepted = performIntent(resolved)
    // The intent may have changed what the surface should show.
    refresh()
    return accepted ? .handled : .failed
  }
}

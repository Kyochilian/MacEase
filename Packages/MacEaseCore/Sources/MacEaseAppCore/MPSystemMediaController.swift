import AppKit
import Foundation
import MediaPlayer

/// The real system media surface.
///
/// It holds no playback state and makes no decisions about what should happen:
/// every command is forwarded to `onCommand`, which validates it against the
/// live projection. The one thing it remembers is the last snapshot it
/// published, because the system's like button is a toggle and needs to know
/// which way it is pointing.
@MainActor
package final class MPSystemMediaController: SystemMediaControlling {
  package var onCommand: (@MainActor (SystemMediaCommand) -> SystemMediaCommandResult)?

  private let infoCenter: MPNowPlayingInfoCenter
  private let commandCenter: MPRemoteCommandCenter
  /// What the system was last told. Used for the like toggle's direction and
  /// to keep command enablement in step; never consulted as a source of truth
  /// about playback.
  private var lastPublished: PlaybackSnapshot?
  private var registeredTargets: [(MPRemoteCommand, Any)] = []

  package init(
    infoCenter: MPNowPlayingInfoCenter = .default(),
    commandCenter: MPRemoteCommandCenter = .shared()
  ) {
    self.infoCenter = infoCenter
    self.commandCenter = commandCenter
    registerTargets()
  }

  deinit {
    // Targets cannot be removed here: `deinit` is nonisolated, and the tokens
    // are MainActor state. `detach()` is the supported teardown, and
    // `registerTargets` also clears its own tokens first, so re-registering
    // this instance cannot double up either.
  }

  /// Removes every command target this controller registered. The composition
  /// root owns one instance for the process lifetime, so this exists for tests
  /// and for a future teardown path rather than for normal running.
  package func detach() {
    removeRegisteredTargets()
    onCommand = nil
  }

  private func removeRegisteredTargets() {
    for (command, target) in registeredTargets {
      command.removeTarget(target)
    }
    registeredTargets = []
  }

  package func publish(_ snapshot: PlaybackSnapshot) {
    publish(snapshot, artwork: nil)
  }

  package func publishArtwork(
    _ artwork: NSImage,
    for snapshot: PlaybackSnapshot
  ) {
    publish(snapshot, artwork: artwork)
  }

  private func publish(_ snapshot: PlaybackSnapshot, artwork: NSImage?) {
    lastPublished = snapshot

    var info: [String: Any] = [:]
    info[MPMediaItemPropertyTitle] = snapshot.title ?? ""
    if let artist = snapshot.artist {
      info[MPMediaItemPropertyArtist] = artist
    }
    if let albumTitle = snapshot.albumTitle {
      info[MPMediaItemPropertyAlbumTitle] = albumTitle
    }
    if let image = artwork?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
      info[MPMediaItemPropertyArtwork] = Self.mediaArtwork(image)
    }
    if let duration = snapshot.durationSeconds {
      info[MPMediaItemPropertyPlaybackDuration] = duration
    }
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = snapshot.elapsedSeconds
    info[MPNowPlayingInfoPropertyPlaybackRate] = snapshot.rate
    if let trackID = snapshot.trackID {
      info[MPMediaItemPropertyPersistentID] = UInt64(bitPattern: trackID)
    }
    infoCenter.nowPlayingInfo = info
    infoCenter.playbackState = playbackState(for: snapshot.state)

    updateEnablement(for: snapshot)
  }

  package func clear() {
    lastPublished = nil
    infoCenter.nowPlayingInfo = nil
    infoCenter.playbackState = .stopped
    updateEnablement(for: nil)
  }

  // MediaPlayer requests images on its own queue. Build this callback outside
  // MainActor isolation and capture only immutable pixels, not a UI NSImage.
  nonisolated package static func mediaArtwork(_ image: CGImage) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: CGSize(width: image.width, height: image.height)) { _ in
      NSImage(cgImage: image, size: .zero)
    }
  }

  private func playbackState(
    for state: PlaybackSnapshot.State
  ) -> MPNowPlayingPlaybackState {
    switch state {
    case .playing: .playing
    case .paused: .paused
    case .stopped: .stopped
    }
  }

  /// Enablement mirrors what the coordinator would accept, so the system does
  /// not offer a control that is guaranteed to be refused.
  private func updateEnablement(for snapshot: PlaybackSnapshot?) {
    let hasItem = snapshot?.hasActionableItem ?? false
    commandCenter.playCommand.isEnabled = snapshot?.state == .paused
    commandCenter.pauseCommand.isEnabled = snapshot?.state == .playing
    commandCenter.togglePlayPauseCommand.isEnabled =
      hasItem && snapshot?.state != .stopped
    commandCenter.nextTrackCommand.isEnabled = snapshot?.canStepNext ?? false
    commandCenter.previousTrackCommand.isEnabled = snapshot?.canStepPrevious ?? false
    commandCenter.changePlaybackPositionCommand.isEnabled =
      hasItem && (snapshot?.durationSeconds ?? 0) > 0
    // A liked state nobody has loaded would make the button a coin flip.
    let liked = snapshot?.liked ?? .unknown
    commandCenter.likeCommand.isEnabled = liked != .unknown
    commandCenter.likeCommand.isActive = liked == .liked
  }

  private func registerTargets() {
    // Idempotent: registering twice on one instance replaces rather than
    // duplicates.
    removeRegisteredTargets()
    register(commandCenter.playCommand) { _ in .play }
    register(commandCenter.pauseCommand) { _ in .pause }
    register(commandCenter.togglePlayPauseCommand) { _ in .toggle }
    register(commandCenter.nextTrackCommand) { _ in .next }
    register(commandCenter.previousTrackCommand) { _ in .previous }
    register(commandCenter.changePlaybackPositionCommand) { event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else {
        return nil
      }
      return .seek(event.positionTime)
    }
    register(commandCenter.likeCommand) { [weak self] _ in
      // The system's like control is a toggle, so the target state is the
      // opposite of what was last published.
      guard let liked = self?.lastPublished?.liked, liked != .unknown else {
        return nil
      }
      return .setLiked(liked != .liked)
    }
  }

  private func register(
    _ command: MPRemoteCommand,
    map: @escaping @MainActor (MPRemoteCommandEvent) -> SystemMediaCommand?
  ) {
    let target = command.addTarget { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, let mapped = map(event) else {
          return .noActionableNowPlayingItem
        }
        guard let handler = self.onCommand else {
          return .noActionableNowPlayingItem
        }
        return Self.status(for: handler(mapped))
      }
    }
    registeredTargets.append((command, target))
  }

  private static func status(
    for result: SystemMediaCommandResult
  ) -> MPRemoteCommandHandlerStatus {
    switch result {
    case .handled: .success
    case .noActionableItem: .noActionableNowPlayingItem
    // The system uses this to stop showing the control as having worked.
    // Reporting success for something that was refused would make the surface
    // disagree with the app.
    case .notPermitted, .failed: .commandFailed
    }
  }
}

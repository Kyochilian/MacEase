import Foundation
import NeteaseKit

package enum AppPlaybackCommand: Equatable, Sendable {
  case togglePlayback
  case previous
  case next
  case setMode(PlaybackMode)
  case toggleLiked
}

/// Connects the system media surface to the objects that actually own
/// playback and the liked set.
///
/// This lives here rather than inside the app's composition root so it can be
/// tested against real coordinators. The bug it exists to prevent is specific:
/// a router that calls a `Void` method and returns `true` reports success to
/// the system for a command the arbiter, the session or the queue refused, and
/// no test of a configurable fake handler can catch that.
///
/// References are weak. The router is held by `NowPlayingCoordinator`, which
/// outlives nothing; a strong reference here would keep a signed-out session's
/// coordinators alive.
@MainActor
package struct SystemMediaRouter {
  private weak var playback: PlaybackController?
  private weak var library: PlaylistLibraryCoordinator?
  private weak var session: (any SessionProviding)?

  package init(
    playback: PlaybackController,
    library: PlaylistLibraryCoordinator,
    session: any SessionProviding
  ) {
    self.playback = playback
    self.library = library
    self.session = session
  }

  /// The current projection, with the liked state of whatever is playing.
  package func snapshot() -> PlaybackSnapshot {
    guard let playback else { return .empty }
    let liked =
      playback.currentTrack
      .map { library?.liked.state(of: $0.id) ?? .unknown } ?? .unknown
    return playback.snapshot(liked: liked)
  }

  /// Dispatches an approved command and reports whether its owner accepted it.
  ///
  /// Acceptance means the intent started, not that the server answered. A
  /// write's result arrives later and reaches the user through the arbiter's
  /// outcome, not through the command's return value.
  package func perform(_ command: SystemMediaCommand) -> Bool {
    guard let playback, let session else { return false }
    switch command {
    case .play:
      return playback.resume()
    case .pause:
      return playback.pause()
    case .next:
      return playback.playNext(session: session)
    case .previous:
      return playback.playPrevious(session: session)
    case .seek(let seconds):
      return playback.seek(to: seconds)
    case .setLiked(let liked):
      guard let library, let track = playback.currentTrack else { return false }
      return library.setLiked(liked, for: track, session: session)
    case .toggle:
      // `NowPlayingCoordinator` resolves toggle to play or pause before
      // dispatch, so reaching here means the projection and the command
      // disagreed. Refusing is the honest answer.
      return false
    }
  }

  package func canPerform(_ command: AppPlaybackCommand) -> Bool {
    guard let playback else { return false }
    let snapshot = snapshot()
    switch command {
    case .togglePlayback:
      return snapshot.state == .playing || snapshot.state == .paused
    case .previous:
      guard let session else { return false }
      return playback.canPlayPrevious(session: session)
    case .next:
      guard let session else { return false }
      return playback.canPlayNext(session: session)
    case .setMode:
      return true
    case .toggleLiked:
      guard let session, let library else { return false }
      return playback.currentTrack != nil && snapshot.liked != .unknown
        && library.canSetLiked(session: session)
    }
  }

  /// App and Dock commands share this route. It derives toggle direction and
  /// enablement from the live snapshot, then calls the same owners as system
  /// media commands.
  package func perform(_ command: AppPlaybackCommand) -> Bool {
    guard canPerform(command), let playback else { return false }
    switch command {
    case .togglePlayback:
      return snapshot().state == .playing
        ? perform(.pause) : perform(.play)
    case .previous:
      return perform(SystemMediaCommand.previous)
    case .next:
      return perform(SystemMediaCommand.next)
    case .setMode(let mode):
      playback.playbackMode = mode
      return true
    case .toggleLiked:
      let liked = snapshot().liked
      return perform(.setLiked(liked != .liked))
    }
  }
}

import Foundation

/// A command arriving from the system: the media keys, Control Centre, the
/// Now Playing widget or a Bluetooth remote.
///
/// These are requests, not instructions. Each one is checked against the
/// current projection before it becomes a playback intent, and none of them
/// reaches the transport: a remote command can never cause a NetEase request
/// that the user did not ask for through the app.
package enum SystemMediaCommand: Equatable, Sendable {
  case play
  case pause
  case toggle
  case next
  case previous
  case seek(Double)
  case setLiked(Bool)
}

/// What the system is told about a command. The system uses this to decide
/// whether to show an error, so guessing `handled` for something that did not
/// happen makes the surface lie.
package enum SystemMediaCommandResult: Equatable, Sendable {
  case handled
  /// Nothing is loaded, so there is nothing to act on.
  case noActionableItem
  /// There is a track, but this command does not apply to it right now:
  /// pausing what is already paused, stepping past the end of the queue, or
  /// liking a track whose liked state has not been loaded.
  case notPermitted
  /// The intent was dispatched and refused.
  case failed
}

/// The system media surface.
///
/// Keeping `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` behind this
/// protocol is what lets the projection and command rules be tested without a
/// real media server, which no unit test can assert against.
@MainActor
package protocol SystemMediaControlling: AnyObject {
  /// Invoked for every command the system delivers. The coordinator sets this;
  /// nothing else may.
  var onCommand: (@MainActor (SystemMediaCommand) -> SystemMediaCommandResult)? {
    get set
  }

  /// Publishes the current projection.
  func publish(_ snapshot: PlaybackSnapshot)

  /// Removes MacEase from the system surface entirely.
  func clear()
}

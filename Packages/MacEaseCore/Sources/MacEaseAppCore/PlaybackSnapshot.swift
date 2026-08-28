import Foundation
import NeteaseKit

/// A read-only projection of playback for system integration.
///
/// Now Playing and the remote command centre must not become a second place
/// that decides what is playing. This type is derived from
/// `PlaybackController` on demand and holds no storage of its own, so there is
/// nothing to keep in sync and no way for the system's view to survive a state
/// change the controller made.
///
/// It deliberately carries only what the system surface can express. Album and
/// artwork are absent because the domain has no field for them yet: the queue
/// is built from `Track`, which is an id, a name and artist names.
/// Publishing an empty album string would be indistinguishable from a track
/// that really has none.
package struct PlaybackSnapshot: Equatable, Sendable {
  /// What the system should show. `resolving` and `failed` are not separate
  /// system states — neither has audio — so both project to `stopped` while
  /// keeping whatever track the user last chose visible.
  package enum State: Equatable, Sendable {
    case stopped
    case playing
    case paused
  }

  package let state: State
  package let trackID: Int64?
  package let title: String?
  package let artist: String?
  package let durationSeconds: Double?
  package let elapsedSeconds: Double
  /// Increments whenever position moved for a reason other than playback
  /// advancing: a seek, or a newly loaded item. The system extrapolates
  /// elapsed time from the rate, so it only needs a fresh value at these
  /// discontinuities rather than on every clock tick.
  package let positionEpoch: Int
  package let canStepNext: Bool
  package let canStepPrevious: Bool
  package let liked: LikedState

  package init(
    state: State,
    trackID: Int64?,
    title: String?,
    artist: String?,
    durationSeconds: Double?,
    elapsedSeconds: Double,
    positionEpoch: Int,
    canStepNext: Bool,
    canStepPrevious: Bool,
    liked: LikedState
  ) {
    self.state = state
    self.trackID = trackID
    self.title = title
    self.artist = artist
    self.durationSeconds = durationSeconds
    self.elapsedSeconds = elapsedSeconds
    self.positionEpoch = positionEpoch
    self.canStepNext = canStepNext
    self.canStepPrevious = canStepPrevious
    self.liked = liked
  }

  /// Nothing is loaded. Used to clear the system surface on stop or sign-out.
  package static let empty = PlaybackSnapshot(
    state: .stopped,
    trackID: nil,
    title: nil,
    artist: nil,
    durationSeconds: nil,
    elapsedSeconds: 0,
    positionEpoch: 0,
    canStepNext: false,
    canStepPrevious: false,
    liked: .unknown
  )

  /// Whether there is a track the system can act on. Commands that need one
  /// report `noActionableItem` rather than silently succeeding.
  package var hasActionableItem: Bool { trackID != nil }

  /// The rate the system should use to extrapolate elapsed time.
  package var rate: Double { state == .playing ? 1 : 0 }

  /// Whether anything changed that the system must be told about. Elapsed time
  /// alone is excluded: while the rate is unchanged the system advances the
  /// clock itself, so pushing every tick would be a redraw per tick for no new
  /// information. A seek or a new item bumps `positionEpoch`, which is
  /// compared here and does force a push.
  package func requiresPublishing(comparedTo previous: PlaybackSnapshot?) -> Bool {
    guard let previous else { return true }
    return state != previous.state
      || trackID != previous.trackID
      || title != previous.title
      || artist != previous.artist
      || durationSeconds != previous.durationSeconds
      || positionEpoch != previous.positionEpoch
      || canStepNext != previous.canStepNext
      || canStepPrevious != previous.canStepPrevious
      || liked != previous.liked
  }
}

import Foundation
import NeteaseKit

/// One actual run of one queue entry. A repeat-one replay creates another
/// identity even though it keeps the same AVPlayer item and song URL.
package struct PlaybackLifecycleInstance: Equatable, Sendable {
  package let id: UUID
  package let accountID: Int64
  package let track: Track
  package let context: PlaybackContext

  package init(
    id: UUID = UUID(),
    accountID: Int64,
    track: Track,
    context: PlaybackContext
  ) {
    self.id = id
    self.accountID = accountID
    self.track = track
    self.context = context
  }

  /// The endpoint only accepts a real playlist source. Other playback
  /// contexts must not be represented as a made-up playlist id.
  package var scrobbleContext: ScrobbleContext? {
    switch context {
    case .playlist(let id, _): ScrobbleContext(sourceID: id)
    default: nil
    }
  }
}

package enum PlaybackLifecycleEvent: Equatable, Sendable {
  case started(PlaybackLifecycleInstance)
  case finished(PlaybackLifecycleInstance, playedSeconds: Int)
}

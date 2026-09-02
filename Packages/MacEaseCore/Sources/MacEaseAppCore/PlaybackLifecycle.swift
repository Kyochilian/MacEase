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

  /// The locked feedback contract only proves `source=list`. A real playlist
  /// id is preserved; every other context uses the protocol's zero fallback
  /// rather than pretending an album, search or FM queue is a playlist.
  package var scrobbleContext: ScrobbleContext {
    switch context {
    case .playlist(let id, _): ScrobbleContext(source: "list", sourceID: id)
    default: ScrobbleContext(source: "list", sourceID: 0)
    }
  }
}

package enum PlaybackLifecycleEvent: Equatable, Sendable {
  case started(PlaybackLifecycleInstance)
  case finished(PlaybackLifecycleInstance, playedSeconds: Int)
}

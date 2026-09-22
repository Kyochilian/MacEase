import Foundation
import NeteaseKit

/// One actual run of one queue entry. A repeat-one replay creates another
/// identity even though it keeps the same AVPlayer item and song URL.
package struct PlaybackLifecycleInstance: Equatable, Sendable {
  package let id: UUID
  package let accountID: Int64
  package let track: Track
  package let context: PlaybackContext
  package let downloaded: Bool

  package init(
    id: UUID = UUID(),
    accountID: Int64,
    track: Track,
    context: PlaybackContext,
    downloaded: Bool = false
  ) {
    self.id = id
    self.accountID = accountID
    self.track = track
    self.context = context
    self.downloaded = downloaded
  }

  package var scrobbleContext: ScrobbleContext {
    switch context {
    case .song(let id, _): ScrobbleContext(sourceID: id, source: .song, downloaded: downloaded)
    case .playlist(let id, _): ScrobbleContext(sourceID: id, downloaded: downloaded)
    case .album(let id, _): ScrobbleContext(sourceID: id, source: .album, downloaded: downloaded)
    case .artist(let id, _): ScrobbleContext(sourceID: id, source: .artist, downloaded: downloaded)
    case .heartbeatMode(_, let playlistID, _):
      ScrobbleContext(sourceID: playlistID, downloaded: downloaded)
    case .searchResults: ScrobbleContext(source: .search, downloaded: downloaded)
    case .dailyRecommendations, .recommendationHistory:
      ScrobbleContext(source: .recommendations, downloaded: downloaded)
    default: ScrobbleContext(downloaded: downloaded)
    }
  }
}

package enum PlaybackLifecycleEvent: Equatable, Sendable {
  case started(PlaybackLifecycleInstance)
  case finished(PlaybackLifecycleInstance, playedSeconds: Int, end: ScrobbleEnd = .completed)
}

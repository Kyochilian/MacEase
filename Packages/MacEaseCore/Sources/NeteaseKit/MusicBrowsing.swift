import Foundation

package enum PlaylistTagKind: String, CaseIterable, Sendable { case all, popular, highQuality }
package struct PlaylistTag: Equatable, Sendable, Identifiable {
  package let name: String
  package let category: String?
  package var id: String { name }
  package init(name: String, category: String? = nil) {
    self.name = name
    self.category = category
  }
}
package struct HotSearch: Equatable, Sendable, Identifiable {
  package let keyword: String
  package let description: String?
  package var id: String { keyword }
  package init(keyword: String, description: String? = nil) {
    self.keyword = keyword
    self.description = description
  }
}
package enum RecentMusicKind: String, CaseIterable, Sendable {
  case songs = "song"
  case albums = "album"
  case playlists = "playlist"
}
package enum RecentMusicResource: Equatable, Sendable {
  case song(Track)
  case album(Album)
  case playlist(DiscoveredPlaylist)
  package var name: String {
    switch self {
    case .song(let v): v.name
    case .album(let v): v.name
    case .playlist(let v): v.name
    }
  }
  package var resourceID: Int64 {
    switch self {
    case .song(let v): v.id
    case .album(let v): v.id
    case .playlist(let v): v.id
    }
  }
}
package struct RecentMusicEntry: Equatable, Sendable, Identifiable {
  package let resource: RecentMusicResource
  package let playedAt: Date
  package var id: String { "\(resource.resourceID)-\(playedAt.timeIntervalSince1970)" }
  package init(resource: RecentMusicResource, playedAt: Date) {
    self.resource = resource
    self.playedAt = playedAt
  }
}

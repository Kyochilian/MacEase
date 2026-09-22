import Foundation

extension NeteaseSession {
  package func artistSongs(artistID: Int64, limit: Int, offset: Int, credential: NeteaseCredential)
    async throws -> CatalogPage<Track>
  {
    struct Parameters: Encodable, Sendable {
      let id: Int64
      let private_cloud = "true"
      let work_type = 1
      let order = "hot"
      let offset: Int
      let limit: Int
    }
    struct Payload: Decodable {
      let songs: [SongRowPayload]
      let more: Bool
    }
    guard artistID > 0, (1...1000).contains(limit), offset >= 0 else {
      throw NeteaseCatalogError.invalidResponse
    }
    let data = try await eapiData(
      path: "/api/v1/artist/songs", fields: Parameters(id: artistID, offset: offset, limit: limit),
      credential: credential)
    let page = try JSONDecoder().decode(Payload.self, from: data)
    guard !page.more || !page.songs.isEmpty else { throw NeteaseCatalogError.invalidResponse }
    return CatalogPage(items: page.songs.map(\.track), more: page.more)
  }

  package func artistBiography(artistID: Int64, credential: NeteaseCredential) async throws
    -> String
  {
    struct Payload: Decodable {
      let briefDesc: String?
      let introduction: [Paragraph]?
      struct Paragraph: Decodable {
        let ti: String?
        let txt: String
      }
    }
    let data = try await weapiData(
      path: "/api/artist/introduction", fields: ["id": String(artistID)], credential: credential)
    let payload = try JSONDecoder().decode(Payload.self, from: data)
    guard payload.briefDesc != nil || payload.introduction != nil else {
      throw NeteaseCatalogError.invalidResponse
    }
    return
      ([payload.briefDesc].compactMap { $0 }
      + (payload.introduction ?? []).map {
        [$0.ti, $0.txt].compactMap { $0 }.joined(separator: "\n")
      }).filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  package func playlistTags(kind: PlaylistTagKind, credential: NeteaseCredential) async throws
    -> [PlaylistTag]
  {
    struct Tag: Decodable {
      let name: String
      let category: Int?
    }
    struct Catalogue: Decodable {
      let sub: [Tag]
      let categories: [String: String]
    }
    struct Quality: Decodable { let tags: [Tag] }
    struct Popular: Decodable {
      let tags: [Item]
      struct Item: Decodable { let playlistTag: Tag }
    }
    let empty: [String: String] = [:]
    let tags: [PlaylistTag]
    switch kind {
    case .all:
      let data = try await eapiData(
        path: "/api/playlist/catalogue", fields: empty, credential: credential)
      let result = try JSONDecoder().decode(Catalogue.self, from: data)
      tags = result.sub.map {
        PlaylistTag(name: $0.name, category: $0.category.flatMap { result.categories[String($0)] })
      }
    case .popular:
      let data = try await weapiData(
        path: "/api/playlist/hottags", fields: empty, credential: credential)
      tags = try JSONDecoder().decode(Popular.self, from: data).tags.map {
        PlaylistTag(name: $0.playlistTag.name)
      }
    case .highQuality:
      let data = try await weapiData(
        path: "/api/playlist/highquality/tags", fields: empty, credential: credential)
      tags = try JSONDecoder().decode(Quality.self, from: data).tags.map {
        PlaylistTag(name: $0.name)
      }
    }
    var seen = Set<String>()
    return tags.filter { !$0.name.isEmpty && seen.insert($0.name).inserted }
  }

  package func hotSearches(credential: NeteaseCredential) async throws -> [HotSearch] {
    struct Payload: Decodable {
      let data: [Item]
      struct Item: Decodable {
        let searchWord: String
        let content: String?
      }
    }
    let data = try await weapiData(
      path: "/api/hotsearchlist/get", fields: [String: String](), credential: credential)
    var seen = Set<String>()
    return try JSONDecoder().decode(Payload.self, from: data).data
      .filter { !$0.searchWord.isEmpty && seen.insert($0.searchWord).inserted }
      .map { HotSearch(keyword: $0.searchWord, description: $0.content) }
  }

  package func recommendationHistoryDates(credential: NeteaseCredential) async throws -> [String] {
    struct Payload: Decodable {
      let data: Dates
      struct Dates: Decodable { let dates: [String] }
    }
    let data = try await weapiData(
      path: "/api/discovery/recommend/songs/history/recent", fields: [String: String](),
      credential: credential)
    return try JSONDecoder().decode(Payload.self, from: data).data.dates
  }

  package func recommendationHistory(date: String, credential: NeteaseCredential) async throws
    -> [Track]
  {
    struct Payload: Decodable {
      let data: Songs
      struct Songs: Decodable { let songs: [SongRowPayload] }
    }
    let data = try await weapiData(
      path: "/api/discovery/recommend/songs/history/detail", fields: ["date": date],
      credential: credential)
    return try JSONDecoder().decode(Payload.self, from: data).data.songs.map(\.track)
  }

  package func recentMusic(kind: RecentMusicKind, credential: NeteaseCredential) async throws
    -> [RecentMusicEntry]
  {
    let data = try await weapiData(
      path: "/api/play-record/\(kind.rawValue)/list", fields: ["limit": 100], credential: credential
    )
    let entries: [RecentMusicEntry]
    switch kind {
    case .songs:
      entries = try JSONDecoder().decode(RecentMusicPayload<SongRowPayload>.self, from: data).data
        .list.map {
          RecentMusicEntry(
            resource: .song($0.data.track),
            playedAt: Date(timeIntervalSince1970: Double($0.playTime) / 1000))
        }
    case .albums:
      entries = try JSONDecoder().decode(RecentMusicPayload<AlbumRowPayload>.self, from: data).data
        .list.map {
          RecentMusicEntry(
            resource: .album($0.data.album),
            playedAt: Date(timeIntervalSince1970: Double($0.playTime) / 1000))
        }
    case .playlists:
      entries = try JSONDecoder().decode(RecentMusicPayload<PlaylistRowPayload>.self, from: data)
        .data.list.map {
          RecentMusicEntry(
            resource: .playlist($0.data.playlist),
            playedAt: Date(timeIntervalSince1970: Double($0.playTime) / 1000))
        }
    }
    guard entries.allSatisfy({ $0.playedAt.timeIntervalSince1970 > 0 }) else {
      throw NeteaseCatalogError.invalidResponse
    }
    return entries.sorted { $0.playedAt > $1.playedAt }
  }
}

private struct RecentMusicPayload<Resource: Decodable>: Decodable {
  let data: Page
  struct Page: Decodable { let list: [Item] }
  struct Item: Decodable {
    let playTime: Int64
    let data: Resource
  }
}

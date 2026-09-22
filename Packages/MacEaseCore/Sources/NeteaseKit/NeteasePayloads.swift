import Foundation

/// One song as NetEase returns it inside any list response.
///
/// The catalogue serves songs in two shapes. The modern endpoints — song
/// detail, cloudsearch, daily recommendations, listening rankings — use `ar`,
/// `al` and `dt`. The legacy ones — `simiSong` — use `artists`, `album` and
/// `duration` for exactly the same fields. Five payload types each declared
/// their own nested `Song` and `Artist`, so a field added for one list had to
/// be added five times and the legacy spelling had already caused one bug.
struct SongRowPayload: Decodable {
  let id: Int64
  let name: String
  let artists: [ArtistRow]
  let album: AlbumRow?
  let durationMilliseconds: Int?
  let aliases: [String]?
  let translations: [String]?
  let disc: String?
  let trackNumber: Int?
  let fee: Int?
  let privilege: SongPrivilegePayload?
  let songType: Int?
  let matchedSongID: Int64?

  struct ArtistRow: Decodable {
    let id: Int64?
    let name: String
  }

  struct AlbumRow: Decodable {
    let id: Int64?
    let name: String?
    let picUrl: String?
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case ar
    case artists
    case al
    case album
    case dt
    case duration
    case alia, tns, cd, no, fee, privilege, t, s_id
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int64.self, forKey: .id)
    songType = try container.decodeIfPresent(Int.self, forKey: .t)
    matchedSongID = try container.decodeIfPresent(Int64.self, forKey: .s_id)
    if songType == 1 || songType == 2 {
      name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Cloud file"
    } else {
      name = try container.decode(String.self, forKey: .name)
    }
    artists =
      try container.decodeIfPresent([ArtistRow].self, forKey: .ar)
      ?? container.decodeIfPresent([ArtistRow].self, forKey: .artists)
      ?? []
    album =
      try container.decodeIfPresent(AlbumRow.self, forKey: .al)
      ?? container.decodeIfPresent(AlbumRow.self, forKey: .album)
    durationMilliseconds =
      try container.decodeIfPresent(Int.self, forKey: .dt)
      ?? container.decodeIfPresent(Int.self, forKey: .duration)
    aliases = try container.decodeIfPresent([String].self, forKey: .alia)
    translations = try container.decodeIfPresent([String].self, forKey: .tns)
    disc = try container.decodeIfPresent(String.self, forKey: .cd)
    trackNumber = try container.decodeIfPresent(Int.self, forKey: .no)
    fee = try container.decodeIfPresent(Int.self, forKey: .fee)
    privilege = try container.decodeIfPresent(SongPrivilegePayload.self, forKey: .privilege)
  }

  /// The domain track.
  ///
  /// NetEase writes "no artist page for this" as a missing `id` on some rows
  /// and as `id: 0` on others; both mean the same thing, so both become nil.
  var track: Track {
    Track(
      id: id,
      name: name,
      artists: artists.map { ArtistRef(id: Self.navigableID($0.id), name: $0.name) },
      album: album.flatMap { row in
        guard let name = row.name, !name.isEmpty else { return nil }
        return AlbumRef(
          id: Self.navigableID(row.id),
          name: name,
          artworkURL: NeteaseArtworkURL.approved(row.picUrl)
        )
      },
      durationMilliseconds: durationMilliseconds,
      cloudFileID: songType == 1 || songType == 2 ? id : nil,
      catalogSongID: songType == 2 && matchedSongID != id ? Self.navigableID(matchedSongID) : nil,
      aliases: aliases, translations: translations, disc: disc, trackNumber: trackNumber,
      fee: fee, privilege: privilege?.value
    )
  }

  static func navigableID(_ id: Int64?) -> Int64? {
    guard let id, id > 0 else { return nil }
    return id
  }
}

struct SongPrivilegePayload: Decodable {
  let id: Int64?
  let st: Int?
  let pl: Int?
  let dl: Int?
  var value: SongPrivilege { SongPrivilege(status: st, playBitRate: pl, downloadBitRate: dl) }
}

/// One album row, as the collected-albums list returns it.
struct AlbumRowPayload: Decodable {
  let id: Int64
  let name: String
  let picUrl: String?
  let size: Int?
  let artists: [SongRowPayload.ArtistRow]?
  let artist: SongRowPayload.ArtistRow?
  let description: String?
  let publishTime: Int64?
  let company: String?

  var album: Album {
    Album(
      id: id,
      name: name,
      // The list returns `artists` for a compilation and a single `artist`
      // for everything else; neither alone covers both.
      artists: (artists ?? artist.map { [$0] } ?? [])
        .map { ArtistRef(id: SongRowPayload.navigableID($0.id), name: $0.name) },
      artworkURL: NeteaseArtworkURL.approved(picUrl),
      trackCount: size ?? 0,
      description: description,
      releaseDate: publishTime.flatMap {
        $0 > 0 ? Date(timeIntervalSince1970: Double($0) / 1000) : nil
      },
      company: company
    )
  }
}

/// One artist row, as the followed-artists list returns it.
struct ArtistRowPayload: Decodable {
  let id: Int64
  let name: String
  let picUrl: String?
  let img1v1Url: String?
  let albumSize: Int?
  let musicSize: Int?
  let briefDesc: String?

  var artist: Artist {
    Artist(
      id: id,
      name: name,
      // `picUrl` is the artist's own photo and `img1v1Url` the square
      // fallback the service substitutes when there is none.
      artworkURL: NeteaseArtworkURL.approved(picUrl)
        ?? NeteaseArtworkURL.approved(img1v1Url),
      albumCount: albumSize ?? 0,
      songCount: musicSize ?? 0,
      biography: briefDesc
    )
  }
}

/// One playlist row, as any list response returns it.
///
/// The cover is `coverImgUrl` on the playlist-shaped endpoints (toplist,
/// playlist detail, browse) and `picUrl` on the recommendation-shaped ones.
/// They are the same field, so one row decoder reads both rather than each
/// caller learning which spelling its endpoint happens to use.
struct PlaylistRowPayload: Decodable {
  let id: Int64
  let name: String
  let artworkURL: URL?

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case coverImgUrl
    case picUrl
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int64.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    artworkURL =
      try NeteaseArtworkURL.approved(
        container.decodeIfPresent(String.self, forKey: .coverImgUrl)
      )
      ?? NeteaseArtworkURL.approved(
        container.decodeIfPresent(String.self, forKey: .picUrl)
      )
  }

  var playlist: DiscoveredPlaylist {
    DiscoveredPlaylist(id: id, name: name, artworkURL: artworkURL)
  }
}

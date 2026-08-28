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
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int64.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
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
      durationMilliseconds: durationMilliseconds
    )
  }

  static func navigableID(_ id: Int64?) -> Int64? {
    guard let id, id > 0 else { return nil }
    return id
  }
}

/// One album row, as the collected-albums list returns it.
struct AlbumRowPayload: Decodable {
  let id: Int64
  let name: String
  let picUrl: String?
  let size: Int?
  let artists: [SongRowPayload.ArtistRow]?
  let artist: SongRowPayload.ArtistRow?

  var album: Album {
    Album(
      id: id,
      name: name,
      // The list returns `artists` for a compilation and a single `artist`
      // for everything else; neither alone covers both.
      artists: (artists ?? artist.map { [$0] } ?? [])
        .map { ArtistRef(id: SongRowPayload.navigableID($0.id), name: $0.name) },
      artworkURL: NeteaseArtworkURL.approved(picUrl),
      trackCount: size ?? 0
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

  var artist: Artist {
    Artist(
      id: id,
      name: name,
      // `picUrl` is the artist's own photo and `img1v1Url` the square
      // fallback the service substitutes when there is none.
      artworkURL: NeteaseArtworkURL.approved(picUrl)
        ?? NeteaseArtworkURL.approved(img1v1Url),
      albumCount: albumSize ?? 0,
      songCount: musicSize ?? 0
    )
  }
}

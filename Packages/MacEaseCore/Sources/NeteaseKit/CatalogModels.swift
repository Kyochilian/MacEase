import Foundation

/// The hosts MacEase is willing to load NetEase-served content from.
///
/// Playback used to carry this rule inline, so when artwork arrived it would
/// have needed a second copy of the same list. Both media and images are
/// addresses chosen by the server, which is untrusted input, so they are
/// approved in one place.
package enum NeteaseResourceHost {
  /// True for `music.126.net` and `music.163.com` and their subdomains. The
  /// CDN serves audio from `*.music.126.net` and artwork from
  /// `p1..p4.music.126.net`, which this covers without naming each shard.
  package static func isApproved(_ host: String) -> Bool {
    let host = host.lowercased()
    return isAudioCDN(host)
      || host == "music.163.com" || host.hasSuffix(".music.163.com")
  }

  package static func isAudioCDN(_ host: String) -> Bool {
    let host = host.lowercased()
    return host == "music.126.net" || host.hasSuffix(".music.126.net")
  }
}

/// An artwork address the server supplied.
///
/// Artwork is decorative: a URL MacEase will not load is dropped to `nil`
/// rather than failing the request that carried it, because a missing cover
/// must not stop a playlist from opening. It is still validated — the point is
/// that the app never issues a request to a host NetEase did not serve from.
package enum NeteaseArtworkURL {
  package static func approved(_ value: String?) -> URL? {
    guard
      let value,
      let url = URL(string: value),
      let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http",
      let host = url.host,
      NeteaseResourceHost.isApproved(host)
    else { return nil }
    // NetEase returns http for some legacy rows. MacEase upgrades rather than
    // refusing: the same object is served over TLS on the same host.
    guard scheme == "http" else { return url }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.scheme = "https"
    return components?.url
  }

  /// The same image scaled server-side to a `pixels` × `pixels` square.
  ///
  /// The image CDN resizes on a `param=WxH` query, which api-enhanced
  /// d55d92cd0031d7c7746b7068faecd7ade1d354ac uses in `public/ugc.html`
  /// (`?param=50y50`, `?param=100y100`) and strips in
  /// `module/related_playlist.js`. Without it every cover is the original
  /// upload, commonly a megabyte or more for a row drawn at 36 points.
  /// Any `param` already present is replaced so one image has one address per size.
  package static func sized(_ url: URL, pixels: Int) -> URL {
    guard pixels > 0,
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return url }
    var items = (components.queryItems ?? []).filter { $0.name != "param" }
    items.append(URLQueryItem(name: "param", value: "\(pixels)y\(pixels)"))
    components.queryItems = items
    return components.url ?? url
  }
}

/// An artist as it appears inside another object.
///
/// Track rows carried artist *names* only, so an artist could be shown but
/// never opened, and the artist-follow list had nothing to join against.
///
/// `id` is optional because NetEase itself serves rows without one — an
/// unattributed upload, or a name it holds no artist page for. Those are
/// displayed and not navigable, which is the truth; a placeholder id would
/// produce a row that opens onto nothing.
package struct ArtistRef: Equatable, Hashable, Sendable, Codable {
  package let id: Int64?
  package let name: String

  package init(id: Int64?, name: String) {
    self.id = id
    self.name = name
  }
}

/// An album as it appears inside a track. `artworkURL` is the only artwork
/// address NetEase gives for a track, which is why cover art hangs off the
/// album rather than the track.
package struct AlbumRef: Equatable, Hashable, Sendable, Codable {
  package let id: Int64?
  package let name: String
  package let artworkURL: URL?

  package init(id: Int64?, name: String, artworkURL: URL?) {
    self.id = id
    self.name = name
    self.artworkURL = artworkURL
  }
}

/// One playable song.
///
/// This was `PlaylistTrack`, which named where the first caller found it
/// rather than what it is: search results, daily recommendations, similar
/// songs, listening rankings and the cloud drive all produce the same thing.
package struct Track: Equatable, Hashable, Sendable, Codable, Identifiable {
  package var id: Int64
  package var cloudFileID: Int64?
  package var catalogSongID: Int64?
  package let name: String
  package let artists: [ArtistRef]
  package let album: AlbumRef?
  /// Track length as the catalogue reports it. Playback still takes its
  /// duration from the decoded asset; this is what a list can show before
  /// anything has been resolved.
  package let durationMilliseconds: Int?
  package let aliases: [String]?
  package let translations: [String]?
  package let disc: String?
  package let trackNumber: Int?
  package let fee: Int?
  package var privilege: SongPrivilege?

  package init(
    id: Int64,
    name: String,
    artists: [ArtistRef] = [],
    album: AlbumRef? = nil,
    durationMilliseconds: Int? = nil,
    cloudFileID: Int64? = nil,
    catalogSongID: Int64? = nil,
    aliases: [String]? = nil,
    translations: [String]? = nil,
    disc: String? = nil,
    trackNumber: Int? = nil,
    fee: Int? = nil,
    privilege: SongPrivilege? = nil
  ) {
    self.id = id
    self.name = name
    self.artists = artists
    self.album = album
    self.durationMilliseconds = durationMilliseconds
    self.cloudFileID = cloudFileID
    self.catalogSongID = catalogSongID
    self.aliases = aliases
    self.translations = translations
    self.disc = disc
    self.trackNumber = trackNumber
    self.fee = fee
    self.privilege = privilege
  }

  package var artistNames: [String] { artists.map(\.name) }

  /// Public catalog actions use the matched song, while playback/downloads
  /// retain the cloud file ID. An unmatched upload has no catalog identity.
  package var catalogIdentity: Int64? {
    let candidate = cloudFileID == nil ? id : catalogSongID
    guard let candidate, candidate > 0 else { return nil }
    return candidate
  }

  /// The one place artist names are joined for display, so the separator does
  /// not drift between the track list, Now Playing and the lyrics header.
  package var artistDisplayName: String? {
    artists.isEmpty ? nil : artists.map(\.name).joined(separator: ", ")
  }

  package var artworkURL: URL? { album?.artworkURL }
  package var playbackNotice: String? {
    if cloudFileID != nil { return nil }
    if let status = privilege?.status, status < 0 { return "Currently unavailable" }
    if privilege?.playBitRate == 0 { return "Playback may be limited to a preview" }
    if let rate = privilege?.playBitRate, rate > 0 { return nil }
    if let fee, fee == 1 || fee == 8 { return "Membership may be required" }
    if fee == 4 { return "Album purchase may be required" }
    return nil
  }

  package var durationSeconds: Double? {
    guard let durationMilliseconds, durationMilliseconds > 0 else { return nil }
    return Double(durationMilliseconds) / 1000
  }
}

package struct SongPrivilege: Equatable, Hashable, Sendable, Codable {
  package let status: Int?
  package let playBitRate: Int?
  package let downloadBitRate: Int?
  package init(status: Int?, playBitRate: Int?, downloadBitRate: Int?) {
    self.status = status
    self.playBitRate = playBitRate
    self.downloadBitRate = downloadBitRate
  }
}

/// A full album row, as returned by the collected-albums list.
package struct Album: Equatable, Sendable, Codable, Identifiable {
  package let id: Int64
  package let name: String
  package let artists: [ArtistRef]
  package let artworkURL: URL?
  package var trackCount: Int
  package let description: String?
  package let releaseDate: Date?
  package let company: String?

  package init(
    id: Int64,
    name: String,
    artists: [ArtistRef],
    artworkURL: URL?,
    trackCount: Int,
    description: String? = nil,
    releaseDate: Date? = nil,
    company: String? = nil
  ) {
    self.id = id
    self.name = name
    self.artists = artists
    self.artworkURL = artworkURL
    self.trackCount = trackCount
    self.description = description
    self.releaseDate = releaseDate
    self.company = company
  }

  package var artistDisplayName: String? {
    artists.isEmpty ? nil : artists.map(\.name).joined(separator: ", ")
  }
}

/// A full artist row, as returned by the followed-artists list.
package struct Artist: Equatable, Sendable, Codable, Identifiable {
  package let id: Int64
  package let name: String
  package let artworkURL: URL?
  package let albumCount: Int
  package let songCount: Int
  package let biography: String?

  package init(
    id: Int64,
    name: String,
    artworkURL: URL?,
    albumCount: Int,
    songCount: Int,
    biography: String? = nil
  ) {
    self.id = id
    self.name = name
    self.artworkURL = artworkURL
    self.albumCount = albumCount
    self.songCount = songCount
    self.biography = biography
  }
}

/// A page of a collection the server pages through by offset.
///
/// The collected-albums, followed-artists and cloud-drive endpoints all report
/// "is there more" the same way, and each had started to grow its own pair of
/// `items`/`more` fields.
package struct CatalogPage<Item: Equatable & Sendable>: Equatable, Sendable {
  package let items: [Item]
  package let more: Bool

  package init(items: [Item], more: Bool) {
    self.items = items
    self.more = more
  }
}

/// A song stored in the account's cloud drive.
///
/// `track` is the catalogue entry NetEase matched the upload to. `fileName`
/// and `fileSize` describe the upload itself, which is what the drive's
/// capacity is spent on and what the user recognises when deleting.
package struct CloudSong: Equatable, Sendable, Identifiable {
  package let id: Int64
  package let track: Track
  package let fileName: String
  package let fileSize: Int64

  package init(id: Int64, track: Track, fileName: String, fileSize: Int64) {
    self.id = id
    self.track = track
    self.fileName = fileName
    self.fileSize = fileSize
  }
}

/// How much of the cloud drive is in use.
package struct CloudCapacity: Equatable, Sendable {
  package let usedBytes: Int64
  package let totalBytes: Int64

  package init(usedBytes: Int64, totalBytes: Int64) {
    self.usedBytes = usedBytes
    self.totalBytes = totalBytes
  }
}

/// One page of the cloud drive, with the capacity the same response reports.
package struct CloudPage: Equatable, Sendable {
  package let songs: [CloudSong]
  package let more: Bool
  package let capacity: CloudCapacity

  package init(songs: [CloudSong], more: Bool, capacity: CloudCapacity) {
    self.songs = songs
    self.more = more
    self.capacity = capacity
  }
}

// MARK: - Browsing the catalogue

package enum PlaylistCategory {
  package static let `default` = "全部"
}

/// The order `/playlist/list` sorts a category by.
package enum PlaylistOrder: String, CaseIterable, Sendable {
  case hot
  case new
}

/// One page of the highest-rated playlists.
///
/// Unlike every other paged list here, this one is not paged by offset: the
/// service returns the `updateTime` of the last row and expects it back as
/// `lasttime`, so the cursor travels with the page rather than being counted
/// by the client.
package struct HighQualityPlaylistPage: Equatable, Sendable {
  package let playlists: [DiscoveredPlaylist]
  package let more: Bool
  /// Pass as `before` to fetch the next page.
  package let before: Int64

  package init(playlists: [DiscoveredPlaylist], more: Bool, before: Int64) {
    self.playlists = playlists
    self.more = more
    self.before = before
  }
}

/// The regions `/album/new` filters by.
package enum AlbumArea: String, CaseIterable, Sendable {
  case all = "ALL"
  case chinese = "ZH"
  case western = "EA"
  case korean = "KR"
  case japanese = "JP"
}

/// An album page: what the album is, and what is on it.
package struct AlbumDetail: Equatable, Sendable {
  package let album: Album
  package let tracks: [Track]

  package init(album: Album, tracks: [Track]) {
    self.album = album
    self.tracks = tracks
  }
}

/// The parts of an album that change without the album changing.
///
/// Both fields are optional because the endpoint omits them for an album the
/// account has no relationship with, and "unknown" must not be shown as "not
/// collected" — that would offer a toggle whose starting value was a guess.
package struct AlbumDynamic: Equatable, Sendable {
  package let isCollected: Bool?
  package let collectCount: Int?

  package init(isCollected: Bool?, collectCount: Int?) {
    self.isCollected = isCollected
    self.collectCount = collectCount
  }
}

/// An artist page: who they are, and the songs the service ranks highest.
package struct ArtistDetail: Equatable, Sendable {
  package let artist: Artist
  package let hotSongs: [Track]

  package init(artist: Artist, hotSongs: [Track]) {
    self.artist = artist
    self.hotSongs = hotSongs
  }
}

// MARK: - Search

/// What a search is looking for. The raw values are the `type` cloudsearch
/// takes; MacEase offers the four kinds it can actually open.
package enum SearchScope: Int, CaseIterable, Sendable, Hashable {
  case songs = 1
  case albums = 10
  case artists = 100
  case playlists = 1000
}

/// A search result set, in the shape the requested scope returns.
///
/// One case per scope rather than four optional arrays: a song search cannot
/// produce artists, so a type that allows it would push the impossible case
/// out to every caller.
package enum SearchItems: Equatable, Sendable {
  case songs([Track])
  case albums([Album])
  case artists([Artist])
  case playlists([DiscoveredPlaylist])

  package static func empty(_ scope: SearchScope) -> SearchItems {
    switch scope {
    case .songs: .songs([])
    case .albums: .albums([])
    case .artists: .artists([])
    case .playlists: .playlists([])
    }
  }

  package var scope: SearchScope {
    switch self {
    case .songs: .songs
    case .albums: .albums
    case .artists: .artists
    case .playlists: .playlists
    }
  }

  package var count: Int {
    switch self {
    case .songs(let items): items.count
    case .albums(let items): items.count
    case .artists(let items): items.count
    case .playlists(let items): items.count
    }
  }

  package var isEmpty: Bool { count == 0 }

  /// Appends the next page, dropping rows already held.
  ///
  /// The service repeats rows across pages when the result set shifts between
  /// requests, so identity is the row's id rather than its position. A scope
  /// change resets the list before the request is sent, so the mismatched case
  /// cannot arise from paging; if it ever did, the newer page wins rather than
  /// two unlike kinds being concatenated.
  package func appending(_ page: SearchItems) -> SearchItems {
    switch (self, page) {
    case (.songs(let held), .songs(let next)):
      .songs(held + Self.fresh(next, notIn: held.map(\.id)))
    case (.albums(let held), .albums(let next)):
      .albums(held + Self.fresh(next, notIn: held.map(\.id)))
    case (.artists(let held), .artists(let next)):
      .artists(held + Self.fresh(next, notIn: held.map(\.id)))
    case (.playlists(let held), .playlists(let next)):
      .playlists(held + Self.fresh(next, notIn: held.map(\.id)))
    default:
      page
    }
  }

  private static func fresh<Item>(
    _ next: [Item],
    notIn heldIDs: [Int64]
  ) -> [Item] where Item: Identifiable, Item.ID == Int64 {
    var seen = Set(heldIDs)
    return next.filter { seen.insert($0.id).inserted }
  }
}

/// One page of search results, with what the service says the whole set holds.
package struct SearchPage: Equatable, Sendable {
  package let items: SearchItems
  /// nil when the response did not report a count for this scope; paging then
  /// falls back to "a full page means there may be more".
  package let totalCount: Int?

  package init(items: SearchItems, totalCount: Int?) {
    self.items = items
    self.totalCount = totalCount
  }
}

/// One row of the as-you-type suggestion list.
///
/// A suggestion only ever fills the search field: choosing one never runs a
/// search by itself, so it carries the text to insert and the context that
/// tells the user which of several same-named rows they picked.
package struct SearchSuggestion: Equatable, Sendable, Identifiable {
  package let id: String
  package let keyword: String
  package let detail: String?

  package init(id: String, keyword: String, detail: String?) {
    self.id = id
    self.keyword = keyword
    self.detail = detail
  }
}

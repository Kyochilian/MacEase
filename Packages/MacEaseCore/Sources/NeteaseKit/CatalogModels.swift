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
    return host == "music.126.net" || host.hasSuffix(".music.126.net")
      || host == "music.163.com" || host.hasSuffix(".music.163.com")
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
  package let id: Int64
  package let name: String
  package let artists: [ArtistRef]
  package let album: AlbumRef?
  /// Track length as the catalogue reports it. Playback still takes its
  /// duration from the decoded asset; this is what a list can show before
  /// anything has been resolved.
  package let durationMilliseconds: Int?

  package init(
    id: Int64,
    name: String,
    artists: [ArtistRef] = [],
    album: AlbumRef? = nil,
    durationMilliseconds: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.artists = artists
    self.album = album
    self.durationMilliseconds = durationMilliseconds
  }

  package var artistNames: [String] { artists.map(\.name) }

  /// The one place artist names are joined for display, so the separator does
  /// not drift between the track list, Now Playing and the lyrics header.
  package var artistDisplayName: String? {
    artists.isEmpty ? nil : artists.map(\.name).joined(separator: ", ")
  }

  package var artworkURL: URL? { album?.artworkURL }

  package var durationSeconds: Double? {
    guard let durationMilliseconds, durationMilliseconds > 0 else { return nil }
    return Double(durationMilliseconds) / 1000
  }
}

/// A full album row, as returned by the collected-albums list.
package struct Album: Equatable, Sendable, Codable, Identifiable {
  package let id: Int64
  package let name: String
  package let artists: [ArtistRef]
  package let artworkURL: URL?
  package let trackCount: Int

  package init(
    id: Int64,
    name: String,
    artists: [ArtistRef],
    artworkURL: URL?,
    trackCount: Int
  ) {
    self.id = id
    self.name = name
    self.artists = artists
    self.artworkURL = artworkURL
    self.trackCount = trackCount
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

  package init(
    id: Int64,
    name: String,
    artworkURL: URL?,
    albumCount: Int,
    songCount: Int
  ) {
    self.id = id
    self.name = name
    self.artworkURL = artworkURL
    self.albumCount = albumCount
    self.songCount = songCount
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

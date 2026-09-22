import Foundation
import NeteaseKit

/// Where a queue came from.
///
/// A restored queue that says only "these forty tracks" cannot tell the user
/// what they were listening to, and cannot offer to reload it. Every case here
/// is a place the app actually starts playback from; there are no others
/// reserved for later.
package enum PlaybackContext: Equatable, Sendable, Codable {
  /// Older stored queues did not retain each entry's source.
  case unknown
  case song(id: Int64, name: String)
  case playlist(id: Int64, name: String)
  case album(id: Int64, name: String)
  case artist(id: Int64, name: String)
  case dailyRecommendations
  case recommendationHistory(date: String)
  case recommendedNewSongs
  case searchResults(keywords: String)
  case similarSongs(seedName: String)
  case listeningRankings
  case recentListening
  case cloudDrive
  case downloads
  case personalFM
  case heartbeatMode(seedName: String, playlistID: Int64? = nil, seedSongID: Int64? = nil)

  package var label: String {
    switch self {
    case .unknown: "Unknown source"
    case .song(_, let name): name
    case .playlist(_, let name): name
    case .album(_, let name): "Album: \(name)"
    case .artist(_, let name): "Artist: \(name)"
    case .dailyRecommendations: "Daily recommendations"
    case .recommendationHistory(let date): "Recommendations: \(date)"
    case .recommendedNewSongs: "Recommended new songs"
    case .searchResults(let keywords): "Search: \(keywords)"
    case .similarSongs(let seedName): "Similar to \(seedName)"
    case .listeningRankings: "Listening rankings"
    case .recentListening: "Recently played"
    case .cloudDrive: "Cloud drive"
    case .downloads: "Downloads"
    case .personalFM: "Personal FM"
    case .heartbeatMode(let seedName, _, _): "Heartbeat from \(seedName)"
    }
  }
}

package struct ListeningHistoryEntry: Equatable, Sendable, Codable, Identifiable {
  package let id: UUID
  package let track: Track
  package let context: PlaybackContext
  package let playedAt: Date
  package init(id: UUID, track: Track, context: PlaybackContext, playedAt: Date) {
    self.id = id
    self.track = track
    self.context = context
    self.playedAt = playedAt
  }
}

/// Everything needed to put the user back where they were.
///
/// It holds no URL. A song URL expires in minutes, so a queue restored from
/// yesterday would carry an address that is guaranteed dead; the position and
/// the track are what survive, and resuming re-resolves.
package struct PersistedQueue: Equatable, Sendable, Codable {
  package let tracks: [Track]
  package let currentIndex: Int
  package let mode: PlaybackMode
  package let context: PlaybackContext
  package let trackContexts: [PlaybackContext]
  package let positionSeconds: Double
  package let quality: PlaybackQuality
  /// Whether audio was running when this was written, so restoring a paused
  /// queue does not start playing on launch.
  package let wasPlaying: Bool

  package init(
    tracks: [Track],
    currentIndex: Int,
    mode: PlaybackMode,
    context: PlaybackContext,
    trackContexts: [PlaybackContext]? = nil,
    positionSeconds: Double,
    quality: PlaybackQuality,
    wasPlaying: Bool
  ) {
    self.tracks = tracks
    // Storage is a boundary like any other: an index that does not name a
    // track is clamped here rather than being handed to playback.
    self.currentIndex = tracks.isEmpty ? 0 : min(max(0, currentIndex), tracks.count - 1)
    self.mode = mode
    self.context = context
    assert(trackContexts == nil || trackContexts?.count == tracks.count)
    self.trackContexts = trackContexts ?? Array(repeating: context, count: tracks.count)
    self.positionSeconds =
      positionSeconds.isFinite ? max(0, positionSeconds) : 0
    self.quality = quality
    self.wasPlaying = wasPlaying
  }

  /// Stored bytes are untrusted for the same reason Keychain bytes are: an
  /// older build, a partial write or a hand-edited file can all produce a row
  /// that satisfies the type but not the type's rules. Synthesised decoding
  /// would assign the properties directly and skip the clamping above, so it
  /// is routed back through the initialiser that enforces it.
  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let tracks = try container.decode([Track].self, forKey: .tracks)
    let contexts = try container.decodeIfPresent([PlaybackContext].self, forKey: .trackContexts)
      ?? Array(repeating: .unknown, count: tracks.count)
    guard contexts.count == tracks.count else {
      throw DecodingError.dataCorruptedError(
        forKey: .trackContexts, in: container, debugDescription: "Queue source count does not match tracks")
    }
    self.init(
      tracks: tracks,
      currentIndex: try container.decode(Int.self, forKey: .currentIndex),
      mode: try container.decode(PlaybackMode.self, forKey: .mode),
      context: try container.decode(PlaybackContext.self, forKey: .context),
      trackContexts: contexts,
      positionSeconds: try container.decode(Double.self, forKey: .positionSeconds),
      quality: try container.decode(PlaybackQuality.self, forKey: .quality),
      wasPlaying: try container.decode(Bool.self, forKey: .wasPlaying)
    )
  }
}

package enum LibraryStoreError: Error, Equatable, Sendable {
  /// SQLite refused, with its own result code.
  case sqlite(Int32)
  /// A stored row decoded into something that is not what it claims to be.
  case corruptRow
  /// The system reported no Application Support directory, so there is
  /// nowhere the store is allowed to live.
  case noApplicationSupportDirectory
}

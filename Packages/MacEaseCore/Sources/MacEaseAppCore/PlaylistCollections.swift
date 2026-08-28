import Foundation
import NeteaseKit

/// Whether a locally held collection still corresponds to what the server
/// would return for the same cursor.
package enum CollectionFreshness: Equatable, Sendable {
  case empty
  case current
  /// A write changed the server-side collection, so the cursor this client
  /// holds no longer names the same position. Paging must not continue from
  /// it; the user reloads explicitly.
  case staleAfterMutation
}

/// The user's playlists plus the cursor the next page would use.
///
/// The offset used to be derived from `playlists.count`. Creating,
/// subscribing, unsubscribing or deleting changes the server-side set, so
/// after any of those the visible count stopped naming the same server
/// position and Load More could skip or duplicate rows.
package struct PlaylistCollection: Equatable, Sendable {
  package private(set) var playlists: [UserPlaylist] = []
  /// Advanced only by what a successful page actually returned.
  package private(set) var nextOffset = 0
  package private(set) var serverHasMore = false
  package private(set) var freshness: CollectionFreshness = .empty
  package init() {}

  package var canLoadMore: Bool { serverHasMore && freshness == .current }

  /// True when there is more to fetch but the cursor can no longer be trusted.
  package var needsExplicitReload: Bool {
    freshness == .staleAfterMutation
  }

  package mutating func reset() {
    self = PlaylistCollection()
  }

  package mutating func apply(
    page: UserPlaylistPage,
    replacingAll: Bool
  ) {
    if replacingAll {
      playlists = []
      nextOffset = 0
    }
    playlists.append(contentsOf: page.playlists)
    nextOffset += page.playlists.count
    serverHasMore = page.more
    freshness = .current
  }

  /// Called after any write that changes which playlists the account has, or
  /// in what order the server returns them.
  package mutating func markStaleAfterMutation() {
    freshness = .staleAfterMutation
  }

  /// Seeds the list from what was stored for this account at the last launch.
  ///
  /// It is marked stale on purpose. These rows are what the server said some
  /// time ago, so they are worth showing instead of an empty window, but the
  /// cursor they came with no longer names a server position and paging from
  /// it could skip or repeat rows. Reloading replaces them.
  package mutating func restore(_ playlists: [UserPlaylist]) {
    guard self.playlists.isEmpty, !playlists.isEmpty else { return }
    self.playlists = playlists
    nextOffset = 0
    serverHasMore = false
    freshness = .staleAfterMutation
  }

  package mutating func remove(id: Int64) {
    playlists.removeAll { $0.id == id }
  }

  package mutating func replace(_ playlist: UserPlaylist) {
    guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else {
      return
    }
    playlists[index] = playlist
  }

  /// Keeps the row's track count in step with a track that was added to or
  /// removed from that playlist.
  package mutating func adjustTrackCount(playlistID: Int64, by delta: Int) {
    guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
      return
    }
    let existing = playlists[index]
    playlists[index] = UserPlaylist(
      id: existing.id,
      name: existing.name,
      trackCount: max(0, existing.trackCount + delta),
      owned: existing.owned
    )
  }
}

/// The tracks of the open playlist: the canonical id order the server gave,
/// how far into it the client has resolved metadata, and the rows on screen.
///
/// These used to drift apart. Removing a row edited only the visible array,
/// leaving the id list, the loaded cursor, `hasMoreTracks` and both track
/// counts describing a playlist that no longer existed.
package struct PlaylistTrackCollection: Equatable, Sendable {
  package private(set) var trackIDs: [Int64] = []
  package private(set) var loadedIDCount = 0
  package private(set) var tracks: [Track] = []
  package private(set) var freshness: CollectionFreshness = .empty

  package init() {}

  package var canLoadMore: Bool {
    loadedIDCount < trackIDs.count && freshness == .current
  }

  package var needsExplicitReload: Bool {
    freshness == .staleAfterMutation
  }

  package mutating func reset() {
    self = PlaylistTrackCollection()
  }

  /// The id order from playlist detail, before any metadata batch.
  package mutating func begin(trackIDs: [Int64]) {
    self = PlaylistTrackCollection()
    self.trackIDs = trackIDs
    freshness = .current
  }

  /// The id slice the next metadata batch should ask for.
  package func nextBatch(limit: Int) -> [Int64] {
    guard loadedIDCount < trackIDs.count else { return [] }
    let end = min(loadedIDCount + limit, trackIDs.count)
    return Array(trackIDs[loadedIDCount..<end])
  }

  /// Records a resolved batch. `requestedCount` is how many ids were asked
  /// for, which is what advances the cursor: the server may omit tracks it no
  /// longer serves, and the cursor must not stall on them.
  package mutating func appendBatch(
    _ batch: [Track],
    requestedCount: Int
  ) {
    tracks.append(contentsOf: batch)
    loadedIDCount = min(loadedIDCount + requestedCount, trackIDs.count)
  }

  /// Applies a confirmed server-side removal to every piece of local state at
  /// once. Returns false when the track was not part of this playlist.
  @discardableResult
  package mutating func removeTrack(id: Int64) -> Bool {
    guard let idIndex = trackIDs.firstIndex(of: id) else { return false }
    trackIDs.remove(at: idIndex)
    if idIndex < loadedIDCount {
      loadedIDCount -= 1
    }
    tracks.removeAll { $0.id == id }
    return true
  }

  /// A track was added to this playlist. The server decides where it lands,
  /// so the id order this client holds is no longer authoritative.
  package mutating func markStaleAfterMutation() {
    freshness = .staleAfterMutation
  }
}

import Foundation

/// The transport surface the app layer is allowed to use. `NeteaseSession` is
/// the only production conformance; tests substitute a fake so coordinator
/// behaviour can be exercised without a request. Every member mirrors an
/// entry in the endpoint registry — adding one here means adding an endpoint,
/// which is a separately approved change.
package protocol NeteaseTransporting: Sendable {
  func accountStatus(
    credential: NeteaseCredential
  ) async throws -> AccountSessionState

  func userPlaylists(
    userID: Int64,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> UserPlaylistPage

  func playlistDetail(
    playlistID: Int64,
    credential: NeteaseCredential
  ) async throws -> PlaylistDetail

  func songDetails(
    songIDs: [Int64],
    credential: NeteaseCredential
  ) async throws -> [PlaylistTrack]

  func likedSongIDs(
    userID: Int64,
    credential: NeteaseCredential
  ) async throws -> [Int64]

  func playRecords(
    userID: Int64,
    scope: PlayRecordScope,
    credential: NeteaseCredential
  ) async throws -> [PlayRecordEntry]

  func dailyRecommendedSongs(
    credential: NeteaseCredential
  ) async throws -> [PlaylistTrack]

  func dailyRecommendedPlaylists(
    credential: NeteaseCredential
  ) async throws -> [DiscoveredPlaylist]

  func personalizedPlaylists(
    credential: NeteaseCredential
  ) async throws -> [DiscoveredPlaylist]

  func toplists(credential: NeteaseCredential) async throws -> [DiscoveredPlaylist]

  func similarSongs(
    songID: Int64,
    credential: NeteaseCredential
  ) async throws -> [PlaylistTrack]

  func searchSongs(
    keywords: String,
    credential: NeteaseCredential
  ) async throws -> [PlaylistTrack]

  func setSongLiked(
    songID: Int64,
    liked: Bool,
    credential: NeteaseCredential
  ) async throws

  func createPlaylist(name: String, credential: NeteaseCredential) async throws

  func deletePlaylist(playlistID: Int64, credential: NeteaseCredential) async throws

  func editPlaylistTracks(
    _ edit: PlaylistTrackEdit,
    playlistID: Int64,
    trackIDs: [Int64],
    credential: NeteaseCredential
  ) async throws

  func renamePlaylist(
    playlistID: Int64,
    name: String,
    credential: NeteaseCredential
  ) async throws

  func setPlaylistSubscribed(
    _ subscribed: Bool,
    playlistID: Int64,
    credential: NeteaseCredential
  ) async throws

  func resolveSongURL(
    songID: Int64,
    quality: PlaybackQuality,
    credential: NeteaseCredential
  ) async throws -> SongURLResolution
}

extension NeteaseSession: NeteaseTransporting {}

/// The credential store the app layer is allowed to use, so coordinators
/// never construct a `CredentialVault` of their own and tests never touch the
/// real Keychain.
package protocol CredentialStoring: Sendable {
  func load() async throws -> NeteaseCredential?
  func save(_ credential: NeteaseCredential) async throws
  func delete() async throws
  /// Deletes only when the stored item still equals `credential`; returns
  /// false when it was already replaced.
  func delete(matching credential: NeteaseCredential) async throws -> Bool
}

extension CredentialVault: CredentialStoring {}

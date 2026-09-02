import Foundation

/// The transport surface the app layer is allowed to use. `NeteaseSession` is
/// the only production conformance; tests substitute a fake so coordinator
/// behaviour can be exercised without a request. Every member is one explicit
/// capability; exact paths, encryption and fields live beside the endpoint
/// implementation and its contract tests.
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
  ) async throws -> [Track]

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
  ) async throws -> [Track]

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
  ) async throws -> [Track]

  func lyrics(songID: Int64, credential: NeteaseCredential) async throws -> Lyrics

  func setSongLiked(
    songID: Int64,
    liked: Bool,
    credential: NeteaseCredential
  ) async throws

  func createPlaylist(
    name: String,
    isPrivate: Bool,
    credential: NeteaseCredential
  ) async throws

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

  func scrobbleStart(
    songID: Int64,
    context: ScrobbleContext,
    credential: NeteaseCredential
  ) async throws

  func scrobbleFinish(
    songID: Int64,
    context: ScrobbleContext,
    playedSeconds: Int,
    credential: NeteaseCredential
  ) async throws

  // MARK: - Sign-in, sign-out and refresh

  func beginQRLogin() async throws -> QRLoginSession

  func pollQRLogin(key: String) async throws -> QRLoginStatus

  func sendLoginCode(phone: String, countryCode: String) async throws

  func signIn(
    phone: String,
    code: String,
    countryCode: String
  ) async throws -> NeteaseCredential

  func signOut(credential: NeteaseCredential) async throws

  func refreshSession(
    credential: NeteaseCredential
  ) async throws -> NeteaseCredential

  // MARK: - Collections

  func collectedAlbums(
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<Album>

  func followedArtists(
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<Artist>

  func setAlbumCollected(
    _ collected: Bool,
    albumID: Int64,
    credential: NeteaseCredential
  ) async throws

  func setArtistFollowed(
    _ followed: Bool,
    artistID: Int64,
    credential: NeteaseCredential
  ) async throws

  func cloudSongs(
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> CloudPage

  func deleteCloudSong(songID: Int64, credential: NeteaseCredential) async throws

  /// Publishes a private playlist. There is no verified reverse, so there is
  /// no member for one.
  func publishPrivatePlaylist(
    playlistID: Int64,
    credential: NeteaseCredential
  ) async throws

  // MARK: - Browsing, radio and search

  func categoryPlaylists(
    category: String,
    order: PlaylistOrder,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<DiscoveredPlaylist>

  func highQualityPlaylists(
    category: String,
    limit: Int,
    before: Int64,
    credential: NeteaseCredential
  ) async throws -> HighQualityPlaylistPage

  func playlistBrief(
    playlistID: Int64,
    credential: NeteaseCredential
  ) async throws -> DiscoveredPlaylist

  func recommendedNewSongs(
    limit: Int,
    credential: NeteaseCredential
  ) async throws -> [Track]

  func personalFM(credential: NeteaseCredential) async throws -> [Track]

  func trashFMSong(songID: Int64, credential: NeteaseCredential) async throws

  func heartbeatQueue(
    songID: Int64,
    playlistID: Int64,
    startMusicID: Int64,
    credential: NeteaseCredential
  ) async throws -> [Track]

  func similarArtists(
    artistID: Int64,
    credential: NeteaseCredential
  ) async throws -> [Artist]

  func search(
    keywords: String,
    scope: SearchScope,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> SearchPage

  func searchSuggestions(
    keywords: String,
    credential: NeteaseCredential
  ) async throws -> [SearchSuggestion]

  func defaultSearchKeyword(credential: NeteaseCredential) async throws -> String?

  // MARK: - Albums and artists

  func albumDetail(
    albumID: Int64,
    credential: NeteaseCredential
  ) async throws -> AlbumDetail

  func albumDynamic(
    albumID: Int64,
    credential: NeteaseCredential
  ) async throws -> AlbumDynamic

  func newAlbums(
    area: AlbumArea,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<Album>

  func artistDetail(
    artistID: Int64,
    credential: NeteaseCredential
  ) async throws -> ArtistDetail

  func artistAlbums(
    artistID: Int64,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<Album>

  func topArtists(
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<Artist>
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

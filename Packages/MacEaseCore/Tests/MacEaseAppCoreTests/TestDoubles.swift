import Foundation

@testable import MacEaseAppCore
@testable import NeteaseKit

// MARK: - Fixtures

let testAccount = NeteaseAccount(userID: 42)
let otherAccount = NeteaseAccount(userID: 43)

func makeCredential(_ value: String = "music-u") -> NeteaseCredential {
  guard
    let cookie = NeteaseCookie(name: .musicU, value: value),
    let credential = NeteaseCredential(musicU: cookie, csrf: nil)
  else {
    fatalError("invalid credential fixture")
  }
  return credential
}

func makeTracks(_ ids: [Int64]) -> [Track] {
  ids.map {
    Track(
      id: $0,
      name: "track-\($0)",
      artists: [ArtistRef(id: 900 + $0, name: "artist")],
      album: AlbumRef(
        id: 800 + $0,
        name: "album-\($0)",
        artworkURL: URL(string: "https://p1.music.126.net/cover-\($0).jpg")
      ),
      durationMilliseconds: 200_000
    )
  }
}

func makePlaylists(
  _ ids: [Int64],
  owned: Bool = true,
  isPrivate: Bool? = nil
) -> [UserPlaylist] {
  ids.map {
    UserPlaylist(
      id: $0,
      name: "playlist-\($0)",
      trackCount: 3,
      owned: owned,
      isPrivate: isPrivate
    )
  }
}

func makeDiscovered(_ ids: [Int64]) -> [DiscoveredPlaylist] {
  ids.map { DiscoveredPlaylist(id: $0, name: "discovered-\($0)") }
}

// MARK: - Gate

/// Lets a test hold a fake request open so it can act while the request is
/// still in flight, then release it.
actor RequestGate {
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var isOpen = true
  private var arrivals = 0

  func close() { isOpen = false }

  func open() {
    isOpen = true
    let pending = waiters
    waiters = []
    for continuation in pending { continuation.resume() }
  }

  /// Releases only the newest blocked arrival while the gate stays closed.
  /// This lets a supersession test make the old request finish last.
  func releaseNewestArrival() {
    guard let continuation = waiters.popLast() else { return }
    continuation.resume()
  }

  func arrivalCount() -> Int { arrivals }

  func pass() async {
    arrivals += 1
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}

// MARK: - Transport

/// Records what the app layer asked for and returns programmed answers. It
/// never touches the network; an unprogrammed call is a test failure, not a
/// silent empty result.
actor FakeTransport: NeteaseTransporting {
  enum Call: Equatable, Sendable {
    case accountStatus
    case userPlaylists(offset: Int, limit: Int)
    case playlistDetail(Int64)
    case songDetails([Int64])
    case likedSongIDs
    case playRecords(PlayRecordScope)
    case dailyRecommendedSongs
    case dailyRecommendedPlaylists
    case personalizedPlaylists
    case toplists
    case similarSongs(Int64)
    case lyrics(Int64)
    case setSongLiked(Int64, Bool)
    case createPlaylist(String, isPrivate: Bool)
    case deletePlaylist(Int64)
    case editPlaylistTracks(PlaylistTrackEdit, Int64, [Int64])
    case renamePlaylist(Int64, String)
    case setPlaylistSubscribed(Bool, Int64)
    case resolveSongURL(Int64, PlaybackQuality)
    case scrobbleStart(Int64, ScrobbleContext)
    case scrobbleFinish(Int64, ScrobbleContext, Int)
    case beginQRLogin
    case pollQRLogin(String)
    case sendLoginCode(String)
    case signIn(String, String)
    case signOut
    case refreshSession
    case collectedAlbums(offset: Int)
    case followedArtists(offset: Int)
    case setAlbumCollected(Int64, Bool)
    case setArtistFollowed(Int64, Bool)
    case cloudSongs(offset: Int)
    case deleteCloudSong(Int64)
    case publishPrivatePlaylist(Int64)
    case categoryPlaylists(String, PlaylistOrder, offset: Int)
    case highQualityPlaylists(String, before: Int64)
    case playlistBrief(Int64)
    case recommendedNewSongs
    case personalFM
    case trashFMSong(Int64)
    case heartbeatQueue(songID: Int64, playlistID: Int64, startMusicID: Int64)
    case similarArtists(Int64)
    case search(String, SearchScope, offset: Int)
    case searchSuggestions(String)
    case defaultSearchKeyword
    case albumDetail(Int64)
    case albumDynamic(Int64)
    case newAlbums(AlbumArea, offset: Int)
    case artistDetail(Int64)
    case artistAlbums(Int64, offset: Int)
    case topArtists(offset: Int)
  }

  struct Unprogrammed: Error, Equatable {
    let call: String
  }

  private(set) var calls: [Call] = []
  let gate = RequestGate()

  var accountStatusResult: Result<AccountSessionState, any Error> = .success(
    .authenticated(testAccount)
  )
  var playlistPages: [UserPlaylistPage] = []
  var playlistPageError: (any Error)?
  var playlistDetailResult: Result<PlaylistDetail, any Error>?
  var songDetailBatches: [[Track]] = []
  var likedIDsResult: Result<[Int64], any Error> = .success([])
  var discoveryTracksResult: Result<[Track], any Error> = .success([])
  var discoveryPlaylistsResult: Result<[DiscoveredPlaylist], any Error> = .success([])
  var recordsResult: Result<[PlayRecordEntry], any Error> = .success([])
  var writeResult: Result<Void, any Error> = .success(())
  var songURLResult: Result<SongURLResolution, any Error> = .success(
    .unavailable(itemCode: 404, fee: nil)
  )
  var songURLResults: [Result<SongURLResolution, any Error>] = []
  var lyricsResult: Result<Lyrics, any Error> = .success(.none)
  var lyricsResults: [Result<Lyrics, any Error>] = []

  func setLyrics(_ value: Result<Lyrics, any Error>) { lyricsResult = value }
  func setLyrics(_ values: [Result<Lyrics, any Error>]) { lyricsResults = values }

  var qrSessionResult: Result<QRLoginSession, any Error> = .success(
    QRLoginSession(key: "key", url: URL(string: "https://music.163.com/login?codekey=key")!)
  )
  /// Consumed one per poll, so a test can script the whole scan lifecycle.
  var qrPollResults: [Result<QRLoginStatus, any Error>] = []
  var signInResult: Result<NeteaseCredential, any Error> = .success(makeCredential("signed-in"))
  var refreshResult: Result<NeteaseCredential, any Error> = .success(makeCredential("refreshed"))
  var albumPages: [CatalogPage<Album>] = []
  var artistPages: [CatalogPage<Artist>] = []
  var cloudPages: [CloudPage] = []
  var collectionError: (any Error)?

  func setQRSession(_ value: Result<QRLoginSession, any Error>) { qrSessionResult = value }
  func setQRPolls(_ value: [Result<QRLoginStatus, any Error>]) { qrPollResults = value }
  func setSignIn(_ value: Result<NeteaseCredential, any Error>) { signInResult = value }
  func setRefresh(_ value: Result<NeteaseCredential, any Error>) { refreshResult = value }
  func setAlbumPages(_ value: [CatalogPage<Album>]) { albumPages = value }
  func setArtistPages(_ value: [CatalogPage<Artist>]) { artistPages = value }
  func setCloudPages(_ value: [CloudPage]) { cloudPages = value }
  func setCollectionError(_ value: (any Error)?) { collectionError = value }

  func beginQRLogin() async throws -> QRLoginSession {
    await record(.beginQRLogin)
    return try qrSessionResult.get()
  }

  func pollQRLogin(key: String) async throws -> QRLoginStatus {
    await record(.pollQRLogin(key))
    guard !qrPollResults.isEmpty else { throw Unprogrammed(call: "pollQRLogin") }
    return try qrPollResults.removeFirst().get()
  }

  func sendLoginCode(phone: String, countryCode: String) async throws {
    await record(.sendLoginCode(phone))
    try writeResult.get()
  }

  func signIn(
    phone: String,
    code: String,
    countryCode: String
  ) async throws -> NeteaseCredential {
    await record(.signIn(phone, code))
    return try signInResult.get()
  }

  func signOut(credential: NeteaseCredential) async throws {
    await record(.signOut)
    try writeResult.get()
  }

  func refreshSession(credential: NeteaseCredential) async throws -> NeteaseCredential {
    await record(.refreshSession)
    return try refreshResult.get()
  }

  func collectedAlbums(
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<Album> {
    await record(.collectedAlbums(offset: offset))
    if let collectionError { throw collectionError }
    guard !albumPages.isEmpty else { throw Unprogrammed(call: "collectedAlbums") }
    return albumPages.removeFirst()
  }

  func followedArtists(
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<Artist> {
    await record(.followedArtists(offset: offset))
    if let collectionError { throw collectionError }
    guard !artistPages.isEmpty else { throw Unprogrammed(call: "followedArtists") }
    return artistPages.removeFirst()
  }

  func setAlbumCollected(
    _ collected: Bool,
    albumID: Int64,
    credential: NeteaseCredential
  ) async throws {
    await record(.setAlbumCollected(albumID, collected))
    try writeResult.get()
  }

  func setArtistFollowed(
    _ followed: Bool,
    artistID: Int64,
    credential: NeteaseCredential
  ) async throws {
    await record(.setArtistFollowed(artistID, followed))
    try writeResult.get()
  }

  func cloudSongs(
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> CloudPage {
    await record(.cloudSongs(offset: offset))
    if let collectionError { throw collectionError }
    guard !cloudPages.isEmpty else { throw Unprogrammed(call: "cloudSongs") }
    return cloudPages.removeFirst()
  }

  func deleteCloudSong(songID: Int64, credential: NeteaseCredential) async throws {
    await record(.deleteCloudSong(songID))
    try writeResult.get()
  }

  func publishPrivatePlaylist(
    playlistID: Int64,
    credential: NeteaseCredential
  ) async throws {
    await record(.publishPrivatePlaylist(playlistID))
    try writeResult.get()
  }

  func setAccountStatus(_ value: Result<AccountSessionState, any Error>) {
    accountStatusResult = value
  }
  func setPlaylistPages(_ value: [UserPlaylistPage]) { playlistPages = value }
  func setPlaylistPageError(_ value: (any Error)?) { playlistPageError = value }
  func setPlaylistDetail(_ value: Result<PlaylistDetail, any Error>) {
    playlistDetailResult = value
  }
  func setSongDetailBatches(_ value: [[Track]]) { songDetailBatches = value }
  func setLikedIDs(_ value: Result<[Int64], any Error>) { likedIDsResult = value }
  func setDiscoveryTracks(_ value: Result<[Track], any Error>) {
    discoveryTracksResult = value
  }
  func setDiscoveryPlaylists(_ value: Result<[DiscoveredPlaylist], any Error>) {
    discoveryPlaylistsResult = value
  }
  func setRecords(_ value: Result<[PlayRecordEntry], any Error>) { recordsResult = value }
  func setWriteResult(_ value: Result<Void, any Error>) { writeResult = value }
  func setSongURL(_ value: Result<SongURLResolution, any Error>) {
    songURLResults = []
    songURLResult = value
  }
  func setSongURLs(_ values: [Result<SongURLResolution, any Error>]) {
    songURLResults = values
  }

  func recordedCalls() -> [Call] { calls }
  func callCount() -> Int { calls.count }

  private func record(_ call: Call) async {
    calls.append(call)
    await gate.pass()
  }

  /// Reserves a FIFO answer before the gate suspends the request. When several
  /// waiters are released together, executor resume order must not decide
  /// which request receives which programmed response.
  private func record<Response>(
    _ call: Call,
    reserving response: () -> Result<Response, any Error>
  ) async throws -> Response {
    calls.append(call)
    let reserved = response()
    await gate.pass()
    return try reserved.get()
  }

  func accountStatus(
    credential: NeteaseCredential
  ) async throws -> AccountSessionState {
    await record(.accountStatus)
    return try accountStatusResult.get()
  }

  func userPlaylists(
    userID: Int64,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> UserPlaylistPage {
    await record(.userPlaylists(offset: offset, limit: limit))
    if let playlistPageError { throw playlistPageError }
    guard !playlistPages.isEmpty else {
      throw Unprogrammed(call: "userPlaylists")
    }
    return playlistPages.removeFirst()
  }

  func playlistDetail(
    playlistID: Int64,
    credential: NeteaseCredential
  ) async throws -> PlaylistDetail {
    await record(.playlistDetail(playlistID))
    guard let playlistDetailResult else { throw Unprogrammed(call: "playlistDetail") }
    return try playlistDetailResult.get()
  }

  func songDetails(
    songIDs: [Int64],
    credential: NeteaseCredential
  ) async throws -> [Track] {
    await record(.songDetails(songIDs))
    guard !songDetailBatches.isEmpty else {
      throw Unprogrammed(call: "songDetails")
    }
    return songDetailBatches.removeFirst()
  }

  func likedSongIDs(
    userID: Int64,
    credential: NeteaseCredential
  ) async throws -> [Int64] {
    await record(.likedSongIDs)
    return try likedIDsResult.get()
  }

  func lyrics(songID: Int64, credential: NeteaseCredential) async throws -> Lyrics {
    try await record(.lyrics(songID)) {
      lyricsResults.isEmpty ? lyricsResult : lyricsResults.removeFirst()
    }
  }

  func playRecords(
    userID: Int64,
    scope: PlayRecordScope,
    credential: NeteaseCredential
  ) async throws -> [PlayRecordEntry] {
    await record(.playRecords(scope))
    return try recordsResult.get()
  }

  func dailyRecommendedSongs(
    credential: NeteaseCredential
  ) async throws -> [Track] {
    await record(.dailyRecommendedSongs)
    return try discoveryTracksResult.get()
  }

  func dailyRecommendedPlaylists(
    credential: NeteaseCredential
  ) async throws -> [DiscoveredPlaylist] {
    await record(.dailyRecommendedPlaylists)
    return try discoveryPlaylistsResult.get()
  }

  func personalizedPlaylists(
    credential: NeteaseCredential
  ) async throws -> [DiscoveredPlaylist] {
    await record(.personalizedPlaylists)
    return try discoveryPlaylistsResult.get()
  }

  func toplists(credential: NeteaseCredential) async throws -> [DiscoveredPlaylist] {
    await record(.toplists)
    return try discoveryPlaylistsResult.get()
  }

  func similarSongs(
    songID: Int64,
    credential: NeteaseCredential
  ) async throws -> [Track] {
    await record(.similarSongs(songID))
    return try discoveryTracksResult.get()
  }

  // MARK: - Browsing, radio, search and detail

  var browsePages: [CatalogPage<DiscoveredPlaylist>] = []
  var highQualityPages: [HighQualityPlaylistPage] = []
  var playlistBriefResult: Result<DiscoveredPlaylist, any Error> = .success(
    DiscoveredPlaylist(id: 1, name: "radar")
  )
  var fmBatches: [[Track]] = []
  var heartbeatResult: Result<[Track], any Error> = .success([])
  var similarArtistsResult: Result<[Artist], any Error> = .success([])
  var searchPages: [SearchPage] = []
  var searchError: (any Error)?
  var suggestionsResult: Result<[SearchSuggestion], any Error> = .success([])
  var defaultKeywordResult: Result<String?, any Error> = .success(nil)
  var albumDetailResult: Result<AlbumDetail, any Error>?
  var albumDynamicResult: Result<AlbumDynamic, any Error> = .success(
    AlbumDynamic(isCollected: false, collectCount: 0)
  )
  var artistDetailResult: Result<ArtistDetail, any Error>?
  var artistAlbumPages: [CatalogPage<Album>] = []
  var newAlbumPages: [CatalogPage<Album>] = []
  var topArtistPages: [CatalogPage<Artist>] = []
  var catalogError: (any Error)?

  func setBrowsePages(_ value: [CatalogPage<DiscoveredPlaylist>]) {
    browsePages = value
  }
  func setHighQualityPages(_ value: [HighQualityPlaylistPage]) {
    highQualityPages = value
  }
  func setPlaylistBrief(_ value: Result<DiscoveredPlaylist, any Error>) {
    playlistBriefResult = value
  }
  func setFMBatches(_ value: [[Track]]) { fmBatches = value }
  func setHeartbeat(_ value: Result<[Track], any Error>) { heartbeatResult = value }
  func setSimilarArtists(_ value: Result<[Artist], any Error>) {
    similarArtistsResult = value
  }
  func setSearchPages(_ value: [SearchPage]) { searchPages = value }
  func setSearchError(_ value: (any Error)?) { searchError = value }
  func setSuggestions(_ value: Result<[SearchSuggestion], any Error>) {
    suggestionsResult = value
  }
  func setDefaultKeyword(_ value: Result<String?, any Error>) {
    defaultKeywordResult = value
  }
  func setAlbumDetail(_ value: Result<AlbumDetail, any Error>?) {
    albumDetailResult = value
  }
  func setAlbumDynamic(_ value: Result<AlbumDynamic, any Error>) {
    albumDynamicResult = value
  }
  func setArtistDetail(_ value: Result<ArtistDetail, any Error>?) {
    artistDetailResult = value
  }
  func setArtistAlbumPages(_ value: [CatalogPage<Album>]) { artistAlbumPages = value }
  func setNewAlbumPages(_ value: [CatalogPage<Album>]) { newAlbumPages = value }
  func setTopArtistPages(_ value: [CatalogPage<Artist>]) { topArtistPages = value }
  func setCatalogError(_ value: (any Error)?) { catalogError = value }

  func categoryPlaylists(
    category: String,
    order: PlaylistOrder,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<DiscoveredPlaylist> {
    await record(.categoryPlaylists(category, order, offset: offset))
    if let catalogError { throw catalogError }
    guard !browsePages.isEmpty else { throw Unprogrammed(call: "categoryPlaylists") }
    return browsePages.removeFirst()
  }

  func highQualityPlaylists(
    category: String,
    limit: Int,
    before: Int64,
    credential: NeteaseCredential
  ) async throws -> HighQualityPlaylistPage {
    await record(.highQualityPlaylists(category, before: before))
    if let catalogError { throw catalogError }
    guard !highQualityPages.isEmpty else {
      throw Unprogrammed(call: "highQualityPlaylists")
    }
    return highQualityPages.removeFirst()
  }

  func playlistBrief(
    playlistID: Int64,
    credential: NeteaseCredential
  ) async throws -> DiscoveredPlaylist {
    await record(.playlistBrief(playlistID))
    if let catalogError { throw catalogError }
    return try playlistBriefResult.get()
  }

  func recommendedNewSongs(
    limit: Int,
    credential: NeteaseCredential
  ) async throws -> [Track] {
    await record(.recommendedNewSongs)
    return try discoveryTracksResult.get()
  }

  func personalFM(credential: NeteaseCredential) async throws -> [Track] {
    await record(.personalFM)
    if let catalogError { throw catalogError }
    guard !fmBatches.isEmpty else { throw Unprogrammed(call: "personalFM") }
    return fmBatches.removeFirst()
  }

  func trashFMSong(songID: Int64, credential: NeteaseCredential) async throws {
    await record(.trashFMSong(songID))
    try writeResult.get()
  }

  func heartbeatQueue(
    songID: Int64,
    playlistID: Int64,
    startMusicID: Int64,
    credential: NeteaseCredential
  ) async throws -> [Track] {
    await record(
      .heartbeatQueue(
        songID: songID,
        playlistID: playlistID,
        startMusicID: startMusicID
      )
    )
    return try heartbeatResult.get()
  }

  func similarArtists(
    artistID: Int64,
    credential: NeteaseCredential
  ) async throws -> [Artist] {
    await record(.similarArtists(artistID))
    return try similarArtistsResult.get()
  }

  func search(
    keywords: String,
    scope: SearchScope,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> SearchPage {
    try await record(.search(keywords, scope, offset: offset)) {
      if let searchError { return .failure(searchError) }
      guard !searchPages.isEmpty else {
        return .failure(Unprogrammed(call: "search"))
      }
      return .success(searchPages.removeFirst())
    }
  }

  func searchSuggestions(
    keywords: String,
    credential: NeteaseCredential
  ) async throws -> [SearchSuggestion] {
    await record(.searchSuggestions(keywords))
    return try suggestionsResult.get()
  }

  func defaultSearchKeyword(credential: NeteaseCredential) async throws -> String? {
    await record(.defaultSearchKeyword)
    return try defaultKeywordResult.get()
  }

  func albumDetail(
    albumID: Int64,
    credential: NeteaseCredential
  ) async throws -> AlbumDetail {
    await record(.albumDetail(albumID))
    if let catalogError { throw catalogError }
    guard let albumDetailResult else { throw Unprogrammed(call: "albumDetail") }
    return try albumDetailResult.get()
  }

  func albumDynamic(
    albumID: Int64,
    credential: NeteaseCredential
  ) async throws -> AlbumDynamic {
    await record(.albumDynamic(albumID))
    if let catalogError { throw catalogError }
    return try albumDynamicResult.get()
  }

  func newAlbums(
    area: AlbumArea,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<Album> {
    await record(.newAlbums(area, offset: offset))
    if let catalogError { throw catalogError }
    guard !newAlbumPages.isEmpty else { throw Unprogrammed(call: "newAlbums") }
    return newAlbumPages.removeFirst()
  }

  func artistDetail(
    artistID: Int64,
    credential: NeteaseCredential
  ) async throws -> ArtistDetail {
    await record(.artistDetail(artistID))
    if let catalogError { throw catalogError }
    guard let artistDetailResult else { throw Unprogrammed(call: "artistDetail") }
    return try artistDetailResult.get()
  }

  func artistAlbums(
    artistID: Int64,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<Album> {
    await record(.artistAlbums(artistID, offset: offset))
    if let catalogError { throw catalogError }
    guard !artistAlbumPages.isEmpty else { throw Unprogrammed(call: "artistAlbums") }
    return artistAlbumPages.removeFirst()
  }

  func topArtists(
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<Artist> {
    await record(.topArtists(offset: offset))
    if let catalogError { throw catalogError }
    guard !topArtistPages.isEmpty else { throw Unprogrammed(call: "topArtists") }
    return topArtistPages.removeFirst()
  }

  func setSongLiked(
    songID: Int64,
    liked: Bool,
    credential: NeteaseCredential
  ) async throws {
    await record(.setSongLiked(songID, liked))
    try writeResult.get()
  }

  func createPlaylist(
    name: String,
    isPrivate: Bool,
    credential: NeteaseCredential
  ) async throws {
    await record(.createPlaylist(name, isPrivate: isPrivate))
    try writeResult.get()
  }

  func deletePlaylist(playlistID: Int64, credential: NeteaseCredential) async throws {
    await record(.deletePlaylist(playlistID))
    try writeResult.get()
  }

  func editPlaylistTracks(
    _ edit: PlaylistTrackEdit,
    playlistID: Int64,
    trackIDs: [Int64],
    credential: NeteaseCredential
  ) async throws {
    await record(.editPlaylistTracks(edit, playlistID, trackIDs))
    try writeResult.get()
  }

  func renamePlaylist(
    playlistID: Int64,
    name: String,
    credential: NeteaseCredential
  ) async throws {
    await record(.renamePlaylist(playlistID, name))
    try writeResult.get()
  }

  func setPlaylistSubscribed(
    _ subscribed: Bool,
    playlistID: Int64,
    credential: NeteaseCredential
  ) async throws {
    await record(.setPlaylistSubscribed(subscribed, playlistID))
    try writeResult.get()
  }

  func resolveSongURL(
    songID: Int64,
    quality: PlaybackQuality,
    credential: NeteaseCredential
  ) async throws -> SongURLResolution {
    await record(.resolveSongURL(songID, quality))
    if !songURLResults.isEmpty {
      return try songURLResults.removeFirst().get()
    }
    return try songURLResult.get()
  }

  func scrobbleStart(
    songID: Int64,
    context: ScrobbleContext,
    credential: NeteaseCredential
  ) async throws {
    await record(.scrobbleStart(songID, context))
    try writeResult.get()
  }

  func scrobbleFinish(
    songID: Int64,
    context: ScrobbleContext,
    playedSeconds: Int,
    credential: NeteaseCredential
  ) async throws {
    await record(.scrobbleFinish(songID, context, playedSeconds))
    try writeResult.get()
  }
}

// MARK: - Credential store

actor FakeVault: CredentialStoring {
  private var stored: NeteaseCredential?
  private var loadError: (any Error)?
  private var deleteError: (any Error)?
  private(set) var loadCount = 0

  init(stored: NeteaseCredential?) {
    self.stored = stored
  }

  func setStored(_ credential: NeteaseCredential?) { stored = credential }
  /// Reads without counting as a `load()`, so a test can check what was
  /// written without disturbing the load-count assertions.
  func storedForTesting() -> NeteaseCredential? { stored }
  func setLoadError(_ error: (any Error)?) { loadError = error }
  func setDeleteError(_ error: (any Error)?) { deleteError = error }

  func load() throws -> NeteaseCredential? {
    loadCount += 1
    if let loadError { throw loadError }
    return stored
  }

  func save(_ credential: NeteaseCredential) throws { stored = credential }

  func delete() throws {
    if let deleteError { throw deleteError }
    stored = nil
  }

  func delete(matching credential: NeteaseCredential) throws -> Bool {
    if let deleteError { throw deleteError }
    guard stored == credential else { return false }
    stored = nil
    return true
  }
}

// MARK: - Session

@MainActor
final class FakeSession: SessionProviding {
  var account: NeteaseAccount?
  var validatedCredential: NeteaseCredential?
  private(set) var divergences: [SessionDivergence] = []
  private(set) var invalidations: [NeteaseCredential] = []
  var invalidationResult: SessionInvalidationResult = .deleted

  init(account: NeteaseAccount? = testAccount, credential: NeteaseCredential?) {
    self.account = account
    self.validatedCredential = credential
  }

  func matchesValidatedSession(
    _ credential: NeteaseCredential,
    account: NeteaseAccount
  ) -> Bool {
    self.account == account && validatedCredential == credential
  }

  func reportDivergence(_ divergence: SessionDivergence) {
    divergences.append(divergence)
    account = nil
    validatedCredential = nil
  }

  func invalidateStoredSession(
    matching credential: NeteaseCredential,
    message: String,
    readToken: OperationToken
  ) async -> SessionInvalidationResult {
    invalidations.append(credential)
    if invalidationResult == .deleted {
      account = nil
      validatedCredential = nil
    }
    return invalidationResult
  }
}

// MARK: - Audio

/// Stands in for AVPlayer. Nothing here touches real media, so the recovery
/// rules can be exercised deterministically.
@MainActor
final class FakeAudioOutput: AudioOutput {
  struct LoadFailure: Error, Equatable {
    let reason: String
  }

  var volume: Float = 1
  var isMuted = false
  var currentPositionSeconds: Double?

  var onPositionUpdate: (@MainActor (Double) -> Void)?
  var onPlaybackStateChanged:
    (@MainActor (AudioOutputPlaybackState) -> Void)?
  var onPlayedToEnd: (@MainActor () -> Void)?
  var onFailure: (@MainActor (AudioOutputFailure) -> Void)?

  /// Programmed answer for the next `prepare`.
  var prepareResult: Result<AudioAssetInfo, any Error> = .success(
    AudioAssetInfo(isPlayable: true, durationSeconds: 200)
  )
  var prepareResults: [Result<AudioAssetInfo, any Error>] = []
  private(set) var preparedURLs: [URL] = []
  private(set) var preparedResources: [PlaybackResource] = []
  private(set) var isPlaying = false
  private(set) var seeks: [Double] = []
  private(set) var teardownCount = 0
  private(set) var loadedURL: URL?
  var automaticallyReportsPlaying = true
  private(set) var prepareIsBlocked = false
  private var generation: UInt64 = 0
  private var shouldBlockNextPrepare = false
  private var blockedPrepare: CheckedContinuation<Void, Never>?

  func prepare(
    resource: PlaybackResource,
    userAgent: String
  ) async throws -> AudioAssetInfo {
    teardown()
    let generation = self.generation
    preparedResources.append(resource)
    let url: URL
    switch resource.location {
    case .remote(let value), .local(let value): url = value
    }
    preparedURLs.append(url)
    if shouldBlockNextPrepare {
      shouldBlockNextPrepare = false
      prepareIsBlocked = true
      await withCheckedContinuation { blockedPrepare = $0 }
      prepareIsBlocked = false
    }
    try Task.checkCancellation()
    guard self.generation == generation else { throw CancellationError() }
    let result = try (
      prepareResults.isEmpty ? prepareResult : prepareResults.removeFirst()
    ).get()
    loadedURL = url
    return result
  }

  func play() {
    isPlaying = true
    if automaticallyReportsPlaying {
      onPlaybackStateChanged?(.playing)
    }
  }

  func pause() {
    isPlaying = false
    onPlaybackStateChanged?(.notPlaying)
  }

  func seek(to seconds: Double) async throws {
    seeks.append(seconds)
    currentPositionSeconds = seconds
  }

  func teardown() {
    generation &+= 1
    isPlaying = false
    loadedURL = nil
    teardownCount += 1
  }

  // MARK: Test drivers

  func blockNextPrepare() {
    shouldBlockNextPrepare = true
  }

  func resumeBlockedPrepare() {
    blockedPrepare?.resume()
    blockedPrepare = nil
  }

  func queuedFailure(_ failure: AudioOutputFailure) -> @MainActor () -> Void {
    let generation = generation
    return { [weak self] in
      guard let self, self.generation == generation else { return }
      self.onFailure?(failure)
    }
  }

  func reportPosition(_ seconds: Double) {
    currentPositionSeconds = seconds
    onPositionUpdate?(seconds)
  }

  func reportPlaybackState(_ state: AudioOutputPlaybackState) {
    onPlaybackStateChanged?(state)
  }

  func reportFailure(_ detail: String) {
    onFailure?(.itemPlayback(detail))
  }

  func reportFailure(_ failure: AudioOutputFailure) {
    onFailure?(failure)
  }

  func reportPlayedToEnd() {
    onPlayedToEnd?()
  }
}

func makeResolvedAsset(
  songID: Int64,
  urlString: String = "https://m8.music.126.net/track.mp3",
  requestedQuality: PlaybackQuality = .standard,
  actualQuality: String? = nil
) -> SongURLResolution {
  .resolved(
    ResolvedAudioAsset(
      songID: songID,
      url: URL(string: urlString)!,
      sourceScheme: "https",
      requestedQuality: requestedQuality,
      actualQuality: actualQuality ?? requestedQuality.rawValue,
      format: "mp3",
      bitRate: 128_000,
      byteCount: 3_000_000,
      expiresIn: 1200,
      fee: 0,
      trial: false
    )
  )
}

import Foundation
import NeteaseKit

@testable import MacEaseAppCore

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

func makeTracks(_ ids: [Int64]) -> [PlaylistTrack] {
  ids.map { PlaylistTrack(id: $0, name: "track-\($0)", artists: ["artist"]) }
}

func makePlaylists(_ ids: [Int64], owned: Bool = true) -> [UserPlaylist] {
  ids.map {
    UserPlaylist(id: $0, name: "playlist-\($0)", trackCount: 3, owned: owned)
  }
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
    case searchSongs(String)
    case setSongLiked(Int64, Bool)
    case createPlaylist(String)
    case deletePlaylist(Int64)
    case editPlaylistTracks(PlaylistTrackEdit, Int64, [Int64])
    case renamePlaylist(Int64, String)
    case setPlaylistSubscribed(Bool, Int64)
    case resolveSongURL(Int64, PlaybackQuality)
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
  var songDetailBatches: [[PlaylistTrack]] = []
  var likedIDsResult: Result<[Int64], any Error> = .success([])
  var discoveryTracksResult: Result<[PlaylistTrack], any Error> = .success([])
  var discoveryPlaylistsResult: Result<[DiscoveredPlaylist], any Error> = .success([])
  var recordsResult: Result<[PlayRecordEntry], any Error> = .success([])
  var writeResult: Result<Void, any Error> = .success(())
  var songURLResult: Result<SongURLResolution, any Error> = .success(
    .unavailable(itemCode: 404, fee: nil)
  )

  func setAccountStatus(_ value: Result<AccountSessionState, any Error>) {
    accountStatusResult = value
  }
  func setPlaylistPages(_ value: [UserPlaylistPage]) { playlistPages = value }
  func setPlaylistPageError(_ value: (any Error)?) { playlistPageError = value }
  func setPlaylistDetail(_ value: Result<PlaylistDetail, any Error>) {
    playlistDetailResult = value
  }
  func setSongDetailBatches(_ value: [[PlaylistTrack]]) { songDetailBatches = value }
  func setLikedIDs(_ value: Result<[Int64], any Error>) { likedIDsResult = value }
  func setDiscoveryTracks(_ value: Result<[PlaylistTrack], any Error>) {
    discoveryTracksResult = value
  }
  func setDiscoveryPlaylists(_ value: Result<[DiscoveredPlaylist], any Error>) {
    discoveryPlaylistsResult = value
  }
  func setRecords(_ value: Result<[PlayRecordEntry], any Error>) { recordsResult = value }
  func setWriteResult(_ value: Result<Void, any Error>) { writeResult = value }
  func setSongURL(_ value: Result<SongURLResolution, any Error>) { songURLResult = value }

  func recordedCalls() -> [Call] { calls }
  func callCount() -> Int { calls.count }

  private func record(_ call: Call) async {
    calls.append(call)
    await gate.pass()
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
  ) async throws -> [PlaylistTrack] {
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
  ) async throws -> [PlaylistTrack] {
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
  ) async throws -> [PlaylistTrack] {
    await record(.similarSongs(songID))
    return try discoveryTracksResult.get()
  }

  func searchSongs(
    keywords: String,
    credential: NeteaseCredential
  ) async throws -> [PlaylistTrack] {
    await record(.searchSongs(keywords))
    return try discoveryTracksResult.get()
  }

  func setSongLiked(
    songID: Int64,
    liked: Bool,
    credential: NeteaseCredential
  ) async throws {
    await record(.setSongLiked(songID, liked))
    try writeResult.get()
  }

  func createPlaylist(name: String, credential: NeteaseCredential) async throws {
    await record(.createPlaylist(name))
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
    return try songURLResult.get()
  }
}

extension PlaylistTrackEdit: @retroactive Equatable {}

// MARK: - Credential store

actor FakeVault: CredentialStoring {
  private var stored: NeteaseCredential?
  private var loadError: (any Error)?
  private(set) var loadCount = 0

  init(stored: NeteaseCredential?) {
    self.stored = stored
  }

  func setStored(_ credential: NeteaseCredential?) { stored = credential }
  func setLoadError(_ error: (any Error)?) { loadError = error }

  func load() throws -> NeteaseCredential? {
    loadCount += 1
    if let loadError { throw loadError }
    return stored
  }

  func save(_ credential: NeteaseCredential) throws { stored = credential }

  func delete() throws { stored = nil }

  func delete(matching credential: NeteaseCredential) throws -> Bool {
    guard stored == credential else { return false }
    stored = nil
    return true
  }
}

// MARK: - Session

@MainActor
final class FakeSession: SessionProviding {
  var account: NeteaseAccount?
  var isBusy = false
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
    message: String
  ) async -> SessionInvalidationResult {
    invalidations.append(credential)
    if invalidationResult == .deleted {
      account = nil
      validatedCredential = nil
    }
    return invalidationResult
  }
}

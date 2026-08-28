import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

/// P1: per-account storage.
///
/// The rule that matters is the account key: signing in as someone else must
/// never show the previous account's library or resume into their queue.

private func makeStore() throws -> LibraryStore {
  try LibraryStore(path: LibraryStore.inMemoryPath)
}

private let alice: Int64 = 42
private let bob: Int64 = 43

private func makeQueue(
  ids: [Int64] = [1, 2, 3],
  currentIndex: Int = 1,
  positionSeconds: Double = 30,
  wasPlaying: Bool = true
) -> PersistedQueue {
  PersistedQueue(
    tracks: makeTracks(ids),
    currentIndex: currentIndex,
    mode: .shuffle,
    context: .playlist(id: 7, name: "Evening"),
    positionSeconds: positionSeconds,
    quality: .lossless,
    wasPlaying: wasPlaying
  )
}

@Test func playlistsRoundTripInTheServersOrder() async throws {
  let store = try makeStore()
  let playlists = makePlaylists([3, 1, 2])

  try await store.savePlaylists(playlists, accountID: alice)

  #expect(try await store.playlists(accountID: alice) == playlists)
}

@Test func savingPlaylistsReplacesRatherThanAccumulates() async throws {
  let store = try makeStore()

  try await store.savePlaylists(makePlaylists([1, 2, 3]), accountID: alice)
  try await store.savePlaylists(makePlaylists([9]), accountID: alice)

  #expect(try await store.playlists(accountID: alice).map(\.id) == [9])
}

/// The account is part of the key rather than something the caller is trusted
/// to filter on, so one account's library can never surface under another.
@Test func accountsDoNotSeeEachOthersLibraries() async throws {
  let store = try makeStore()

  try await store.savePlaylists(makePlaylists([1]), accountID: alice)
  try await store.savePlaylists(makePlaylists([2]), accountID: bob)

  #expect(try await store.playlists(accountID: alice).map(\.id) == [1])
  #expect(try await store.playlists(accountID: bob).map(\.id) == [2])
}

@Test func theQueueRoundTripsWithItsContextAndPosition() async throws {
  let store = try makeStore()
  let queue = makeQueue()

  try await store.saveQueue(queue, accountID: alice)

  #expect(try await store.queue(accountID: alice) == queue)
  #expect(try await store.queue(accountID: bob) == nil)
}

@Test func savingTheQueueReplacesTheOneAlreadyStored() async throws {
  let store = try makeStore()

  try await store.saveQueue(makeQueue(ids: [1, 2, 3]), accountID: alice)
  try await store.saveQueue(makeQueue(ids: [9], currentIndex: 0), accountID: alice)

  #expect(try await store.queue(accountID: alice)?.tracks.map(\.id) == [9])
}

/// Stored bytes are untrusted. An index that names no track would put playback
/// off the end of its own queue on the next launch.
@Test func aStoredIndexOutsideTheQueueIsClamped() async throws {
  let store = try makeStore()
  try await store.saveQueue(
    PersistedQueue(
      tracks: makeTracks([1, 2]),
      currentIndex: 99,
      mode: .sequential,
      context: .dailyRecommendations,
      positionSeconds: -5,
      quality: .standard,
      wasPlaying: false
    ),
    accountID: alice
  )

  let restored = try await store.queue(accountID: alice)
  #expect(restored?.currentIndex == 1)
  #expect(restored?.positionSeconds == 0)
}

/// Decoding is where an older schema arrives, so the clamping has to run there
/// too — synthesised decoding would assign the fields and skip it.
@Test func decodingRunsTheSameClampingAsTheInitialiser() throws {
  let payload = Data(
    (#"{"tracks":[],"currentIndex":7,"mode":"shuffle","#
      + #""context":{"dailyRecommendations":{}},"positionSeconds":-1,"#
      + #""quality":"hires","wasPlaying":true}"#).utf8
  )

  let decoded = try JSONDecoder().decode(PersistedQueue.self, from: payload)

  #expect(decoded.currentIndex == 0)
  #expect(decoded.positionSeconds == 0)
}

/// A non-finite position comes straight from AVPlayer for an item that never
/// became ready, and would be written as `null` in JSON if it survived.
@Test func aNonFinitePositionIsStoredAsZero() async throws {
  let store = try makeStore()
  try await store.saveQueue(
    makeQueue(positionSeconds: .nan),
    accountID: alice
  )

  #expect(try await store.queue(accountID: alice)?.positionSeconds == 0)
}

/// A payload an older build wrote must not stop the app from launching. The
/// only thing lost is a resume point.
@Test func anUndecodablePayloadReadsAsNoQueueRatherThanThrowing() async throws {
  let store = try makeStore()
  try await store.saveQueue(makeQueue(), accountID: alice)
  try await store.writeRawQueuePayloadForTesting(
    Data(#"{"schema":"from the future"}"#.utf8),
    accountID: alice
  )

  #expect(try await store.queue(accountID: alice) == nil)
}

@Test func clearingAnAccountLeavesTheOtherAccountAlone() async throws {
  let store = try makeStore()
  try await store.savePlaylists(makePlaylists([1]), accountID: alice)
  try await store.saveQueue(makeQueue(), accountID: alice)
  try await store.savePlaylists(makePlaylists([2]), accountID: bob)
  try await store.saveQueue(makeQueue(ids: [5], currentIndex: 0), accountID: bob)

  try await store.clear(accountID: alice)

  #expect(try await store.playlists(accountID: alice).isEmpty)
  #expect(try await store.queue(accountID: alice) == nil)
  #expect(try await store.playlists(accountID: bob).map(\.id) == [2])
  #expect(try await store.queue(accountID: bob)?.tracks.map(\.id) == [5])
}

/// The restored queue is what the artwork, the album line and Now Playing all
/// read, so the track model has to survive storage whole.
@Test func aRestoredTrackKeepsItsArtistsAlbumAndArtwork() async throws {
  let store = try makeStore()
  let track = Track(
    id: 1,
    name: "Song",
    artists: [ArtistRef(id: 5, name: "A"), ArtistRef(id: nil, name: "B")],
    album: AlbumRef(
      id: 9,
      name: "Album",
      artworkURL: URL(string: "https://p1.music.126.net/c.jpg")
    ),
    durationMilliseconds: 210_000
  )
  try await store.saveQueue(
    PersistedQueue(
      tracks: [track],
      currentIndex: 0,
      mode: .repeatOne,
      context: .searchResults(keywords: "x"),
      positionSeconds: 12,
      quality: .exhigh,
      wasPlaying: false
    ),
    accountID: alice
  )

  let restored = try await store.queue(accountID: alice)
  #expect(restored?.tracks == [track])
  #expect(restored?.context == .searchResults(keywords: "x"))
  #expect(restored?.mode == .repeatOne)
  #expect(restored?.quality == .exhigh)
  #expect(restored?.wasPlaying == false)
}

// MARK: - Showing a stored library before a reload

/// A window that opens empty while the user decides whether to reload is worse
/// than one showing what the server said last time — as long as it is clear it
/// cannot be paged from.
@Test @MainActor func aRestoredLibraryIsShownButNotPagedFrom() {
  let transport = FakeTransport()
  let credential = makeCredential()
  let library = PlaylistLibraryCoordinator(
    transport: transport,
    vault: FakeVault(stored: credential),
    arbiter: OperationArbiter()
  )

  library.restore(playlists: makePlaylists([1, 2]))

  #expect(library.playlists.map(\.id) == [1, 2])
  #expect(library.canLoadMore == false)
  #expect(library.playlistsNeedReload)
}

/// Rows the server confirmed this run are the truth. A late restore must not
/// put yesterday's list back over them.
@Test @MainActor func aRestoreNeverOverwritesConfirmedRows() async {
  let transport = FakeTransport()
  let credential = makeCredential()
  let session = FakeSession(credential: credential)
  let library = PlaylistLibraryCoordinator(
    transport: transport,
    vault: FakeVault(stored: credential),
    arbiter: OperationArbiter()
  )
  await transport.setPlaylistPages([
    UserPlaylistPage(playlists: makePlaylists([9]), more: false)
  ])
  library.load(reset: true, session: session)
  await library.settleForTesting()

  library.restore(playlists: makePlaylists([1, 2]))

  #expect(library.playlists.map(\.id) == [9])
}

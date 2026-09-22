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

@Test func aStoredPlaylistPreservesItsConfirmedMetadata() async throws {
  let store = try makeStore()
  let playlist = UserPlaylist(
    id: 1,
    name: "Private",
    trackCount: 3,
    owned: true,
    isPrivate: true
  )

  try await store.savePlaylists([playlist], accountID: alice)

  #expect(try await store.playlists(accountID: alice)[0] == playlist)
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

@Test func clearingOneQueueDoesNotTouchAnotherAccount() async throws {
  let store = try makeStore()
  try await store.saveQueue(makeQueue(ids: [1]), accountID: alice)
  try await store.saveQueue(makeQueue(ids: [2]), accountID: bob)

  try await store.clearQueue(accountID: alice)

  #expect(try await store.queue(accountID: alice) == nil)
  #expect(try await store.queue(accountID: bob)?.tracks.map(\.id) == [2])
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

// MARK: - A write that failed is retried, not remembered

@MainActor
private struct PersistenceRig {
  let store: LibraryStore
  let persistence: QueuePersistence
  let playback: PlaybackController
  let library: PlaylistLibraryCoordinator
  let transport = FakeTransport()
  let session: FakeSession

  init() throws {
    let credential = makeCredential()
    let vault = FakeVault(stored: credential)
    let arbiter = OperationArbiter()
    store = try LibraryStore(path: LibraryStore.inMemoryPath)
    session = FakeSession(credential: credential)
    playback = PlaybackController(
      transport: transport,
      vault: vault,
      arbiter: arbiter,
      output: FakeAudioOutput()
    )
    playback.attach(session: session)
    library = PlaylistLibraryCoordinator(
      transport: transport,
      vault: vault,
      arbiter: arbiter
    )
    persistence = QueuePersistence(store: store, playback: playback)
  }
}

@MainActor
private func connectPlaylistPersistence(
  _ library: PlaylistLibraryCoordinator,
  to persistence: QueuePersistence
) {
  library.onPersistablePlaylistsChanged = { accountID, playlists in
    await persistence.savePlaylists(playlists, accountID: accountID)
  }
}

/// `lastWritten` used to be set before the write was attempted, and the write
/// itself was a `try?`. One failed save therefore silenced every later one:
/// the queue looked stored and never was.
@Test @MainActor func aFailedQueueWriteIsRetriedRatherThanRemembered() async throws {
  let rig = try PersistenceRig()
  await rig.persistence.activate(accountID: alice)
  rig.playback.restore(makeQueue())

  await rig.store.failNextWriteForTesting()
  await rig.persistence.save()

  #expect(rig.persistence.lastFailure != nil)
  #expect(try await rig.store.queue(accountID: alice) == nil)

  await rig.persistence.save()

  #expect(rig.persistence.lastFailure == nil)
  #expect(try await rig.store.queue(accountID: alice)?.tracks.map(\.id) == [1, 2, 3])
  await rig.persistence.deactivate()
}

@Test @MainActor func aFailedPlaylistWriteIsReportedAndRetried() async throws {
  let rig = try PersistenceRig()
  await rig.persistence.activate(accountID: alice)

  await rig.store.failNextWriteForTesting()
  await rig.persistence.savePlaylists(makePlaylists([1, 2]), accountID: alice)

  #expect(rig.persistence.lastFailure != nil)
  #expect(try await rig.store.playlists(accountID: alice).isEmpty)

  await rig.persistence.savePlaylists(makePlaylists([1, 2]), accountID: alice)

  #expect(rig.persistence.lastFailure == nil)
  #expect(try await rig.store.playlists(accountID: alice).map(\.id) == [1, 2])
  await rig.persistence.deactivate()
}

// MARK: - Account-scoped playlist persistence

@Test @MainActor func signingOutAndResettingKeepTheAccountsPlaylistCache() async throws {
  let rig = try PersistenceRig()
  let cached = makePlaylists([1, 2])
  try await rig.store.savePlaylists(cached, accountID: alice)
  await rig.persistence.activate(accountID: alice)
  connectPlaylistPersistence(rig.library, to: rig.persistence)
  rig.library.restore(
    playlists: await rig.persistence.storedPlaylists(accountID: alice)
  )

  rig.library.reset()
  await rig.persistence.deactivate()

  #expect(try await rig.store.playlists(accountID: alice) == cached)
}

@Test @MainActor func switchingAccountsRestoresEachCacheWithoutSavingTheGap() async throws {
  let rig = try PersistenceRig()
  let alicePlaylists = makePlaylists([1, 2])
  let bobPlaylists = makePlaylists([8, 9])
  try await rig.store.savePlaylists(alicePlaylists, accountID: alice)
  try await rig.store.savePlaylists(bobPlaylists, accountID: bob)
  connectPlaylistPersistence(rig.library, to: rig.persistence)

  await rig.persistence.activate(accountID: alice)
  rig.library.restore(
    playlists: await rig.persistence.storedPlaylists(accountID: alice)
  )
  #expect(rig.library.playlists == alicePlaylists)

  rig.library.reset()
  await rig.persistence.activate(accountID: bob)
  rig.library.restore(
    playlists: await rig.persistence.storedPlaylists(accountID: bob)
  )

  #expect(rig.library.playlists == bobPlaylists)
  #expect(try await rig.store.playlists(accountID: alice) == alicePlaylists)
  #expect(try await rig.store.playlists(accountID: bob) == bobPlaylists)
  await rig.persistence.deactivate()
}

@Test @MainActor func aLateAliceSaveCannotWriteBob() async throws {
  let rig = try PersistenceRig()
  let alicePlaylists = makePlaylists([1])
  let bobPlaylists = makePlaylists([9])
  try await rig.store.savePlaylists(alicePlaylists, accountID: alice)
  try await rig.store.savePlaylists(bobPlaylists, accountID: bob)
  await rig.persistence.activate(accountID: alice)
  let gate = RequestGate()
  await gate.close()
  let persistence = rig.persistence
  let lateSave = Task { @MainActor in
    await gate.pass()
    await persistence.savePlaylists([], accountID: alice)
  }
  while await gate.arrivalCount() == 0 { await Task.yield() }
  await rig.persistence.activate(accountID: bob)

  await gate.open()
  await lateSave.value

  #expect(try await rig.store.playlists(accountID: alice) == alicePlaylists)
  #expect(try await rig.store.playlists(accountID: bob) == bobPlaylists)
  await rig.persistence.deactivate()
}

@Test @MainActor func anAuthoritativeEmptyPageReplacesTheOldCache() async throws {
  let rig = try PersistenceRig()
  try await rig.store.savePlaylists(makePlaylists([1, 2]), accountID: alice)
  await rig.persistence.activate(accountID: alice)
  connectPlaylistPersistence(rig.library, to: rig.persistence)
  await rig.transport.setPlaylistPages([
    UserPlaylistPage(playlists: [], more: false)
  ])

  rig.library.load(reset: true, session: rig.session)
  await rig.library.settleForTesting()

  #expect(try await rig.store.playlists(accountID: alice).isEmpty)
  await rig.persistence.deactivate()
}

/// Signing out keeps this account's place. The account is part of the key, so
/// nobody else can see it, and deactivating never touches the disk.
@Test @MainActor func signingOutKeepsThisAccountsQueueAndHidesItFromOthers() async throws {
  let rig = try PersistenceRig()
  await rig.persistence.activate(accountID: alice)
  rig.playback.restore(makeQueue())
  await rig.persistence.save()

  await rig.persistence.deactivate()

  #expect(try await rig.store.queue(accountID: alice) != nil)
  #expect(try await rig.store.queue(accountID: bob) == nil)
}

// MARK: - Changes that do not move the count

/// The coordinator emits the confirmed snapshot after a rename. The count and
/// ids do not move, so a count observer could never cover this change.
@Test @MainActor func aRenameChangesTheListWithoutChangingItsCount() async throws {
  let rig = try PersistenceRig()
  await rig.persistence.activate(accountID: alice)
  connectPlaylistPersistence(rig.library, to: rig.persistence)
  await rig.transport.setPlaylistPages([
    UserPlaylistPage(playlists: makePlaylists([1, 2]), more: false)
  ])
  rig.library.load(reset: true, session: rig.session)
  await rig.library.settleForTesting()
  rig.library.selectedPlaylist = rig.library.playlists[0]
  let before = rig.library.playlists

  rig.library.renameSelectedPlaylist(to: "Evening", session: rig.session)
  await rig.library.settleForTesting()

  #expect(rig.library.playlists.count == before.count)
  #expect(rig.library.playlists != before)

  #expect(
    try await rig.store.playlists(accountID: alice).map(\.name)
      == ["Evening", "playlist-2"]
  )
  await rig.persistence.deactivate()
}

// MARK: - Explicit Stop

@Test @MainActor func explicitStopClearsTheStoredQueueBeforeReactivation() async throws {
  let rig = try PersistenceRig()
  await rig.persistence.activate(accountID: alice)
  let persistence = rig.persistence
  rig.playback.onExplicitStop = {
    persistence.clearQueueAfterExplicitStop()
  }
  rig.playback.restore(makeQueue())
  await rig.persistence.save()

  rig.playback.stop()
  await rig.persistence.settleQueueClearForTesting()
  await rig.persistence.deactivate()
  await rig.persistence.activate(accountID: alice)

  #expect(try await rig.store.queue(accountID: alice) == nil)
  #expect(rig.playback.currentTrack == nil)
  await rig.persistence.deactivate()
}

@Test @MainActor func sessionCleanupKeepsTheQueueForTheSameAccount() async throws {
  let rig = try PersistenceRig()
  await rig.persistence.activate(accountID: alice)
  rig.playback.restore(makeQueue())
  await rig.persistence.save()

  rig.playback.stopForSessionChange()
  await rig.persistence.deactivate()
  await rig.persistence.activate(accountID: alice)

  #expect(try await rig.store.queue(accountID: alice) != nil)
  #expect(rig.playback.currentTrack?.id == 2)
  await rig.persistence.deactivate()
}

@Test @MainActor func aFailedExplicitStopClearIsRetried() async throws {
  let rig = try PersistenceRig()
  await rig.persistence.activate(accountID: alice)
  let persistence = rig.persistence
  rig.playback.onExplicitStop = {
    persistence.clearQueueAfterExplicitStop()
  }
  rig.playback.restore(makeQueue())
  await rig.persistence.save()
  await rig.store.failNextWriteForTesting()

  rig.playback.stop()
  await rig.persistence.settleQueueClearForTesting()

  #expect(rig.persistence.lastFailure != nil)
  #expect(try await rig.store.queue(accountID: alice) != nil)

  await rig.persistence.save()

  #expect(rig.persistence.lastFailure == nil)
  #expect(try await rig.store.queue(accountID: alice) == nil)
  await rig.persistence.deactivate()
}

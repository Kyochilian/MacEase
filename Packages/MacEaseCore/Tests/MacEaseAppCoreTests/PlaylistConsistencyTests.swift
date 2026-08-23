import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

/// P0-04: the page cursor comes from what the server returned, not from the
/// length of the visible array, and a write never leaves the counts, the id
/// list and the rows describing different playlists.

// MARK: - Paging cursor

@Test func theCursorFollowsWhatTheServerReturnedNotTheVisibleCount() {
  var collection = PlaylistCollection()
  collection.apply(
    page: UserPlaylistPage(playlists: makePlaylists(Array(1...30)), more: true),
    replacingAll: true
  )

  #expect(collection.nextOffset == 30)
  #expect(collection.canLoadMore)

  // A page that repeats two rows still advances the cursor by 30.
  let duplicates = collection.apply(
    page: UserPlaylistPage(
      playlists: makePlaylists(Array(29...58)),
      more: true
    ),
    replacingAll: false
  )

  #expect(duplicates == 2)
  #expect(collection.nextOffset == 60)
  #expect(collection.playlists.count == 58)
  #expect(collection.duplicateRowsDropped == 2)
  #expect(Set(collection.playlists.map(\.id)).count == 58)
}

@Test func creatingAPlaylistStopsPagingUntilAnExplicitReload() {
  var collection = PlaylistCollection()
  collection.apply(
    page: UserPlaylistPage(playlists: makePlaylists(Array(1...30)), more: true),
    replacingAll: true
  )
  collection.markStaleAfterMutation()

  #expect(!collection.canLoadMore)
  #expect(collection.needsExplicitReload)

  collection.apply(
    page: UserPlaylistPage(playlists: makePlaylists(Array(1...30)), more: true),
    replacingAll: true
  )
  #expect(collection.canLoadMore)
  #expect(collection.nextOffset == 30)
}

@Test func deletingARowRemovesItAndStopsPaging() {
  var collection = PlaylistCollection()
  collection.apply(
    page: UserPlaylistPage(playlists: makePlaylists([1, 2, 3]), more: true),
    replacingAll: true
  )
  collection.remove(id: 2)
  collection.markStaleAfterMutation()

  #expect(collection.playlists.map(\.id) == [1, 3])
  // The cursor is untouched: it is no longer usable, not merely shorter.
  #expect(collection.nextOffset == 3)
  #expect(!collection.canLoadMore)
}

@Test func adjustingATrackCountNeverGoesNegative() {
  var collection = PlaylistCollection()
  collection.apply(
    page: UserPlaylistPage(playlists: makePlaylists([1]), more: false),
    replacingAll: true
  )

  collection.adjustTrackCount(playlistID: 1, by: 1)
  #expect(collection.playlists[0].trackCount == 4)
  collection.adjustTrackCount(playlistID: 1, by: -10)
  #expect(collection.playlists[0].trackCount == 0)
  // An unknown id is a no-op, not a crash.
  collection.adjustTrackCount(playlistID: 999, by: 1)
  #expect(collection.playlists.count == 1)
}

// MARK: - Track detail consistency

/// `#expect` cannot call a mutating member on its captured value.
private func removed(
  _ detail: inout PlaylistTrackCollection,
  _ id: Int64
) -> Bool {
  detail.removeTrack(id: id)
}

private func loadedDetail(
  idCount: Int,
  batchLimit: Int
) -> PlaylistTrackCollection {
  var detail = PlaylistTrackCollection()
  let ids = Array(Int64(1)...Int64(idCount))
  detail.begin(trackIDs: ids)
  let batch = detail.nextBatch(limit: batchLimit)
  detail.appendBatch(makeTracks(batch), requestedCount: batch.count)
  return detail
}

@Test func removingALoadedTrackKeepsEveryCounterInStep() {
  var detail = loadedDetail(idCount: 1500, batchLimit: 1000)
  #expect(detail.trackIDs.count == 1500)
  #expect(detail.loadedIDCount == 1000)
  #expect(detail.tracks.count == 1000)
  #expect(detail.canLoadMore)

  #expect(removed(&detail, 1))
  #expect(detail.trackIDs.count == 1499)
  #expect(detail.loadedIDCount == 999)
  #expect(detail.tracks.count == 999)

  #expect(removed(&detail, 500))
  #expect(removed(&detail, 1000))
  #expect(detail.trackIDs.count == 1497)
  #expect(detail.loadedIDCount == 997)
  #expect(detail.tracks.count == 997)

  // The next slice starts where the loaded ids end, so nothing is skipped and
  // nothing is fetched twice.
  let next = detail.nextBatch(limit: 1000)
  #expect(next.first == 1001)
  #expect(next.count == 500)
}

@Test func removingATrackThatIsNotLoadedYetDoesNotMoveTheCursor() {
  var detail = loadedDetail(idCount: 1500, batchLimit: 1000)

  #expect(removed(&detail, 1200))
  #expect(detail.loadedIDCount == 1000)
  #expect(detail.trackIDs.count == 1499)
  #expect(detail.tracks.count == 1000)
  #expect(!detail.trackIDs.contains(1200))
}

@Test func removingAnUnknownTrackChangesNothing() {
  var detail = loadedDetail(idCount: 10, batchLimit: 10)
  let before = detail

  #expect(!removed(&detail, 999))
  #expect(detail == before)
}

@Test func aRemovedTrackNeverComesBackOnTheNextPage() {
  var detail = loadedDetail(idCount: 2000, batchLimit: 1000)
  _ = removed(&detail, 5)

  let next = detail.nextBatch(limit: 1000)
  #expect(!next.contains(5))
  detail.appendBatch(makeTracks(next), requestedCount: next.count)

  #expect(!detail.tracks.contains { $0.id == 5 })
  #expect(detail.tracks.count == detail.trackIDs.count)
  #expect(!detail.canLoadMore)
}

@Test func addingToTheOpenPlaylistStopsPagingUntilItIsReopened() {
  var detail = loadedDetail(idCount: 1500, batchLimit: 1000)
  detail.markStaleAfterMutation()

  #expect(!detail.canLoadMore)
  #expect(detail.needsExplicitReload)

  detail.begin(trackIDs: Array(Int64(1)...Int64(1501)))
  #expect(detail.canLoadMore)
}

/// The server omits tracks it no longer serves, so the cursor advances by
/// what was asked for rather than by what came back.
@Test func aShortBatchStillAdvancesTheCursor() {
  var detail = PlaylistTrackCollection()
  detail.begin(trackIDs: Array(Int64(1)...Int64(20)))
  let batch = detail.nextBatch(limit: 10)
  detail.appendBatch(makeTracks([1, 2, 3]), requestedCount: batch.count)

  #expect(detail.loadedIDCount == 10)
  #expect(detail.tracks.count == 3)
  #expect(detail.nextBatch(limit: 10) == Array(Int64(11)...Int64(20)))
}

// MARK: - Coordinator-level behaviour

@MainActor
private struct LibraryRig {
  let transport = FakeTransport()
  let vault: FakeVault
  let arbiter = OperationArbiter()
  let session: FakeSession
  let library: PlaylistLibraryCoordinator

  init() {
    let credential = makeCredential()
    vault = FakeVault(stored: credential)
    session = FakeSession(credential: credential)
    library = PlaylistLibraryCoordinator(
      transport: transport,
      vault: vault,
      arbiter: arbiter
    )
  }

  func loadFirstPage(_ ids: [Int64], more: Bool) async {
    await transport.setPlaylistPages([
      UserPlaylistPage(playlists: makePlaylists(ids), more: more)
    ])
    library.load(reset: true, session: session)
    await library.settleForTesting()
  }
}

@Test @MainActor func loadMoreIsRefusedAfterEachCollectionChangingWrite() async {
  for write in ["create", "delete", "subscribe", "unsubscribe"] {
    let rig = LibraryRig()
    await rig.loadFirstPage(Array(1...30), more: true)
    #expect(rig.library.canLoadMore, "\(write): paging should start usable")

    switch write {
    case "create":
      rig.library.createPlaylist(named: "new", session: rig.session)
    case "delete":
      rig.library.deletePlaylist(rig.library.playlists[0], session: rig.session)
    case "subscribe":
      rig.library.setSubscribed(
        true,
        playlistID: 99,
        playlistName: "other",
        session: rig.session
      )
    default:
      rig.library.setSubscribed(
        false,
        playlistID: 1,
        playlistName: "playlist-1",
        session: rig.session
      )
    }
    await rig.library.settleForTesting()

    #expect(!rig.library.canLoadMore, "\(write): paging must stop")
    #expect(rig.library.playlistsNeedReload, "\(write): a reload must be asked for")

    // Load More must not reach the transport while the cursor is stale.
    let before = await rig.transport.callCount()
    rig.library.load(reset: false, session: rig.session)
    await rig.library.settleForTesting()
    #expect(await rig.transport.callCount() == before, "\(write): no extra read")

    // An explicit reload starts over and makes paging usable again.
    await rig.transport.setPlaylistPages([
      UserPlaylistPage(playlists: makePlaylists(Array(1...30)), more: true)
    ])
    rig.library.load(reset: true, session: rig.session)
    await rig.library.settleForTesting()
    #expect(rig.library.canLoadMore, "\(write): reload restores paging")
  }
}

@Test @MainActor func renamingKeepsPagingUsable() async {
  let rig = LibraryRig()
  await rig.loadFirstPage(Array(1...30), more: true)
  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 1, name: "playlist-1", trackIDs: [7]))
  )
  await rig.transport.setSongDetailBatches([makeTracks([7])])
  rig.library.loadTracks(for: rig.library.playlists[0], session: rig.session)
  await rig.library.settleForTesting()

  rig.library.renameSelectedPlaylist(to: "renamed", session: rig.session)
  await rig.library.settleForTesting()

  #expect(rig.library.playlists[0].name == "renamed")
  #expect(rig.library.selectedPlaylist?.name == "renamed")
  #expect(rig.library.canLoadMore)
}

@Test @MainActor func removingATrackUpdatesBothTrackCounts() async {
  let rig = LibraryRig()
  await rig.loadFirstPage([1], more: false)
  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 1, name: "playlist-1", trackIDs: [10, 11, 12]))
  )
  await rig.transport.setSongDetailBatches([makeTracks([10, 11, 12])])
  rig.library.loadTracks(for: rig.library.playlists[0], session: rig.session)
  await rig.library.settleForTesting()
  #expect(rig.library.selectedPlaylist?.trackCount == 3)

  rig.library.removeSelectedPlaylistTrack(id: 11, session: rig.session)
  await rig.library.settleForTesting()

  #expect(rig.library.tracks.map(\.id) == [10, 12])
  #expect(rig.library.detail.trackIDs == [10, 12])
  #expect(rig.library.detail.loadedIDCount == 2)
  #expect(rig.library.selectedPlaylist?.trackCount == 2)
  #expect(rig.library.playlists[0].trackCount == 2)
  #expect(!rig.library.canLoadMoreTracks)
}

@Test @MainActor func removingATrackSendsTheIdTheUserPickedNotARowPosition() async {
  let rig = LibraryRig()
  await rig.loadFirstPage([1], more: false)
  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 1, name: "playlist-1", trackIDs: [10, 11, 12]))
  )
  await rig.transport.setSongDetailBatches([makeTracks([10, 11, 12])])
  rig.library.loadTracks(for: rig.library.playlists[0], session: rig.session)
  await rig.library.settleForTesting()

  rig.library.removeSelectedPlaylistTrack(id: 12, session: rig.session)
  await rig.library.settleForTesting()

  #expect(
    await rig.transport.recordedCalls().contains(
      .editPlaylistTracks(.del, 1, [12])
    )
  )
  #expect(rig.library.tracks.map(\.id) == [10, 11])
}

@Test @MainActor func addingToTheOpenPlaylistMarksItStaleAndBumpsTheCount() async {
  let rig = LibraryRig()
  await rig.loadFirstPage([1], more: false)
  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 1, name: "playlist-1", trackIDs: [10]))
  )
  await rig.transport.setSongDetailBatches([makeTracks([10])])
  rig.library.loadTracks(for: rig.library.playlists[0], session: rig.session)
  await rig.library.settleForTesting()

  rig.library.addTrack(
    makeTracks([77])[0],
    to: rig.library.playlists[0],
    session: rig.session
  )
  await rig.library.settleForTesting()

  #expect(rig.library.tracksNeedReload)
  #expect(!rig.library.canLoadMoreTracks)
  #expect(rig.library.selectedPlaylist?.trackCount == 2)
  #expect(rig.library.playlists[0].trackCount == 2)
}

@Test @MainActor func addingToADifferentPlaylistOnlyBumpsThatRowsCount() async {
  let rig = LibraryRig()
  await rig.loadFirstPage([1, 2], more: false)
  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 1, name: "playlist-1", trackIDs: [10]))
  )
  await rig.transport.setSongDetailBatches([makeTracks([10])])
  rig.library.loadTracks(for: rig.library.playlists[0], session: rig.session)
  await rig.library.settleForTesting()

  rig.library.addTrack(
    makeTracks([77])[0],
    to: rig.library.playlists[1],
    session: rig.session
  )
  await rig.library.settleForTesting()

  #expect(!rig.library.tracksNeedReload)
  #expect(rig.library.playlists[1].trackCount == 4)
  #expect(rig.library.selectedPlaylist?.trackCount == 1)
}

/// A write that reached the server but could not be published locally must
/// leave the visible state untouched and be reported as unknown.
@Test @MainActor func aRemovalWithAFailedPostflightIsNotAppliedLocally() async {
  let rig = LibraryRig()
  await rig.loadFirstPage([1], more: false)
  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 1, name: "playlist-1", trackIDs: [10, 11]))
  )
  await rig.transport.setSongDetailBatches([makeTracks([10, 11])])
  rig.library.loadTracks(for: rig.library.playlists[0], session: rig.session)
  await rig.library.settleForTesting()

  await rig.transport.gate.close()
  rig.library.removeSelectedPlaylistTrack(id: 10, session: rig.session)
  while await rig.transport.gate.arrivalCount() == 0 { await Task.yield() }
  await rig.vault.setStored(makeCredential("replacement"))
  await rig.transport.gate.open()
  await rig.library.settleForTesting()

  #expect(rig.arbiter.unresolvedOutcomes.map(\.name) == ["Remove track"])
  #expect(rig.arbiter.unresolvedOutcomes.map(\.kind) == [.appliedRemotelyOnly])
  #expect(rig.library.status == "Session changed; validate again")
  // The removal is not applied as a local edit. The session changed, so the
  // whole session-scoped view is dropped rather than half-updated.
  #expect(rig.library.tracks.isEmpty)
  #expect(rig.library.playlists.isEmpty)
  #expect(rig.library.selectedPlaylist == nil)
}

@Test @MainActor func duplicateRowsFromTheServerAreReportedNotShownTwice() async {
  let rig = LibraryRig()
  await rig.loadFirstPage([1, 2, 3], more: true)
  await rig.transport.setPlaylistPages([
    UserPlaylistPage(playlists: makePlaylists([3, 4]), more: false)
  ])

  rig.library.load(reset: false, session: rig.session)
  await rig.library.settleForTesting()

  #expect(rig.library.playlists.map(\.id) == [1, 2, 3, 4])
  #expect(rig.library.status.contains("dropped 1 duplicate rows"))
  #expect(rig.library.collection.nextOffset == 5)
}

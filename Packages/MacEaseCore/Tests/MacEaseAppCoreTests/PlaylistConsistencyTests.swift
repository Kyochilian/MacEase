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

  collection.apply(
    page: UserPlaylistPage(
      playlists: makePlaylists(Array(31...60)),
      more: true
    ),
    replacingAll: false
  )

  #expect(collection.nextOffset == 60)
  #expect(collection.playlists.count == 60)
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

  func loadFirstPage(_ ids: [Int64], more: Bool, owned: Bool = true) async {
    await transport.setPlaylistPages([
      UserPlaylistPage(playlists: makePlaylists(ids, owned: owned), more: more)
    ])
    library.load(reset: true, session: session)
    await library.settleForTesting()
  }

  func openLiked(_ ids: [Int64]) async {
    await transport.setPlaylistPages([
      UserPlaylistPage(playlists: [
        UserPlaylist(id: 17, name: "Liked", trackCount: ids.count, owned: true, specialType: 5)
      ], more: false)
    ])
    await transport.setLikedIDs(.success(ids))
    await transport.setPlaylistDetail(.success(PlaylistDetail(id: 17, name: "Liked", trackIDs: ids)))
    await transport.setSongDetailBatches([makeTracks(Array(ids.prefix(NeteaseSession.songDetailRequestLimit)))])
    await library.openLikedSongs(session: session)
    await library.settleForTesting()
  }
}

@Test @MainActor func unlikeKeepsLikedPlaylistIDsRowsCountsAndPaginationConsistent() async {
  for removedID: Int64 in [1, 1001] {
    let rig = LibraryRig()
    await rig.openLiked(Array(1...1002))
    let before = await rig.transport.callCount()
    #expect(rig.library.setLiked(false, for: makeTracks([removedID])[0], session: rig.session))
    await rig.library.settleForTesting()
    #expect(rig.library.liked.state(of: removedID) == .notLiked)
    #expect(!rig.library.detail.trackIDs.contains(removedID))
    #expect(!rig.library.tracks.contains { $0.id == removedID })
    #expect(rig.library.selectedPlaylist?.trackCount == 1001)
    #expect(rig.library.playlists.first?.trackCount == 1001)
    #expect(rig.library.detail.loadedIDCount == (removedID == 1 ? 999 : 1000))
    #expect(rig.library.detail.nextBatch(limit: 1000) == (removedID == 1 ? [1001, 1002] : [1002]))
    #expect(await rig.transport.callCount() == before + 1)
    #expect(!rig.library.tracksNeedReload)
  }
}

@Test @MainActor func unlikingTheOnlySongLeavesAnEmptyPlayableCollection() async {
  let rig = LibraryRig()
  await rig.openLiked([1])
  rig.library.setLiked(false, for: makeTracks([1])[0], session: rig.session)
  await rig.library.settleForTesting()
  #expect(rig.library.tracks.isEmpty)
  #expect(rig.library.detail.trackIDs.isEmpty)
  #expect(rig.library.selectedPlaylist?.trackCount == 0)
  #expect(rig.library.playlists.first?.trackCount == 0)
}

@Test @MainActor func matchedCloudAddsThePublicSongAndUnmatchedBatchIsRefused() async {
  let rig = LibraryRig()
  await rig.loadFirstPage([17], more: false)
  let playlist = rig.library.playlists[0]
  let matched = Track(id: 9001, name: "Matched", cloudFileID: 9001, catalogSongID: 42)
  rig.library.addTrack(matched, to: playlist, session: rig.session)
  await rig.library.settleForTesting()
  #expect(await rig.transport.recordedCalls().contains(.editPlaylistTracks(.add, 17, [42])))
  let before = await rig.transport.callCount()
  rig.library.editTracks(
    .add, tracks: [makeTracks([43])[0], Track(id: 9002, name: "Unmatched", cloudFileID: 9002)],
    in: playlist, session: rig.session)
  await rig.library.settleForTesting()
  #expect(await rig.transport.callCount() == before)
  #expect(rig.library.status.contains("Match each cloud file"))
}

@Test @MainActor func likingIntoAnOpenSpecialPlaylistUsesConfirmedServerOrder() async {
  let rig = LibraryRig()
  await rig.openLiked([1, 2])
  await rig.transport.setPlaylistDetail(.success(
    PlaylistDetail(id: 17, name: "Liked", trackIDs: [3, 1, 2])))
  await rig.transport.setSongDetailBatches([makeTracks([3, 1, 2])])
  let before = await rig.transport.callCount()
  rig.library.setLiked(true, for: makeTracks([3])[0], session: rig.session)
  await rig.library.settleForTesting()
  #expect(rig.library.tracks.map(\.id) == [3, 1, 2])
  #expect(rig.library.detail.trackIDs == [3, 1, 2])
  #expect(rig.library.selectedPlaylist?.trackCount == 3)
  #expect(rig.library.playlists.first?.trackCount == 3)
  #expect(rig.library.liked.state(of: 3) == .liked)
  #expect(await rig.transport.callCount() == before + 3)
}

@Test @MainActor func failedOrUnknownUnlikeDoesNotInventAConfirmedRemoval() async {
  for unknown in [false, true] {
    let rig = LibraryRig()
    await rig.openLiked([1])
    await rig.transport.setWriteResult(.failure(
      NeteaseServiceError(source: unknown ? .http : .service, statusCode: 503)))
    let before = await rig.transport.callCount()
    rig.library.setLiked(false, for: makeTracks([1])[0], session: rig.session)
    await rig.library.settleForTesting()
    #expect(rig.library.tracks.map(\.id) == [1])
    #expect(rig.library.selectedPlaylist?.trackCount == 1)
    #expect(rig.library.liked.state(of: 1) == .liked)
    #expect(rig.arbiter.unresolvedOutcomes.isEmpty == !unknown)
    #expect(await rig.transport.callCount() == before + 1)
  }
}

@Test @MainActor func unlikePostflightCannotPublishIntoAReplacementAccount() async {
  let rig = LibraryRig()
  await rig.openLiked([1])
  await rig.transport.gate.close()
  let before = await rig.transport.gate.arrivalCount()
  rig.library.setLiked(false, for: makeTracks([1])[0], session: rig.session)
  while await rig.transport.gate.arrivalCount() == before { await Task.yield() }
  await rig.vault.setStored(makeCredential("replacement"))
  await rig.transport.gate.open()
  await rig.library.settleForTesting()
  #expect(rig.library.playlists.isEmpty)
  #expect(rig.library.tracks.isEmpty)
  #expect(rig.library.liked.state(of: 1) == .unknown)
  #expect(rig.arbiter.unresolvedOutcomes.map(\.kind) == [.appliedRemotelyOnly])
}

@Test @MainActor func likedWriteReadbackFailureKeepsSuccessAndRequiresFreshPlaybackMetadata() async {
  let rig = LibraryRig()
  await rig.openLiked([1])
  await rig.transport.setPlaylistDetail(.failure(URLError(.timedOut)))
  rig.library.setLiked(true, for: makeTracks([2])[0], session: rig.session)
  await rig.library.settleForTesting()
  #expect(rig.library.liked.state(of: 2) == .liked)
  #expect(rig.library.tracksNeedReload)
  #expect(rig.library.status.contains("saved, but"))
  #expect(rig.arbiter.unresolvedOutcomes.isEmpty)
}

@Test @MainActor func aStaleCursorRestartsAtZeroAfterCollectionChangingWrites() async {
  for write in ["create", "delete", "subscribe", "unsubscribe"] {
    let rig = LibraryRig()
    await rig.loadFirstPage(Array(1...30), more: true, owned: write != "unsubscribe")
    #expect(rig.library.canLoadMore, "\(write): paging should start usable")

    switch write {
    case "create":
      rig.library.createPlaylist(named: "new", isPrivate: false, session: rig.session)
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

    // A new paging intent must refresh the first page, never use the old offset.
    let before = await rig.transport.callCount()
    rig.library.load(reset: false, session: rig.session)
    await rig.library.settleForTesting()
    #expect(await rig.transport.callCount() == before + 1)
    #expect(await rig.transport.recordedCalls().last == .userPlaylists(offset: 0, limit: 30))

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

// MARK: - Privacy

/// Creating a private playlist is one write on the same path as any other:
/// the user pressed the button, it goes through the arbiter, and the privacy
/// choice reaches the transport rather than being dropped on the way.
@Test @MainActor func creatingAPrivatePlaylistIsOneArbitratedWrite() async {
  let rig = LibraryRig()
  await rig.loadFirstPage([1], more: false)

  rig.library.createPlaylist(named: "  Secret  ", isPrivate: true, session: rig.session)
  #expect(rig.arbiter.active?.effect == .write)
  await rig.library.settleForTesting()

  #expect(await rig.transport.recordedCalls().last == .createPlaylist("Secret", isPrivate: true))
  #expect(rig.library.selectedPlaylist?.id == 9999)
  #expect(rig.library.playlists.first?.name == "Secret")
  #expect(rig.arbiter.canStart())
  #expect(rig.arbiter.unresolvedOutcomes.isEmpty)
}

/// Publishing is the only privacy change MacEase makes to a playlist that
/// already exists, and it retires the page cursor because whether the server
/// reorders afterwards is not something this client has verified.
@Test @MainActor func publishingAPlaylistSynchronizesPrivacyAndRestartsTheCursor() async {
  let rig = LibraryRig()
  await rig.transport.setPlaylistPages([
    UserPlaylistPage(
      playlists: makePlaylists(Array(1...30), isPrivate: true),
      more: true
    )
  ])
  rig.library.load(reset: true, session: rig.session)
  await rig.library.settleForTesting()
  #expect(rig.library.canLoadMore)
  rig.library.selectedPlaylist = rig.library.playlists[0]

  var published = makePlaylists(Array(1...30), isPrivate: true)
  published[0].isPrivate = false
  await rig.transport.setPlaylistPages([UserPlaylistPage(playlists: published, more: true)])

  rig.library.publishPlaylist(rig.library.playlists[0], session: rig.session)
  #expect(rig.arbiter.active?.effect == .write)
  await rig.library.settleForTesting()

  let calls = await rig.transport.recordedCalls()
  #expect(calls.last == .userPlaylists(offset: 0, limit: 30))
  #expect(calls.filter { $0 == .publishPrivatePlaylist(1) }.count == 1)
  #expect(rig.library.canLoadMore)
  #expect(!rig.library.playlistsNeedReload)
  #expect(rig.library.playlists[0].isPrivate == false)
  #expect(rig.library.selectedPlaylist?.isPrivate == false)
  #expect(rig.arbiter.canStart())
}

@Test @MainActor func onlyAnOwnedPrivatePlaylistCanBePublished() async {
  let refused = [
    UserPlaylist(
      id: 1,
      name: "Public",
      trackCount: 1,
      owned: true,
      isPrivate: false
    ),
    UserPlaylist(
      id: 2,
      name: "Unknown",
      trackCount: 1,
      owned: true,
      isPrivate: nil
    ),
    UserPlaylist(
      id: 3,
      name: "Saved",
      trackCount: 1,
      owned: false,
      isPrivate: true
    ),
  ]

  for playlist in refused {
    let rig = LibraryRig()
    await rig.transport.setPlaylistPages([
      UserPlaylistPage(playlists: [playlist], more: false)
    ])
    rig.library.load(reset: true, session: rig.session)
    await rig.library.settleForTesting()
    let before = await rig.transport.callCount()

    rig.library.publishPlaylist(playlist, session: rig.session)
    await rig.library.settleForTesting()

    #expect(await rig.transport.callCount() == before)
    #expect(rig.arbiter.canStart())
  }
}

@Test @MainActor func privacySurvivesDetailRenameAndTrackCountUpdates() async {
  let rig = LibraryRig()
  await rig.transport.setPlaylistPages([
    UserPlaylistPage(playlists: makePlaylists([1], isPrivate: true), more: false)
  ])
  rig.library.load(reset: true, session: rig.session)
  await rig.library.settleForTesting()
  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 1, name: "Private", trackIDs: [10]))
  )
  await rig.transport.setSongDetailBatches([makeTracks([10])])

  rig.library.loadTracks(for: rig.library.playlists[0], session: rig.session)
  await rig.library.settleForTesting()
  #expect(rig.library.playlists[0].isPrivate == true)
  #expect(rig.library.selectedPlaylist?.isPrivate == true)

  rig.library.renameSelectedPlaylist(to: "Renamed", session: rig.session)
  await rig.library.settleForTesting()
  #expect(rig.library.playlists[0].isPrivate == true)
  #expect(rig.library.selectedPlaylist?.isPrivate == true)

  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 1, name: "Renamed", trackIDs: [10, 11])))
  await rig.transport.setSongDetailBatches([makeTracks([10, 11])])
  rig.library.addTrack(
    makeTracks([11])[0],
    to: rig.library.playlists[0],
    session: rig.session
  )
  await rig.library.settleForTesting()
  #expect(rig.library.playlists[0].trackCount == 2)
  #expect(rig.library.playlists[0].isPrivate == true)
  #expect(rig.library.selectedPlaylist?.isPrivate == true)
}

/// Local SQLite work must not split the detail request from its song-detail
/// request. An await in that gap lets another read invalidate the session and
/// leaves this task able to send request two with the credential just retired.
@Test @MainActor func persistenceRunsAfterTheTwoRequestDetailFlow() async {
  let rig = LibraryRig()
  await rig.loadFirstPage([1], more: false)
  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 1, name: "Changed", trackIDs: [10]))
  )
  await rig.transport.setSongDetailBatches([makeTracks([10])])
  let persistenceGate = RequestGate()
  await persistenceGate.close()
  rig.library.onPersistablePlaylistsChanged = { _, _ in
    await persistenceGate.pass()
  }

  rig.library.loadTracks(for: rig.library.playlists[0], session: rig.session)
  while await persistenceGate.arrivalCount() == 0 { await Task.yield() }

  #expect(
    await rig.transport.recordedCalls().suffix(2)
      == [.playlistDetail(1), .songDetails([10])]
  )

  await persistenceGate.open()
  await rig.library.settleForTesting()
  #expect(rig.library.selectedPlaylist?.name == "Changed")
  #expect(rig.library.tracks.map(\.id) == [10])
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

  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 1, name: "playlist-1", trackIDs: [10, 12])))
  await rig.transport.setSongDetailBatches([makeTracks([10, 12])])
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

  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 1, name: "playlist-1", trackIDs: [10, 11])))
  await rig.transport.setSongDetailBatches([makeTracks([10, 11])])
  rig.library.removeSelectedPlaylistTrack(id: 12, session: rig.session)
  await rig.library.settleForTesting()

  #expect(
    await rig.transport.recordedCalls().contains(
      .editPlaylistTracks(.del, 1, [12])
    )
  )
  #expect(rig.library.tracks.map(\.id) == [10, 11])
}

@Test @MainActor func addingToTheOpenPlaylistUsesTheServerOrderAndCount() async {
  let rig = LibraryRig()
  await rig.loadFirstPage([1], more: false)
  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 1, name: "playlist-1", trackIDs: [10]))
  )
  await rig.transport.setSongDetailBatches([makeTracks([10])])
  rig.library.loadTracks(for: rig.library.playlists[0], session: rig.session)
  await rig.library.settleForTesting()

  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 1, name: "playlist-1", trackIDs: [77, 10])))
  await rig.transport.setSongDetailBatches([makeTracks([77, 10])])
  rig.library.addTrack(
    makeTracks([77])[0],
    to: rig.library.playlists[0],
    session: rig.session
  )
  await rig.library.settleForTesting()

  #expect(!rig.library.tracksNeedReload)
  #expect(rig.library.tracks.map(\.id) == [77, 10])
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

  await rig.transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 2, name: "playlist-2", trackIDs: [20, 21, 22, 77])))
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

  #expect(rig.arbiter.unresolvedOutcomes.map(\.name) == ["Remove tracks"])
  #expect(rig.arbiter.unresolvedOutcomes.map(\.kind) == [.appliedRemotelyOnly])
  #expect(rig.library.status == "Session changed; validate again")
  // The removal is not applied as a local edit. The session changed, so the
  // whole session-scoped view is dropped rather than half-updated.
  #expect(rig.library.tracks.isEmpty)
  #expect(rig.library.playlists.isEmpty)
  #expect(rig.library.selectedPlaylist == nil)
}

import Foundation
import Testing

@testable import MacEaseAppCore
@testable import NeteaseKit

@MainActor private struct ResponseRig {
  let transport = FakeTransport()
  let credential = makeCredential()
  let vault: FakeVault
  let session: FakeSession
  let arbiter = OperationArbiter()
  init() {
    vault = FakeVault(stored: credential)
    session = FakeSession(credential: credential)
  }
  var catalog: CatalogCoordinator {
    CatalogCoordinator(transport: transport, vault: vault, arbiter: arbiter)
  }
  var library: PlaylistLibraryCoordinator {
    PlaylistLibraryCoordinator(transport: transport, vault: vault, arbiter: arbiter)
  }
}

@Test @MainActor func albumTracksAppearBeforeSlowMembershipAndSurviveItsFailure() async {
  let rig = ResponseRig()
  let catalog = rig.catalog
  let gate = RequestGate()
  await gate.close()
  await rig.transport.setGate(gate, for: .albumDynamic(5))
  await rig.transport.setAlbumDetail(
    .success(AlbumDetail(album: makeAlbums([5])[0], tracks: makeTracks([1]))))
  await rig.transport.setAlbumDynamic(.failure(URLError(.timedOut)))
  catalog.openAlbum(id: 5, session: rig.session)
  for _ in 0..<2000 {
    if catalog.album != nil, await gate.arrivalCount() == 1 { break }
    await Task.yield()
  }
  #expect(catalog.album?.tracks.map(\.id) == [1])
  #expect(catalog.isLoadingDetail)
  await gate.open()
  await catalog.settleForTesting()
  #expect(catalog.album?.tracks.map(\.id) == [1])
  #expect(catalog.detailStatus.contains("collection status unavailable"))
}

@Test @MainActor func homePublishesOtherSectionsWhileDailySongsAreSlow() async {
  let rig = ResponseRig()
  let home = DiscoveryCoordinator(transport: rig.transport, vault: rig.vault, arbiter: rig.arbiter)
  let gate = RequestGate()
  await gate.close()
  await rig.transport.setGate(gate, for: .dailyRecommendedSongs)
  await rig.transport.setDiscoveryTracks(.success(makeTracks([1])))
  await rig.transport.setDiscoveryPlaylists(.success(makeDiscovered([2])))
  home.prefetch(session: rig.session)
  for _ in 0..<2000 {
    if !home.toplists.isEmpty, !home.personalized.isEmpty { break }
    await Task.yield()
  }
  #expect(home.dailySongs.isEmpty)
  #expect(home.toplists.map(\.id) == [2])
  #expect(home.personalized.map(\.id) == [2])
  await gate.open()
  await home.settleForTesting()
  #expect(home.dailySongs.map(\.id) == [1])
}

@Test @MainActor func playlistUsesEmbeddedSongsAndOnlyRequestsMissingMetadata() async {
  let rig = ResponseRig()
  let library = rig.library
  await rig.transport.setPlaylistDetail(
    .success(
      PlaylistDetail(
        id: 5, name: "Playlist", trackIDs: [1, 2, 3], tracks: makeTracks([1, 3]))))
  await rig.transport.setSongDetailBatches([makeTracks([2])])
  let gate = RequestGate()
  await gate.close()
  await rig.transport.setGate(gate, for: .songDetails([2]))
  library.loadTracks(for: makePlaylists([5])[0], session: rig.session)
  for _ in 0..<2000 {
    if await gate.arrivalCount() == 1 { break }
    await Task.yield()
  }
  #expect(library.tracks.map(\.id) == [1, 3])
  await gate.open()
  await library.settleForTesting()
  #expect(library.tracks.map(\.id) == [1, 2, 3])
  #expect(library.detail.loadedIDCount == 3)
  #expect(await rig.transport.recordedCalls() == [.playlistDetail(5), .songDetails([2])])
}

@Test @MainActor func completePlaylistNeedsOnlyOneRequest() async {
  let rig = ResponseRig()
  let library = rig.library
  await rig.transport.setPlaylistDetail(
    .success(
      PlaylistDetail(
        id: 5, name: "Playlist", trackIDs: [1, 2], tracks: makeTracks([1, 2]))))
  library.loadTracks(for: makePlaylists([5])[0], session: rig.session)
  await library.settleForTesting()
  #expect(library.tracks.map(\.id) == [1, 2])
  #expect(await rig.transport.recordedCalls() == [.playlistDetail(5)])
}

@Test @MainActor func remainingPlaylistBatchesOverlapAndKeepCanonicalOrder() async {
  let rig = ResponseRig()
  let library = rig.library
  let ids = Array(Int64(1)...3001)
  await rig.transport.setPlaylistDetail(
    .success(
      PlaylistDetail(
        id: 5, name: "Large playlist", trackIDs: ids, tracks: makeTracks(Array(ids.prefix(1000))))))
  await rig.transport.setSongDetailBatches([makeTracks(Array(Int64(1001)...2000))])
  library.loadTracks(for: makePlaylists([5])[0], session: rig.session)
  await library.settleForTesting()

  let delayedIDs = Array(Int64(2001)...3000)
  let gate = RequestGate()
  await gate.close()
  await rig.transport.setGate(gate, for: .songDetails(delayedIDs))
  await rig.transport.setSongDetailBatches([makeTracks([3001]), makeTracks(delayedIDs)])
  let fill = Task { await library.loadRemainingTracks(session: rig.session) }
  for _ in 0..<2000 {
    if await rig.transport.recordedCalls().contains(.songDetails([3001])) { break }
    await Task.yield()
  }
  #expect(await gate.arrivalCount() == 1)
  #expect(await rig.transport.recordedCalls().contains(.songDetails([3001])))
  await gate.open()
  await fill.value
  #expect(library.tracks.map(\.id) == ids)
  #expect(!library.detail.canLoadMore)
}

@Test @MainActor func collectionNavigationLoadsConcurrentlyAndReusesLoadedPages() async {
  let rig = ResponseRig()
  let collections = CollectionsCoordinator(
    transport: rig.transport, vault: rig.vault, arbiter: rig.arbiter)
  let gate = RequestGate()
  await gate.close()
  await rig.transport.setGate(gate, for: .collectedAlbums(offset: 0))
  await rig.transport.setAlbumPages([CatalogPage(items: makeAlbums([5]), more: false)])
  await rig.transport.setArtistPages([CatalogPage(items: makeArtists([6]), more: false)])
  collections.loadIfNeeded(.albums, session: rig.session)
  collections.loadIfNeeded(.artists, session: rig.session)
  for _ in 0..<2000 {
    if !collections.artists.isEmpty { break }
    await Task.yield()
  }
  #expect(collections.artists.map(\.id) == [6])
  #expect(collections.albums.isEmpty)
  await gate.open()
  await collections.settleForTesting()
  collections.loadIfNeeded(.albums, session: rig.session)
  collections.loadIfNeeded(.artists, session: rig.session)
  await collections.settleForTesting()
  #expect(await rig.transport.callCount() == 2)
}

@Test @MainActor func aLateMembershipReadDoesNotUndoANewerCollectionWrite() async {
  let rig = ResponseRig()
  let catalog = rig.catalog
  var collected = false
  catalog.onAlbumCollectionStateConfirmed = { _, value in collected = value }
  await rig.transport.setAlbumDetail(
    .success(AlbumDetail(album: makeAlbums([5])[0], tracks: makeTracks([1]))))
  await rig.transport.setAlbumDynamic(.success(AlbumDynamic(isCollected: true, collectCount: 1)))
  let gate = RequestGate()
  await gate.close()
  await rig.transport.setGate(gate, for: .albumDynamic(5))
  catalog.openAlbum(id: 5, session: rig.session)
  for _ in 0..<2000 {
    if await gate.arrivalCount() > 0 { break }
    await Task.yield()
  }
  let write = rig.arbiter.begin(name: "Remove album", effect: .write)!
  collected = false
  rig.arbiter.end(write, outcome: .applied)
  await gate.open()
  await catalog.settleForTesting()
  #expect(!collected)
  #expect(catalog.album != nil)
}

@Test @MainActor func sameAccountRenewalKeepsTheReadResultAndDoesNotBlockBrowsing() async throws {
  let rig = ResponseRig()
  let library = rig.library
  await rig.transport.setPlaylistDetail(
    .success(
      PlaylistDetail(
        id: 5, name: "Playlist", trackIDs: [1], tracks: makeTracks([1]))))
  await rig.transport.gate.close()
  library.loadTracks(for: makePlaylists([5])[0], session: rig.session)
  for _ in 0..<2000 {
    if await rig.transport.gate.arrivalCount() > 0 { break }
    await Task.yield()
  }
  let refresh = try #require(rig.arbiter.begin(name: "Refresh session", effect: .sessionRefresh))
  let otherRead = try #require(rig.arbiter.begin(name: "Search", effect: .read))
  let renewed = makeCredential("renewed")
  await rig.vault.setStored(renewed)
  rig.session.validatedCredential = renewed
  rig.arbiter.end(refresh, outcome: .applied)
  rig.arbiter.end(otherRead, outcome: .applied)
  await rig.transport.gate.open()
  await library.settleForTesting()
  #expect(library.tracks.map(\.id) == [1])
  #expect(rig.session.account == testAccount)
}

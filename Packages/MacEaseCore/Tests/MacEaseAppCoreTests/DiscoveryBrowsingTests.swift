import Foundation
import Testing

@testable import MacEaseAppCore
@testable import NeteaseKit

/// Browsing the playlist catalogue, the radar family, recommended new songs
/// and similar artists.
///
/// The recurring risk is a page arriving after the thing it was for has
/// changed. Every list here is keyed by the category, order or seed it was
/// asked for, so the answer to one question is never shown as the answer to
/// another.
@MainActor
private struct BrowseRig {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault: FakeVault
  let session: FakeSession
  let arbiter = OperationArbiter()
  let discovery: DiscoveryCoordinator

  init() {
    let credential = self.credential
    vault = FakeVault(stored: credential)
    session = FakeSession(credential: credential)
    discovery = DiscoveryCoordinator(
      transport: transport,
      vault: vault,
      arbiter: arbiter
    )
  }

  func settle() async { await discovery.settleForTesting() }
}

// MARK: - Category playlists

@Test @MainActor func categoryPlaylistsPageFromTheCountAlreadyHeld() async {
  let rig = BrowseRig()
  await rig.transport.setBrowsePages([
    CatalogPage(items: makeDiscovered([1, 2]), more: true),
    CatalogPage(items: makeDiscovered([3]), more: false),
  ])

  rig.discovery.selectedCategory = "华语"
  rig.discovery.loadCategoryPlaylists(reset: true, session: rig.session)
  await rig.settle()
  #expect(rig.discovery.categoryHasMore)

  rig.discovery.loadCategoryPlaylists(reset: false, session: rig.session)
  await rig.settle()

  #expect(rig.discovery.categoryPlaylists.map(\.id) == [1, 2, 3])
  #expect(rig.discovery.categoryHasMore == false)
  #expect(
    await rig.transport.recordedCalls() == [
      .categoryPlaylists("华语", .hot, offset: 0),
      .categoryPlaylists("华语", .hot, offset: 2),
    ]
  )
}

@Test @MainActor func categoryPagingDeduplicatesRowsButAdvancesByTheRawPage() async {
  let rig = BrowseRig()
  await rig.transport.setBrowsePages([
    CatalogPage(items: makeDiscovered([1, 1, 2]), more: true),
    CatalogPage(items: makeDiscovered([2, 3, 3]), more: false),
  ])

  rig.discovery.loadCategoryPlaylists(reset: true, session: rig.session)
  await rig.settle()
  rig.discovery.loadCategoryPlaylists(reset: false, session: rig.session)
  await rig.settle()

  #expect(rig.discovery.categoryPlaylists.map(\.id) == [1, 2, 3])
  #expect(rig.discovery.categoryHasMore == false)
  #expect(
    await rig.transport.recordedCalls() == [
      .categoryPlaylists("全部", .hot, offset: 0),
      .categoryPlaylists("全部", .hot, offset: 3),
    ]
  )
}

@Test @MainActor func categoryResetReplacesTheOldPageAfterDeduplication() async {
  let rig = BrowseRig()
  await rig.transport.setBrowsePages([
    CatalogPage(items: makeDiscovered([1, 2]), more: true),
    CatalogPage(items: makeDiscovered([9, 9]), more: false),
  ])

  rig.discovery.loadCategoryPlaylists(reset: true, session: rig.session)
  await rig.settle()
  rig.discovery.loadCategoryPlaylists(reset: true, session: rig.session)
  await rig.settle()

  #expect(rig.discovery.categoryPlaylists.map(\.id) == [9])
  #expect(rig.discovery.categoryHasMore == false)
}

/// Asking for more when the service said there is none must not spend a
/// request finding that out again.
@Test @MainActor func categoryPagingStopsWhenTheServiceSaidThereIsNoMore() async {
  let rig = BrowseRig()
  await rig.transport.setBrowsePages([
    CatalogPage(items: makeDiscovered([1]), more: false)
  ])
  rig.discovery.loadCategoryPlaylists(reset: true, session: rig.session)
  await rig.settle()

  rig.discovery.loadCategoryPlaylists(reset: false, session: rig.session)
  await rig.settle()

  #expect(await rig.transport.callCount() == 1)
}

/// A page for the tag the user left must not be shown under the one they
/// chose, and its cursor must not be adopted for the new list.
@Test @MainActor func aLatePageForTheOldCategoryIsDiscarded() async {
  let rig = BrowseRig()
  await rig.transport.setBrowsePages([
    CatalogPage(items: makeDiscovered([1]), more: true)
  ])
  await rig.transport.gate.close()

  rig.discovery.selectedCategory = "华语"
  rig.discovery.loadCategoryPlaylists(reset: true, session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }

  rig.discovery.selectedCategory = "摇滚"
  await rig.transport.gate.open()
  await rig.settle()

  #expect(rig.discovery.categoryPlaylists.isEmpty)
  #expect(rig.discovery.categoryHasMore == false)
  #expect(rig.discovery.status == "Discarded a 华语 page; the category changed")
}

@Test @MainActor func changingTheOrderAlsoInvalidatesAPageInFlight() async {
  let rig = BrowseRig()
  await rig.transport.setBrowsePages([
    CatalogPage(items: makeDiscovered([1]), more: true)
  ])
  await rig.transport.gate.close()

  rig.discovery.loadCategoryPlaylists(reset: true, session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }

  rig.discovery.categoryOrder = .new
  await rig.transport.gate.open()
  await rig.settle()

  #expect(rig.discovery.categoryPlaylists.isEmpty)
}

// MARK: - Highest-rated playlists

/// This list pages by the service's own cursor, not by a count the client
/// keeps, so the cursor from one page has to reach the next request.
@Test @MainActor func highestRatedPagingCarriesTheServiceCursor() async {
  let rig = BrowseRig()
  await rig.transport.setHighQualityPages([
    HighQualityPlaylistPage(
      playlists: makeDiscovered([1]),
      more: true,
      before: 900
    ),
    HighQualityPlaylistPage(playlists: makeDiscovered([2]), more: false, before: 800),
  ])

  rig.discovery.loadHighQualityPlaylists(reset: true, session: rig.session)
  await rig.settle()
  rig.discovery.loadHighQualityPlaylists(reset: false, session: rig.session)
  await rig.settle()

  #expect(rig.discovery.highQualityPlaylists.map(\.id) == [1, 2])
  #expect(
    await rig.transport.recordedCalls() == [
      .highQualityPlaylists("全部", before: 0),
      .highQualityPlaylists("全部", before: 900),
    ]
  )
}

@Test @MainActor func highestRatedPagingDeduplicatesWithinAndAcrossPages() async {
  let rig = BrowseRig()
  await rig.transport.setHighQualityPages([
    HighQualityPlaylistPage(
      playlists: makeDiscovered([1, 1, 2]),
      more: true,
      before: 900
    ),
    HighQualityPlaylistPage(
      playlists: makeDiscovered([2, 3, 3]),
      more: false,
      before: 800
    ),
  ])

  rig.discovery.loadHighQualityPlaylists(reset: true, session: rig.session)
  await rig.settle()
  rig.discovery.loadHighQualityPlaylists(reset: false, session: rig.session)
  await rig.settle()

  #expect(rig.discovery.highQualityPlaylists.map(\.id) == [1, 2, 3])
  #expect(rig.discovery.highQualityHasMore == false)
  #expect(
    await rig.transport.recordedCalls() == [
      .highQualityPlaylists("全部", before: 0),
      .highQualityPlaylists("全部", before: 900),
    ]
  )
}

@Test @MainActor func highestRatedResetsItsCursorForANewCategory() async {
  let rig = BrowseRig()
  await rig.transport.setHighQualityPages([
    HighQualityPlaylistPage(playlists: makeDiscovered([1]), more: true, before: 900),
    HighQualityPlaylistPage(playlists: makeDiscovered([5]), more: false, before: 700),
  ])
  rig.discovery.loadHighQualityPlaylists(reset: true, session: rig.session)
  await rig.settle()

  rig.discovery.selectedHighQualityCategory = "爵士"
  rig.discovery.loadHighQualityPlaylists(reset: true, session: rig.session)
  await rig.settle()

  #expect(rig.discovery.highQualityPlaylists.map(\.id) == [5])
  #expect(
    await rig.transport.recordedCalls() == [
      .highQualityPlaylists("全部", before: 0),
      .highQualityPlaylists("爵士", before: 0),
    ]
  )
}

// MARK: - Radar

/// The four independent radar playlists load concurrently; each ID is read once.
@Test @MainActor func radarReadsEachFixedPlaylistOnceAndKeepsPartialResults() async {
  let rig = BrowseRig()
  await rig.transport.setPlaylistBrief(
    .success(DiscoveredPlaylist(id: 1, name: "私人雷达"))
  )

  rig.discovery.loadRadarPlaylists(session: rig.session)
  await rig.settle()

  let calls = await rig.transport.recordedCalls()
  #expect(calls.count == DiscoveryCoordinator.radarPlaylistIDs.count)
  for id in DiscoveryCoordinator.radarPlaylistIDs {
    #expect(calls.filter { $0 == .playlistBrief(id) }.count == 1)
  }
  #expect(rig.discovery.radarPlaylists.count == 4)
}

@Test @MainActor func radarFailureDoesNotStopOtherPlaylists() async {
  let rig = BrowseRig()
  await rig.transport.setCatalogError(
    NeteaseServiceError(source: .http, statusCode: 500)
  )

  rig.discovery.loadRadarPlaylists(session: rig.session)
  await rig.settle()

  #expect(await rig.transport.callCount() == 4)
  #expect(rig.discovery.radarPlaylists.isEmpty)
}

// MARK: - New songs and similar artists

@Test @MainActor func recommendedNewSongsLoadOnlyFromAnExplicitAction() async {
  let rig = BrowseRig()
  await rig.transport.setDiscoveryTracks(.success(makeTracks([1, 2])))

  #expect(await rig.transport.callCount() == 0)
  rig.discovery.loadNewSongs(session: rig.session)
  await rig.settle()

  #expect(rig.discovery.newSongs.map(\.id) == [1, 2])
  #expect(await rig.transport.recordedCalls() == [.recommendedNewSongs])
}

@Test @MainActor func similarArtistsRecordTheSeedTheyBelongTo() async {
  let rig = BrowseRig()
  await rig.transport.setSimilarArtists(.success(makeArtists([9])))

  rig.discovery.loadSimilarArtists(seed: makeArtists([3])[0], session: rig.session)
  await rig.settle()

  #expect(rig.discovery.similarArtists.map(\.id) == [9])
  #expect(rig.discovery.similarArtistSeedName == "artist-3")
  #expect(await rig.transport.recordedCalls() == [.similarArtists(3)])
}

// MARK: - Session boundaries

/// Account A's browse page must never land in account B's window.
@Test @MainActor func aBrowsePageForAnotherAccountIsDiscarded() async {
  let rig = BrowseRig()
  let credentialB = makeCredential("b")
  await rig.transport.setBrowsePages([
    CatalogPage(items: makeDiscovered([1]), more: false)
  ])
  await rig.transport.gate.close()

  rig.discovery.loadCategoryPlaylists(reset: true, session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }

  await rig.vault.setStored(credentialB)
  rig.session.account = otherAccount
  rig.session.validatedCredential = credentialB
  await rig.transport.gate.open()
  await rig.settle()

  #expect(rig.discovery.categoryPlaylists.isEmpty)
  #expect(rig.discovery.status == "Session changed; validate again")
}

@Test @MainActor func resetClearsEveryBrowsingList() async {
  let rig = BrowseRig()
  await rig.transport.setBrowsePages([
    CatalogPage(items: makeDiscovered([1]), more: true)
  ])
  await rig.transport.setHighQualityPages([
    HighQualityPlaylistPage(playlists: makeDiscovered([2]), more: true, before: 900)
  ])
  await rig.transport.setDiscoveryTracks(.success(makeTracks([3])))
  await rig.transport.setSimilarArtists(.success(makeArtists([4])))
  await rig.transport.setPlaylistBrief(.success(makeDiscovered([5])[0]))

  rig.discovery.loadCategoryPlaylists(reset: true, session: rig.session)
  await rig.settle()
  rig.discovery.loadHighQualityPlaylists(reset: true, session: rig.session)
  await rig.settle()
  rig.discovery.loadNewSongs(session: rig.session)
  await rig.settle()
  rig.discovery.loadSimilarArtists(seed: makeArtists([4])[0], session: rig.session)
  await rig.settle()
  rig.discovery.loadRadarPlaylists(session: rig.session)
  await rig.settle()

  rig.discovery.reset()

  #expect(rig.discovery.categoryPlaylists.isEmpty)
  #expect(rig.discovery.categoryHasMore == false)
  #expect(rig.discovery.highQualityPlaylists.isEmpty)
  #expect(rig.discovery.highQualityHasMore == false)
  #expect(rig.discovery.newSongs.isEmpty)
  #expect(rig.discovery.similarArtists.isEmpty)
  #expect(rig.discovery.similarArtistSeedName == nil)
  #expect(rig.discovery.radarPlaylists.isEmpty)
  #expect(rig.arbiter.activeReadCount == 0)

  // The cursor went with it: the next highest-rated page starts over.
  await rig.transport.setHighQualityPages([
    HighQualityPlaylistPage(playlists: [], more: false, before: 0)
  ])
  rig.discovery.loadHighQualityPlaylists(reset: false, session: rig.session)
  await rig.settle()
  #expect(
    await rig.transport.recordedCalls().filter {
      if case .highQualityPlaylists = $0 { true } else { false }
    }.count == 1
  )
}

/// A read the arbiter refuses sends nothing and leaves what is on screen.
@Test @MainActor func aWaitingBrowseReadKeepsTheOldPageUntilItCanContinue() async {
  let rig = BrowseRig()
  await rig.transport.setBrowsePages([
    CatalogPage(items: makeDiscovered([1]), more: true)
  ])
  rig.discovery.loadCategoryPlaylists(reset: true, session: rig.session)
  await rig.settle()

  let blocking = try! #require(rig.arbiter.begin(name: "write", effect: .write))
  await rig.transport.setBrowsePages([CatalogPage(items: makeDiscovered([2]), more: false)])
  rig.discovery.loadCategoryPlaylists(reset: false, session: rig.session)
  await Task.yield()

  #expect(await rig.transport.callCount() == 1)
  #expect(rig.discovery.categoryPlaylists.map(\.id) == [1])
  rig.arbiter.end(blocking, outcome: .applied)
  await rig.settle()
  #expect(rig.discovery.categoryPlaylists.map(\.id) == [1, 2])
}

// MARK: - Listening rankings

/// Changing the scope while the rankings are still loading supersedes that
/// read; it is neither ignored nor allowed to cancel the unrelated Discover
/// sections that may be loading at the same time.
@Test @MainActor func aRankingsScopeChangeSupersedesOnlyItsOwnRead() async {
  let rig = BrowseRig()
  let rankings = RequestGate()
  let daily = RequestGate()
  await rankings.close()
  await daily.close()
  await rig.transport.setGate(rankings, for: .playRecords(.allTime))
  await rig.transport.setGate(daily, for: .dailyRecommendedSongs)
  await rig.transport.setRecords(
    .success([PlayRecordEntry(track: makeTracks([7])[0], playCount: 3)]))
  rig.discovery.loadDailySongs(session: rig.session)
  rig.discovery.loadRecords(session: rig.session)
  while await rankings.arrivalCount() < 1 { await Task.yield() }
  while await daily.arrivalCount() < 1 { await Task.yield() }
  #expect(rig.discovery.isLoading("Listening rankings"))
  #expect(rig.discovery.isLoading("Daily songs"))

  rig.discovery.recordScope = .lastWeek
  rig.discovery.loadRecords(session: rig.session)
  await rankings.open()
  await daily.open()
  await rig.settle()

  #expect(rig.discovery.records.map(\.playCount) == [3])
  #expect(
    await rig.transport.recordedCalls().filter {
      if case .playRecords = $0 { true } else { false }
    } == [.playRecords(.allTime), .playRecords(.lastWeek)])
  #expect(rig.discovery.sectionStatuses["Daily songs"] == "Loaded 0 daily recommended songs")
  #expect(rig.discovery.sectionStatuses["Listening rankings"] == "Loaded 1 ranking entries")
  #expect(rig.arbiter.activeReadCount == 0)
}

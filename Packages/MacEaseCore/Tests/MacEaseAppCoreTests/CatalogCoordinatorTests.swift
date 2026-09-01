import Foundation
import Testing

@testable import MacEaseAppCore
@testable import NeteaseKit

/// Search, suggestions and the album/artist pages.
///
/// The three lanes are the point of most of these: typing must not cancel an
/// album that is opening, opening an album must not cancel a search, and a
/// result that arrives after the thing it was for has changed must not be
/// shown as though it were for the new one.
@MainActor
private struct CatalogRig {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault: FakeVault
  let session: FakeSession
  let arbiter: OperationArbiter
  let catalog: CatalogCoordinator

  init(maximumConcurrentReads: Int = OperationArbiter.defaultMaximumConcurrentReads) {
    let credential = self.credential
    vault = FakeVault(stored: credential)
    session = FakeSession(credential: credential)
    arbiter = OperationArbiter(maximumConcurrentReads: maximumConcurrentReads)
    catalog = CatalogCoordinator(
      transport: transport,
      vault: vault,
      arbiter: arbiter,
      suggestionDelay: .zero
    )
  }

  func settle() async { await catalog.settleForTesting() }
}

private func songPage(_ ids: [Int64], total: Int?) -> SearchPage {
  SearchPage(items: .songs(makeTracks(ids)), totalCount: total)
}

// MARK: - Search paging and identity

/// Load More asks for the rows after the ones actually held, so a page the
/// service trimmed cannot make the next request skip.
@Test @MainActor func searchPagesFromTheCountAlreadyHeld() async {
  let rig = CatalogRig()
  await rig.transport.setSearchPages([
    songPage([1, 2], total: 4),
    songPage([3, 4], total: 4),
  ])

  rig.catalog.query = "canary"
  rig.catalog.runSearch(session: rig.session)
  await rig.settle()
  #expect(rig.catalog.resultsHaveMore)

  rig.catalog.loadMoreResults(session: rig.session)
  await rig.settle()

  #expect(rig.catalog.results == .songs(makeTracks([1, 2, 3, 4])))
  #expect(rig.catalog.resultsHaveMore == false)
  #expect(
    await rig.transport.recordedCalls() == [
      .search("canary", .songs, offset: 0),
      .search("canary", .songs, offset: 2),
    ]
  )
}

/// The service repeats rows when the result set shifts between requests. The
/// list is keyed by id, so a repeat is dropped rather than shown twice.
@Test @MainActor func searchPagingDropsRowsAlreadyHeld() async {
  let rig = CatalogRig()
  await rig.transport.setSearchPages([
    songPage([1, 2], total: 6),
    songPage([2, 3], total: 6),
    songPage([3, 4], total: 6),
  ])

  rig.catalog.query = "canary"
  rig.catalog.runSearch(session: rig.session)
  await rig.settle()
  rig.catalog.loadMoreResults(session: rig.session)
  await rig.settle()
  rig.catalog.loadMoreResults(session: rig.session)
  await rig.settle()

  #expect(rig.catalog.results == .songs(makeTracks([1, 2, 3, 4])))
  #expect(
    await rig.transport.recordedCalls() == [
      .search("canary", .songs, offset: 0),
      .search("canary", .songs, offset: 2),
      .search("canary", .songs, offset: 4),
    ]
  )
}

@Test @MainActor func changingTheScopeStartsOverAtOffsetZero() async {
  let rig = CatalogRig()
  await rig.transport.setSearchPages([
    songPage([1, 2], total: 9),
    SearchPage(items: .albums(makeAlbums([5])), totalCount: 1),
  ])

  rig.catalog.query = "canary"
  rig.catalog.runSearch(session: rig.session)
  await rig.settle()

  rig.catalog.scope = .albums
  rig.catalog.runSearch(session: rig.session)
  await rig.settle()

  #expect(rig.catalog.results == .albums(makeAlbums([5])))
  #expect(rig.catalog.resultsHaveMore == false)
  #expect(
    await rig.transport.recordedCalls() == [
      .search("canary", .songs, offset: 0),
      .search("canary", .albums, offset: 0),
    ]
  )
}

/// A page for the query the user has left must not be published under the one
/// they typed instead.
@Test @MainActor func aLateResultForTheOldQueryIsNotShownForTheNewOne() async {
  let rig = CatalogRig()
  await rig.transport.setSearchPages([
    songPage([1], total: 1),
    songPage([2], total: 1),
  ])
  await rig.transport.gate.close()

  rig.catalog.query = "first"
  rig.catalog.runSearch(session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }

  rig.catalog.query = "second"
  rig.catalog.runSearch(session: rig.session)
  await rig.transport.gate.open()
  await rig.settle()

  #expect(rig.catalog.resultsKeywords == "second")
  #expect(rig.catalog.results == .songs(makeTracks([2])))
}

/// Editing is itself supersession. The user need not submit B to stop the
/// already submitted A from publishing into B's input.
@Test @MainActor func editingAnInFlightSearchWithoutSubmittingTheEditCancelsIt() async {
  let rig = CatalogRig()
  await rig.transport.setSearchPages([songPage([1], total: 1)])
  await rig.transport.gate.close()

  rig.catalog.query = "first"
  rig.catalog.runSearch(session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }

  rig.catalog.query = "second"

  #expect(rig.catalog.results.isEmpty)
  #expect(rig.catalog.resultsKeywords == nil)
  #expect(rig.catalog.resultsHaveMore == false)
  #expect(rig.catalog.isSearching == false)
  #expect(rig.arbiter.activeReadCount == 0)

  await rig.transport.gate.open()
  for _ in 0..<10 { await Task.yield() }
  #expect(rig.catalog.results.isEmpty)
  #expect(rig.catalog.resultsKeywords == nil)
}

@Test @MainActor func changingScopeWithoutSubmittingCancelsTheOldSearch() async {
  let rig = CatalogRig()
  await rig.transport.setSearchPages([songPage([1], total: 1)])
  await rig.transport.gate.close()

  rig.catalog.query = "canary"
  rig.catalog.runSearch(session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }

  rig.catalog.scope = .albums

  #expect(rig.catalog.results == .albums([]))
  #expect(rig.catalog.resultsKeywords == nil)
  #expect(rig.catalog.resultsHaveMore == false)
  #expect(rig.arbiter.activeReadCount == 0)

  await rig.transport.gate.open()
  for _ in 0..<10 { await Task.yield() }
  #expect(rig.catalog.results == .albums([]))
}

/// Pressing Search twice for the same query is one request; a different query
/// supersedes rather than queueing behind it.
@Test @MainActor func repeatingTheSameSearchDoesNotSendItTwice() async {
  let rig = CatalogRig()
  await rig.transport.setSearchPages([songPage([1], total: 1)])
  await rig.transport.gate.close()

  rig.catalog.query = "canary"
  rig.catalog.runSearch(session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }
  rig.catalog.runSearch(session: rig.session)

  await rig.transport.gate.open()
  await rig.settle()

  #expect(await rig.transport.callCount() == 1)
}

/// Account A's answer must never land in account B's window.
@Test @MainActor func aResultForAnotherAccountIsDiscarded() async {
  let rig = CatalogRig()
  let credentialB = makeCredential("b")
  await rig.transport.setSearchPages([songPage([1], total: 1)])
  await rig.transport.gate.close()

  rig.catalog.query = "canary"
  rig.catalog.runSearch(session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }

  await rig.vault.setStored(credentialB)
  rig.session.account = otherAccount
  rig.session.validatedCredential = credentialB
  await rig.transport.gate.open()
  await rig.settle()

  #expect(rig.catalog.results.isEmpty)
  #expect(rig.catalog.status == "Session changed; validate again")
}

/// A read the arbiter refuses sends nothing and leaves what is on screen.
@Test @MainActor func aRefusedSearchSendsNothingAfterTheEditClearsOldResults() async {
  let rig = CatalogRig()
  await rig.transport.setSearchPages([songPage([1], total: 1)])
  rig.catalog.query = "canary"
  rig.catalog.runSearch(session: rig.session)
  await rig.settle()

  let blocking = try! #require(rig.arbiter.begin(name: "write", effect: .write))
  rig.catalog.query = "second"
  rig.catalog.runSearch(session: rig.session)
  await rig.settle()

  #expect(await rig.transport.callCount() == 1)
  #expect(rig.catalog.results.isEmpty)
  #expect(rig.catalog.resultsKeywords == nil)
  #expect(rig.catalog.resultsHaveMore == false)
  rig.arbiter.end(blocking, outcome: .applied)
}

// MARK: - Suggestions

@Test @MainActor func suggestionsRunOnTypingAndClearWithTheField() async {
  let rig = CatalogRig()
  await rig.transport.setSuggestions(
    .success([SearchSuggestion(id: "song-1", keyword: "canary", detail: "Bird")])
  )

  rig.catalog.query = "can"
  rig.catalog.updateSuggestions(session: rig.session)
  await rig.settle()
  #expect(rig.catalog.suggestions.map(\.keyword) == ["canary"])

  rig.catalog.query = "   "
  rig.catalog.updateSuggestions(session: rig.session)
  await rig.settle()
  #expect(rig.catalog.suggestions.isEmpty)
  #expect(await rig.transport.recordedCalls() == [.searchSuggestions("can")])
}

@Test @MainActor func changingWordsImmediatelyClearsResultsPagingAndSuggestions() async {
  let rig = CatalogRig()
  await rig.transport.setSearchPages([songPage([1], total: 9)])
  await rig.transport.setSuggestions(
    .success([SearchSuggestion(id: "old", keyword: "old suggestion", detail: nil)])
  )

  rig.catalog.query = "old"
  rig.catalog.runSearch(session: rig.session)
  await rig.settle()
  rig.catalog.updateSuggestions(session: rig.session)
  await rig.settle()
  #expect(!rig.catalog.results.isEmpty)
  #expect(rig.catalog.resultsHaveMore)
  #expect(!rig.catalog.suggestions.isEmpty)

  rig.catalog.query = "new"

  #expect(rig.catalog.results.isEmpty)
  #expect(rig.catalog.resultsKeywords == nil)
  #expect(rig.catalog.resultsHaveMore == false)
  #expect(rig.catalog.suggestions.isEmpty)
}

/// Repeating the same input while its request is out must not send it again.
@Test @MainActor func theSameSuggestionInputIsNotRequestedTwice() async {
  let rig = CatalogRig()
  await rig.transport.setSuggestions(.success([]))
  await rig.transport.gate.close()

  rig.catalog.query = "can"
  rig.catalog.updateSuggestions(session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }
  rig.catalog.updateSuggestions(session: rig.session)

  await rig.transport.gate.open()
  await rig.settle()

  #expect(await rig.transport.callCount() == 1)
}

/// A failed suggestion is not a failed search. It clears the list and leaves
/// the prompt for the newly edited, not-yet-submitted input intact.
@Test @MainActor func aFailedSuggestionDoesNotOverwriteTheSearchStatus() async {
  let rig = CatalogRig()
  await rig.transport.setSearchPages([songPage([1], total: 1)])
  rig.catalog.query = "canary"
  rig.catalog.runSearch(session: rig.session)
  await rig.settle()

  await rig.transport.setSuggestions(
    .failure(NeteaseServiceError(source: .http, statusCode: 500))
  )
  rig.catalog.query = "canaryx"
  let afterEdit = rig.catalog.status
  rig.catalog.updateSuggestions(session: rig.session)
  await rig.settle()

  #expect(rig.catalog.suggestions.isEmpty)
  #expect(rig.catalog.status == afterEdit)
}

/// Suggestions and a search are separate lanes, so one cannot cancel the other.
@Test @MainActor func aSuggestionInFlightDoesNotBlockASearch() async {
  let rig = CatalogRig()
  await rig.transport.setSuggestions(.success([]))
  await rig.transport.setSearchPages([songPage([7], total: 1)])
  await rig.transport.gate.close()

  rig.catalog.query = "canary"
  rig.catalog.updateSuggestions(session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }
  rig.catalog.runSearch(session: rig.session)

  while await rig.transport.gate.arrivalCount() < 2 { await Task.yield() }
  #expect(rig.arbiter.activeReadCount == 2)

  await rig.transport.gate.open()
  await rig.settle()

  #expect(rig.catalog.results == .songs(makeTracks([7])))
  #expect(
    await rig.transport.recordedCalls().contains(.search("canary", .songs, offset: 0))
  )
}

@Test @MainActor func clearingInputCancelsAnInFlightSuggestionWithoutANewRequest() async {
  let rig = CatalogRig()
  await rig.transport.setSuggestions(
    .success([SearchSuggestion(id: "old", keyword: "old", detail: nil)])
  )
  await rig.transport.gate.close()

  rig.catalog.query = "can"
  rig.catalog.updateSuggestions(session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }
  #expect(rig.arbiter.activeReadCount == 1)

  rig.catalog.query = "   "
  rig.catalog.updateSuggestions(session: rig.session)

  #expect(rig.catalog.suggestions.isEmpty)
  #expect(rig.arbiter.activeReadCount == 0)
  #expect(await rig.transport.recordedCalls() == [.searchSuggestions("can")])

  await rig.transport.gate.open()
  for _ in 0..<10 { await Task.yield() }
  #expect(rig.catalog.suggestions.isEmpty)
  #expect(await rig.transport.callCount() == 1)
}

@Test @MainActor func theDefaultKeywordIsShownAndNeverSearched() async {
  let rig = CatalogRig()
  await rig.transport.setDefaultKeyword(.success("周杰伦"))

  rig.catalog.loadDefaultKeyword(session: rig.session)
  await rig.settle()

  #expect(rig.catalog.defaultKeyword == "周杰伦")
  #expect(rig.catalog.results.isEmpty)
  #expect(await rig.transport.recordedCalls() == [.defaultSearchKeyword])
}

// MARK: - Album and artist pages

@Test @MainActor func openingAnAlbumReadsItsTracksAndCollectedState() async {
  let rig = CatalogRig()
  let collections = CollectionsCoordinator(
    transport: rig.transport,
    vault: rig.vault,
    arbiter: rig.arbiter
  )
  rig.catalog.onAlbumCollectionStateConfirmed = { albumID, collected in
    collections.confirmAlbumCollected(collected, albumID: albumID)
  }
  await rig.transport.setAlbumDetail(
    .success(AlbumDetail(album: makeAlbums([5])[0], tracks: makeTracks([1, 2])))
  )
  await rig.transport.setAlbumDynamic(
    .success(AlbumDynamic(isCollected: true, collectCount: 9))
  )

  rig.catalog.openAlbum(id: 5, session: rig.session)
  await rig.settle()

  #expect(rig.catalog.album?.tracks.map(\.id) == [1, 2])
  #expect(rig.catalog.albumDynamic?.isCollected == true)
  #expect(collections.albumCollectionState(for: 5) == .confirmed(true))
  #expect(
    await rig.transport.recordedCalls() == [.albumDetail(5), .albumDynamic(5)]
  )
}

@Test @MainActor func openingAnArtistReadsTopSongsAndTheFirstAlbumPage() async {
  let rig = CatalogRig()
  await rig.transport.setArtistDetail(
    .success(ArtistDetail(artist: makeArtists([3])[0], hotSongs: makeTracks([1])))
  )
  await rig.transport.setArtistAlbumPages([
    CatalogPage(items: makeAlbums([10, 11]), more: true),
    CatalogPage(items: makeAlbums([11, 12]), more: true),
    CatalogPage(items: makeAlbums([12, 13]), more: false),
  ])

  rig.catalog.openArtist(id: 3, session: rig.session)
  await rig.settle()
  #expect(rig.catalog.artistAlbums.map(\.id) == [10, 11])
  #expect(rig.catalog.artistAlbumsHaveMore)

  rig.catalog.loadMoreArtistAlbums(session: rig.session)
  await rig.settle()
  rig.catalog.loadMoreArtistAlbums(session: rig.session)
  await rig.settle()

  // The repeated row is dropped rather than listed twice.
  #expect(rig.catalog.artistAlbums.map(\.id) == [10, 11, 12, 13])
  #expect(
    await rig.transport.recordedCalls() == [
      .artistDetail(3),
      .artistAlbums(3, offset: 0),
      .artistAlbums(3, offset: 2),
      .artistAlbums(3, offset: 4),
    ]
  )
}

/// Opening a second thing supersedes the first: the old page must not appear
/// under the new one's header.
@Test @MainActor func aLateAlbumDoesNotOverwriteTheArtistOpenedAfterIt() async {
  let rig = CatalogRig()
  await rig.transport.setAlbumDetail(
    .success(AlbumDetail(album: makeAlbums([5])[0], tracks: makeTracks([1])))
  )
  await rig.transport.setArtistDetail(
    .success(ArtistDetail(artist: makeArtists([3])[0], hotSongs: makeTracks([2])))
  )
  await rig.transport.setArtistAlbumPages([CatalogPage(items: [], more: false)])
  await rig.transport.gate.close()

  rig.catalog.openAlbum(id: 5, session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }
  rig.catalog.openArtist(id: 3, session: rig.session)

  await rig.transport.gate.open()
  await rig.settle()

  #expect(rig.catalog.album == nil)
  #expect(rig.catalog.artist?.artist.id == 3)
}

/// Load More for an artist the user has left must not append to the one they
/// opened instead.
@Test @MainActor func lateArtistAlbumsAreNotAppendedToADifferentArtist() async {
  let rig = CatalogRig()
  await rig.transport.setArtistDetail(
    .success(ArtistDetail(artist: makeArtists([3])[0], hotSongs: []))
  )
  await rig.transport.setArtistAlbumPages([
    CatalogPage(items: makeAlbums([10]), more: true),
    CatalogPage(items: makeAlbums([99]), more: false),
  ])
  rig.catalog.openArtist(id: 3, session: rig.session)
  await rig.settle()

  await rig.transport.gate.close()
  rig.catalog.loadMoreArtistAlbums(session: rig.session)
  while await rig.transport.gate.arrivalCount() < 3 { await Task.yield() }

  await rig.transport.setArtistDetail(
    .success(ArtistDetail(artist: makeArtists([4])[0], hotSongs: []))
  )
  // Two identical pages: the superseded Load More and the new artist's first
  // page both draw one, and which reaches the queue first is not fixed.
  await rig.transport.setArtistAlbumPages([
    CatalogPage(items: [], more: false),
    CatalogPage(items: [], more: false),
  ])
  rig.catalog.openArtist(id: 4, session: rig.session)
  await rig.transport.gate.open()
  await rig.settle()

  #expect(rig.catalog.artist?.artist.id == 4)
  #expect(rig.catalog.artistAlbums.isEmpty)
}

// MARK: - Browse lists

@Test @MainActor func newAlbumsAndTopArtistsPageAndDeduplicate() async {
  let rig = CatalogRig()
  await rig.transport.setNewAlbumPages([
    CatalogPage(items: makeAlbums([1, 1, 2]), more: true),
    CatalogPage(items: makeAlbums([2, 3, 3]), more: false),
  ])
  await rig.transport.setTopArtistPages([
    CatalogPage(items: makeArtists([7, 7, 8]), more: true),
    CatalogPage(items: makeArtists([8, 9, 9]), more: false),
  ])

  rig.catalog.loadNewAlbums(reset: true, session: rig.session)
  await rig.settle()
  rig.catalog.loadNewAlbums(reset: false, session: rig.session)
  await rig.settle()
  rig.catalog.loadTopArtists(reset: true, session: rig.session)
  await rig.settle()
  rig.catalog.loadTopArtists(reset: false, session: rig.session)
  await rig.settle()

  #expect(rig.catalog.newAlbums.map(\.id) == [1, 2, 3])
  #expect(rig.catalog.newAlbumsHaveMore == false)
  #expect(rig.catalog.topArtists.map(\.id) == [7, 8, 9])
  #expect(rig.catalog.topArtistsHaveMore == false)
  #expect(
    await rig.transport.recordedCalls() == [
      .newAlbums(.all, offset: 0),
      .newAlbums(.all, offset: 3),
      .topArtists(offset: 0),
      .topArtists(offset: 3),
    ]
  )
}

@Test @MainActor func changingNewAlbumAreaClearsTheOldPageAndCursor() async {
  let rig = CatalogRig()
  await rig.transport.setNewAlbumPages([
    CatalogPage(items: makeAlbums([1, 2]), more: true),
    CatalogPage(items: makeAlbums([9]), more: false),
  ])
  rig.catalog.loadNewAlbums(reset: true, session: rig.session)
  await rig.settle()

  rig.catalog.newAlbumArea = .japanese
  #expect(rig.catalog.newAlbums.isEmpty)
  #expect(rig.catalog.newAlbumsHaveMore == false)
  rig.catalog.loadNewAlbums(reset: true, session: rig.session)
  await rig.settle()

  #expect(rig.catalog.newAlbums.map(\.id) == [9])
  #expect(
    await rig.transport.recordedCalls() == [
      .newAlbums(.all, offset: 0),
      .newAlbums(.japanese, offset: 0),
    ]
  )
}

/// Asking for more when the service said there is none must not spend a
/// request finding that out again.
@Test @MainActor func loadingMoreIsRefusedOnceTheServiceSaidThereIsNone() async {
  let rig = CatalogRig()
  await rig.transport.setTopArtistPages([
    CatalogPage(items: makeArtists([1]), more: false)
  ])
  rig.catalog.loadTopArtists(reset: true, session: rig.session)
  await rig.settle()

  rig.catalog.loadTopArtists(reset: false, session: rig.session)
  await rig.settle()

  #expect(await rig.transport.callCount() == 1)
}

// MARK: - Lifecycle

@Test @MainActor func resetClearsEveryPaneAndCancelsEveryLane() async {
  let rig = CatalogRig()
  await rig.transport.setSearchPages([songPage([1], total: 1)])
  await rig.transport.setAlbumDetail(
    .success(AlbumDetail(album: makeAlbums([5])[0], tracks: makeTracks([1])))
  )
  await rig.transport.setSuggestions(
    .success([SearchSuggestion(id: "s", keyword: "k", detail: nil)])
  )
  rig.catalog.query = "canary"
  rig.catalog.runSearch(session: rig.session)
  await rig.settle()
  rig.catalog.openAlbum(id: 5, session: rig.session)
  await rig.settle()
  rig.catalog.updateSuggestions(session: rig.session)
  await rig.settle()

  rig.catalog.reset()

  #expect(rig.catalog.results.isEmpty)
  #expect(rig.catalog.resultsKeywords == nil)
  #expect(rig.catalog.suggestions.isEmpty)
  #expect(rig.catalog.album == nil)
  #expect(rig.catalog.albumDynamic == nil)
  #expect(rig.catalog.artist == nil)
  #expect(rig.catalog.defaultKeyword == nil)
  #expect(rig.catalog.isSearching == false)
  #expect(rig.catalog.isLoadingDetail == false)
  #expect(rig.arbiter.activeReadCount == 0)
}

@Test @MainActor func resetReleasesSearchDetailAndSuggestionTokensInFlight() async {
  let rig = CatalogRig()
  await rig.transport.setSearchPages([songPage([1], total: 1)])
  await rig.transport.setAlbumDetail(
    .success(AlbumDetail(album: makeAlbums([5])[0], tracks: makeTracks([1])))
  )
  await rig.transport.setSuggestions(.success([]))
  await rig.transport.gate.close()

  rig.catalog.query = "canary"
  rig.catalog.runSearch(session: rig.session)
  rig.catalog.openAlbum(id: 5, session: rig.session)
  rig.catalog.updateSuggestions(session: rig.session)
  while await rig.transport.gate.arrivalCount() < 3 { await Task.yield() }
  #expect(rig.arbiter.activeReadCount == 3)

  rig.catalog.reset()

  #expect(rig.arbiter.activeReadCount == 0)
  #expect(rig.catalog.isSearching == false)
  #expect(rig.catalog.isLoadingDetail == false)
  #expect(rig.catalog.results.isEmpty)
  #expect(rig.catalog.album == nil)
  #expect(rig.catalog.suggestions.isEmpty)

  await rig.transport.gate.open()
}

/// Superseding gives the abandoned read its slot back, so a lane cannot run
/// itself out of the arbiter's read ceiling.
@Test @MainActor func supersedingASearchReleasesItsReadSlot() async {
  let rig = CatalogRig(maximumConcurrentReads: 1)
  await rig.transport.setSearchPages([
    songPage([1], total: 1),
    songPage([2], total: 1),
  ])
  await rig.transport.gate.close()

  rig.catalog.query = "first"
  rig.catalog.runSearch(session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }
  rig.catalog.query = "second"
  rig.catalog.runSearch(session: rig.session)

  await rig.transport.gate.open()
  await rig.settle()

  #expect(rig.catalog.results == .songs(makeTracks([2])))
  #expect(rig.arbiter.activeReadCount == 0)
}

import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

/// Characterization tests for the guarantees the review says must never be
/// removed: fail-closed preflight, postflight before publishing, no automatic
/// retry, and generation guards that drop a superseded task's late write.
/// They run entirely on fakes: no network, no Keychain, no AVPlayer.

@MainActor
private func makeLibrary(
  transport: FakeTransport,
  vault: FakeVault,
  arbiter: OperationArbiter = OperationArbiter()
) -> PlaylistLibraryCoordinator {
  PlaylistLibraryCoordinator(transport: transport, vault: vault, arbiter: arbiter)
}

// MARK: - Preflight

@Test @MainActor func libraryDoesNotSendARequestWhenTheKeychainItemVanished() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: nil)
  let session = FakeSession(credential: credential)
  let library = makeLibrary(transport: transport, vault: vault)

  library.load(reset: true, session: session)
  await library.settleForTesting()

  #expect(await transport.callCount() == 0)
  #expect(session.divergences == [.storedSessionMissing])
  #expect(library.status == "No stored session to load library")
}

@Test @MainActor func libraryDoesNotSendARequestWhenTheStoredItemWasReplaced() async {
  let transport = FakeTransport()
  let vault = FakeVault(stored: makeCredential("replacement"))
  let session = FakeSession(credential: makeCredential("original"))
  let library = makeLibrary(transport: transport, vault: vault)

  library.load(reset: true, session: session)
  await library.settleForTesting()

  #expect(await transport.callCount() == 0)
  #expect(session.divergences == [.storedSessionChanged(hasStoredItem: true)])
}

@Test @MainActor func libraryRefusesToLoadWithoutAValidatedAccount() async {
  let transport = FakeTransport()
  let credential = makeCredential()
  let vault = FakeVault(stored: credential)
  let session = FakeSession(account: nil, credential: credential)
  let library = makeLibrary(transport: transport, vault: vault)

  library.load(reset: true, session: session)
  await library.settleForTesting()

  #expect(await transport.callCount() == 0)
}

// MARK: - Postflight

@Test @MainActor func aResultIsNotPublishedWhenTheCredentialChangedInFlight() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let session = FakeSession(credential: credential)
  let library = makeLibrary(transport: transport, vault: vault)
  await transport.setPlaylistPages([
    UserPlaylistPage(playlists: makePlaylists([1, 2]), more: false)
  ])
  await transport.gate.close()

  library.load(reset: true, session: session)
  // The request is in flight; the stored item is swapped underneath it.
  while await transport.gate.arrivalCount() == 0 { await Task.yield() }
  await vault.setStored(makeCredential("replacement"))
  await transport.gate.open()
  await library.settleForTesting()

  #expect(library.playlists.isEmpty)
  #expect(session.divergences == [.storedSessionChanged(hasStoredItem: true)])
  #expect(library.status == "Session changed; validate again")
}

@Test @MainActor func aSupersededTaskDoesNotWriteState() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let session = FakeSession(credential: credential)
  let arbiter = OperationArbiter()
  let library = makeLibrary(transport: transport, vault: vault, arbiter: arbiter)
  await transport.setPlaylistPages([
    UserPlaylistPage(playlists: makePlaylists([1, 2]), more: true)
  ])
  await transport.gate.close()

  library.load(reset: true, session: session)
  while await transport.gate.arrivalCount() == 0 { await Task.yield() }
  library.reset()
  await transport.gate.open()
  // `reset` clears the task handle, so settling on it would prove nothing.
  // Wait until the arbiter slot the superseded task held is actually free.
  while !arbiter.canStart() { await Task.yield() }

  #expect(library.playlists.isEmpty)
  #expect(!library.canLoadMore)
  #expect(!library.isLoading)
  #expect(library.status == "Validate the session before loading playlists")
}

// MARK: - No automatic retry, failures stop

@Test @MainActor func aFailedPageIsReportedOnceWithNoRetry() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let session = FakeSession(credential: credential)
  let library = makeLibrary(transport: transport, vault: vault)

  library.load(reset: true, session: session)
  await library.settleForTesting()

  #expect(await transport.callCount() == 1)
  #expect(library.status == "Playlist network or response error")
  #expect(library.playlists.isEmpty)
}

@Test @MainActor func aFailedWriteDoesNotApplyItsLocalChange() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let session = FakeSession(credential: credential)
  let library = makeLibrary(transport: transport, vault: vault)
  await transport.setPlaylistPages([
    UserPlaylistPage(playlists: makePlaylists([7]), more: false)
  ])
  library.load(reset: true, session: session)
  await library.settleForTesting()
  #expect(library.playlists.count == 1)

  await transport.setWriteResult(
    .failure(NeteaseServiceError(source: .service, statusCode: -460))
  )
  library.deletePlaylist(library.playlists[0], session: session)
  await library.settleForTesting()

  #expect(library.playlists.count == 1)
  #expect(library.status == "Delete playlist service error -460")
}

@Test @MainActor func serviceThreeOhOneOnAPageInvalidatesTheStoredSession() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let session = FakeSession(credential: credential)
  let library = makeLibrary(transport: transport, vault: vault)
  await transport.setPlaylistPageError(
    NeteaseServiceError(source: .service, statusCode: 301)
  )

  library.load(reset: true, session: session)
  await library.settleForTesting()

  #expect(session.invalidations == [credential])
  #expect(library.status == "Stored session expired; sign in again")
  #expect(library.playlists.isEmpty)
}

/// Only the playlist page read is allowed to invalidate; the other reads have
/// no verified 301 semantics, so they classify and stop.
@Test @MainActor func serviceThreeOhOneOnANonPageReadOnlyClassifies() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let session = FakeSession(credential: credential)
  let library = makeLibrary(transport: transport, vault: vault)
  await transport.setLikedIDs(
    .failure(NeteaseServiceError(source: .service, statusCode: 301))
  )

  library.loadLikedIDs(session: session)
  await library.settleForTesting()

  #expect(session.invalidations.isEmpty)
  #expect(library.status == "Liked songs service error 301")
}

// MARK: - Liked writes

@Test @MainActor func likingATrackUpdatesOnlyTheLocalSetAndNeverRefetches() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let session = FakeSession(credential: credential)
  let library = makeLibrary(transport: transport, vault: vault)
  await transport.setLikedIDs(.success([1]))

  library.loadLikedIDs(session: session)
  await library.settleForTesting()
  #expect(library.liked.state(of: 1) == .liked)

  library.setLiked(true, for: makeTracks([2])[0], session: session)
  await library.settleForTesting()

  #expect(library.liked.state(of: 1) == .liked)
  #expect(library.liked.state(of: 2) == .liked)
  #expect(library.liked.state(of: 3) == .notLiked)
  #expect(
    await transport.recordedCalls() == [.likedSongIDs, .setSongLiked(2, true)]
  )
}

// MARK: - Discovery

@Test @MainActor func discoveryPrefetchRunsOnceAndStopsAtTheFirstError() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let session = FakeSession(credential: credential)
  let discovery = DiscoveryCoordinator(
    transport: transport,
    vault: vault,
    arbiter: OperationArbiter()
  )
  await transport.setDiscoveryTracks(
    .failure(NeteaseServiceError(source: .http, statusCode: 500))
  )

  discovery.prefetch(session: session)
  await discovery.settleForTesting()

  #expect(await transport.recordedCalls() == [.dailyRecommendedSongs])

  discovery.prefetch(session: session)
  await discovery.settleForTesting()

  #expect(await transport.callCount() == 1)
}

@Test @MainActor func searchRunsOnlyFromAnExplicitNonEmptyQuery() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let session = FakeSession(credential: credential)
  let discovery = DiscoveryCoordinator(
    transport: transport,
    vault: vault,
    arbiter: OperationArbiter()
  )
  await transport.setDiscoveryTracks(.success(makeTracks([9])))

  discovery.searchQuery = "   "
  discovery.search(session: session)
  await discovery.settleForTesting()
  #expect(await transport.callCount() == 0)

  discovery.searchQuery = "  canary  "
  discovery.search(session: session)
  await discovery.settleForTesting()

  #expect(await transport.recordedCalls() == [.searchSongs("canary")])
  #expect(discovery.searchResults.map(\.id) == [9])
}

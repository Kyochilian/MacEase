import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

/// P1-03 and P1-04: "not loaded yet" is not "not liked", and a form clears its
/// input only when its own request succeeded.

// MARK: - Liked is a tri-state

@Test func anUnloadedLikedListReportsUnknownNotNotLiked() {
  let liked = LikedSongs()

  #expect(!liked.isLoaded)
  #expect(liked.state(of: 1) == .unknown)
}

@Test func loadingTheListMakesEveryTrackKnown() {
  var liked = LikedSongs()
  liked.load([1, 2])

  #expect(liked.isLoaded)
  #expect(liked.state(of: 1) == .liked)
  #expect(liked.state(of: 99) == .notLiked)
}

/// A confirmed write proves that track's state and nothing else; it must not
/// pretend the whole set is loaded.
@Test func aWriteWithoutALoadedListOnlyResolvesThatTrack() {
  var liked = LikedSongs()
  liked.setLiked(true, trackID: 7)

  #expect(liked.state(of: 7) == .liked)
  #expect(liked.state(of: 8) == .unknown)
  #expect(!liked.isLoaded)
}

@Test func unlikingWithoutALoadedListIsAlsoRecorded() {
  var liked = LikedSongs()
  liked.setLiked(false, trackID: 7)

  #expect(liked.state(of: 7) == .notLiked)
  #expect(liked.state(of: 8) == .unknown)
}

@Test func loadingAfterIndividualWritesTakesOver() {
  var liked = LikedSongs()
  liked.setLiked(true, trackID: 7)
  liked.load([1])

  #expect(liked.state(of: 7) == .notLiked)
  #expect(liked.state(of: 1) == .liked)
}

@Test func resettingReturnsEverythingToUnknown() {
  var liked = LikedSongs()
  liked.load([1, 2])
  liked.reset()

  #expect(liked.state(of: 1) == .unknown)
  #expect(!liked.isLoaded)
}

@Test @MainActor func likingAnUnknownTrackNeverFabricatesALoadedSet() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let arbiter = OperationArbiter()
  let session = FakeSession(credential: credential)
  let library = PlaylistLibraryCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )

  #expect(library.liked.state(of: 5) == .unknown)
  library.setLiked(true, for: makeTracks([5])[0], session: session)
  await library.settleForTesting()

  #expect(library.liked.state(of: 5) == .liked)
  #expect(library.liked.state(of: 6) == .unknown)
  #expect(!library.liked.isLoaded)
  #expect(library.status.contains("load liked IDs"))
  // Exactly one request: the liked list is never fetched to fill the gap.
  #expect(await transport.recordedCalls() == [.setSongLiked(5, true)])
}

// MARK: - Write receipts

@MainActor
private func makeLibraryRig() -> (FakeTransport, PlaylistLibraryCoordinator, FakeSession) {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let session = FakeSession(credential: credential)
  let library = PlaylistLibraryCoordinator(
    transport: transport,
    vault: vault,
    arbiter: OperationArbiter()
  )
  return (transport, library, session)
}

@Test @MainActor func aSuccessfulCreatePublishesASucceededReceipt() async {
  let (_, library, session) = makeLibraryRig()

  library.createPlaylist(named: "canary", session: session)
  await library.settleForTesting()

  #expect(library.lastCreateReceipt?.succeeded == true)
}

@Test @MainActor func aFailedCreatePublishesAFailedReceipt() async {
  let (transport, library, session) = makeLibraryRig()
  await transport.setWriteResult(
    .failure(NeteaseServiceError(source: .service, statusCode: -460))
  )

  library.createPlaylist(named: "canary", session: session)
  await library.settleForTesting()

  #expect(library.lastCreateReceipt?.succeeded == false)
  #expect(library.lastCreateReceipt?.outcome == .failed)
}

@Test @MainActor func aTimedOutWritePublishesAnUnknownReceipt() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let arbiter = OperationArbiter()
  let session = FakeSession(credential: credential)
  let library = PlaylistLibraryCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  await transport.setWriteResult(.failure(URLError(.timedOut)))

  library.createPlaylist(named: "canary", session: session)
  await library.settleForTesting()

  #expect(library.lastCreateReceipt?.outcome == .outcomeUnknown)
  #expect(arbiter.unresolvedOutcomes.map(\.kind) == [.unknown])
}

@Test @MainActor func anUndecodableWriteResponseHasAnUnknownOutcome() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let arbiter = OperationArbiter()
  let session = FakeSession(credential: credential)
  let library = PlaylistLibraryCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  let decodingError = DecodingError.dataCorrupted(
    .init(codingPath: [], debugDescription: "missing write acknowledgement")
  )
  await transport.setWriteResult(.failure(decodingError))

  library.createPlaylist(named: "canary", session: session)
  await library.settleForTesting()

  #expect(library.lastCreateReceipt?.outcome == .outcomeUnknown)
  #expect(arbiter.unresolvedOutcomes.map(\.kind) == [.unknown])
}

@Test @MainActor func aPostflightKeychainFailureIsAppliedRemotelyOnly() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let arbiter = OperationArbiter()
  let session = FakeSession(credential: credential)
  let library = PlaylistLibraryCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  await transport.gate.close()

  library.createPlaylist(named: "canary", session: session)
  while await transport.gate.arrivalCount() == 0 { await Task.yield() }
  await vault.setLoadError(CredentialVaultError.keychain(-25300))
  await transport.gate.open()
  await library.settleForTesting()

  #expect(library.lastCreateReceipt?.outcome == .appliedRemotelyOnly)
  #expect(arbiter.unresolvedOutcomes.map(\.kind) == [.appliedRemotelyOnly])
  #expect(library.status == "Keychain error status=-25300")
}

/// Each write gets its own receipt id, so a view can tell its own action's
/// completion from a later one.
@Test @MainActor func consecutiveWritesGetDistinctReceipts() async {
  let (_, library, session) = makeLibraryRig()

  library.createPlaylist(named: "one", session: session)
  await library.settleForTesting()
  let first = library.lastCreateReceipt

  library.createPlaylist(named: "two", session: session)
  await library.settleForTesting()
  let second = library.lastCreateReceipt

  #expect(first != nil)
  #expect(second != nil)
  #expect(first?.id != second?.id)
}

@Test @MainActor func aWriteThatOnlyLandedRemotelyIsNotReportedAsSuccess() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let session = FakeSession(credential: credential)
  let library = PlaylistLibraryCoordinator(
    transport: transport,
    vault: vault,
    arbiter: OperationArbiter()
  )
  await transport.gate.close()

  library.createPlaylist(named: "canary", session: session)
  while await transport.gate.arrivalCount() == 0 { await Task.yield() }
  await vault.setStored(makeCredential("replacement"))
  await transport.gate.open()
  await library.settleForTesting()

  #expect(library.lastCreateReceipt?.outcome == .appliedRemotelyOnly)
  #expect(library.lastCreateReceipt?.succeeded == false)
}

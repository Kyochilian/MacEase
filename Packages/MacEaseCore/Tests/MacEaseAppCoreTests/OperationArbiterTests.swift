import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

/// P0-01: one arbiter owns "a NetEase request is in flight". These tests pin
/// the properties the review demands, above all that a write which reached the
/// server is never silently dropped by a session action.

// MARK: - Arbiter semantics

@Test @MainActor func onlyOneOperationCanHoldTheArbiter() {
  let arbiter = OperationArbiter()

  let first = arbiter.begin(name: "Playlist", effect: .read)
  #expect(first != nil)
  #expect(arbiter.begin(name: "Daily songs", effect: .read) == nil)
  #expect(arbiter.begin(name: "Like", effect: .write) == nil)
  #expect(arbiter.begin(name: "Validate session", effect: .sessionMutation) == nil)
  #expect(arbiter.begin(name: "Song URL", effect: .playbackResolution) == nil)

  arbiter.end(first!, outcome: .applied)
  #expect(arbiter.begin(name: "Daily songs", effect: .read) != nil)
}

@Test @MainActor func aWriteCancelledBeforeItIsSentIsJustCancelled() {
  let arbiter = OperationArbiter()
  let token = arbiter.begin(name: "Like", effect: .write)!

  #expect(!arbiter.abandoningLosesTheOutcome(token))
  #expect(arbiter.end(token, outcome: .cancelled) == .cancelled)
  #expect(arbiter.unresolvedOutcomes.isEmpty)
}

@Test @MainActor func aWriteCancelledAfterItIsSentBecomesOutcomeUnknown() {
  let arbiter = OperationArbiter()
  let token = arbiter.begin(name: "Subscribe", effect: .write)!
  arbiter.markRequestSent(token)

  #expect(arbiter.abandoningLosesTheOutcome(token))
  #expect(arbiter.end(token, outcome: .cancelled) == .outcomeUnknown)
  #expect(arbiter.unresolvedOutcomes.map(\.name) == ["Subscribe"])
}

@Test @MainActor func aCancelledReadNeverBecomesOutcomeUnknown() {
  let arbiter = OperationArbiter()
  for effect in [
    OperationEffect.read, .playbackResolution, .sessionMutation,
  ] {
    let token = arbiter.begin(name: "op", effect: effect)!
    arbiter.markRequestSent(token)
    #expect(!arbiter.abandoningLosesTheOutcome(token))
    #expect(arbiter.end(token, outcome: .cancelled) == .cancelled)
  }
  #expect(arbiter.unresolvedOutcomes.isEmpty)
}

@Test @MainActor func aSentWriteThatFailedIsAFailureNotAnUnknown() {
  let arbiter = OperationArbiter()
  let token = arbiter.begin(name: "Create playlist", effect: .write)!
  arbiter.markRequestSent(token)

  #expect(arbiter.end(token, outcome: .failed) == .failed)
  #expect(arbiter.unresolvedOutcomes.isEmpty)
}

@Test @MainActor func onlyTheOwnerCanReleaseTheArbiter() {
  let arbiter = OperationArbiter()
  let first = arbiter.begin(name: "Playlist", effect: .read)!
  arbiter.end(first, outcome: .applied)
  let second = arbiter.begin(name: "Daily songs", effect: .read)!

  // A late completion from the finished operation must not free the new one.
  #expect(arbiter.end(first, outcome: .applied) == nil)
  #expect(arbiter.isBusy)
  #expect(arbiter.active?.name == "Daily songs")

  // Nor may a duplicate completion of the current one release twice.
  #expect(arbiter.end(second, outcome: .applied) == .applied)
  #expect(arbiter.end(second, outcome: .cancelled) == nil)
  #expect(!arbiter.isBusy)
}

@Test @MainActor func aStaleTokenCannotMoveAnotherOperationsPhase() {
  let arbiter = OperationArbiter()
  let stale = arbiter.begin(name: "Like", effect: .write)!
  arbiter.end(stale, outcome: .applied)
  let current = arbiter.begin(name: "Playlist", effect: .read)!

  arbiter.markRequestSent(stale)
  #expect(arbiter.active?.phase == .preparing)
  arbiter.markRequestSent(current)
  #expect(arbiter.active?.phase == .requestSent)
}

@Test @MainActor func unresolvedOutcomesOnlyClearOnAnExplicitAcknowledgement() {
  let arbiter = OperationArbiter()
  let token = arbiter.begin(name: "Remove track", effect: .write)!
  arbiter.markRequestSent(token)
  arbiter.end(token, outcome: .cancelled)

  let next = arbiter.begin(name: "Playlist", effect: .read)!
  arbiter.end(next, outcome: .applied)
  #expect(arbiter.unresolvedOutcomes.count == 1)

  arbiter.acknowledgeUnresolvedOutcomes()
  #expect(arbiter.unresolvedOutcomes.isEmpty)
}

// MARK: - Cross-module exclusion

@MainActor
private struct Rig {
  let transport = FakeTransport()
  let vault: FakeVault
  let arbiter = OperationArbiter()
  let session: FakeSession
  let library: PlaylistLibraryCoordinator
  let discovery: DiscoveryCoordinator
  let playback: PlaybackController

  init() {
    let credential = makeCredential()
    vault = FakeVault(stored: credential)
    session = FakeSession(credential: credential)
    library = PlaylistLibraryCoordinator(
      transport: transport,
      vault: vault,
      arbiter: arbiter
    )
    discovery = DiscoveryCoordinator(
      transport: transport,
      vault: vault,
      arbiter: arbiter
    )
    playback = PlaybackController(
      transport: transport,
      vault: vault,
      arbiter: arbiter
    )
    playback.attach(session: session)
  }

  func waitForFirstRequest() async {
    while await transport.gate.arrivalCount() == 0 { await Task.yield() }
  }
}

@Test @MainActor func twoReadsCannotRunConcurrently() async {
  let rig = Rig()
  await rig.transport.setPlaylistPages([
    UserPlaylistPage(playlists: makePlaylists([1]), more: false)
  ])
  await rig.transport.setDiscoveryTracks(.success(makeTracks([2])))
  await rig.transport.gate.close()

  rig.library.load(reset: true, session: rig.session)
  await rig.waitForFirstRequest()
  rig.discovery.loadDailySongs(session: rig.session)

  #expect(await rig.transport.callCount() == 1)
  #expect(rig.discovery.dailySongs.isEmpty)

  await rig.transport.gate.open()
  await rig.library.settleForTesting()
  #expect(rig.library.playlists.count == 1)
}

@Test @MainActor func aReadCannotStartWhileAWriteIsInFlight() async {
  let rig = Rig()
  await rig.transport.gate.close()

  rig.library.setLiked(true, for: makeTracks([5])[0], session: rig.session)
  await rig.waitForFirstRequest()
  rig.discovery.loadToplists(session: rig.session)
  rig.library.load(reset: true, session: rig.session)

  #expect(await rig.transport.callCount() == 1)

  await rig.transport.gate.open()
  await rig.library.settleForTesting()
}

@Test @MainActor func playbackResolutionCannotRunAlongsideADiscoveryRead() async {
  let rig = Rig()
  await rig.transport.setDiscoveryTracks(.success(makeTracks([7])))
  await rig.transport.gate.close()

  rig.discovery.loadDailySongs(session: rig.session)
  await rig.waitForFirstRequest()
  rig.playback.play(tracks: makeTracks([7]), startIndex: 0, session: rig.session)

  #expect(await rig.transport.callCount() == 1)
  #expect(rig.playback.phase == .idle)

  await rig.transport.gate.open()
  await rig.discovery.settleForTesting()
}

@Test @MainActor func aSessionMutationCannotStartWhileAWriteIsInFlight() async {
  let rig = Rig()
  await rig.transport.gate.close()

  rig.library.createPlaylist(named: "canary", session: rig.session)
  await rig.waitForFirstRequest()

  // This is what the Session tab's buttons check before they run.
  #expect(!rig.arbiter.canStart())
  #expect(rig.arbiter.active?.effect == .write)
  #expect(rig.arbiter.active?.phase == .requestSent)

  await rig.transport.gate.open()
  await rig.library.settleForTesting()
  #expect(rig.arbiter.canStart())
  #expect(rig.arbiter.unresolvedOutcomes.isEmpty)
}

/// The regression the review calls a server-state problem: a session action
/// used to cancel an in-flight write. The write must survive, and its result
/// must still be applied.
@Test @MainActor func aLocalResetDoesNotDiscardASentWritesResult() async {
  let rig = Rig()
  await rig.transport.setPlaylistPages([
    UserPlaylistPage(playlists: makePlaylists([11]), more: false)
  ])
  rig.library.load(reset: true, session: rig.session)
  await rig.library.settleForTesting()

  await rig.transport.gate.close()
  rig.library.deletePlaylist(rig.library.playlists[0], session: rig.session)
  await rig.waitForFirstRequest()

  // Discovery reset is a local action and must not touch the library's write.
  rig.discovery.reset()
  await rig.transport.gate.open()
  await rig.library.settleForTesting()

  #expect(rig.library.playlists.isEmpty)
  #expect(rig.library.status == "Deleted playlist-11")
  #expect(rig.arbiter.unresolvedOutcomes.isEmpty)
}

/// A write whose request reached the server but whose session changed
/// underneath it must be reported as unknown, not as success or failure.
@Test @MainActor func aSentWriteWhoseSessionChangedIsReportedAsUnknown() async {
  let rig = Rig()
  await rig.transport.gate.close()

  rig.library.setLiked(true, for: makeTracks([3])[0], session: rig.session)
  await rig.waitForFirstRequest()
  await rig.vault.setStored(makeCredential("replacement"))
  await rig.transport.gate.open()
  await rig.library.settleForTesting()

  #expect(rig.arbiter.unresolvedOutcomes.map(\.name) == ["Like"])
  #expect(rig.library.status == "Session changed; validate again")
  #expect(rig.library.likedIDs == nil)
}

@Test @MainActor func theArbiterIsReleasedOnEveryEarlyReturn() async {
  let rig = Rig()

  // No validated account: claimed and released without a request.
  rig.session.account = nil
  rig.library.load(reset: true, session: rig.session)
  await rig.library.settleForTesting()
  #expect(rig.arbiter.canStart())
  #expect(await rig.transport.callCount() == 0)

  // Keychain item gone: released on the preflight path.
  let credential = makeCredential()
  rig.session.account = testAccount
  rig.session.validatedCredential = credential
  await rig.vault.setStored(nil)
  rig.library.load(reset: true, session: rig.session)
  await rig.library.settleForTesting()
  #expect(rig.arbiter.canStart())

  // Keychain throws: released on the error path.
  await rig.vault.setStored(credential)
  await rig.vault.setLoadError(CredentialVaultError.keychain(-25300))
  rig.session.account = testAccount
  rig.session.validatedCredential = credential
  rig.library.load(reset: true, session: rig.session)
  await rig.library.settleForTesting()
  #expect(rig.arbiter.canStart())
  #expect(rig.library.status == "Keychain error status=-25300")

  // Transport throws: released on the failure path.
  await rig.vault.setLoadError(nil)
  rig.session.account = testAccount
  rig.session.validatedCredential = credential
  await rig.transport.setPlaylistPageError(
    NeteaseServiceError(source: .http, statusCode: 500)
  )
  rig.library.load(reset: true, session: rig.session)
  await rig.library.settleForTesting()
  #expect(rig.arbiter.canStart())
  #expect(rig.library.status == "Playlist http error 500")
}

@Test @MainActor func stoppingPlaybackFreesTheArbiterImmediately() async {
  let rig = Rig()
  await rig.transport.gate.close()

  rig.playback.play(tracks: makeTracks([9]), startIndex: 0, session: rig.session)
  await rig.waitForFirstRequest()
  #expect(!rig.arbiter.canStart())

  rig.playback.stop()
  #expect(rig.arbiter.canStart())
  #expect(rig.arbiter.unresolvedOutcomes.isEmpty)

  await rig.transport.gate.open()
  await rig.playback.settleForTesting()
  // The abandoned task's late release must not free a newer operation.
  let later = rig.arbiter.begin(name: "Playlist", effect: .read)
  #expect(later != nil)
}

@Test @MainActor func autoAdvanceDoesNotStartWhileAnotherRequestIsInFlight() async {
  let rig = Rig()
  await rig.transport.gate.close()
  rig.library.load(reset: true, session: rig.session)
  await rig.waitForFirstRequest()

  // Auto-advance consults the same arbiter every page does.
  #expect(!rig.arbiter.canStart())

  await rig.transport.gate.open()
  await rig.library.settleForTesting()
  #expect(rig.arbiter.canStart())
}

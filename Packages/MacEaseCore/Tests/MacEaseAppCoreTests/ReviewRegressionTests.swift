import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

/// Regressions for the defects the independent review found in the P0 work.
/// Each one is a behaviour that was wrong, not a refactor.

// MARK: - The two unresolved kinds are different things

@Test @MainActor func aSentWriteWithNoAnswerIsUnknown() {
  let arbiter = OperationArbiter()
  let token = arbiter.begin(name: "Like", effect: .write)!
  arbiter.markRequestSent(token)

  #expect(arbiter.end(token, outcome: .cancelled) == .outcomeUnknown)
  #expect(arbiter.unresolvedOutcomes.map(\.kind) == [.unknown])
  #expect(arbiter.unresolvedOutcomes[0].advice.contains("unknown"))
}

/// Once the response is in hand the server's answer is known. Abandoning the
/// local apply is a display problem, and calling it "unknown" would send the
/// user looking for something that did happen.
@Test @MainActor func aWriteAbandonedAfterTheResponseIsNotUnknown() {
  let arbiter = OperationArbiter()
  let token = arbiter.begin(name: "Remove track", effect: .write)!
  arbiter.markRequestSent(token)
  arbiter.markSettling(token)

  #expect(!arbiter.abandoningLosesTheOutcome(token))
  #expect(arbiter.end(token, outcome: .cancelled) == .appliedRemotelyOnly)
  #expect(arbiter.unresolvedOutcomes.map(\.kind) == [.appliedRemotelyOnly])
  #expect(arbiter.unresolvedOutcomes[0].advice.contains("server"))
}

@Test @MainActor func aReadThatPublishesNothingIsNeverUnresolved() async {
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
  await transport.setPlaylistPages([
    UserPlaylistPage(playlists: makePlaylists([1]), more: false)
  ])
  await transport.gate.close()

  library.load(reset: true, session: session)
  while await transport.gate.arrivalCount() == 0 { await Task.yield() }
  await vault.setStored(makeCredential("replacement"))
  await transport.gate.open()
  await library.settleForTesting()

  #expect(arbiter.unresolvedOutcomes.isEmpty)
  #expect(library.playlists.isEmpty)
}

// MARK: - A module reset must not cancel a sent write

@MainActor
private struct Rig {
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
}

@Test @MainActor func resettingDuringASentWriteLetsItFinish() async {
  let rig = Rig()
  await rig.transport.gate.close()

  rig.library.setLiked(true, for: makeTracks([9])[0], session: rig.session)
  while await rig.transport.gate.arrivalCount() == 0 { await Task.yield() }
  #expect(rig.arbiter.activeWriteIsInFlight)

  // The write is in flight; a local reset must not cancel it.
  rig.library.reset()
  await rig.transport.gate.open()
  await rig.library.settleForTesting()

  // It reached the server and succeeded. The local list was reset out from
  // under it, so the user is told the account did change even though the
  // screen does not show it — never that the like was simply dropped.
  #expect(rig.arbiter.unresolvedOutcomes.map(\.kind) == [.appliedRemotelyOnly])
  #expect(rig.arbiter.unresolvedOutcomes.map(\.name) == ["Like"])
  #expect(rig.arbiter.canStart())
  #expect(await rig.transport.recordedCalls() == [.setSongLiked(9, true)])
}

@Test @MainActor func resettingDuringAReadStillCancelsIt() async {
  let rig = Rig()
  await rig.transport.setPlaylistPages([
    UserPlaylistPage(playlists: makePlaylists([1]), more: false)
  ])
  await rig.transport.gate.close()

  rig.library.load(reset: true, session: rig.session)
  while await rig.transport.gate.arrivalCount() == 0 { await Task.yield() }
  #expect(!rig.arbiter.activeWriteIsInFlight)

  rig.library.reset()
  await rig.transport.gate.open()
  await rig.library.settleForTesting()

  #expect(rig.library.playlists.isEmpty)
  #expect(rig.arbiter.unresolvedOutcomes.isEmpty)
}

// MARK: - Superseding one's own playback resolve

/// Play A, then immediately Play B while A is still resolving. The old
/// behaviour cancelled A and then failed to claim the arbiter for B, so
/// nothing played at all.
@Test @MainActor func supersedingAnInFlightResolveStartsTheNewTrack() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let arbiter = OperationArbiter()
  let output = FakeAudioOutput()
  let session = FakeSession(credential: credential)
  let playback = PlaybackController(
    transport: transport,
    vault: vault,
    arbiter: arbiter,
    output: output
  )
  playback.attach(session: session)
  await transport.setSongURL(.success(makeResolvedAsset(songID: 202)))
  await transport.gate.close()

  playback.play(tracks: makeTracks([101]), startIndex: 0, context: .dailyRecommendations, session: session)
  while await transport.gate.arrivalCount() == 0 { await Task.yield() }

  playback.play(tracks: makeTracks([202]), startIndex: 0, context: .dailyRecommendations, session: session)
  #expect(playback.phase == .resolving)

  await transport.gate.open()
  await playback.settleForTesting()

  #expect(playback.phase == .playing)
  #expect(await transport.recordedCalls().last == .resolveSongURL(202, .standard))
  #expect(arbiter.unresolvedOutcomes.isEmpty)
  #expect(arbiter.canStart())
}

@Test @MainActor func aCancelledPlaybackTaskIsNotOfferedAsARetry() {
  #expect(PlaybackFailureClassifier.kind(for: CancellationError()) == .terminal)
}

// MARK: - Session commits the review found wrong

@Test func aSecondReadThatComesBackEmptyMeansTheItemIsGone() {
  // The reducer must be told the truth; the coordinator regression is that it
  // used to hardcode "still stored" here.
  let (after, result) = SessionReducer.reduce(
    SessionSnapshot(presence: .validated(testAccount), validatedCredential: makeCredential()),
    .storedItemChanged(hasStoredItem: false)
  )

  #expect(after.presence == .absent)
  #expect(after.storedSessionPresence == .absent)
  #expect(result == .credentialReplaced(nil))
}

/// A confirmed sign-out whose Keychain delete failed must stop treating the
/// account as validated without guessing whether an item remains.
@Test func aConfirmedSignOutWithAFailedDeleteDropsValidation() {
  let (after, result) = SessionReducer.reduce(
    SessionSnapshot(presence: .validated(testAccount), validatedCredential: makeCredential()),
    .storedItemPresenceUnknown
  )

  #expect(after.account == nil)
  #expect(after.validatedCredential == nil)
  #expect(after.presence == .unknown)
  #expect(after.storedSessionPresence == .unknown)
  #expect(result == .storedPresenceUnknown)
}

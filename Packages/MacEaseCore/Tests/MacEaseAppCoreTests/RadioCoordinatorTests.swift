import Foundation
import Testing

@testable import MacEaseAppCore
@testable import NeteaseKit

/// Personal FM and heartbeat mode.
///
/// Both are real playback: every assertion here checks that the queue and the
/// audio came through `PlaybackController`, not that a list was fetched. The
/// continuation rules are the other half — a radio that is not playing must
/// never issue a request, and one that is must never issue two at once.
@MainActor
private struct RadioRig {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault: FakeVault
  let session: FakeSession
  let arbiter: OperationArbiter
  let output = FakeAudioOutput()
  let playback: PlaybackController
  let radio: RadioCoordinator

  init(
    maximumConcurrentReads: Int = OperationArbiter.defaultMaximumConcurrentReads
  ) {
    let credential = self.credential
    vault = FakeVault(stored: credential)
    session = FakeSession(credential: credential)
    arbiter = OperationArbiter(maximumConcurrentReads: maximumConcurrentReads)
    playback = PlaybackController(
      transport: transport,
      vault: vault,
      arbiter: arbiter,
      output: output
    )
    radio = RadioCoordinator(transport: transport, vault: vault, arbiter: arbiter)
    playback.attach(session: session)
    radio.attach(playback: playback)
    // The same wiring the composition root installs.
    let radio = self.radio
    let session = self.session
    playback.onPlaybackChanged = { [weak radio] revision in
      radio?.playbackChanged(revision: revision, session: session)
    }
  }

  func settle() async {
    await radio.settleForTesting()
    await playback.settleForTesting()
  }

  /// Starts FM and lets both the fetch and the first resolve settle.
  func startFM() async {
    radio.startPersonalFM(session: session)
    await settle()
    await settle()
  }
}

// MARK: - Starting

@Test @MainActor func personalFMBecomesARealQueueThroughPlayback() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([makeTracks([1, 2, 3])])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))

  await rig.startFM()

  #expect(rig.playback.queueContext == .personalFM)
  #expect(rig.playback.queue?.count == 3)
  #expect(rig.playback.currentTrack?.id == 1)
  #expect(rig.playback.phase == .playing)
  #expect(rig.radio.isPlayingFM)
  #expect(rig.output.preparedURLs.count == 1)
}

/// The service repeats songs across batches; a queue holding the same song
/// twice would play it twice and make Previous ambiguous.
@Test @MainActor func theFirstFMBatchIsDeduplicatedByID() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([makeTracks([1, 1, 2])])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))

  await rig.startFM()

  #expect(rig.playback.queuedTracks(context: .personalFM).map(\.id) == [1, 2])
}

@Test @MainActor func anEmptyFMBatchStartsNothing() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([[]])

  await rig.startFM()

  #expect(rig.playback.queue == nil)
  #expect(rig.radio.isPlayingFM == false)
  #expect(rig.radio.status == "Personal FM returned no tracks")
}

@Test @MainActor func anInFlightFMRequestCannotOverrideNewOrdinaryPlayback() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([makeTracks([1, 2])])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 50)))
  await rig.transport.gate.close()

  rig.radio.startPersonalFM(session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }

  rig.playback.play(
    tracks: makeTracks([50]),
    startIndex: 0,
    context: .dailyRecommendations,
    session: rig.session
  )
  while await rig.transport.gate.arrivalCount() < 2 { await Task.yield() }
  #expect(rig.radio.isLoading == false)
  // The FM token was released; the only read left belongs to song resolution.
  #expect(rig.arbiter.activeReadCount == 1)

  await rig.transport.gate.open()
  await rig.playback.settleForTesting()
  for _ in 0..<10 { await Task.yield() }

  #expect(rig.playback.queueContext == .dailyRecommendations)
  #expect(rig.playback.currentTrack?.id == 50)
  #expect(rig.radio.isPlayingFM == false)
}

@Test @MainActor func anInFlightHeartbeatCannotOverrideNewOrdinaryPlayback() async {
  let rig = RadioRig()
  await rig.transport.setHeartbeat(.success(makeTracks([7, 8])))
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 50)))
  await rig.transport.gate.close()

  rig.radio.startHeartbeatMode(
    seed: makeTracks([7])[0],
    playlistID: 9,
    session: rig.session
  )
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }

  rig.playback.play(
    tracks: makeTracks([50]),
    startIndex: 0,
    context: .listeningRankings,
    session: rig.session
  )
  while await rig.transport.gate.arrivalCount() < 2 { await Task.yield() }

  await rig.transport.gate.open()
  await rig.playback.settleForTesting()
  for _ in 0..<10 { await Task.yield() }

  #expect(rig.playback.queueContext == .listeningRankings)
  #expect(rig.playback.currentTrack?.id == 50)
}

@Test @MainActor func newerPlaybackWinsWhenRadioHoldsTheOnlyReadSlot() async {
  let rig = RadioRig(maximumConcurrentReads: 1)
  await rig.transport.setFMBatches([makeTracks([1, 2])])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 50)))
  await rig.transport.gate.close()

  rig.radio.startPersonalFM(session: rig.session)
  while await rig.transport.gate.arrivalCount() < 1 { await Task.yield() }

  rig.playback.play(
    tracks: makeTracks([50]),
    startIndex: 0,
    context: .dailyRecommendations,
    session: rig.session
  )

  #expect(rig.radio.isLoading == false)
  // The obsolete radio read released the sole slot synchronously, then the
  // newer playback resolution claimed it.
  #expect(rig.arbiter.activeReadCount == 1)
  while await rig.transport.gate.arrivalCount() < 2 { await Task.yield() }

  await rig.transport.gate.open()
  await rig.playback.settleForTesting()
  for _ in 0..<10 { await Task.yield() }

  #expect(rig.playback.queueContext == .dailyRecommendations)
  #expect(rig.playback.currentTrack?.id == 50)
}

// MARK: - Continuation

/// Nothing is fetched until playback is within the last few entries, and then
/// only one batch is ever out at a time.
@Test @MainActor func fmContinuesOnlyNearTheEndAndOnlyOneBatchAtATime() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([
    makeTracks([1, 2, 3, 4, 5]),
    makeTracks([5, 6]),
  ])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))

  await rig.startFM()
  // Five entries with the first playing leaves four ahead: too many to top up.
  #expect(await rig.transport.recordedCalls().filter { $0 == .personalFM }.count == 1)

  rig.playback.playNext(session: rig.session)
  await rig.settle()
  #expect(await rig.transport.recordedCalls().filter { $0 == .personalFM }.count == 1)

  // Index 2 of 5 leaves two ahead, which is the threshold.
  rig.playback.playNext(session: rig.session)
  await rig.settle()
  await rig.settle()

  #expect(await rig.transport.recordedCalls().filter { $0 == .personalFM }.count == 2)
  // The repeated id is dropped; the queue grew by exactly one.
  #expect(rig.playback.queuedTracks(context: .personalFM).map(\.id) == [1, 2, 3, 4, 5, 6])
  #expect(rig.playback.currentTrack?.id == 3)
  #expect(rig.radio.isContinuing == false)
}

/// Stopping ends the radio. Nothing may be fetched afterwards, and a batch
/// that was already out must not be appended to whatever plays next.
@Test @MainActor func stoppingCancelsTheRadioAndItsContinuation() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([makeTracks([1, 2]), makeTracks([9])])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
  await rig.startFM()
  let beforeStop = await rig.transport.recordedCalls().filter { $0 == .personalFM }
    .count

  await rig.transport.gate.close()
  rig.playback.playNext(session: rig.session)
  while await rig.transport.gate.arrivalCount() < beforeStop + 1 {
    await Task.yield()
  }
  rig.playback.stop()
  await rig.transport.gate.open()
  await rig.settle()

  #expect(rig.playback.queue == nil)
  #expect(rig.radio.isPlayingFM == false)
  #expect(rig.radio.status == "Radio request cancelled by newer playback")

  // Nothing further is requested while the radio is not playing.
  let afterStop = await rig.transport.callCount()
  rig.radio.playbackAdvanced(session: rig.session)
  await rig.settle()
  #expect(await rig.transport.callCount() == afterStop)
}

@Test @MainActor func stopCancelsAContinuationAndReleasesItsTokenImmediately() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([
    makeTracks([1, 2, 3]),
    makeTracks([6]),
  ])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
  await rig.startFM()

  let before = await rig.transport.gate.arrivalCount()
  await rig.transport.gate.close()
  rig.radio.playbackAdvanced(session: rig.session)
  while await rig.transport.gate.arrivalCount() < before + 1 { await Task.yield() }
  #expect(rig.radio.isContinuing)
  #expect(rig.arbiter.activeReadCount == 1)

  rig.playback.stop()

  #expect(rig.radio.isContinuing == false)
  #expect(rig.radio.isLoading == false)
  #expect(rig.arbiter.activeReadCount == 0)

  await rig.transport.gate.open()
}

@Test @MainActor func changingContextCancelsContinuationWithoutAppendingIt() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([
    makeTracks([1, 2, 3]),
    makeTracks([9]),
  ])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
  await rig.startFM()

  let before = await rig.transport.gate.arrivalCount()
  await rig.transport.gate.close()
  rig.radio.playbackAdvanced(session: rig.session)
  while await rig.transport.gate.arrivalCount() < before + 1 { await Task.yield() }

  rig.playback.play(
    tracks: makeTracks([50]),
    startIndex: 0,
    context: .dailyRecommendations,
    session: rig.session
  )
  #expect(rig.radio.isContinuing == false)
  // The continuation slot is gone; the remaining read is the new track URL.
  #expect(rig.arbiter.activeReadCount == 1)

  await rig.transport.gate.open()
  await rig.playback.settleForTesting()
  for _ in 0..<10 { await Task.yield() }

  #expect(rig.playback.queueContext == .dailyRecommendations)
  #expect(rig.playback.queuedTracks(context: .dailyRecommendations).map(\.id) == [50])
}

/// Playing something that is not the radio ends it, so a queue that has
/// nothing to do with FM never grows from an FM batch.
@Test @MainActor func adifferentContextIsNeverToppedUpWithRadioTracks() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([makeTracks([1, 2])])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
  await rig.startFM()

  rig.playback.play(
    tracks: makeTracks([50]),
    startIndex: 0,
    context: .dailyRecommendations,
    session: rig.session
  )
  await rig.settle()
  let calls = await rig.transport.callCount()

  rig.radio.playbackAdvanced(session: rig.session)
  await rig.settle()

  #expect(rig.radio.isPlayingFM == false)
  #expect(await rig.transport.callCount() == calls)
  #expect(rig.playback.queuedTracks(context: .dailyRecommendations).map(\.id) == [50])
}

// MARK: - Trash

/// The queue changes only once the service has said it accepted the rejection.
@Test @MainActor func trashRemovesTheSongOnlyAfterTheServiceConfirms() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([makeTracks([1, 2, 3, 4, 5])])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
  await rig.startFM()

  rig.radio.trashCurrentFMSong(session: rig.session)
  await rig.settle()
  await rig.settle()

  #expect(await rig.transport.recordedCalls().contains(.trashFMSong(1)))
  #expect(rig.playback.queuedTracks(context: .personalFM).map(\.id) == [2, 3, 4, 5])
  #expect(rig.playback.currentTrack?.id == 2)
  #expect(rig.radio.failedTrash == nil)
}

/// A rejected write leaves the song where it is and offers a retry, rather
/// than skipping a song the service still serves.
@Test @MainActor func aFailedTrashKeepsTheSongAndOffersARetry() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([makeTracks([1, 2, 3, 4, 5])])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
  await rig.startFM()
  await rig.transport.setWriteResult(
    .failure(NeteaseServiceError(source: .service, statusCode: 400))
  )

  rig.radio.trashCurrentFMSong(session: rig.session)
  await rig.settle()

  #expect(rig.playback.queuedTracks(context: .personalFM).map(\.id) == [1, 2, 3, 4, 5])
  #expect(rig.playback.currentTrack?.id == 1)
  #expect(rig.radio.failedTrash?.id == 1)
  #expect(rig.arbiter.unresolvedOutcomes.isEmpty)
}

/// A confirmation that arrives after the account changed must not edit the new
/// account's playback.
@Test @MainActor func aLateTrashConfirmationDoesNotTouchAnotherAccount() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([makeTracks([1, 2, 3, 4, 5])])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
  await rig.startFM()
  let beforeTrash = await rig.transport.gate.arrivalCount()

  await rig.transport.gate.close()
  rig.radio.trashCurrentFMSong(session: rig.session)
  while await rig.transport.gate.arrivalCount() < beforeTrash + 1 {
    await Task.yield()
  }

  let credentialB = makeCredential("b")
  await rig.vault.setStored(credentialB)
  rig.session.account = otherAccount
  rig.session.validatedCredential = credentialB
  await rig.transport.gate.open()
  await rig.settle()

  // The service did act, so the outcome is recorded rather than reported as a
  // success or a failure; nothing local was changed.
  #expect(rig.playback.queuedTracks(context: .personalFM).map(\.id) == [1, 2, 3, 4, 5])
  #expect(
    rig.arbiter.unresolvedOutcomes.map(\.kind) == [.appliedRemotelyOnly]
  )
}

/// Trash is not unlike: it must never reach the liked-songs endpoint.
@Test @MainActor func trashDoesNotTouchTheLikedSongsEndpoint() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([makeTracks([1, 2])])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
  await rig.startFM()

  rig.radio.trashCurrentFMSong(session: rig.session)
  await rig.settle()
  await rig.settle()

  let calls = await rig.transport.recordedCalls()
  #expect(!calls.contains { if case .setSongLiked = $0 { true } else { false } })
}

@Test @MainActor func trashingTheLastSongStopsWithoutErasingTheSavedQueue() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([makeTracks([1])])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
  var explicitStops = 0
  rig.playback.onExplicitStop = { explicitStops += 1 }
  await rig.startFM()

  rig.radio.trashCurrentFMSong(session: rig.session)
  await rig.settle()

  #expect(rig.playback.queue == nil)
  #expect(explicitStops == 0)
}

// MARK: - Heartbeat mode

@Test @MainActor func heartbeatModeSendsBothIdsAndPlaysThroughPlayback() async {
  let rig = RadioRig()
  await rig.transport.setHeartbeat(.success(makeTracks([7, 8])))
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 7)))

  rig.radio.startHeartbeatMode(
    seed: makeTracks([7])[0],
    playlistID: 24_381_616,
    session: rig.session
  )
  await rig.settle()
  await rig.settle()

  #expect(
    await rig.transport.recordedCalls() == [
      .heartbeatQueue(songID: 7, playlistID: 24_381_616, startMusicID: 7),
      .resolveSongURL(7, .standard),
    ]
  )
  #expect(rig.playback.queueContext == .heartbeatMode(seedName: "track-7"))
  #expect(rig.playback.queue?.count == 2)
  #expect(rig.playback.phase == .playing)
}

/// Without a real playlist there is no id to send, and one must not be
/// invented: the request is never made.
@Test @MainActor func heartbeatModeWithoutAPlaylistSendsNothing() async {
  let rig = RadioRig()

  rig.radio.startHeartbeatMode(
    seed: makeTracks([7])[0],
    playlistID: 0,
    session: rig.session
  )
  await rig.settle()

  #expect(await rig.transport.callCount() == 0)
  #expect(rig.playback.queue == nil)
  #expect(
    RadioCoordinator.canStartHeartbeat(seed: makeTracks([7])[0], playlistID: 0)
      == false
  )
  #expect(
    RadioCoordinator.canStartHeartbeat(seed: makeTracks([7])[0], playlistID: 5)
  )
}

@Test @MainActor func anEmptyHeartbeatQueueStartsNothing() async {
  let rig = RadioRig()
  await rig.transport.setHeartbeat(.success([]))

  rig.radio.startHeartbeatMode(
    seed: makeTracks([7])[0],
    playlistID: 5,
    session: rig.session
  )
  await rig.settle()

  #expect(rig.playback.queue == nil)
}

// MARK: - Lifecycle

@Test @MainActor func restoredFMIsNotPlayingAndCannotBeTrashedBeforeResume() async {
  let rig = RadioRig()
  rig.playback.restore(
    PersistedQueue(
      tracks: makeTracks([1, 2]),
      currentIndex: 0,
      mode: .sequential,
      context: .personalFM,
      positionSeconds: 12,
      quality: .standard,
      wasPlaying: true
    )
  )

  #expect(rig.playback.phase == .idle)
  #expect(rig.radio.isPlayingFM == false)
  rig.radio.trashCurrentFMSong(session: rig.session)
  #expect(await rig.transport.callCount() == 0)
}

@Test @MainActor func resolvingPlayingAndPausedFMAreActive() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([makeTracks([1, 2, 3])])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
  rig.output.blockNextPrepare()

  rig.radio.startPersonalFM(session: rig.session)
  await rig.radio.settleForTesting()
  while !rig.output.prepareIsBlocked { await Task.yield() }

  #expect(rig.playback.phase == .resolving)
  #expect(rig.radio.isPlayingFM)

  rig.output.resumeBlockedPrepare()
  await rig.playback.settleForTesting()
  #expect(rig.playback.phase == .playing)
  #expect(rig.radio.isPlayingFM)

  rig.playback.pause()
  #expect(rig.playback.phase == .paused)
  #expect(rig.radio.isPlayingFM)
}

@Test @MainActor func finishedAndStoppedFMAreNotPlaying() async {
  let finished = RadioRig()
  await finished.transport.setFMBatches([makeTracks([1])])
  await finished.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
  await finished.startFM()

  finished.output.reportPlayedToEnd()
  #expect(finished.playback.phase == .finished)
  #expect(finished.radio.isPlayingFM == false)

  let stopped = RadioRig()
  await stopped.transport.setFMBatches([makeTracks([2])])
  await stopped.transport.setSongURL(.success(makeResolvedAsset(songID: 2)))
  await stopped.startFM()
  stopped.playback.stop()
  #expect(stopped.playback.phase == .idle)
  #expect(stopped.radio.isPlayingFM == false)
}

@Test @MainActor func resetStopsTheRadioFromRequestingAnything() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([makeTracks([1, 2])])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
  await rig.startFM()

  rig.playback.stopForSessionChange()
  rig.radio.reset()
  let calls = await rig.transport.callCount()

  rig.radio.playbackAdvanced(session: rig.session)
  rig.radio.trashCurrentFMSong(session: rig.session)
  await rig.settle()

  #expect(await rig.transport.callCount() == calls)
  #expect(rig.radio.failedTrash == nil)
  #expect(rig.arbiter.activeReadCount == 0)
}

/// The radio adds no read of its own to playback: a batch plus exactly one
/// resolve per track, through the same entry point every other queue uses. The
/// local-first half of that entry point is covered in the download tests.
@Test @MainActor func radioPlaybackCostsOneBatchAndOneResolve() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([makeTracks([1, 2])])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
  await rig.startFM()

  #expect(
    await rig.transport.recordedCalls() == [
      .personalFM, .resolveSongURL(1, .standard),
    ]
  )
}

/// A write and a session mutation are mutually exclusive, so a rejection
/// cannot be sent while the identity is being changed underneath it.
@Test @MainActor func trashIsRefusedWhileTheSessionIsBeingMutated() async {
  let rig = RadioRig()
  await rig.transport.setFMBatches([makeTracks([1, 2])])
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
  await rig.startFM()
  let before = await rig.transport.callCount()

  let mutation = try! #require(
    rig.arbiter.begin(name: "Validate", effect: .sessionMutation)
  )
  rig.radio.trashCurrentFMSong(session: rig.session)
  await rig.settle()

  #expect(await rig.transport.callCount() == before)
  #expect(rig.playback.queuedTracks(context: .personalFM).map(\.id) == [1, 2])
  rig.arbiter.end(mutation, outcome: .applied)
}

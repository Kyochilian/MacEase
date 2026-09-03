import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

/// P1: the queue surviving a relaunch.
///
/// The rule restoring has to keep is that it costs nothing. The user has just
/// opened the app and has not asked for audio, so a restore rebuilds the queue
/// and waits; continuing costs the same single resolve any other explicit play
/// costs.

@MainActor
private struct RestoreRig {
  let transport = FakeTransport()
  let vault: FakeVault
  let arbiter = OperationArbiter()
  let output = FakeAudioOutput()
  let session: FakeSession
  let playback: PlaybackController

  init() {
    let credential = makeCredential()
    vault = FakeVault(stored: credential)
    session = FakeSession(credential: credential)
    playback = PlaybackController(
      transport: transport,
      vault: vault,
      arbiter: arbiter,
      output: output
    )
    playback.attach(session: session)
  }
}

private func stored(
  ids: [Int64] = [101, 202, 303],
  currentIndex: Int = 1,
  positionSeconds: Double = 42,
  wasPlaying: Bool = true
) -> PersistedQueue {
  PersistedQueue(
    tracks: makeTracks(ids),
    currentIndex: currentIndex,
    mode: .repeatAll,
    context: .playlist(id: 7, name: "Evening"),
    positionSeconds: positionSeconds,
    quality: .lossless,
    wasPlaying: wasPlaying
  )
}

@Test @MainActor func restoringIssuesNoRequestAndPlaysNothing() async {
  let rig = RestoreRig()

  rig.playback.restore(stored())

  #expect(rig.playback.phase == .idle)
  #expect(rig.output.isPlaying == false)
  #expect(await rig.transport.callCount() == 0)
  #expect(rig.arbiter.isBusy == false)
}

@Test @MainActor func restoringRebuildsTheQueueItWasGiven() async {
  let rig = RestoreRig()

  rig.playback.restore(stored())

  #expect(rig.playback.currentTrack?.id == 202)
  #expect(rig.playback.queuePosition == "2 of 3")
  #expect(rig.playback.playbackMode == .repeatAll)
  #expect(rig.playback.quality == .lossless)
  #expect(rig.playback.positionSeconds == 42)
  #expect(rig.playback.status.contains("Evening"))
}

@Test @MainActor func restoringAnOlderQueueRemovesDuplicateSongIdentities() {
  let rig = RestoreRig()

  rig.playback.restore(
    stored(ids: [101, 202, 101, 303, 202], currentIndex: 2)
  )

  #expect(rig.playback.persistedQueue()?.tracks.map(\.id) == [202, 101, 303])
  #expect(rig.playback.queue?.currentIndex == 1)
  #expect(rig.playback.currentTrack?.id == 101)
  #expect(rig.playback.queueSnapshot?.upcoming.map(\.id) == [303])
}

/// The restore leaves a retry entry point, so continuing is the same single
/// resolve as any other play, and it lands at the stored position.
@Test @MainActor func continuingARestoredQueueResolvesOnceAndSeeks() async {
  let rig = RestoreRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 202)))
  rig.playback.restore(stored())
  #expect(rig.playback.canPlayAgain)
  #expect(rig.playback.retryResumesPlayback)

  rig.playback.playAgain(session: rig.session)
  await rig.playback.settleForTesting()

  #expect(rig.playback.phase == .playing)
  #expect(rig.output.seeks == [42])
  #expect(await rig.transport.recordedCalls() == [.resolveSongURL(202, .lossless)])
}

/// A queue that was paused when it was stored must not start playing when it
/// is picked up again.
@Test @MainActor func aQueueStoredWhilePausedComesBackPaused() async {
  let rig = RestoreRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 202)))
  rig.playback.restore(stored(wasPlaying: false))
  #expect(rig.playback.retryResumesPlayback == false)

  rig.playback.playAgain(session: rig.session)
  await rig.playback.settleForTesting()

  #expect(rig.playback.phase == .paused)
  #expect(rig.output.isPlaying == false)
}

/// Restoring over something already playing would silently replace the user's
/// queue with an older one.
@Test @MainActor func restoringIsRefusedWhilePlaybackIsActive() async {
  let rig = RestoreRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  rig.playback.play(
    tracks: makeTracks([101]),
    startIndex: 0,
    context: .dailyRecommendations,
    session: rig.session
  )
  await rig.playback.settleForTesting()

  rig.playback.restore(stored())

  #expect(rig.playback.currentTrack?.id == 101)
  #expect(rig.playback.phase == .playing)
}

@Test @MainActor func anEmptyStoredQueueRestoresNothing() {
  let rig = RestoreRig()

  rig.playback.restore(
    PersistedQueue(
      tracks: [],
      currentIndex: 0,
      mode: .sequential,
      context: .dailyRecommendations,
      positionSeconds: 0,
      quality: .standard,
      wasPlaying: false
    )
  )

  #expect(rig.playback.queue == nil)
  #expect(rig.playback.canPlayAgain == false)
}

// MARK: - Snapshotting for storage

@Test @MainActor func aPlayingQueueSnapshotsWhatItIs() async {
  let rig = RestoreRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 202)))
  rig.playback.quality = .exhigh
  rig.playback.play(
    tracks: makeTracks([101, 202]),
    startIndex: 1,
    context: .searchResults(keywords: "rain"),
    session: rig.session
  )
  await rig.playback.settleForTesting()

  let snapshot = rig.playback.persistedQueue()

  #expect(snapshot?.tracks.map(\.id) == [101, 202])
  #expect(snapshot?.currentIndex == 1)
  #expect(snapshot?.context == .searchResults(keywords: "rain"))
  #expect(snapshot?.quality == .exhigh)
  #expect(snapshot?.wasPlaying == true)
}

/// Stopping is the user saying they are done, so there is nothing left to
/// remember and nothing to restore next time.
@Test @MainActor func aStoppedQueueSnapshotsToNothing() async {
  let rig = RestoreRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  rig.playback.play(
    tracks: makeTracks([101]),
    startIndex: 0,
    context: .listeningRankings,
    session: rig.session
  )
  await rig.playback.settleForTesting()
  #expect(rig.playback.persistedQueue() != nil)

  rig.playback.stop()

  #expect(rig.playback.persistedQueue() == nil)
}

/// A restored queue must itself be storable, or the resume point would be lost
/// the moment it was picked up and put down again.
@Test @MainActor func aRestoredQueueCanBeStoredAgain() {
  let rig = RestoreRig()
  let original = stored()

  rig.playback.restore(original)
  let snapshot = rig.playback.persistedQueue()

  #expect(snapshot?.tracks == original.tracks)
  #expect(snapshot?.currentIndex == original.currentIndex)
  #expect(snapshot?.context == original.context)
  #expect(snapshot?.positionSeconds == original.positionSeconds)
  // Nothing is playing yet, which is the honest thing to store.
  #expect(snapshot?.wasPlaying == false)
}

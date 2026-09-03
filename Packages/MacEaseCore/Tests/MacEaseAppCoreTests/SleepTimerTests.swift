import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

@MainActor
private struct SleepTimerRig {
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

  func play() async {
    await transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
    playback.play(
      tracks: makeTracks([101, 202]),
      startIndex: 0,
      context: .dailyRecommendations,
      session: session
    )
    await playback.settleForTesting()
  }
}

@Test @MainActor func immediateSleepStopDoesNotClearThePersistedQueue() async {
  let rig = SleepTimerRig()
  await rig.play()
  var explicitStops = 0
  rig.playback.onExplicitStop = { explicitStops += 1 }
  rig.playback.sleepStopsImmediately = true
  rig.playback.setSleepTimer(minutes: 1)
  rig.playback.fireSleepTimerForTesting()

  #expect(rig.playback.phase == .idle)
  #expect(explicitStops == 0)
}

@Test @MainActor func finishingTrackSleepStopDoesNotClearThePersistedQueue() async {
  let rig = SleepTimerRig()
  await rig.play()
  var explicitStops = 0
  rig.playback.onExplicitStop = { explicitStops += 1 }
  rig.playback.sleepStopsImmediately = false
  rig.playback.setSleepTimer(minutes: 1)
  rig.playback.fireSleepTimerForTesting()
  #expect(rig.playback.sleepTimer == .finishingTrack)

  rig.output.reportPlayedToEnd()

  #expect(rig.playback.phase == .idle)
  #expect(explicitStops == 0)
}

@Test @MainActor func explicitStopStillNotifiesQueuePersistenceOnce() async {
  let rig = SleepTimerRig()
  await rig.play()
  var explicitStops = 0
  rig.playback.onExplicitStop = { explicitStops += 1 }

  rig.playback.stop()

  #expect(rig.playback.phase == .idle)
  #expect(explicitStops == 1)
}

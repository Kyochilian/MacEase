import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

/// P0 Gate C: what the machine does to playback.
///
/// Sleeping, waking, losing the headphones and losing the network cannot be
/// produced by a unit test. What can be tested — and what the acceptance run
/// on real hardware would otherwise be the only check of — is the decision
/// each one leads to: which stop playback, which only report, and which never
/// issue a request.

@MainActor
private struct SystemRig {
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

  /// Gets to a genuinely playing track, so the pause decisions have something
  /// to act on.
  func playing() async {
    await transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
    playback.play(
      tracks: makeTracks([101, 102]),
      startIndex: 0,
      context: .dailyRecommendations,
      session: session
    )
    await playback.settleForTesting()
  }

  func failed() async {
    await transport.setSongURL(.failure(URLError(.notConnectedToInternet)))
    playback.play(tracks: makeTracks([101]), startIndex: 0, context: .dailyRecommendations, session: session)
    await playback.settleForTesting()
  }
}

// MARK: - Sleep and wake

@Test @MainActor func sleepPausesPlaybackAndWakeLeavesItPaused() async {
  let rig = SystemRig()
  await rig.playing()
  #expect(rig.playback.phase == .playing)

  rig.playback.handle(system: .willSleep)
  #expect(rig.playback.phase == .paused)
  #expect(rig.output.isPlaying == false)

  rig.playback.handle(system: .didWake)
  // Waking must not start audio on its own, and must not spend a request
  // re-resolving something the user may not want to hear.
  #expect(rig.playback.phase == .paused)
  #expect(rig.playback.status == "Paused while asleep; press Resume to continue")
  #expect(await rig.transport.callCount() == 1)
}

/// Waking must not take credit for — or narrate over — a pause the user asked
/// for before the machine slept.
@Test @MainActor func wakeLeavesAUserPauseAlone() async {
  let rig = SystemRig()
  await rig.playing()
  rig.playback.pause()
  #expect(rig.playback.status == "Paused")

  rig.playback.handle(system: .willSleep)
  rig.playback.handle(system: .didWake)

  #expect(rig.playback.phase == .paused)
  #expect(rig.playback.status == "Paused")
}

@Test @MainActor func sleepDoesNothingWhenNothingIsPlaying() async {
  let rig = SystemRig()

  rig.playback.handle(system: .willSleep)
  rig.playback.handle(system: .didWake)

  #expect(rig.playback.phase == .idle)
  #expect(await rig.transport.callCount() == 0)
}

// MARK: - Audio output device

/// Unplugging headphones must not continue out loud on the built-in speakers.
@Test @MainActor func losingTheOutputDevicePausesPlayback() async {
  let rig = SystemRig()
  await rig.playing()

  rig.playback.handle(system: .audioOutputDeviceLost)

  #expect(rig.playback.phase == .paused)
  #expect(rig.output.isPlaying == false)
  #expect(rig.playback.status == "Paused: the output device was disconnected")
  #expect(await rig.transport.callCount() == 1)
}

/// Choosing a different speaker is not a disconnection. Audio follows the new
/// system default, so pausing here would be the app fighting the user.
@Test @MainActor func switchingTheOutputDeviceKeepsPlaying() async {
  let rig = SystemRig()
  await rig.playing()

  rig.playback.handle(system: .audioOutputDeviceChanged)

  #expect(rig.playback.phase == .playing)
  #expect(rig.output.isPlaying)
  #expect(await rig.transport.callCount() == 1)
}

/// Resume after a machine pause is an ordinary resume: it must not report
/// itself as still being interrupted.
@Test @MainActor func resumingAfterAMachinePauseClearsTheReason() async {
  let rig = SystemRig()
  await rig.playing()
  rig.playback.handle(system: .audioOutputDeviceLost)

  #expect(rig.playback.resume())
  rig.playback.handle(system: .didWake)

  #expect(rig.playback.phase == .playing)
  #expect(rig.playback.status.hasPrefix("Playing"))
}

// MARK: - Network

/// A buffered track keeps playing when the network goes: the audio is already
/// on this machine, and stopping it would throw away sound the user can hear.
@Test @MainActor func losingTheNetworkDoesNotStopABufferedTrack() async {
  let rig = SystemRig()
  await rig.playing()

  rig.playback.handle(system: .networkReachabilityChanged(false))

  #expect(rig.playback.phase == .playing)
  #expect(rig.output.isPlaying)
  #expect(
    rig.playback.status == "Network unavailable; playing from what is already buffered"
  )
}

/// Coming back must not resolve, resume or retry anything: it only tells a
/// user looking at a failure that the button in front of them can now work.
@Test @MainActor func regainingTheNetworkOffersTheRetryWithoutTakingIt() async {
  let rig = SystemRig()
  await rig.failed()
  #expect(rig.playback.phase == .failed)
  #expect(rig.playback.canPlayAgain)

  rig.playback.handle(system: .networkReachabilityChanged(true))

  #expect(rig.playback.phase == .failed)
  #expect(await rig.transport.callCount() == 1)
  #expect(rig.playback.status.hasPrefix("Network is back"))
}

/// With nothing to retry there is nothing to say, and saying it anyway would
/// overwrite whatever the user was actually reading.
@Test @MainActor func regainingTheNetworkIsSilentWhenThereIsNothingToRetry() async {
  let rig = SystemRig()
  let before = rig.playback.status

  rig.playback.handle(system: .networkReachabilityChanged(false))
  rig.playback.handle(system: .networkReachabilityChanged(true))

  #expect(rig.playback.status == before)
  #expect(await rig.transport.callCount() == 0)
}

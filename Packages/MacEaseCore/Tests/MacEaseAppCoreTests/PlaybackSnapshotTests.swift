import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

/// SYS-001: the system media surface reads a projection of playback rather
/// than keeping its own copy. These tests pin what that projection says, and
/// in particular that it never reports a state the controller is not in.

@MainActor
private struct SnapshotRig {
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

  /// Resolves successfully, so the rig reaches a state that actually has
  /// audio. Tests that need a failure override the transport first.
  func play(_ ids: [Int64] = [101], startIndex: Int = 0) async {
    await transport.setSongURL(.success(makeResolvedAsset(songID: ids[startIndex])))
    playback.play(tracks: makeTracks(ids), startIndex: startIndex, context: .dailyRecommendations, session: session)
    await playback.settleForTesting()
  }
}

// MARK: - Nothing loaded

@Test @MainActor func anIdleControllerProjectsNoActionableItem() {
  let rig = SnapshotRig()
  let snapshot = rig.playback.snapshot(liked: .liked)

  #expect(snapshot.state == .stopped)
  #expect(!snapshot.hasActionableItem)
  #expect(snapshot.trackID == nil)
  #expect(snapshot.rate == 0)
  // With no track there is nothing for a like command to refer to, so the
  // liked state the library supplied must not be projected onto nothing.
  #expect(snapshot.liked == .unknown)
}

@Test @MainActor func stoppingClearsTheProjection() async {
  let rig = SnapshotRig()
  await rig.play([101, 102])
  #expect(rig.playback.snapshot(liked: .liked).hasActionableItem)

  rig.playback.stop()
  let snapshot = rig.playback.snapshot(liked: .liked)

  #expect(snapshot.state == .stopped)
  #expect(!snapshot.hasActionableItem)
  #expect(snapshot.canStepNext == false)
  #expect(snapshot.canStepPrevious == false)
}

// MARK: - Playing state

@Test @MainActor func aPlayingTrackProjectsItsMetadataAndRate() async {
  let rig = SnapshotRig()
  await rig.play([101, 102, 103], startIndex: 1)

  let snapshot = rig.playback.snapshot(liked: .liked)
  #expect(snapshot.state == .playing)
  #expect(snapshot.trackID == 102)
  #expect(snapshot.title == "track-102")
  #expect(snapshot.artist == "artist")
  #expect(snapshot.rate == 1)
  #expect(snapshot.liked == .liked)
  #expect(snapshot.canStepNext)
  #expect(snapshot.canStepPrevious)
}

@Test @MainActor func pausingProjectsRateZeroWithoutLosingTheTrack() async {
  let rig = SnapshotRig()
  await rig.play()
  rig.playback.pause()

  let snapshot = rig.playback.snapshot(liked: .notLiked)
  #expect(snapshot.state == .paused)
  #expect(snapshot.rate == 0)
  #expect(snapshot.trackID == 101)
  #expect(snapshot.liked == .notLiked)
}

@Test @MainActor func queueBoundariesDisableTheStepsTheyShould() async {
  let rig = SnapshotRig()
  await rig.play([101, 102], startIndex: 0)

  let first = rig.playback.snapshot(liked: .unknown)
  #expect(first.canStepNext)
  #expect(!first.canStepPrevious)
}

// MARK: - States with no audio

@Test @MainActor func aFailedResolveProjectsStoppedRatherThanPlaying() async {
  let rig = SnapshotRig()

  rig.playback.play(tracks: makeTracks([101]), startIndex: 0, context: .dailyRecommendations, session: rig.session)
  await rig.playback.settleForTesting()
  await rig.transport.setSongURL(.failure(URLError(.timedOut)))
  rig.playback.playAgain(session: rig.session)
  await rig.playback.settleForTesting()

  #expect(rig.playback.phase == .failed)
  let snapshot = rig.playback.snapshot(liked: .unknown)
  // The system must not claim audio is playing when none is.
  #expect(snapshot.state == .stopped)
  #expect(snapshot.rate == 0)
  // The chosen track stays visible so the surface does not blank out.
  #expect(snapshot.trackID == 101)
}

// MARK: - Publishing rule

@Test @MainActor func theClockAdvancingAloneDoesNotRequirePublishing() async {
  let rig = SnapshotRig()
  await rig.play()

  let before = rig.playback.snapshot(liked: .unknown)
  rig.output.reportPosition(12)
  let after = rig.playback.snapshot(liked: .unknown)

  #expect(after.elapsedSeconds == 12)
  #expect(after.positionEpoch == before.positionEpoch)
  // The system extrapolates elapsed time from the rate, so a tick carries no
  // information it does not already have.
  #expect(!after.requiresPublishing(comparedTo: before))
}

@Test @MainActor func aSeekRequiresPublishingBecauseTheClockJumped() async {
  let rig = SnapshotRig()
  await rig.play()
  rig.output.reportPosition(12)
  let before = rig.playback.snapshot(liked: .unknown)

  rig.playback.seek(to: 90)
  let after = rig.playback.snapshot(liked: .unknown)

  #expect(after.elapsedSeconds == 90)
  #expect(after.positionEpoch != before.positionEpoch)
  #expect(after.requiresPublishing(comparedTo: before))
}

@Test @MainActor func aChangedLikedStateRequiresPublishing() async {
  let rig = SnapshotRig()
  await rig.play()

  let notLiked = rig.playback.snapshot(liked: .notLiked)
  let liked = rig.playback.snapshot(liked: .liked)

  #expect(liked.requiresPublishing(comparedTo: notLiked))
}

@Test @MainActor func theFirstSnapshotAlwaysRequiresPublishing() {
  let rig = SnapshotRig()
  #expect(rig.playback.snapshot(liked: .unknown).requiresPublishing(comparedTo: nil))
}

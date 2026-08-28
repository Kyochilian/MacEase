import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

/// Regression for the 2026-08-27 review finding that the composition root
/// reported every remote command as handled. These drive the real router
/// against real coordinators, because a configurable fake handler can only
/// prove the coordinator forwards a result — not that the result is true.

@MainActor
private final class RouterRig {
  let transport = FakeTransport()
  let vault: FakeVault
  let arbiter: OperationArbiter
  let output = FakeAudioOutput()
  let session: FakeSession
  let playback: PlaybackController
  let library: PlaylistLibraryCoordinator
  let router: SystemMediaRouter

  init(arbiter: OperationArbiter = OperationArbiter()) {
    let credential = makeCredential()
    self.arbiter = arbiter
    vault = FakeVault(stored: credential)
    session = FakeSession(credential: credential)
    playback = PlaybackController(
      transport: transport,
      vault: vault,
      arbiter: arbiter,
      output: output
    )
    library = PlaylistLibraryCoordinator(
      transport: transport,
      vault: vault,
      arbiter: arbiter
    )
    playback.attach(session: session)
    router = SystemMediaRouter(playback: playback, library: library, session: session)
  }

  func play(_ ids: [Int64] = [101, 102]) async {
    await transport.setSongURL(.success(makeResolvedAsset(songID: ids[0])))
    playback.play(tracks: makeTracks(ids), startIndex: 0, session: session)
    await playback.settleForTesting()
  }
}

// MARK: - Transport commands really are refused

@Test @MainActor func pausingWhenNothingIsLoadedIsReportedAsRefused() {
  let rig = RouterRig()
  // No queue, so there is nothing to pause. The old router returned true here.
  #expect(!rig.router.perform(.pause))
  #expect(!rig.router.perform(.play))
  #expect(!rig.router.perform(.seek(10)))
}

@Test @MainActor func steppingWithoutAValidatedSessionIsRefused() async {
  let rig = RouterRig()
  await rig.play()
  rig.session.account = nil

  #expect(!rig.router.perform(.next))
  #expect(!rig.router.perform(.previous))
}

@Test @MainActor func steppingPastTheEndOfTheQueueIsRefused() async {
  let rig = RouterRig()
  await rig.play([101])

  // A single-track sequential queue has nowhere to step.
  #expect(!rig.router.perform(.next))
  #expect(!rig.router.perform(.previous))
}

@Test @MainActor func steppingIsRefusedWhileAWriteOwnsTheArbiter() async {
  let rig = RouterRig()
  await rig.play()

  // A write holds the exclusive slot, so a playback resolution cannot claim.
  let write = rig.arbiter.begin(name: "Like", effect: .write)
  #expect(write != nil)

  #expect(!rig.router.perform(.next))
  #expect(await rig.transport.callCount() == 1)
}

@Test @MainActor func togglingIsAlwaysRefusedBecauseItIsResolvedEarlier() async {
  let rig = RouterRig()
  await rig.play()

  // The coordinator turns toggle into play or pause before dispatch, so a
  // toggle reaching the router means the two disagreed.
  #expect(!rig.router.perform(.toggle))
}

// MARK: - Accepted commands

@Test @MainActor func pausingAndResumingALoadedTrackIsAccepted() async {
  let rig = RouterRig()
  await rig.play()

  #expect(rig.router.perform(.pause))
  #expect(rig.playback.phase == .paused)
  #expect(rig.router.perform(.play))
  #expect(rig.playback.phase == .playing)
  #expect(rig.router.perform(.seek(30)))
}

// MARK: - Like

@Test @MainActor func likingIsRefusedWhileAnotherWriteIsInFlight() async {
  let rig = RouterRig()
  await rig.play()
  let write = rig.arbiter.begin(name: "Create playlist", effect: .write)
  #expect(write != nil)

  // The like write cannot claim, so nothing was sent and the system must not
  // be told the heart changed.
  #expect(!rig.router.perform(.setLiked(true)))
}

@Test @MainActor func likingIsRefusedWithoutACurrentTrack() {
  let rig = RouterRig()
  #expect(!rig.router.perform(.setLiked(true)))
}

@Test @MainActor func likingACurrentTrackIsAccepted() async {
  let rig = RouterRig()
  await rig.play()

  #expect(rig.router.perform(.setLiked(true)))
  await rig.library.settleForTesting()
  #expect(rig.library.liked.state(of: 101) == .liked)
}

// MARK: - Projection

@Test @MainActor func theRouterProjectsTheLikedStateOfTheCurrentTrack() async {
  let rig = RouterRig()
  await rig.play()

  #expect(rig.router.snapshot().liked == .unknown)

  #expect(rig.router.perform(.setLiked(true)))
  await rig.library.settleForTesting()

  #expect(rig.router.snapshot().liked == .liked)
  #expect(rig.router.snapshot().trackID == 101)
}

// MARK: - End to end through the coordinator

@Test @MainActor func aRefusedIntentReachesTheSystemAsCommandFailure() async {
  let rig = RouterRig()
  await rig.play()

  final class Surface: SystemMediaControlling {
    var onCommand: (@MainActor (SystemMediaCommand) -> SystemMediaCommandResult)?
    func publish(_ snapshot: PlaybackSnapshot) {}
    func clear() {}
  }
  let surface = Surface()
  let coordinator = NowPlayingCoordinator(
    surface: surface,
    snapshotProvider: { rig.router.snapshot() },
    performIntent: { rig.router.perform($0) }
  )

  // A write owns the arbiter, so the real Next entry point refuses.
  _ = rig.arbiter.begin(name: "Like", effect: .write)

  #expect(surface.onCommand?(.next) == .failed)
  withExtendedLifetime(coordinator) {}
}

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
    playback.play(
      tracks: makeTracks(ids), startIndex: 0, context: .dailyRecommendations, session: session)
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

  #expect(!rig.router.perform(AppPlaybackCommand.next))
  #expect(!rig.router.perform(AppPlaybackCommand.previous))
}

@Test @MainActor func steppingPastTheEndOfTheQueueIsRefused() async {
  let rig = RouterRig()
  await rig.play([101])

  // A single-track sequential queue has nowhere to step.
  #expect(!rig.router.perform(AppPlaybackCommand.next))
  #expect(!rig.router.perform(AppPlaybackCommand.previous))
}

@Test @MainActor func steppingIsRefusedWhileTheAccountIsChanging() async {
  let rig = RouterRig()
  await rig.play()

  let write = rig.arbiter.begin(name: "Change account", effect: .sessionMutation)
  #expect(write != nil)

  #expect(!rig.router.canPerform(AppPlaybackCommand.next))
  #expect(!rig.router.perform(AppPlaybackCommand.next))
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

@Test @MainActor func matchedCloudHeartUsesOneCatalogIdentityAcrossLibraryAndSystemControls() async {
  let rig = RouterRig()
  let track = Track(id: 9001, name: "Cloud file", cloudFileID: 9001, catalogSongID: 42)
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 9001)))
  rig.playback.play(tracks: [track], startIndex: 0, context: .cloudDrive, session: rig.session)
  await rig.playback.settleForTesting()
  await rig.transport.setLikedIDs(.success([42]))
  rig.library.loadLikedIDs(session: rig.session)
  await rig.library.settleForTesting()
  #expect(rig.library.likedState(for: track) == .liked)
  #expect(rig.router.snapshot().liked == .liked)
  #expect(rig.router.snapshot().trackID == 9001)
  #expect(rig.router.perform(.setLiked(false)))
  await rig.library.settleForTesting()
  #expect(rig.library.likedState(for: makeTracks([42])[0]) == .notLiked)
  #expect(rig.router.snapshot().liked == .notLiked)
  #expect(await rig.transport.recordedCalls().contains(.resolveCloudURL(9001, .standard)))
  #expect(await rig.transport.recordedCalls().contains(.setSongLiked(42, false)))
  #expect(!((await rig.transport.recordedCalls()).contains(.setSongLiked(9001, false))))
}

@Test @MainActor func unmatchedCloudFilesRefuseCatalogWritesAtTheSharedBoundary() async {
  let rig = RouterRig()
  let track = Track(id: 9001, name: "Cloud file", cloudFileID: 9001)
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 9001)))
  rig.playback.play(tracks: [track], startIndex: 0, context: .cloudDrive, session: rig.session)
  await rig.playback.settleForTesting()
  #expect(!rig.library.canLike(track, session: rig.session))
  #expect(!rig.router.perform(.setLiked(true)))
  #expect(!rig.router.canPerform(.toggleLiked))
  #expect(rig.router.snapshot().liked == .unknown)
  #expect(await rig.transport.recordedCalls() == [.resolveCloudURL(9001, .standard)])
}

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

  _ = rig.arbiter.begin(name: "Change account", effect: .sessionMutation)

  #expect(surface.onCommand?(.next) == .failed)
  withExtendedLifetime(coordinator) {}
}

// MARK: - App and Dock command route

@Test @MainActor func appToggleUsesTheSameLivePlaybackState() async {
  let rig = RouterRig()
  await rig.play()

  #expect(rig.router.canPerform(.togglePlayback))
  #expect(rig.router.perform(.togglePlayback))
  #expect(rig.playback.phase == .paused)
  #expect(rig.router.perform(.togglePlayback))
  #expect(rig.playback.phase == .playing)
}

@Test @MainActor func appModeCommandMutatesOnlyPlaybackControllersMode() {
  let rig = RouterRig()

  #expect(rig.router.perform(.setMode(.shuffle)))
  #expect(rig.playback.playbackMode == .shuffle)
  #expect(rig.router.snapshot().trackID == nil)
}

@Test @MainActor func appLikeToggleRefusesUnknownAndArbiterRejection() async {
  let rig = RouterRig()
  await rig.play()

  #expect(!rig.router.canPerform(.toggleLiked))
  #expect(!rig.router.perform(.toggleLiked))

  #expect(rig.router.perform(SystemMediaCommand.setLiked(true)))
  await rig.library.settleForTesting()
  #expect(rig.router.canPerform(.toggleLiked))

  let blocker = rig.arbiter.begin(name: "Another write", effect: .write)!
  #expect(!rig.router.canPerform(.toggleLiked))
  #expect(!rig.router.perform(.toggleLiked))
  #expect(rig.arbiter.end(blocker, outcome: .applied) == .applied)
}

@Test @MainActor func appPreviousAndNextReportRealQueueBoundaries() async {
  let rig = RouterRig()
  await rig.play([101])
  #expect(!rig.router.canPerform(.previous))
  #expect(!rig.router.canPerform(.next))

  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  rig.playback.play(
    tracks: makeTracks([101, 202]),
    startIndex: 0,
    context: .dailyRecommendations,
    session: rig.session
  )
  await rig.playback.settleForTesting()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 202)))

  #expect(rig.router.perform(AppPlaybackCommand.next))
  await rig.playback.settleForTesting()
  #expect(rig.playback.currentTrack?.id == 202)
}

@Test @MainActor func queuePanelCommandsUseTheSharedRouterAndRejectStaleRows() async throws {
  let rig = RouterRig()
  await rig.play([101, 102, 103])
  let first = try #require(rig.playback.queueSnapshot)

  #expect(
    rig.router.perform(
      .removeQueueEntry(
        songID: 103,
        accountID: first.accountID,
        revision: first.revision
      )
    )
  )
  #expect(rig.playback.queueSnapshot?.upcoming.map(\.id) == [102])
  #expect(
    !rig.router.perform(
      .clearUpcoming(accountID: first.accountID, revision: first.revision)
    )
  )

  let second = try #require(rig.playback.queueSnapshot)
  #expect(
    rig.router.perform(
      .removeQueueEntry(
        songID: 102,
        accountID: second.accountID,
        revision: second.revision
      )
    )
  )
  let third = try #require(rig.playback.queueSnapshot)
  #expect(
    rig.router.perform(
      .clearUpcoming(accountID: third.accountID, revision: third.revision)
    )
  )
  #expect(rig.playback.queueSnapshot?.upcoming.isEmpty == true)
}

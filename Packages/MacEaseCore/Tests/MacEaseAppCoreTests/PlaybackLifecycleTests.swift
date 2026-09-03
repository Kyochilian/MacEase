import Foundation
import MacEaseSession
import NeteaseKit
import Testing

@testable import MacEaseAppCore

@MainActor
private final class LifecycleClock {
  var now: TimeInterval = 1_000
  func advance(_ seconds: TimeInterval) { now += seconds }
}

@MainActor
private struct LifecycleRig {
  let transport = FakeTransport()
  let vault: FakeVault
  let arbiter = OperationArbiter()
  let output = FakeAudioOutput()
  let session: FakeSession
  let clock = LifecycleClock()
  let playback: PlaybackController
  let events: EventBox

  init() {
    let credential = makeCredential()
    vault = FakeVault(stored: credential)
    session = FakeSession(credential: credential)
    events = EventBox()
    playback = PlaybackController(
      transport: transport,
      vault: vault,
      arbiter: arbiter,
      output: output,
      monotonicNow: { [clock] in clock.now }
    )
    playback.attach(session: session)
    playback.onLifecycleEvent = { [events] in events.values.append($0) }
  }

  func play(
    _ ids: [Int64] = [101],
    startIndex: Int = 0,
    context: PlaybackContext = .dailyRecommendations
  ) async {
    await transport.setSongURL(.success(makeResolvedAsset(songID: ids[startIndex])))
    playback.play(
      tracks: makeTracks(ids),
      startIndex: startIndex,
      context: context,
      session: session
    )
    await playback.settleForTesting()
  }
}

@MainActor
private final class EventBox {
  var values: [PlaybackLifecycleEvent] = []
}

@Test @MainActor func prepareFailureAndUnconfirmedOutputProduceNoLifecycleStart() async {
  let failed = LifecycleRig()
  await failed.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  failed.output.prepareResult = .failure(AudioOutputFailure.assetLoad("timeout"))
  failed.playback.play(
    tracks: makeTracks([101]),
    startIndex: 0,
    context: .dailyRecommendations,
    session: failed.session
  )
  await failed.playback.settleForTesting()
  #expect(failed.events.values.isEmpty)

  let waiting = LifecycleRig()
  waiting.output.automaticallyReportsPlaying = false
  await waiting.play()
  #expect(waiting.playback.phase == .playing)
  #expect(waiting.events.values.isEmpty)

  waiting.output.reportPlaybackState(.playing)
  #expect(waiting.events.values.count == 1)
}

@Test @MainActor func pauseResumeBufferingAndSeekCountOnlyMonotonicPlayingTime() async {
  let rig = LifecycleRig()
  await rig.play()
  #expect(rig.events.values.count == 1)

  rig.clock.advance(10)
  rig.playback.seek(to: 190)
  rig.clock.advance(2)
  rig.output.reportPlaybackState(.notPlaying)
  rig.clock.advance(100)
  rig.output.reportPlaybackState(.playing)
  rig.clock.advance(5)
  rig.playback.pause()
  rig.clock.advance(50)
  rig.playback.resume()
  rig.clock.advance(3)
  rig.playback.stop()

  #expect(rig.events.values.count == 2)
  guard case .finished(_, let seconds) = rig.events.values.last else {
    Issue.record("Expected a finish event")
    return
  }
  #expect(seconds == 20)
}

@Test @MainActor func replacingStoppingFailingAndSessionCleanupFinishOnce() async {
  let rig = LifecycleRig()
  await rig.play([101, 202])
  rig.clock.advance(4)
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 202)))
  #expect(rig.playback.playNext(session: rig.session))
  await rig.playback.settleForTesting()
  rig.clock.advance(3)
  rig.output.reportFailure("network")
  rig.playback.stopForSessionChange()

  let finishes = rig.events.values.compactMap { event -> (Int64, Int)? in
    guard case .finished(let instance, let seconds) = event else { return nil }
    return (instance.track.id, seconds)
  }
  #expect(finishes.map(\.0) == [101, 202])
  #expect(finishes.map(\.1) == [4, 3])
}

@Test @MainActor func previousAndNaturalEndEachSettleTheCurrentInstance() async {
  let rig = LifecycleRig()
  await rig.play([101, 202], startIndex: 1)
  rig.clock.advance(2)
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  #expect(rig.playback.playPrevious(session: rig.session))
  await rig.playback.settleForTesting()
  rig.clock.advance(6)
  rig.output.reportPlayedToEnd()

  let finishedIDs = rig.events.values.compactMap { event -> Int64? in
    guard case .finished(let instance, _) = event else { return nil }
    return instance.track.id
  }
  #expect(finishedIDs == [202, 101])
}

@Test @MainActor func fmTrashSettlesTheRemovedCurrentInstanceOnce() async {
  let rig = LifecycleRig()
  await rig.play([101, 202], context: .personalFM)
  rig.clock.advance(5)
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 202)))

  #expect(
    rig.playback.removeTrack(
      songID: 101,
      from: .personalFM,
      session: rig.session,
      emptyStatus: "FM is empty"
    )
  )
  await rig.playback.settleForTesting()

  let finishes = rig.events.values.compactMap { event -> (Int64, Int)? in
    guard case .finished(let instance, let seconds) = event else { return nil }
    return (instance.track.id, seconds)
  }
  #expect(finishes.map(\.0) == [101])
  #expect(finishes.map(\.1) == [5])
  #expect(rig.playback.currentTrack?.id == 202)
}

@Test @MainActor func lifecycleSecondsStayNonnegativeAndDoNotExceedDuration() async {
  let capped = LifecycleRig()
  await capped.play()
  capped.clock.advance(250)
  capped.playback.stop()

  let reversed = LifecycleRig()
  await reversed.play()
  reversed.clock.advance(-10)
  reversed.playback.stop()

  let nonfinite = LifecycleRig()
  await nonfinite.play()
  nonfinite.clock.now = .infinity
  nonfinite.playback.stop()

  let cappedSeconds = capped.events.values.compactMap { event -> Int? in
    guard case .finished(_, let seconds) = event else { return nil }
    return seconds
  }
  let reversedSeconds = reversed.events.values.compactMap { event -> Int? in
    guard case .finished(_, let seconds) = event else { return nil }
    return seconds
  }
  let nonfiniteSeconds = nonfinite.events.values.compactMap { event -> Int? in
    guard case .finished(_, let seconds) = event else { return nil }
    return seconds
  }
  #expect(cappedSeconds == [200])
  #expect(reversedSeconds == [0])
  #expect(nonfiniteSeconds == [0])
}

@Test @MainActor func repeatOneCreatesASeparateLifecycleForEveryRound() async {
  let rig = LifecycleRig()
  rig.playback.playbackMode = .repeatOne
  await rig.play()
  rig.clock.advance(8)
  rig.output.reportPlayedToEnd()
  await Task.yield()
  rig.clock.advance(7)
  rig.output.reportPlayedToEnd()
  await Task.yield()

  let starts = rig.events.values.compactMap { event -> UUID? in
    guard case .started(let instance) = event else { return nil }
    return instance.id
  }
  let finishes = rig.events.values.compactMap { event -> UUID? in
    guard case .finished(let instance, _) = event else { return nil }
    return instance.id
  }
  #expect(starts.count == 3)
  #expect(finishes.count == 2)
  #expect(Set(starts).count == 3)
  #expect(finishes == Array(starts.prefix(2)))
}

@Test func scrobbleSourceUsesOnlyAConfirmedPlaylistID() {
  let track = makeTracks([1])[0]
  let playlist = PlaybackLifecycleInstance(
    accountID: 42,
    track: track,
    context: .playlist(id: 77, name: "named")
  )
  let album = PlaybackLifecycleInstance(
    accountID: 42,
    track: track,
    context: .album(id: 88, name: "album")
  )

  #expect(playlist.scrobbleContext == ScrobbleContext(sourceID: 77))
  #expect(album.scrobbleContext == nil)
}

@Test @MainActor func nonPlaylistPlaybackSendsNoScrobbleRequests() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let arbiter = OperationArbiter()
  let session = FakeSession(credential: credential)
  let coordinator = ScrobbleCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  let track = makeTracks([101])[0]
  let album = PlaybackLifecycleInstance(
    accountID: testAccount.userID,
    track: track,
    context: .album(id: 88, name: "album")
  )
  let fm = PlaybackLifecycleInstance(
    accountID: testAccount.userID,
    track: track,
    context: .personalFM
  )

  for instance in [album, fm] {
    coordinator.handle(.started(instance), session: session)
    coordinator.handle(.finished(instance, playedSeconds: 12), session: session)
  }
  await coordinator.settleForTesting()

  #expect(await transport.recordedCalls().isEmpty)
  #expect(arbiter.unresolvedOutcomes.isEmpty)
}

@Test @MainActor func scrobbleRequiresAConfirmedStartBeforeFinish() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let arbiter = OperationArbiter()
  let session = FakeSession(credential: credential)
  let coordinator = ScrobbleCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  let instance = PlaybackLifecycleInstance(
    accountID: testAccount.userID,
    track: makeTracks([101])[0],
    context: .playlist(id: 77, name: "list")
  )
  await transport.setWriteResult(.failure(URLError(.networkConnectionLost)))

  coordinator.handle(.started(instance), session: session)
  coordinator.handle(.finished(instance, playedSeconds: 20), session: session)
  await coordinator.settleForTesting()

  #expect(await transport.recordedCalls() == [
    .scrobbleStart(101, ScrobbleContext(sourceID: 77))
  ])
  #expect(arbiter.unresolvedOutcomes.count == 1)
  #expect(coordinator.status.contains("not sent"))
}

@Test @MainActor func scrobbleStartAndFinishUseTheWriteArbiterInOrder() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let arbiter = OperationArbiter()
  let session = FakeSession(credential: credential)
  let coordinator = ScrobbleCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  let instance = PlaybackLifecycleInstance(
    accountID: testAccount.userID,
    track: makeTracks([101])[0],
    context: .playlist(id: 77, name: "list")
  )

  coordinator.handle(.started(instance), session: session)
  coordinator.handle(.finished(instance, playedSeconds: 12), session: session)
  await coordinator.settleForTesting()

  #expect(await transport.recordedCalls() == [
    .scrobbleStart(101, ScrobbleContext(sourceID: 77)),
    .scrobbleFinish(101, ScrobbleContext(sourceID: 77), 12),
  ])
  #expect(arbiter.active == nil)
  #expect(coordinator.status.contains("12s"))
}

@Test @MainActor func scrobbleArbiterRefusalSendsNothingAndDoesNotRetry() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let arbiter = OperationArbiter()
  let session = FakeSession(credential: credential)
  let coordinator = ScrobbleCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  let blocker = arbiter.begin(name: "Like", effect: .write)!
  let instance = PlaybackLifecycleInstance(
    accountID: testAccount.userID,
    track: makeTracks([101])[0],
    context: .playlist(id: 77, name: "list")
  )

  coordinator.handle(.started(instance), session: session)
  coordinator.handle(.finished(instance, playedSeconds: 4), session: session)
  await coordinator.settleForTesting()

  #expect(await transport.recordedCalls().isEmpty)
  #expect(coordinator.status.contains("not confirmed"))
  #expect(arbiter.end(blocker, outcome: .applied) == .applied)
}

@Test @MainActor func remoteNextSettlesTheOldScrobbleWhileResolvingTheNewSong() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let arbiter = OperationArbiter()
  let output = FakeAudioOutput()
  let session = FakeSession(credential: credential)
  let clock = LifecycleClock()
  let playback = PlaybackController(
    transport: transport,
    vault: vault,
    arbiter: arbiter,
    output: output,
    monotonicNow: { clock.now }
  )
  let scrobble = ScrobbleCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  playback.attach(session: session)
  playback.onLifecycleEvent = { scrobble.handle($0, session: session) }

  await transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  playback.play(
    tracks: makeTracks([101, 202]),
    startIndex: 0,
    context: .playlist(id: 77, name: "list"),
    session: session
  )
  await playback.settleForTesting()
  await scrobble.settleForTesting()
  clock.advance(8)

  await transport.setSongURL(.success(makeResolvedAsset(songID: 202)))
  #expect(playback.playNext(session: session))
  await playback.settleForTesting()
  await scrobble.settleForTesting()

  let feedback = await transport.recordedCalls().filter { call in
    switch call {
    case .scrobbleStart, .scrobbleFinish: true
    default: false
    }
  }
  #expect(feedback == [
    .scrobbleStart(101, ScrobbleContext(sourceID: 77)),
    .scrobbleFinish(101, ScrobbleContext(sourceID: 77), 8),
    .scrobbleStart(202, ScrobbleContext(sourceID: 77)),
  ])
  #expect(arbiter.active == nil)
  #expect(arbiter.activeReadCount == 0)
}

@Test @MainActor func lateAccountAStartCannotEnableAFinishOnAccountB() async {
  let credentialA = makeCredential("account-a")
  let credentialB = makeCredential("account-b")
  let transport = FakeTransport()
  await transport.gate.close()
  let vault = FakeVault(stored: credentialA)
  let arbiter = OperationArbiter()
  let session = FakeSession(credential: credentialA)
  let coordinator = ScrobbleCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  let old = PlaybackLifecycleInstance(
    accountID: testAccount.userID,
    track: makeTracks([101])[0],
    context: .playlist(id: 77, name: "list")
  )
  coordinator.handle(.started(old), session: session)
  while await transport.gate.arrivalCount() == 0 { await Task.yield() }

  coordinator.reset()
  session.account = otherAccount
  session.validatedCredential = credentialB
  await vault.setStored(credentialB)
  await transport.gate.open()
  await coordinator.settleForTesting()
  coordinator.handle(.finished(old, playedSeconds: 9), session: session)
  await coordinator.settleForTesting()

  #expect(await transport.recordedCalls() == [
    .scrobbleStart(101, ScrobbleContext(sourceID: 77))
  ])
  #expect(!coordinator.status.contains("confirmed: 9s"))
}

@Test @MainActor func explicitSessionClearSettlesBeforeReplacingTheCredential() async {
  let credential = makeCredential("old-account")
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let arbiter = OperationArbiter()
  let output = FakeAudioOutput()
  let clock = LifecycleClock()
  let session = LoginCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  #expect(await session.validateSession() == .credentialReplaced(testAccount))

  let playback = PlaybackController(
    transport: transport,
    vault: vault,
    arbiter: arbiter,
    output: output,
    monotonicNow: { clock.now }
  )
  let coordinator = ScrobbleCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  playback.attach(session: session)
  playback.onLifecycleEvent = { event in
    coordinator.handle(event, session: session)
  }
  session.onPrepareIdentityMutation = {
    playback.stopForSessionChange()
    await coordinator.settle()
  }
  session.onIdentityChanged = {
    playback.stopForSessionChange()
    coordinator.reset()
  }

  await transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  playback.play(
    tracks: makeTracks([101]),
    startIndex: 0,
    context: .playlist(id: 77, name: "list"),
    session: session
  )
  await playback.settleForTesting()
  await coordinator.settle()
  clock.advance(7)

  #expect(await session.clearSession() == .signedOut)
  #expect(await vault.storedForTesting() == nil)
  let feedbackCalls = await transport.recordedCalls().filter { call in
    switch call {
    case .scrobbleStart, .scrobbleFinish: true
    default: false
    }
  }
  #expect(feedbackCalls == [
    .scrobbleStart(101, ScrobbleContext(sourceID: 77)),
    .scrobbleFinish(101, ScrobbleContext(sourceID: 77), 7),
  ])
  #expect(arbiter.active == nil)
}

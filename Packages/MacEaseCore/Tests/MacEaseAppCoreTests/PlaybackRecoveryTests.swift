import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

/// P0-05: every failure that a second explicit request could fix keeps a Play
/// Again entry point, and every failure that it could not fix removes one.
/// Play Again re-resolves; it never reuses the URL that failed.

@MainActor
private struct PlaybackRig {
  let transport = FakeTransport()
  let vault: FakeVault
  let arbiter: OperationArbiter
  let output = FakeAudioOutput()
  let session: FakeSession
  let playback: PlaybackController

  init(
    arbiter: OperationArbiter = OperationArbiter(),
    admissionTimeout: Duration = .seconds(30)
  ) {
    let credential = makeCredential()
    self.arbiter = arbiter
    vault = FakeVault(stored: credential)
    session = FakeSession(credential: credential)
    playback = PlaybackController(
      transport: transport,
      vault: vault,
      arbiter: arbiter,
      output: output,
      admissionTimeout: admissionTimeout
    )
    playback.attach(session: session)
  }

  func play(_ ids: [Int64] = [101], startIndex: Int = 0) async {
    playback.play(
      tracks: makeTracks(ids), startIndex: startIndex, context: .dailyRecommendations,
      session: session)
    await playback.settleForTesting()
  }

  func playAgain() async {
    playback.playAgain(session: session)
    await playback.settleForTesting()
  }
}

@Test @MainActor func naturalContinuationWaitsForReadsOrSameAccountRenewal() async throws {
  for effect in [OperationEffect.read, .sessionMutation] {
    let rig = PlaybackRig(arbiter: OperationArbiter(maximumConcurrentReads: 1))
    var events: [PlaybackLifecycleEvent] = []
    rig.playback.onLifecycleEvent = { events.append($0) }
    await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
    await rig.play([101, 102])
    let oldEnd = rig.output.onPlayedToEnd
    let blocker = try #require(rig.arbiter.begin(name: "Busy", effect: effect))

    oldEnd?()
    #expect(rig.playback.phase == .resolving)
    #expect(rig.playback.currentTrack?.id == 102)
    #expect(rig.playback.attempt?.resumePosition == 0)
    // A late duplicate completion still belongs to the ended item.
    oldEnd?()
    if effect == .sessionMutation {
      let renewed = makeCredential("renewed")
      await rig.vault.setStored(renewed)
      rig.session.validatedCredential = renewed
    }
    await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 102)))
    rig.arbiter.end(blocker, outcome: .applied)
    await rig.playback.settleForTesting()

    #expect(rig.playback.phase == .playing)
    #expect(rig.playback.currentTrack?.id == 102)
    #expect(events.count == 3)
    #expect(await rig.transport.recordedCalls() == [
      .resolveSongURL(101, .standard), .resolveSongURL(102, .standard)
    ])
    #expect(rig.arbiter.activeReadCount == 0)
  }
}

@Test @MainActor func pendingContinuationIsCancelledByStopNewIntentOrAccountChange() async throws {
  for replacement in 0..<3 {
    let rig = PlaybackRig(arbiter: OperationArbiter(maximumConcurrentReads: 1))
    await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
    await rig.play([101, 102])
    let blocker = try #require(rig.arbiter.begin(name: "Busy", effect: .read))
    rig.output.reportPlayedToEnd()
    let pending = rig.playback.playTask
    switch replacement {
    case 0: rig.playback.stop()
    case 1:
      #expect(!rig.playback.play(
        tracks: makeTracks([201]), startIndex: 0, context: .dailyRecommendations,
        session: rig.session))
    default:
      rig.session.account = nil
      rig.playback.stopForSessionChange()
    }
    rig.arbiter.end(blocker, outcome: .applied)
    await pending?.value
    #expect(await rig.transport.recordedCalls() == [.resolveSongURL(101, .standard)])
    #expect(rig.playback.phase != .resolving)
    #expect(rig.arbiter.activeReadCount == 0)
  }
}

@Test @MainActor func continuationDeadlineRetainsTheNextTrackForExplicitRetry() async throws {
  let rig = PlaybackRig(
    arbiter: OperationArbiter(maximumConcurrentReads: 1), admissionTimeout: .milliseconds(10))
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  await rig.play([101, 102])
  let blocker = try #require(rig.arbiter.begin(name: "Busy", effect: .read))
  rig.output.reportPlayedToEnd()
  await rig.playback.settleForTesting()
  #expect(rig.playback.phase == .failed)
  #expect(rig.playback.canPlayAgain)
  #expect(rig.playback.attempt?.songID == 102)
  rig.arbiter.end(blocker, outcome: .applied)
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 102)))
  await rig.playAgain()
  #expect(rig.playback.phase == .playing)
  #expect(rig.playback.currentTrack?.id == 102)
}

@Test @MainActor func aFullReadCeilingDoesNotReplaceCurrentRemotePlayback() async throws {
  let arbiter = OperationArbiter(maximumConcurrentReads: 1)
  let rig = PlaybackRig(arbiter: arbiter)
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  await rig.play([101, 102])
  let loadedURL = rig.output.loadedURL
  let teardownCount = rig.output.teardownCount
  let blocker = try #require(
    arbiter.begin(name: "Playlist", effect: .read)
  )

  await rig.play([202, 203])

  #expect(rig.playback.phase == .playing)
  #expect(rig.playback.currentTrack?.id == 101)
  #expect(rig.playback.queuePosition == "1 of 2")
  #expect(rig.output.loadedURL == loadedURL)
  #expect(rig.output.teardownCount == teardownCount)
  #expect(await rig.transport.recordedCalls() == [.resolveSongURL(101, .standard)])
  #expect(rig.playback.status == "Playback is busy; try again")
  #expect(arbiter.end(blocker, outcome: .applied) == .applied)
}

@Test @MainActor func playAgainAtTheReadCeilingStaysRetryable() async throws {
  let arbiter = OperationArbiter(maximumConcurrentReads: 1)
  let rig = PlaybackRig(arbiter: arbiter)
  await rig.transport.setSongURL(.failure(URLError(.timedOut)))
  await rig.play()
  #expect(rig.playback.phase == .failed)
  let blocker = try #require(
    arbiter.begin(name: "Playlist", effect: .read)
  )

  await rig.playAgain()

  #expect(rig.playback.phase == .failed)
  #expect(rig.playback.canPlayAgain)
  #expect(await rig.transport.callCount() == 1)
  #expect(rig.playback.status == "Playback is busy; try again")

  #expect(arbiter.end(blocker, outcome: .applied) == .applied)
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  await rig.playAgain()
  #expect(rig.playback.phase == .playing)
  #expect(await rig.transport.callCount() == 2)
}

@Test @MainActor func nextAtTheReadCeilingKeepsTheCurrentQueueEntryPlaying() async throws {
  let arbiter = OperationArbiter(maximumConcurrentReads: 1)
  let rig = PlaybackRig(arbiter: arbiter)
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  await rig.play([101, 102])
  let loadedURL = rig.output.loadedURL
  let blocker = try #require(
    arbiter.begin(name: "Library", effect: .read)
  )

  #expect(!rig.playback.playNext(session: rig.session))

  #expect(rig.playback.phase == .playing)
  #expect(rig.playback.currentTrack?.id == 101)
  #expect(rig.playback.queuePosition == "1 of 2")
  #expect(rig.output.loadedURL == loadedURL)
  #expect(await rig.transport.recordedCalls() == [.resolveSongURL(101, .standard)])
  #expect(arbiter.end(blocker, outcome: .applied) == .applied)
}

@Test @MainActor func nextWhileResolvingHandsTheSlotToTheReplacementUnderReadPressure()
  async throws
{
  let arbiter = OperationArbiter(maximumConcurrentReads: 1)
  let rig = PlaybackRig(arbiter: arbiter)
  let gate = RequestGate()
  await gate.close()
  await rig.transport.setGate(gate, for: .resolveSongURL(101, .standard))
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  rig.playback.play(
    tracks: makeTracks([101, 102]), startIndex: 0, context: .dailyRecommendations,
    session: rig.session)
  while await gate.arrivalCount() < 1 { await Task.yield() }
  #expect(rig.playback.phase == .resolving)
  // Two reads queue behind the ceiling that the resolve alone fills. Giving the
  // slot back before claiming again would admit one of them and refuse Next.
  let queued = (0..<2).map { index in
    Task { await arbiter.beginWhenAvailable(name: "Discover \(index)", effect: .read) }
  }
  for _ in 0..<10 { await Task.yield() }

  #expect(rig.playback.canPlayNext(session: rig.session))
  #expect(rig.playback.playNext(session: rig.session))
  #expect(rig.playback.phase == .resolving)
  #expect(rig.playback.currentTrack?.id == 102)
  #expect(rig.playback.playTask != nil)
  #expect(arbiter.activeReadCount == 1)

  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 102)))
  await gate.open()
  await rig.playback.settleForTesting()
  #expect(rig.playback.phase == .playing)
  #expect(rig.playback.currentTrack?.id == 102)
  for task in queued {
    if let token = await task.value { arbiter.end(token, outcome: .applied) }
  }
  #expect(arbiter.activeReadCount == 0)
}

// MARK: - Recoverable failures keep the entry point

@Test @MainActor func aResolveThatFailedKeepsPlayAgain() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(.failure(URLError(.timedOut)))

  await rig.play()

  #expect(rig.playback.phase == .failed)
  #expect(rig.playback.canPlayAgain)
  #expect(await rig.transport.callCount() == 1)
}

@Test @MainActor func anHTTPFailureOnTheResolveKeepsPlayAgain() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(
    .failure(NeteaseServiceError(source: .http, statusCode: 503))
  )

  await rig.play()

  #expect(rig.playback.canPlayAgain)
}

/// The Gate C case: the URL resolved but the asset would not load, most often
/// because it had already expired.
@Test @MainActor func anAssetThatWillNotLoadKeepsPlayAgain() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  rig.output.prepareResult = .failure(AudioOutputFailure.assetLoad("NSURLErrorDomain -1001"))

  await rig.play()

  #expect(rig.playback.phase == .failed)
  #expect(rig.playback.canPlayAgain)
}

@Test @MainActor func playbackPassesAccountAndResolvedMetadataToAudioOutput() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))

  await rig.play()

  let resource = rig.output.preparedResources.last
  #expect(resource?.accountID == testAccount.userID)
  #expect(resource?.songID == 101)
  #expect(resource?.requestedQuality == .standard)
  #expect(resource?.actualQuality == "standard")
  #expect(resource?.format == "mp3")
  #expect(resource?.byteCount == 3_000_000)
  #expect(resource?.expiresAt != nil)
}

@Test @MainActor func anAssetReportedUnplayableExhaustsTheOnlySelectedQuality() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  rig.output.prepareResult = .success(
    AudioAssetInfo(isPlayable: false, durationSeconds: nil)
  )

  await rig.play()

  #expect(rig.playback.phase == .failed)
  #expect(!rig.playback.canPlayAgain)
  #expect(rig.output.teardownCount > 0)
}

@Test @MainActor func aFailureAfterPlaybackBeganKeepsTheCurrentPosition() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))

  await rig.play()
  #expect(rig.playback.phase == .playing)

  rig.output.reportPosition(42.5)
  rig.output.reportFailure("NSURLErrorDomain -1005")

  #expect(rig.playback.phase == .failed)
  #expect(rig.playback.canPlayAgain)
  #expect(rig.playback.retryResumesPlayback)

  await rig.transport.setSongURL(
    .success(makeResolvedAsset(songID: 101, urlString: "https://m8.music.126.net/new.mp3"))
  )
  await rig.playAgain()

  #expect(rig.playback.phase == .playing)
  #expect(rig.output.seeks.contains(42.5))
  #expect(rig.output.preparedURLs.map(\.absoluteString).last == "https://m8.music.126.net/new.mp3")
}

/// A NaN or infinite position from an item that never became ready must not
/// reach the retry.
@Test @MainActor func anUnusablePositionIsNormalisedToZero() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  await rig.play()

  rig.output.currentPositionSeconds = .nan
  rig.output.reportFailure("bad clock")

  #expect(rig.playback.canPlayAgain)
  await rig.playAgain()
  #expect(!rig.output.seeks.contains { !$0.isFinite })
}

@Test @MainActor func aFailureWhilePausedRestoresPausedNotPlaying() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  await rig.play()

  rig.output.reportPosition(10)
  rig.playback.pause()
  #expect(rig.playback.phase == .paused)
  rig.output.reportFailure("NSURLErrorDomain -1009")

  #expect(rig.playback.canPlayAgain)
  #expect(!rig.playback.retryResumesPlayback)

  await rig.playAgain()

  #expect(rig.playback.phase == .paused)
  #expect(!rig.output.isPlaying)
  #expect(rig.output.seeks.contains(10))
}

// MARK: - Terminal failures remove the entry point

@Test @MainActor func anUnavailableTrackHasNoPlayAgain() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(.success(.unavailable(itemCode: 404, fee: 1)))

  await rig.play()

  #expect(rig.playback.phase == .failed)
  #expect(!rig.playback.canPlayAgain)
}

@Test @MainActor func anUnapprovedHostHasNoPlayAgain() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(
    .failure(NeteasePlaybackError.unapprovedHost("cdn.example.com"))
  )

  await rig.play()

  #expect(!rig.playback.canPlayAgain)
}

@Test @MainActor func aNonHTTPSHostHasNoPlayAgain() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(
    .failure(NeteasePlaybackError.nonHTTPSURL("music.163.com"))
  )

  await rig.play()

  #expect(!rig.playback.canPlayAgain)
}

@Test @MainActor func serviceThreeOhOneAbandonsPlaybackWithNoPlayAgain() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(
    .failure(NeteaseServiceError(source: .service, statusCode: 301))
  )

  await rig.play()

  #expect(!rig.playback.canPlayAgain)
  #expect(rig.playback.phase == .idle)
  #expect(rig.session.invalidations.count == 1)
}

@Test func theClassifierOnlyAllowsKnownTransientFailures() {
  #expect(
    PlaybackFailureClassifier.kind(
      for: NeteaseServiceError(source: .service, statusCode: 301)
    ) == .terminal
  )
  #expect(
    PlaybackFailureClassifier.kind(for: NeteasePlaybackError.unapprovedHost("h"))
      == .terminal
  )
  #expect(
    PlaybackFailureClassifier.kind(for: NeteasePlaybackError.nonHTTPSURL("h"))
      == .terminal
  )
  // Everything transient stays retryable.
  #expect(PlaybackFailureClassifier.kind(for: URLError(.timedOut)) == .recoverable)
  #expect(
    PlaybackFailureClassifier.kind(
      for: NeteaseServiceError(source: .http, statusCode: 500)
    ) == .recoverable
  )
  #expect(
    PlaybackFailureClassifier.kind(
      for: NeteaseServiceError(source: .service, statusCode: 400)
    ) == .terminal
  )
  #expect(
    PlaybackFailureClassifier.kind(for: CredentialVaultError.keychain(-25300))
      == .terminal
  )
  #expect(
    PlaybackFailureClassifier.kind(for: NeteasePlaybackError.invalidResponse)
      == .terminal
  )
  #expect(
    PlaybackFailureClassifier.kind(for: FakeAudioOutput.LoadFailure(reason: "unknown"))
      == .terminal
  )
  #expect(
    PlaybackFailureClassifier.kind(for: URLError(.cancelled)) == .terminal
  )
  #expect(
    PlaybackFailureClassifier.kind(for: AudioOutputFailure.assetLoad("timeout"))
      == .recoverable
  )
  #expect(
    PlaybackFailureClassifier.kind(for: AudioOutputFailure.itemPlayback("stalled"))
      == .recoverable
  )
}

@Test @MainActor func keychainFailureHasNoPlayAgain() async {
  let rig = PlaybackRig()
  await rig.vault.setLoadError(CredentialVaultError.keychain(-25300))

  await rig.play()

  #expect(rig.playback.phase == .failed)
  #expect(!rig.playback.canPlayAgain)
}

@Test @MainActor func unknownServiceFailureHasNoPlayAgain() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(
    .failure(NeteaseServiceError(source: .service, statusCode: 400))
  )

  await rig.play()

  #expect(rig.playback.phase == .failed)
  #expect(!rig.playback.canPlayAgain)
}

// MARK: - The entry point is retired by newer intents

@Test @MainActor func stopRetiresTheRetryEntryPoint() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(.failure(URLError(.timedOut)))
  await rig.play()
  #expect(rig.playback.canPlayAgain)

  rig.playback.stop()

  #expect(!rig.playback.canPlayAgain)
  #expect(rig.playback.phase == .idle)
}

@Test @MainActor func startingAnotherTrackRetiresTheOldRetry() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(.failure(URLError(.timedOut)))
  await rig.play([101, 202], startIndex: 0)
  #expect(rig.playback.canPlayAgain)

  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 202)))
  rig.playback.playNext(session: rig.session)
  await rig.playback.settleForTesting()

  #expect(rig.playback.phase == .playing)
  #expect(await rig.transport.recordedCalls().last == .resolveSongURL(202, .standard))
}

@Test @MainActor func aNaturalQueueEndRetiresTheRetry() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  await rig.play()

  rig.output.reportPlayedToEnd()

  #expect(rig.playback.phase == .finished)
  #expect(!rig.playback.canPlayAgain)
}

/// A late callback from an abandoned item must not resurrect the button.
@Test @MainActor func aLateFailureCallbackAfterStopChangesNothing() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  await rig.play()

  let staleFailure = rig.output.onFailure
  rig.playback.stop()
  staleFailure?(.itemPlayback("NSURLErrorDomain -1005"))

  #expect(rig.playback.phase == .idle)
  #expect(!rig.playback.canPlayAgain)
}

/// This models a callback that AVPlayer queued before teardown but delivered
/// after a replacement item installed new controller handlers.
@Test @MainActor func aQueuedCallbackFromTheOldItemCannotFailTheNewItem() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  await rig.play([101, 202])
  let staleFailure = rig.output.queuedFailure(.itemPlayback("old item"))

  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 202)))
  rig.playback.playNext(session: rig.session)
  await rig.playback.settleForTesting()
  staleFailure()

  #expect(rig.playback.phase == .playing)
  #expect(rig.playback.currentTrack?.id == 202)
  #expect(!rig.playback.canPlayAgain)
}

/// A cancelled prepare may complete after a newer prepare. It must not install
/// or play its old URL over the replacement item.
@Test @MainActor func aBlockedOldPrepareCannotReplaceTheNewPlayer() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(
    .success(makeResolvedAsset(songID: 101, urlString: "https://m8.music.126.net/old.mp3"))
  )
  rig.output.blockNextPrepare()
  rig.playback.play(
    tracks: makeTracks([101]), startIndex: 0, context: .dailyRecommendations, session: rig.session)
  while !rig.output.prepareIsBlocked { await Task.yield() }

  await rig.transport.setSongURL(
    .success(makeResolvedAsset(songID: 202, urlString: "https://m8.music.126.net/new.mp3"))
  )
  rig.playback.play(
    tracks: makeTracks([202]), startIndex: 0, context: .dailyRecommendations, session: rig.session)
  await rig.playback.settleForTesting()
  rig.output.resumeBlockedPrepare()
  await Task.yield()

  #expect(rig.playback.phase == .playing)
  #expect(rig.playback.currentTrack?.id == 202)
  #expect(rig.output.loadedURL?.absoluteString == "https://m8.music.126.net/new.mp3")
}

// MARK: - Play Again sends exactly one request and keeps its place

@Test @MainActor func playAgainSendsExactlyOneRequestAndKeepsTheQueueIndex() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(.failure(URLError(.timedOut)))
  await rig.play([101, 202, 303], startIndex: 1)
  #expect(rig.playback.canPlayAgain)
  #expect(await rig.transport.callCount() == 1)

  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 202)))
  await rig.playAgain()

  #expect(await rig.transport.callCount() == 2)
  #expect(await rig.transport.recordedCalls().last == .resolveSongURL(202, .standard))
  #expect(rig.playback.queue?.currentIndex == 1)
  #expect(rig.playback.queuePosition == "2 of 3")
  #expect(rig.playback.phase == .playing)
}

@Test @MainActor func playAgainKeepsTheQualityTheAttemptWasMadeWith() async {
  let rig = PlaybackRig()
  rig.playback.quality = .lossless
  await rig.transport.setSongURL(.failure(URLError(.timedOut)))
  await rig.play()

  // Changing the picker afterwards must not silently change the retry.
  rig.playback.quality = .hires
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  await rig.playAgain()

  #expect(await rig.transport.recordedCalls().last == .resolveSongURL(101, .lossless))
}

@Test @MainActor func playAgainCanRunAlongsideAnIndependentRead() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(.failure(URLError(.timedOut)))
  await rig.play()

  let blocker = rig.arbiter.begin(name: "Playlist", effect: .read)!
  rig.playback.playAgain(session: rig.session)
  await rig.playback.settleForTesting()

  #expect(await rig.transport.callCount() == 2)
  #expect(rig.playback.phase == .failed)
  #expect(rig.arbiter.end(blocker, outcome: .applied) == .applied)
}

// MARK: - P4 bounded automatic recovery

@Test @MainActor func unavailableQualitiesDescendWithoutChangingThePreference() async {
  let rig = PlaybackRig()
  rig.playback.quality = .hires
  await rig.transport.setSongURLs([
    .success(.unavailable(itemCode: 404, fee: 1)),
    .success(.unavailable(itemCode: 404, fee: 1)),
    .success(.unavailable(itemCode: 404, fee: 1)),
    .success(.unavailable(itemCode: 404, fee: 1)),
    .success(makeResolvedAsset(songID: 101, requestedQuality: .standard)),
  ])

  await rig.play()

  #expect(
    await rig.transport.recordedCalls() == [
      .resolveSongURL(101, .hires),
      .resolveSongURL(101, .lossless),
      .resolveSongURL(101, .exhigh),
      .resolveSongURL(101, .higher),
      .resolveSongURL(101, .standard),
    ])
  #expect(rig.playback.quality == .hires)
  #expect(rig.playback.phase == .playing)
  #expect(rig.playback.status.contains("requested Hi-Res"))
  #expect(rig.playback.status.contains("Standard"))
  #expect(rig.arbiter.activeReadCount == 0)
}

@Test @MainActor func confirmedHTTPFailureReResolvesOnceThenFallsBack() async {
  let rig = PlaybackRig()
  rig.playback.quality = .lossless
  await rig.transport.setSongURLs([
    .success(makeResolvedAsset(songID: 101, requestedQuality: .lossless)),
    .success(makeResolvedAsset(songID: 101, requestedQuality: .lossless)),
    .success(makeResolvedAsset(songID: 101, requestedQuality: .exhigh)),
  ])
  rig.output.prepareResults = [
    .failure(AudioOutputFailure.resourceUnavailable(statusCode: 403)),
    .failure(AudioOutputFailure.resourceUnavailable(statusCode: 404)),
    .success(AudioAssetInfo(isPlayable: true, durationSeconds: 200)),
  ]

  await rig.play()

  #expect(
    await rig.transport.recordedCalls() == [
      .resolveSongURL(101, .lossless),
      .resolveSongURL(101, .lossless),
      .resolveSongURL(101, .exhigh),
    ])
  #expect(rig.playback.phase == .playing)
  #expect(rig.playback.quality == .lossless)
}

@Test @MainActor func ordinaryAssetNetworkFailureNeverDowngradesOrSkips() async {
  let rig = PlaybackRig()
  rig.playback.quality = .hires
  await rig.transport.setSongURL(
    .success(makeResolvedAsset(songID: 101, requestedQuality: .hires))
  )
  rig.output.prepareResult = .failure(AudioOutputFailure.assetLoad("NSURLErrorDomain -1009"))

  await rig.play([101, 202])

  #expect(await rig.transport.recordedCalls() == [.resolveSongURL(101, .hires)])
  #expect(rig.playback.currentTrack?.id == 101)
  #expect(rig.playback.phase == .failed)
  #expect(rig.playback.canPlayAgain)
}

@Test @MainActor func allQualitiesMustFailBeforeTheNextEntryIsVisited() async {
  let rig = PlaybackRig()
  rig.playback.quality = .higher
  await rig.transport.setSongURLs([
    .success(.unavailable(itemCode: 404, fee: nil)),
    .success(.unavailable(itemCode: 404, fee: nil)),
    .success(makeResolvedAsset(songID: 202, requestedQuality: .higher)),
  ])

  await rig.play([101, 202])

  #expect(
    await rig.transport.recordedCalls() == [
      .resolveSongURL(101, .higher),
      .resolveSongURL(101, .standard),
      .resolveSongURL(202, .higher),
    ])
  #expect(rig.playback.currentTrack?.id == 202)
  #expect(rig.playback.status.contains("Skipped 1"))
}

@Test @MainActor func repeatOneAndRepeatAllRecoveryCannotLoop() async {
  let repeatOne = PlaybackRig()
  repeatOne.playback.playbackMode = .repeatOne
  repeatOne.playback.quality = .standard
  await repeatOne.transport.setSongURL(
    .success(.unavailable(itemCode: 404, fee: nil))
  )
  await repeatOne.play([101])
  #expect(
    await repeatOne.transport.recordedCalls() == [
      .resolveSongURL(101, .standard)
    ])
  #expect(repeatOne.playback.phase == .failed)

  let repeatAll = PlaybackRig()
  repeatAll.playback.playbackMode = .repeatAll
  repeatAll.playback.quality = .standard
  await repeatAll.transport.setSongURLs([
    .success(.unavailable(itemCode: 404, fee: nil)),
    .success(.unavailable(itemCode: 404, fee: nil)),
  ])
  await repeatAll.play([101, 202])
  #expect(
    await repeatAll.transport.recordedCalls() == [
      .resolveSongURL(101, .standard),
      .resolveSongURL(202, .standard),
    ])
  #expect(repeatAll.playback.phase == .failed)
  #expect(repeatAll.arbiter.activeReadCount == 0)
}

@Test @MainActor func shuffleRecoveryVisitsEveryEntryAtMostOnce() async {
  let rig = PlaybackRig()
  rig.playback.playbackMode = .shuffle
  rig.playback.quality = .standard
  await rig.transport.setSongURL(
    .success(.unavailable(itemCode: 404, fee: nil))
  )

  await rig.play([101, 202, 303])

  let calls = await rig.transport.recordedCalls()
  #expect(calls.count == 3)
  let ids = calls.compactMap { call -> Int64? in
    guard case .resolveSongURL(let id, .standard) = call else { return nil }
    return id
  }
  #expect(Set(ids) == [101, 202, 303])
  #expect(rig.playback.phase == .failed)
}

@Test @MainActor func continuationCannotExtendAnAcceptedRecoveryChain() async {
  let rig = PlaybackRig()
  rig.playback.quality = .standard
  await rig.transport.setSongURL(
    .success(.unavailable(itemCode: 404, fee: nil))
  )
  await rig.transport.gate.close()

  rig.playback.play(
    tracks: makeTracks([101]),
    startIndex: 0,
    context: .personalFM,
    session: rig.session
  )
  while await rig.transport.gate.arrivalCount() == 0 { await Task.yield() }
  #expect(
    rig.playback.extendQueue(
      with: makeTracks([202]),
      context: .personalFM
    ) == 1
  )
  await rig.transport.gate.open()
  await rig.playback.settleForTesting()

  #expect(
    await rig.transport.recordedCalls() == [
      .resolveSongURL(101, .standard)
    ])
  #expect(rig.playback.queuedTracks(context: .personalFM).map(\.id) == [101, 202])
  #expect(rig.playback.currentTrack?.id == 101)
  #expect(rig.playback.phase == .failed)
}

@Test @MainActor func playNextCannotExtendAnAcceptedRecoveryChain() async throws {
  let rig = PlaybackRig()
  rig.playback.quality = .standard
  await rig.transport.setSongURL(
    .success(.unavailable(itemCode: 404, fee: nil))
  )
  await rig.transport.gate.close()
  rig.playback.play(
    tracks: makeTracks([101]),
    startIndex: 0,
    context: .dailyRecommendations,
    session: rig.session
  )
  while await rig.transport.gate.arrivalCount() == 0 { await Task.yield() }
  let snapshot = try #require(rig.playback.queueSnapshot)

  #expect(
    rig.playback.queueNext(
      makeTracks([202])[0],
      context: .dailyRecommendations,
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )
  await rig.transport.gate.open()
  await rig.playback.settleForTesting()

  #expect(
    await rig.transport.recordedCalls() == [
      .resolveSongURL(101, .standard)
    ])
  #expect(rig.playback.persistedQueue()?.tracks.map(\.id) == [101, 202])
  #expect(rig.playback.currentTrack?.id == 101)
  #expect(rig.playback.phase == .failed)
}

@Test @MainActor func runtimeExpiredURLRecoversWithoutASecondLifecycleStart() async {
  let clock = LifecycleClockForRecovery()
  let transport = FakeTransport()
  let credential = makeCredential()
  let vault = FakeVault(stored: credential)
  let session = FakeSession(credential: credential)
  let output = FakeAudioOutput()
  let playback = PlaybackController(
    transport: transport,
    vault: vault,
    arbiter: OperationArbiter(),
    output: output,
    monotonicNow: { clock.now }
  )
  playback.attach(session: session)
  var events: [PlaybackLifecycleEvent] = []
  playback.onLifecycleEvent = { events.append($0) }
  await transport.setSongURLs([
    .success(makeResolvedAsset(songID: 101)),
    .success(makeResolvedAsset(songID: 101)),
  ])

  playback.play(
    tracks: makeTracks([101]),
    startIndex: 0,
    context: .dailyRecommendations,
    session: session
  )
  await playback.settleForTesting()
  clock.now += 5
  output.reportFailure(.resourceUnavailable(statusCode: 403))
  await playback.settleForTesting()
  clock.now += 4
  playback.stop()

  #expect(
    await transport.recordedCalls() == [
      .resolveSongURL(101, .standard),
      .resolveSongURL(101, .standard),
    ])
  #expect(events.compactMap { if case .started = $0 { 1 } else { nil } }.count == 1)
  guard case .finished(_, let seconds, _) = events.last else {
    Issue.record("Expected one final lifecycle settlement")
    return
  }
  #expect(seconds == 9)
}

@MainActor
private final class LifecycleClockForRecovery {
  var now: TimeInterval = 1_000
}

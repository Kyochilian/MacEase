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

  func play(_ ids: [Int64] = [101], startIndex: Int = 0) async {
    playback.play(tracks: makeTracks(ids), startIndex: startIndex, session: session)
    await playback.settleForTesting()
  }

  func playAgain() async {
    playback.playAgain(session: session)
    await playback.settleForTesting()
  }
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

@Test @MainActor func anAssetReportedUnplayableKeepsPlayAgain() async {
  let rig = PlaybackRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 101)))
  rig.output.prepareResult = .success(
    AudioAssetInfo(isPlayable: false, durationSeconds: nil)
  )

  await rig.play()

  #expect(rig.playback.phase == .failed)
  #expect(rig.playback.canPlayAgain)
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
  rig.playback.play(tracks: makeTracks([101]), startIndex: 0, session: rig.session)
  while !rig.output.prepareIsBlocked { await Task.yield() }

  await rig.transport.setSongURL(
    .success(makeResolvedAsset(songID: 202, urlString: "https://m8.music.126.net/new.mp3"))
  )
  rig.playback.play(tracks: makeTracks([202]), startIndex: 0, session: rig.session)
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

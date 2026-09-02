import Testing

@testable import NeteaseKit

@Test func playbackExpiryPolicyAddsMarginToReportedTTL() {
  #expect(PlaybackExpiryPolicy.waitSeconds(expiresIn: 1200) == 1260)
  #expect(PlaybackExpiryPolicy.waitSeconds(expiresIn: 1) == 61)
  #expect(PlaybackExpiryPolicy.waitSeconds(expiresIn: 7200) == 7260)
}

@Test func playbackExpiryPolicyRejectsMissingOrOutOfRangeTTL() {
  #expect(PlaybackExpiryPolicy.waitSeconds(expiresIn: nil) == nil)
  #expect(PlaybackExpiryPolicy.waitSeconds(expiresIn: 0) == nil)
  #expect(PlaybackExpiryPolicy.waitSeconds(expiresIn: -1200) == nil)
  #expect(PlaybackExpiryPolicy.waitSeconds(expiresIn: 7201) == nil)
}

@Test func playbackExpiryPolicyRequiresAnInvalidURLStatus() {
  #expect(PlaybackExpiryPolicy.confirmsInvalidURL(statusCode: 403))
  #expect(PlaybackExpiryPolicy.confirmsInvalidURL(statusCode: 404))
  #expect(!PlaybackExpiryPolicy.confirmsInvalidURL(statusCode: 302))
  #expect(!PlaybackExpiryPolicy.confirmsInvalidURL(statusCode: 500))
}

@Test func everySelectedQualityHasTheExactDownwardFallbackSequence() {
  #expect(PlaybackQuality.hires.fallbackSequence == [
    .hires, .lossless, .exhigh, .higher, .standard,
  ])
  #expect(PlaybackQuality.lossless.fallbackSequence == [
    .lossless, .exhigh, .higher, .standard,
  ])
  #expect(PlaybackQuality.exhigh.fallbackSequence == [.exhigh, .higher, .standard])
  #expect(PlaybackQuality.higher.fallbackSequence == [.higher, .standard])
  #expect(PlaybackQuality.standard.fallbackSequence == [.standard])
}

@Test func playbackRecoverySnapshotClampsNegativePosition() {
  let snapshot = PlaybackRecoverySnapshot(
    songID: 347230,
    quality: .higher,
    position: -4,
    shouldResume: true
  )

  #expect(snapshot.position == 0)
  #expect(snapshot.songID == 347230)
  #expect(snapshot.quality == .higher)
  #expect(snapshot.shouldResume)
}

@Test func playbackRecoverySnapshotClampsNonFinitePosition() {
  let nan = PlaybackRecoverySnapshot(
    songID: 347230,
    quality: .standard,
    position: .nan,
    shouldResume: true
  )
  let positiveInfinity = PlaybackRecoverySnapshot(
    songID: 347230,
    quality: .standard,
    position: .infinity,
    shouldResume: true
  )
  let negativeInfinity = PlaybackRecoverySnapshot(
    songID: 347230,
    quality: .standard,
    position: -.infinity,
    shouldResume: true
  )

  #expect(nan.position == 0)
  #expect(positiveInfinity.position == 0)
  #expect(negativeInfinity.position == 0)
  #expect(nan == nan)
}

@Test func playbackRecoverySnapshotPreservesResumeIntentAndPosition() {
  let snapshot = PlaybackRecoverySnapshot(
    songID: 347230,
    quality: .lossless,
    position: 42.5,
    shouldResume: false
  )

  #expect(
    snapshot
      == PlaybackRecoverySnapshot(
        songID: 347230,
        quality: .lossless,
        position: 42.5,
        shouldResume: false
      )
  )
}

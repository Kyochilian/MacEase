import Testing

@testable import NeteaseKit

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

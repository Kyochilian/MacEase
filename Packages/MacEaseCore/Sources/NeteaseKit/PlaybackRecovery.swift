import Foundation

/// The minimum state needed to rebuild a short-lived playback asset.
package struct PlaybackRecoverySnapshot: Equatable, Sendable {
  package let songID: Int64
  package let quality: PlaybackQuality
  package let position: Double
  package let shouldResume: Bool

  package init(
    songID: Int64,
    quality: PlaybackQuality,
    position: Double,
    shouldResume: Bool
  ) {
    self.songID = songID
    self.quality = quality
    self.position = max(0, position)
    self.shouldResume = shouldResume
  }
}

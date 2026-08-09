import Foundation

/// Bounds a controlled URL-expiry wait derived from the server-reported TTL.
package enum PlaybackExpiryPolicy {
  package static let marginSeconds = 60
  package static let maximumExpirySeconds = 7200

  /// Seconds to wait before probing the stale URL, or nil when the reported
  /// TTL cannot support a bounded controlled wait.
  package static func waitSeconds(expiresIn: Int?) -> Int? {
    guard let expiresIn, (1...maximumExpirySeconds).contains(expiresIn) else {
      return nil
    }
    return expiresIn + marginSeconds
  }

  package static func confirmsInvalidURL(statusCode: Int) -> Bool {
    statusCode == 403 || statusCode == 404
  }
}

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

import Foundation
import NeteaseKit

/// Whether a retry should leave the track playing or paused, so a failure
/// that happened while paused does not silently start playback.
package enum DesiredPlaybackState: Equatable, Sendable {
  case playing
  case paused
}

/// Everything needed to make one more explicit attempt at a track.
///
/// It is created *before* the resolve request goes out. The previous model
/// built its recovery state only after `AVURLAsset.load` had already
/// succeeded, so the two most common failures — a resolve that timed out and
/// an asset load that failed on an expired URL — reached `.failed` with no
/// Play Again entry point at all. That is exactly the case Gate C cares
/// about.
///
/// It deliberately carries no URL: recovery re-resolves, it never reuses a
/// stale one.
package struct PlaybackAttempt: Equatable, Sendable {
  package let songID: Int64
  package let quality: PlaybackQuality
  package let queueIndex: Int
  package var resumePosition: Double
  package var desiredState: DesiredPlaybackState

  package init(
    songID: Int64,
    quality: PlaybackQuality,
    queueIndex: Int,
    resumePosition: Double = 0,
    desiredState: DesiredPlaybackState = .playing
  ) {
    self.songID = songID
    self.quality = quality
    self.queueIndex = queueIndex
    self.resumePosition = Self.sanitized(resumePosition)
    self.desiredState = desiredState
  }

  /// Positions come from AVPlayer, which reports NaN and infinity for an item
  /// that never became ready.
  package static func sanitized(_ position: Double) -> Double {
    guard position.isFinite, position > 0 else { return 0 }
    return position
  }

  package func checkpointed(
    at position: Double,
    desiredState: DesiredPlaybackState
  ) -> PlaybackAttempt {
    PlaybackAttempt(
      songID: songID,
      quality: quality,
      queueIndex: queueIndex,
      resumePosition: position,
      desiredState: desiredState
    )
  }
}

/// Whether a failure leaves anything worth retrying.
package enum PlaybackFailureKind: Equatable, Sendable {
  /// Re-resolving the URL may work: the request, the network or the asset
  /// load failed for a reason that is not about this account's rights.
  case recoverable
  /// The answer would be the same next time, so no retry is offered.
  case terminal
}

package enum PlaybackFailureClassifier {
  /// The rules the review fixes in place. Anything not named here is treated
  /// as recoverable, because the cost of one more explicit user-initiated
  /// request is low and silently losing the entry point is not.
  package static func kind(for error: any Error) -> PlaybackFailureKind {
    switch error {
    case let error as NeteaseServiceError
    where error.source == .service && error.statusCode == 301:
      // The session is gone; playback is abandoned, not retried.
      .terminal
    case NeteasePlaybackError.nonHTTPSURL, NeteasePlaybackError.unapprovedHost:
      // A host MacEase refuses will be refused again.
      .terminal
    case is CancellationError:
      // Not a failure: a newer intent superseded this one and owns the state.
      .terminal
    default:
      .recoverable
    }
  }
}

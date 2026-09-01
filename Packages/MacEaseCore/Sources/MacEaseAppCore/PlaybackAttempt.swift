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
  package var queueIndex: Int
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
  /// Retry is opt-in: only failures with evidence that a fresh resolve or a
  /// rebuilt AVFoundation item can succeed retain Play Again.
  package static func kind(for error: any Error) -> PlaybackFailureKind {
    switch error {
    case is AudioOutputFailure:
      .recoverable
    case let error as URLError where isTransient(error.code):
      .recoverable
    case let error as NeteaseServiceError
    where error.source == .http && (500...599).contains(error.statusCode):
      .recoverable
    default:
      .terminal
    }
  }

  private static func isTransient(_ code: URLError.Code) -> Bool {
    switch code {
    case .timedOut,
      .cannotFindHost,
      .cannotConnectToHost,
      .networkConnectionLost,
      .dnsLookupFailed,
      .notConnectedToInternet,
      .resourceUnavailable:
      true
    default:
      false
    }
  }
}

import Foundation
import NeteaseKit

/// Whether a track is in the account's liked songs. "Not loaded yet" is not
/// the same as "not liked": showing an empty heart for an unknown track
/// invited the user to click a toggle whose starting state was a guess.
package enum LikedState: Equatable, Sendable {
  case unknown
  case liked
  case notLiked
}

/// What this client knows about liked songs.
///
/// A successful like or unlike proves the state of *that* track. It does not
/// prove anything about the rest of the account, so it is recorded separately
/// instead of fabricating a fully loaded set.
package struct LikedSongs: Equatable, Sendable {
  private var loadedIDs: Set<Int64>?
  private var individuallyKnown: [Int64: Bool] = [:]

  package init() {}

  package var isLoaded: Bool { loadedIDs != nil }

  package func state(of trackID: Int64) -> LikedState {
    if let loadedIDs {
      return loadedIDs.contains(trackID) ? .liked : .notLiked
    }
    guard let known = individuallyKnown[trackID] else { return .unknown }
    return known ? .liked : .notLiked
  }

  package mutating func load(_ ids: [Int64]) {
    loadedIDs = Set(ids)
    individuallyKnown = [:]
  }

  /// Records a confirmed server-side change for one track.
  package mutating func setLiked(_ liked: Bool, trackID: Int64) {
    if loadedIDs != nil {
      if liked {
        loadedIDs?.insert(trackID)
      } else {
        loadedIDs?.remove(trackID)
      }
      return
    }
    individuallyKnown[trackID] = liked
  }

  package mutating func reset() {
    self = LikedSongs()
  }
}

/// The result of one create request. Its id lets the form distinguish this
/// completion from an older one and clear only the submitted value.
package struct CreateReceipt: Equatable, Identifiable, Sendable {
  package let id: UUID
  package let outcome: OperationOutcome

  package init(id: UUID = UUID(), outcome: OperationOutcome) {
    self.id = id
    self.outcome = outcome
  }

  package var succeeded: Bool { outcome == .applied }
}

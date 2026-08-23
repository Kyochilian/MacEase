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
  package var loadedCount: Int? { loadedIDs?.count }

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

/// The result of one write, tagged so a view can tell its own action's
/// completion from a later one. It exists so a form clears its input only
/// when its own request succeeded, instead of optimistically on submit.
package struct WriteReceipt: Equatable, Identifiable, Sendable {
  package enum Outcome: Equatable, Sendable {
    case succeeded
    case failed
    /// The server acted but the result could not be published locally.
    case appliedRemotelyOnly
  }

  package let id: UUID
  package let operation: String
  package let outcome: Outcome

  package init(id: UUID = UUID(), operation: String, outcome: Outcome) {
    self.id = id
    self.operation = operation
    self.outcome = outcome
  }

  package var succeeded: Bool { outcome == .succeeded }
}

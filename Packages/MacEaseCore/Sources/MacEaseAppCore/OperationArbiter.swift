import Foundation
import Observation

/// What a NetEase request does to server state. Effects are not
/// interchangeable: a read that never arrived costs nothing, a write that may
/// have arrived leaves the account in a state the client cannot infer.
package enum OperationEffect: Equatable, Sendable {
  case read
  case write
  case sessionMutation
  case playbackResolution
}

/// How far an operation has got. Only `preparing` is safe to abandon.
package enum OperationPhase: Equatable, Sendable {
  case preparing
  case requestSent
  case settling
}

package struct OperationToken: Equatable, Sendable {
  fileprivate let id: UUID
}

package struct ActiveOperation: Equatable, Sendable {
  package let id: UUID
  package let name: String
  package let effect: OperationEffect
  package fileprivate(set) var phase: OperationPhase
}

package enum OperationOutcome: Equatable, Sendable {
  /// Finished and its result was published.
  case applied
  /// Finished with a classified failure.
  case failed
  /// Abandoned by the client.
  case cancelled
  /// Produced by the arbiter, never passed in: a write stopped being tracked
  /// after its request left the client, so whether the server executed it is
  /// unknown.
  case outcomeUnknown
}

/// A write whose server-side result the client cannot determine. It is never
/// reported as success or failure, and it is never resolved by an automatic
/// follow-up request — only the user can decide to go and look.
package struct UnresolvedOutcome: Equatable, Identifiable, Sendable {
  package let id: UUID
  package let name: String
}

/// The single owner of "a NetEase request is in flight".
///
/// Before this existed, four coordinators kept their own busy flags and each
/// page rebuilt its own `session.isBusy || library.isLoading || ...`
/// expression. The Session tab only consulted the session flag, so a Validate
/// or Clear could cancel a like, a playlist edit or a subscribe that had
/// already reached the server, and the app would then show only session
/// state — the user could not tell whether the write had taken effect.
///
/// Rules enforced here:
/// - at most one NetEase request at a time, whatever its effect;
/// - local playback actions (pause, seek, volume) never claim it;
/// - a read may be abandoned freely;
/// - a write that has been sent is never silently dropped: abandoning it
///   records an unresolved outcome instead of a success or a failure;
/// - only the operation that holds the arbiter can release it, so a stale or
///   duplicate completion cannot free someone else's slot.
///
/// There is no global instance: `MacEaseApp` creates one and injects it.
@MainActor
@Observable
package final class OperationArbiter {
  package private(set) var active: ActiveOperation?
  package private(set) var unresolvedOutcomes: [UnresolvedOutcome] = []

  package init() {}

  package var isBusy: Bool { active != nil }

  /// True when the arbiter would accept a new operation right now.
  package func canStart() -> Bool { active == nil }

  /// Claims the arbiter, or returns nil when another operation owns it.
  package func begin(name: String, effect: OperationEffect) -> OperationToken? {
    guard active == nil else { return nil }
    let id = UUID()
    active = ActiveOperation(id: id, name: name, effect: effect, phase: .preparing)
    return OperationToken(id: id)
  }

  /// Called immediately before the request is handed to the transport. After
  /// this point a write can no longer be treated as "never happened".
  package func markRequestSent(_ token: OperationToken) {
    guard var operation = active, operation.id == token.id else { return }
    operation.phase = .requestSent
    active = operation
  }

  /// Called once the response is in hand and only local state remains.
  package func markSettling(_ token: OperationToken) {
    guard var operation = active, operation.id == token.id else { return }
    operation.phase = .settling
    active = operation
  }

  /// Whether abandoning this operation right now would leave the server
  /// result unknown. Callers use it to refuse to cancel rather than to guess.
  package func abandoningLosesTheOutcome(_ token: OperationToken) -> Bool {
    guard let operation = active, operation.id == token.id else { return false }
    return operation.effect == .write && operation.phase != .preparing
  }

  @discardableResult
  package func end(
    _ token: OperationToken,
    outcome: OperationOutcome
  ) -> OperationOutcome? {
    guard let operation = active, operation.id == token.id else { return nil }
    let resolved = Self.resolve(outcome, for: operation)
    if resolved == .outcomeUnknown {
      unresolvedOutcomes.append(
        UnresolvedOutcome(id: operation.id, name: operation.name)
      )
    }
    active = nil
    return resolved
  }

  /// The user acknowledged that they have checked the account themselves.
  package func acknowledgeUnresolvedOutcomes() {
    unresolvedOutcomes.removeAll()
  }

  private static func resolve(
    _ outcome: OperationOutcome,
    for operation: ActiveOperation
  ) -> OperationOutcome {
    guard outcome == .cancelled || outcome == .outcomeUnknown else {
      return outcome
    }
    if operation.effect == .write && operation.phase != .preparing {
      return .outcomeUnknown
    }
    return outcome == .outcomeUnknown ? .cancelled : outcome
  }
}

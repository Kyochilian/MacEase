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
  /// Finished with a classified failure. The server either did not act, or
  /// acted and said so.
  case failed
  /// Abandoned by the client.
  case cancelled
  /// The server acknowledged the write, but the result could not be published
  /// locally, typically because the session changed between the response and
  /// the postflight check. The account did change; the visible list did not.
  case appliedRemotelyOnly
  /// The request left the client and no answer arrived, so whether the server
  /// executed it cannot be determined.
  case outcomeUnknown
}

/// A write the user cannot read off the screen. It is never reported as a
/// plain success or failure, and it is never resolved by an automatic
/// follow-up request: only the user can decide to go and look.
package struct UnresolvedOutcome: Equatable, Identifiable, Sendable {
  package enum Kind: Equatable, Sendable {
    /// Sent, no answer: the server may or may not have executed it.
    case unknown
    /// Acknowledged by the server, not reflected in what is on screen.
    case appliedRemotelyOnly
  }

  package let id: UUID
  package let name: String
  package let kind: Kind

  package var advice: String {
    switch kind {
    case .unknown: "outcome unknown, reload to check"
    case .appliedRemotelyOnly: "applied on the server, reload to see it"
    }
  }
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
  /// result unknown. Only a write whose request is still in flight qualifies:
  /// once the response is in hand the phase is `.settling` and the server's
  /// answer is known even if the local apply never runs.
  package func abandoningLosesTheOutcome(_ token: OperationToken) -> Bool {
    guard let operation = active, operation.id == token.id else { return false }
    return operation.effect == .write && operation.phase == .requestSent
  }

  /// True when a write's request is in flight. A module reset consults this
  /// to refuse to cancel rather than to guess what the server did.
  package var activeWriteIsInFlight: Bool {
    guard let operation = active else { return false }
    return operation.effect == .write && operation.phase == .requestSent
  }

  @discardableResult
  package func end(
    _ token: OperationToken,
    outcome: OperationOutcome
  ) -> OperationOutcome? {
    guard let operation = active, operation.id == token.id else { return nil }
    let resolved = Self.resolve(outcome, for: operation)
    if let kind = resolved.unresolvedKind {
      unresolvedOutcomes.append(
        UnresolvedOutcome(id: operation.id, name: operation.name, kind: kind)
      )
    }
    active = nil
    return resolved
  }

  /// The user acknowledged that they have checked the account themselves.
  package func acknowledgeUnresolvedOutcomes() {
    unresolvedOutcomes.removeAll()
  }

  /// Cancellation is the only outcome the arbiter reinterprets, and only for
  /// a write. A dropped read costs nothing; a write that was sent and never
  /// answered leaves the account in a state this client cannot infer.
  private static func resolve(
    _ outcome: OperationOutcome,
    for operation: ActiveOperation
  ) -> OperationOutcome {
    guard outcome == .cancelled, operation.effect == .write else {
      return outcome
    }
    switch operation.phase {
    case .preparing:
      return .cancelled
    case .requestSent:
      return .outcomeUnknown
    case .settling:
      // The response was already in hand, so the answer is known.
      return .appliedRemotelyOnly
    }
  }
}

extension OperationOutcome {
  /// Which outcomes the user has to reconcile by hand.
  fileprivate var unresolvedKind: UnresolvedOutcome.Kind? {
    switch self {
    case .outcomeUnknown: .unknown
    case .appliedRemotelyOnly: .appliedRemotelyOnly
    case .applied, .failed, .cancelled: nil
    }
  }
}

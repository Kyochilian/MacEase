import Foundation
import Observation

/// What a NetEase request does to server state. Effects are not
/// interchangeable: a read that never arrived costs nothing, a write that may
/// have arrived leaves the account in a state the client cannot infer.
package enum OperationEffect: Equatable, Sendable {
  case read
  case write
  /// Automatic listening feedback. It is still a server write with unknown
  /// outcome semantics, but may overlap reads that were already admitted.
  /// New work remains blocked while it owns the exclusive slot.
  case feedback
  case sessionMutation
  case playbackResolution
}

/// How far an operation has got. Only `preparing` is safe to abandon.
package enum OperationPhase: Equatable, Sendable {
  case preparing
  case requestSent
  case settling
}

package enum OperationTokenKind: Equatable, Sendable {
  case read
  case exclusive
}

package struct OperationToken: Equatable, Sendable {
  package let id: UUID
  package let kind: OperationTokenKind
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
  /// The request did not leave the client, or something came back that proves
  /// the server did not act: an application-layer rejection, or an HTTP status
  /// that refused the request before it was handled. An HTTP 5xx is not in
  /// this category — it says the server broke, not that it did nothing.
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

/// The single owner of server writes and destructive session mutations.
///
/// Before this existed, four coordinators kept their own busy flags and each
/// page rebuilt its own `session.isBusy || library.isLoading || ...`
/// expression. The Session tab only consulted the session flag, so a Validate
/// or Clear could cancel a like, a playlist edit or a subscribe that had
/// already reached the server, and the app would then show only session
/// state — the user could not tell whether the write had taken effect.
///
/// Rules enforced here:
/// - writes, feedback and session mutations are mutually exclusive;
/// - reads and playback resolution may run together, but cannot start while an
///   exclusive operation is active, and never exceed a fixed ceiling;
/// - feedback may start alongside reads already in flight, because a remote
///   track transition necessarily owns its next song-URL read before the old
///   listening instance can settle; it still blocks every new operation;
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
  /// The most reads MacEase keeps in flight at once. Concurrency exists so an
  /// independent read does not wait behind an unrelated one, not so the app can
  /// fan out: a composite search is four requests on its own, and without a
  /// ceiling a future feature could turn one user action into a burst that
  /// looks nothing like a person using a music client.
  package static let defaultMaximumConcurrentReads = 6

  package private(set) var active: ActiveOperation?
  package private(set) var unresolvedOutcomes: [UnresolvedOutcome] = []
  private var activeReadTokens: Set<UUID> = []
  private let maximumConcurrentReads: Int

  package init(maximumConcurrentReads: Int = defaultMaximumConcurrentReads) {
    // A ceiling below one would refuse every read; clamp rather than trap,
    // because this value can come from configuration.
    self.maximumConcurrentReads = max(1, maximumConcurrentReads)
  }

  package var isBusy: Bool { active != nil }

  /// How many reads hold the read side right now. Diagnostics and tests use
  /// it; no control-flow branch reads it.
  package var activeReadCount: Int { activeReadTokens.count }

  /// True when no write or session mutation owns the exclusive slot.
  package func canStart() -> Bool { active == nil }

  /// Claims an operation. Reads share the read side up to the ceiling, while a
  /// write or session mutation requires both the read side and the exclusive
  /// slot to be free.
  package func canBegin(effect: OperationEffect) -> Bool {
    if effect == .write || effect == .sessionMutation {
      return active == nil && activeReadTokens.isEmpty
    }
    if effect == .feedback { return active == nil }
    return active == nil && activeReadTokens.count < maximumConcurrentReads
  }

  package func begin(name: String, effect: OperationEffect) -> OperationToken? {
    let id = UUID()
    guard effect == .write || effect == .feedback || effect == .sessionMutation
    else {
      guard canBegin(effect: effect) else { return nil }
      activeReadTokens.insert(id)
      return OperationToken(id: id, kind: .read)
    }
    guard canBegin(effect: effect) else { return nil }
    active = ActiveOperation(id: id, name: name, effect: effect, phase: .preparing)
    return OperationToken(id: id, kind: .exclusive)
  }

  /// Turns an active read into a session mutation without exposing a gap in
  /// which another operation could enter.
  ///
  /// Unlike `begin`, this does not wait for the read side to empty. `begin`
  /// starts a session mutation the user asked for, and can reasonably wait for
  /// a quiet moment. Promotion happens when a read has already proved the
  /// credential is dead, and refusing it because an unrelated read is running
  /// would leave the app using a credential it knows is invalid — the identity
  /// truth would depend on request timing. The concurrent reads are about to be
  /// cleared by the identity change anyway.
  ///
  /// It still refuses while a write or another session mutation owns the
  /// exclusive slot, because that is the guarantee that stops a sent write
  /// from being cancelled.
  package func promote(
    _ readToken: OperationToken,
    name: String
  ) -> OperationToken? {
    guard readToken.kind == .read, active == nil,
      activeReadTokens.contains(readToken.id)
    else { return nil }

    activeReadTokens.remove(readToken.id)
    active = ActiveOperation(
      id: readToken.id,
      name: name,
      effect: .sessionMutation,
      phase: .preparing
    )
    return OperationToken(id: readToken.id, kind: .exclusive)
  }

  /// Called immediately before the request is handed to the transport. After
  /// this point a write can no longer be treated as "never happened".
  package func markRequestSent(_ token: OperationToken) {
    guard token.kind == .exclusive else { return }
    guard var operation = active, operation.id == token.id else { return }
    operation.phase = .requestSent
    active = operation
  }

  /// Called once the response is in hand and only local state remains.
  package func markSettling(_ token: OperationToken) {
    guard token.kind == .exclusive else { return }
    guard var operation = active, operation.id == token.id else { return }
    operation.phase = .settling
    active = operation
  }

  /// Whether abandoning this operation right now would leave the server
  /// result unknown. Only a write whose request is still in flight qualifies:
  /// once the response is in hand the phase is `.settling` and the server's
  /// answer is known even if the local apply never runs.
  package func abandoningLosesTheOutcome(_ token: OperationToken) -> Bool {
    guard token.kind == .exclusive else { return false }
    guard let operation = active, operation.id == token.id else { return false }
    return operation.effect.isServerWrite && operation.phase == .requestSent
  }

  /// True when a write's request is in flight. A module reset consults this
  /// to refuse to cancel rather than to guess what the server did.
  package var activeWriteIsInFlight: Bool {
    guard let operation = active else { return false }
    return operation.effect.isServerWrite && operation.phase == .requestSent
  }

  @discardableResult
  package func end(
    _ token: OperationToken,
    outcome: OperationOutcome
  ) -> OperationOutcome? {
    if token.kind == .read {
      guard activeReadTokens.remove(token.id) != nil else { return nil }
      return outcome
    }
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
    guard outcome == .cancelled, operation.effect.isServerWrite else {
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

extension OperationEffect {
  fileprivate var isServerWrite: Bool {
    self == .write || self == .feedback
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

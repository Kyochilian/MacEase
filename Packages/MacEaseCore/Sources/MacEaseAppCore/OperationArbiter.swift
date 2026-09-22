import Foundation
import OSLog
import Observation

/// What a NetEase request does to server state. Effects are not
/// interchangeable: a read that never arrived costs nothing, a write that may
/// have arrived leaves the account in a state the client cannot infer.
package enum OperationEffect: Equatable, Sendable {
  case read
  case write
  /// Long file uploads keep identity and other writes stable while independent reads continue.
  case upload
  /// Listening feedback serializes with writes and identity changes, while independent reads continue.
  case feedback
  case sessionMutation
  /// Same-account credential renewal runs alongside browsing and playback.
  case sessionRefresh
  case playbackResolution
  /// A local credential check bypasses the network ceiling but excludes identity mutation.
  case localSessionAccess
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
/// - network reads share a fixed ceiling and may overlap writes and same-account renewal;
/// - identity replacement waits for active reads to finish;
/// - local credential reads do not spend that network budget;
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
  /// Bounds concurrent user operations. Each operation can run a small group
  /// of independent requests; URLSession manages connections and multiplexing.
  package static let defaultMaximumConcurrentReads = 6

  package private(set) var active: ActiveOperation?
  package private(set) var unresolvedOutcomes: [UnresolvedOutcome] = []
  package private(set) var writeRevision = 0
  private static let logger = Logger(subsystem: "com.macease.app", category: "Operations")
  private var started: [UUID: (name: String, time: ContinuousClock.Instant)] = [:]
  private var activeReadTokens: Set<UUID> = []
  private var activeLocalTokens: Set<UUID> = []
  private let maximumConcurrentReads: Int
  private struct Waiter {
    let id: UUID
    let name: String
    let effect: OperationEffect
    let continuation: CheckedContinuation<OperationToken?, Never>
    let timeout: Task<Void, Never>
    let queuedAt: ContinuousClock.Instant
  }
  @ObservationIgnored private var waiters: [Waiter] = []

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

  /// Browsing and playback share bounded read capacity. Ordinary writes and
  /// renewal may overlap reads; only replacing identity drains the read side.
  package func canBegin(effect: OperationEffect) -> Bool {
    canAdmit(effect: effect) && !waiters.contains { $0.effect.blocksFollowing(effect) }
  }

  private func canAdmit(effect: OperationEffect) -> Bool {
    if effect == .sessionMutation {
      return active == nil && activeReadTokens.isEmpty && activeLocalTokens.isEmpty
    }
    if effect == .write || effect == .feedback || effect == .upload || effect == .sessionRefresh {
      return active == nil
    }
    if effect == .playbackResolution {
      return active?.effect != .sessionMutation && activeReadTokens.count < maximumConcurrentReads
    }
    if effect == .localSessionAccess {
      return active?.effect != .sessionMutation
    }
    return active?.effect != .sessionMutation && activeReadTokens.count < maximumConcurrentReads
  }

  package func begin(name: String, effect: OperationEffect) -> OperationToken? {
    guard canBegin(effect: effect) else { return nil }
    return admit(name: name, effect: effect)
  }

  private func admit(name: String, effect: OperationEffect) -> OperationToken {
    let id = UUID()
    started[id] = (name, .now)
    Self.logger.info(
      "id=\(id.uuidString, privacy: .public) phase=start operation=\(name, privacy: .public) effect=\(String(describing: effect), privacy: .public)"
    )
    if effect == .write || effect == .upload { writeRevision += 1 }
    guard
      effect == .write || effect == .upload || effect == .feedback || effect == .sessionMutation
        || effect == .sessionRefresh
    else {
      if effect == .localSessionAccess {
        activeLocalTokens.insert(id)
      } else {
        activeReadTokens.insert(id)
      }
      return OperationToken(id: id, kind: .read)
    }
    active = ActiveOperation(id: id, name: name, effect: effect, phase: .preparing)
    return OperationToken(id: id, kind: .exclusive)
  }

  /// Transfers an admitted metadata read to playback without a free-slot gap.
  package func transferRead(_ token: OperationToken) -> OperationToken? {
    guard token.kind == .read, active?.effect != .sessionMutation,
      activeReadTokens.remove(token.id) != nil
    else { return nil }
    let next = OperationToken(id: UUID(), kind: .read)
    started[next.id] = started.removeValue(forKey: token.id) ?? ("Playback", .now)
    activeReadTokens.insert(next.id)
    return next
  }

  /// Waits only before sending a request. Cancellation and the deadline release
  /// the intent; neither path retries a request that has already been sent.
  package func beginWhenAvailable(
    name: String,
    effect: OperationEffect,
    timeout: Duration = .seconds(30)
  ) async -> OperationToken? {
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: nil)
          return
        }
        if let token = begin(name: name, effect: effect) {
          continuation.resume(returning: token)
          return
        }
        guard waiters.count < 64 else {
          continuation.resume(returning: nil)
          return
        }
        let deadline = Task { [weak self] in
          do { try await Task.sleep(for: timeout) } catch { return }
          self?.cancelWaiter(id)
        }
        waiters.append(
          Waiter(
            id: id, name: name, effect: effect,
            continuation: continuation, timeout: deadline, queuedAt: .now
          ))
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelWaiter(id) }
    }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.timeout.cancel()
    waiter.continuation.resume(returning: nil)
    admitWaiters()
  }

  private func admitWaiters() {
    var index = 0
    while index < waiters.count {
      let waiter = waiters[index]
      // FIFO for competing resources, while independent reads may pass a
      // feedback operation waiting for an upload. Only a queued identity
      // change reserves the drain so later reads cannot starve it.
      guard canAdmit(effect: waiter.effect),
        !waiters[..<index].contains(where: { $0.effect.blocksFollowing(waiter.effect) })
      else {
        index += 1
        continue
      }
      let wait = waiter.queuedAt.duration(to: .now)
      let token = admit(name: waiter.name, effect: waiter.effect)
      Self.logger.info(
        "id=\(token.id.uuidString, privacy: .public) phase=admitted queue_ms=\(Self.milliseconds(wait), privacy: .public)"
      )
      waiters.remove(at: index)
      waiter.timeout.cancel()
      waiter.continuation.resume(returning: token)
    }
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
      guard activeReadTokens.remove(token.id) != nil || activeLocalTokens.remove(token.id) != nil
      else { return nil }
      recordCompletion(token, outcome: outcome)
      admitWaiters()
      return outcome
    }
    guard let operation = active, operation.id == token.id else { return nil }
    let resolved = Self.resolve(outcome, for: operation)
    if let kind = resolved.unresolvedKind {
      unresolvedOutcomes.append(
        UnresolvedOutcome(id: operation.id, name: operation.name, kind: kind)
      )
    }
    if operation.effect == .write || operation.effect == .upload { writeRevision += 1 }
    recordCompletion(token, outcome: resolved)
    active = nil
    admitWaiters()
    return resolved
  }

  private func recordCompletion(_ token: OperationToken, outcome: OperationOutcome) {
    guard let start = started.removeValue(forKey: token.id) else { return }
    Self.logger.info(
      "id=\(token.id.uuidString, privacy: .public) phase=complete operation=\(start.name, privacy: .public) operation_ms=\(Self.milliseconds(start.time.duration(to: .now)), privacy: .public) outcome=\(String(describing: outcome), privacy: .public)"
    )
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
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
  fileprivate func blocksFollowing(_ later: OperationEffect) -> Bool {
    switch self {
    case .sessionMutation:
      true
    case .write, .upload, .feedback, .sessionRefresh:
      later == .write || later == .sessionMutation || later == .upload || later == .feedback
        || later == .sessionRefresh
    case .read, .playbackResolution:
      later == .read || later == .playbackResolution || later == .sessionMutation
    case .localSessionAccess:
      later == .sessionMutation
    }
  }

  fileprivate var isServerWrite: Bool {
    self == .write || self == .upload || self == .feedback
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

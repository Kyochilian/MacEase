import Foundation
import NeteaseKit
import Observation

/// Serialises feedback for actual playback instances without owning playback.
/// Audio never awaits this coordinator: lifecycle events are queued in order,
/// while every request still claims the shared write arbiter and rechecks the
/// validated account before and after transport.
@MainActor
@Observable
package final class ScrobbleCoordinator: SessionGuardedCoordinator {
  @ObservationIgnored private let transport: any NeteaseTransporting
  @ObservationIgnored package let vault: any CredentialStoring
  @ObservationIgnored private let arbiter: OperationArbiter
  @ObservationIgnored package private(set) var generation = 0
  @ObservationIgnored private var tailTask: Task<Void, Never>?
  @ObservationIgnored private var seenStarts: Set<UUID> = []
  @ObservationIgnored private var seenFinishes: Set<UUID> = []
  @ObservationIgnored private var confirmedStarts: Set<UUID> = []
  @ObservationIgnored private var pendingTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var completedInstances: [UUID] = []

  package var noStoredSessionStatus: String {
    "Scrobble not sent: no stored session"
  }
  package var status = "Listening feedback waits for actual playback"

  package init(
    transport: any NeteaseTransporting,
    vault: any CredentialStoring,
    arbiter: OperationArbiter
  ) {
    self.transport = transport
    self.vault = vault
    self.arbiter = arbiter
  }

  package func clearSessionScopedData() {
    confirmedStarts.removeAll()
  }

  package func handle(
    _ event: PlaybackLifecycleEvent,
    session: any SessionProviding
  ) {
    guard session.isOnline else { return }
    guard pendingTasks.count < 64 else {
      status = "Listening feedback is busy"
      return
    }
    let instance: PlaybackLifecycleInstance
    switch event {
    case .started(let value):
      guard seenStarts.insert(value.id).inserted else { return }
      instance = value
    case .finished(let value, _, _):
      guard seenFinishes.insert(value.id).inserted else { return }
      instance = value
    }

    let currentGeneration = generation
    let predecessor = tailTask
    let taskID = UUID()
    let task = Task { [weak self] in
      await predecessor?.value
      guard let self else { return }
      defer { self.pendingTasks[taskID] = nil }
      guard self.generation == currentGeneration, !Task.isCancelled else { return }
      switch event {
      case .started:
        await self.start(
          instance,
          generation: currentGeneration,
          session: session
        )
      case .finished(_, let playedSeconds, let end):
        await self.finish(
          instance,
          playedSeconds: playedSeconds,
          end: end,
          generation: currentGeneration,
          session: session
        )
        self.completedInstances.append(instance.id)
        if self.completedInstances.count > 256 {
          let expired = self.completedInstances.removeFirst()
          self.seenStarts.remove(expired)
          self.seenFinishes.remove(expired)
          self.confirmedStarts.remove(expired)
        }
      }
    }
    pendingTasks[taskID] = task
    tailTask = task
  }

  package func reset() {
    generation &+= 1
    pendingTasks.values.forEach { $0.cancel() }
    pendingTasks.removeAll()
    tailTask = nil
    completedInstances.removeAll()
    seenStarts.removeAll()
    seenFinishes.removeAll()
    confirmedStarts.removeAll()
    status = "Listening feedback is waiting for validated playback"
  }

  /// Waits only for feedback already accepted by this coordinator. Session
  /// replacement and application termination use it after stopping playback,
  /// so the old credential remains authoritative through that final write.
  package func settle() async {
    await tailTask?.value
  }

  package func settleForTesting() async {
    await settle()
  }

  private func start(
    _ instance: PlaybackLifecycleInstance,
    generation: Int,
    session: any SessionProviding
  ) async {
    let context = instance.scrobbleContext
    let outcome = await write(
      name: "Scrobble start",
      instance: instance,
      generation: generation,
      session: session
    ) { credential in
      try await self.transport.scrobbleStart(
        songID: instance.track.catalogSongID ?? instance.track.id,
        context: context,
        credential: credential
      )
    }
    guard self.generation == generation else { return }
    if outcome == .applied {
      confirmedStarts.insert(instance.id)
      status = "Listening start confirmed for \(instance.track.name)"
    } else if outcome == .outcomeUnknown {
      status = "Listening start outcome unknown; finish will not be sent"
    } else if outcome == .appliedRemotelyOnly {
      status = "Listening start belonged to the previous session; finish will not be sent"
    }
  }

  private func finish(
    _ instance: PlaybackLifecycleInstance,
    playedSeconds: Int,
    end: ScrobbleEnd,
    generation: Int,
    session: any SessionProviding
  ) async {
    var context = instance.scrobbleContext
    context.end = end
    guard confirmedStarts.remove(instance.id) != nil else {
      if self.generation == generation {
        status = "Listening finish not sent because start was not confirmed"
      }
      return
    }
    let seconds = max(0, playedSeconds)
    let outcome = await write(
      name: "Scrobble finish",
      instance: instance,
      generation: generation,
      session: session
    ) { credential in
      try await self.transport.scrobbleFinish(
        songID: instance.track.catalogSongID ?? instance.track.id,
        context: context,
        playedSeconds: seconds,
        credential: credential
      )
    }
    guard self.generation == generation else { return }
    switch outcome {
    case .applied:
      status = "Listening finish confirmed: \(seconds)s for \(instance.track.name)"
    case .outcomeUnknown:
      status = "Listening finish outcome unknown"
    case .appliedRemotelyOnly:
      status = "Listening finish was acknowledged for the previous session"
    case .failed, .cancelled, nil:
      break
    }
  }

  private func write(
    name: String,
    instance: PlaybackLifecycleInstance,
    generation: Int,
    session: any SessionProviding,
    request: @escaping @MainActor (NeteaseCredential) async throws -> Void
  ) async -> OperationOutcome? {
    guard session.account?.userID == instance.accountID else {
      if self.generation == generation {
        status = "\(name) not sent: playback belongs to another session"
      }
      return .cancelled
    }
    guard
      let token = await arbiter.beginWhenAvailable(
        name: name, effect: .feedback, timeout: .seconds(600))
    else {
      if self.generation == generation {
        status = "\(name) not sent: another operation is active"
      }
      return .cancelled
    }
    guard self.generation == generation, !Task.isCancelled,
      session.isOnline, session.account?.userID == instance.accountID
    else { return arbiter.end(token, outcome: .cancelled) }

    var outcome = OperationOutcome.failed
    var credential: NeteaseCredential?
    do {
      credential = try await currentCredential(
        account: NeteaseAccount(userID: instance.accountID),
        generation: generation,
        session: session
      )
      guard let credential else {
        return arbiter.end(token, outcome: outcome)
      }
      guard self.generation == generation else {
        return arbiter.end(token, outcome: .cancelled)
      }
      arbiter.markRequestSent(token)
      try await request(credential)
      arbiter.markSettling(token)
      outcome = .appliedRemotelyOnly
      guard
        try await sessionRemainsCurrent(
          account: NeteaseAccount(userID: instance.accountID),
          credential: credential,
          generation: generation,
          session: session
        )
      else { return arbiter.end(token, outcome: outcome) }
      outcome = .applied
    } catch {
      if error.provesWriteDidNotRun {
        outcome = .failed
      } else if arbiter.abandoningLosesTheOutcome(token) {
        outcome = .outcomeUnknown
      }
      if self.generation == generation {
        let failure = OperationFailure.classify(error)
        status = failure.statusText(operation: name)
      }
    }
    return arbiter.end(token, outcome: outcome)
  }

}

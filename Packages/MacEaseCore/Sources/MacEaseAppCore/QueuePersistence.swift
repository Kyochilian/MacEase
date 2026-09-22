import Foundation
import NeteaseKit
import Observation

/// Keeps the stored queue in step with what is playing, and puts it back after
/// a relaunch.
///
/// Writing is deliberately unhurried. The queue is saved when it changes in a
/// way worth remembering — a new track, a seek or a pause — and on a slow tick
/// while audio is running, because the position moves continuously and
/// nothing else would notice. An explicit Stop deletes the row. All of it is
/// local disk; none of it is a request.
///
/// Restoring never plays. The user has just opened the app and has not asked
/// for audio, so the queue comes back with a retry entry point and waits.
@MainActor
@Observable
package final class QueuePersistence {
  /// Long enough that a listening session is a handful of small writes, short
  /// enough that a crash loses seconds rather than minutes of position.
  package static let tickSeconds: Double = 15

  @ObservationIgnored package let store: LibraryStore
  @ObservationIgnored private weak var playback: PlaybackController?
  @ObservationIgnored private var accountID: Int64?
  @ObservationIgnored private var bindingRevision: UInt64 = 0
  @ObservationIgnored private var tickTask: Task<Void, Never>?
  @ObservationIgnored private var queueClearTask: Task<Void, Never>?
  @ObservationIgnored private var pendingQueueClears: Set<Int64> = []
  /// The last thing written, so an unchanged queue is not rewritten on every
  /// tick. Only a write that actually landed may be recorded here: remembering
  /// one that failed would make every later tick skip the retry, and the
  /// stored queue would fall silently behind what is playing.
  @ObservationIgnored private var lastWritten: PersistedQueue?

  /// What the last storage operation did, or nil when it succeeded.
  ///
  /// Losing the store costs the resume point, not the app, so nothing here
  /// stops anything. It must never look as though the data had been saved
  /// either, which is why the failure is published rather than dropped.
  package private(set) var lastFailure: String?

  package init(store: LibraryStore, playback: PlaybackController) {
    self.store = store
    self.playback = playback
  }

  /// Binds the account whose queue is being tracked and restores it.
  ///
  /// Called after a validate confirms who is signed in. Re-binding the same
  /// account does nothing, so a second validate does not re-restore over a
  /// queue the user has since started.
  package func activate(accountID: Int64) async {
    guard self.accountID != accountID else { return }
    await deactivate()
    self.accountID = accountID
    bindingRevision &+= 1
    let revision = bindingRevision

    // A failed explicit Stop must not resurrect the old queue. Retry its
    // deletion before looking at the row, and leave restoration skipped while
    // the deletion is still pending.
    if pendingQueueClears.contains(accountID) {
      await clearPendingQueue(accountID: accountID)
      guard isBound(to: accountID, revision: revision) else { return }
      if pendingQueueClears.contains(accountID) {
        startTicking(accountID: accountID, revision: revision)
        return
      }
    }

    do {
      let stored = try await store.queue(accountID: accountID)
      guard isBound(to: accountID, revision: revision) else { return }
      if let stored, playback?.queueTracks.isEmpty == true {
        playback?.restore(stored, accountID: accountID)
        lastWritten = stored
      }
      lastFailure = nil
    } catch {
      guard isBound(to: accountID, revision: revision) else { return }
      // Nothing is known about what is on disk. `lastWritten` stays nil, so
      // the next save writes rather than assuming the stored queue matches.
      lastFailure =
        "The stored queue could not be read: "
        + LibraryStore.diagnostic(for: error)
    }
    startTicking(accountID: accountID, revision: revision)
  }

  /// Stops tracking. The queue already on disk is left alone: signing out does
  /// not mean the user wants to lose their place if they sign back in, and
  /// another account cannot see it because the account is part of the key.
  package func deactivate() async {
    tickTask?.cancel()
    tickTask = nil
    bindingRevision &+= 1
    accountID = nil
    lastWritten = nil
    lastFailure = nil
  }

  /// Writes now if anything worth remembering changed. Safe to call often.
  package func save() async {
    guard let accountID else { return }
    let revision = bindingRevision
    if pendingQueueClears.contains(accountID) {
      await clearPendingQueue(accountID: accountID)
      return
    }
    guard let playback else { return }
    guard let queue = playback.persistedQueue() else { return }
    guard queue != lastWritten else { return }
    guard isBound(to: accountID, revision: revision) else { return }
    do {
      try await store.saveQueue(queue, accountID: accountID)
      guard isBound(to: accountID, revision: revision) else { return }
      lastWritten = queue
      lastFailure = nil
    } catch {
      guard isBound(to: accountID, revision: revision) else { return }
      // `lastWritten` is deliberately untouched, so the next change or tick
      // tries this write again.
      lastFailure =
        "The queue could not be saved: " + LibraryStore.diagnostic(for: error)
    }
  }

  /// Saves one immutable, server-confirmed snapshot for its named account.
  /// Both checks use the same binding revision, so a switch while SQLite is
  /// writing cannot publish diagnostics or bookkeeping into the new binding.
  package func savePlaylists(
    _ playlists: [UserPlaylist],
    accountID: Int64
  ) async {
    let revision = bindingRevision
    guard isBound(to: accountID, revision: revision) else { return }
    let snapshot = playlists
    do {
      try await store.savePlaylists(snapshot, accountID: accountID)
      guard isBound(to: accountID, revision: revision) else { return }
      lastFailure = nil
    } catch {
      guard isBound(to: accountID, revision: revision) else { return }
      lastFailure =
        "The playlists could not be saved: " + LibraryStore.diagnostic(for: error)
    }
  }

  package func storedPlaylists(accountID: Int64) async -> [UserPlaylist] {
    let revision = bindingRevision
    guard isBound(to: accountID, revision: revision) else { return [] }
    do {
      let playlists = try await store.playlists(accountID: accountID)
      guard isBound(to: accountID, revision: revision) else { return [] }
      lastFailure = nil
      return playlists
    } catch {
      guard isBound(to: accountID, revision: revision) else { return [] }
      lastFailure =
        "The stored playlists could not be read: "
        + LibraryStore.diagnostic(for: error)
      return []
    }
  }

  /// Called only by PlaybackController's explicit Stop callback. Session
  /// cleanup never calls it, so an idle phase alone cannot erase a resume row.
  package func clearQueueAfterExplicitStop() {
    guard let accountID else { return }
    pendingQueueClears.insert(accountID)
    queueClearTask = Task { [weak self] in
      await self?.clearPendingQueue(accountID: accountID)
    }
  }

  package func settleQueueClearForTesting() async {
    await queueClearTask?.value
  }

  private func clearPendingQueue(accountID: Int64) async {
    guard pendingQueueClears.contains(accountID) else { return }
    do {
      try await store.clearQueue(accountID: accountID)
      pendingQueueClears.remove(accountID)
      guard self.accountID == accountID else { return }
      lastWritten = nil
      lastFailure = nil
    } catch {
      guard self.accountID == accountID else { return }
      // The account remains pending, so the next tick/save/activation retries.
      lastFailure =
        "The stored queue could not be cleared: "
        + LibraryStore.diagnostic(for: error)
    }
  }

  private func isBound(to accountID: Int64, revision: UInt64) -> Bool {
    self.accountID == accountID && bindingRevision == revision
  }

  private func startTicking(accountID: Int64, revision: UInt64) {
    tickTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.tickSeconds))
        guard !Task.isCancelled else { return }
        guard let self, self.isBound(to: accountID, revision: revision) else {
          return
        }
        await self.save()
      }
    }
  }
}

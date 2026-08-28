import Foundation
import NeteaseKit
import Observation

/// Keeps the stored queue in step with what is playing, and puts it back after
/// a relaunch.
///
/// Writing is deliberately unhurried. The queue is saved when it changes in a
/// way worth remembering — a new track, a seek, a pause, a stop — and on a slow
/// tick while audio is running, because the position moves continuously and
/// nothing else would notice. All of it is local disk; none of it is a
/// request.
///
/// Restoring never plays. The user has just opened the app and has not asked
/// for audio, so the queue comes back with a retry entry point and waits.
@MainActor
@Observable
package final class QueuePersistence {
  /// Long enough that a listening session is a handful of small writes, short
  /// enough that a crash loses seconds rather than minutes of position.
  package static let tickSeconds: Double = 15

  @ObservationIgnored private let store: LibraryStore
  @ObservationIgnored private weak var playback: PlaybackController?
  @ObservationIgnored private var accountID: Int64?
  @ObservationIgnored private var tickTask: Task<Void, Never>?
  /// The last thing written, so an unchanged queue is not rewritten on every
  /// tick.
  @ObservationIgnored private var lastWritten: PersistedQueue?

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

    if let stored = try? await store.queue(accountID: accountID) {
      playback?.restore(stored)
      lastWritten = stored
    }
    startTicking(accountID: accountID)
  }

  /// Stops tracking. The queue already on disk is left alone: signing out does
  /// not mean the user wants to lose their place if they sign back in.
  package func deactivate() async {
    tickTask?.cancel()
    tickTask = nil
    accountID = nil
    lastWritten = nil
  }

  /// Writes now if anything worth remembering changed. Safe to call often.
  package func save() async {
    guard let accountID, let playback else { return }
    guard let queue = playback.persistedQueue() else { return }
    guard queue != lastWritten else { return }
    lastWritten = queue
    try? await store.saveQueue(queue, accountID: accountID)
  }

  /// Forgets this account's stored queue and library. Used when the user signs
  /// out on purpose, where leaving their listening behind on a shared machine
  /// would be the wrong default.
  package func clear(accountID: Int64) async {
    try? await store.clear(accountID: accountID)
    if self.accountID == accountID { lastWritten = nil }
  }

  package func savePlaylists(_ playlists: [UserPlaylist]) async {
    guard let accountID else { return }
    try? await store.savePlaylists(playlists, accountID: accountID)
  }

  package func storedPlaylists() async -> [UserPlaylist] {
    guard let accountID else { return [] }
    return (try? await store.playlists(accountID: accountID)) ?? []
  }

  private func startTicking(accountID: Int64) {
    tickTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.tickSeconds))
        guard !Task.isCancelled else { return }
        guard let self, self.accountID == accountID else { return }
        await self.save()
      }
    }
  }
}

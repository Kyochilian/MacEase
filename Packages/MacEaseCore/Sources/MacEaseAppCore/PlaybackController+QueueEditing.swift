import Foundation
import NeteaseKit

@MainActor
extension PlaybackController {
  package var canStartNonSessionOperation: Bool {
    !sessionMutationPending && arbiter.active?.effect != .sessionMutation
  }

  /// Returns whether the step was accepted. A caller that reports success to
  /// the system — the media keys do — must not assume it was.
  @discardableResult
  package func playNext(session: any SessionProviding) -> Bool {
    step(to: queue?.nextIndex(), session: session)
  }

  @discardableResult
  package func playPrevious(session: any SessionProviding) -> Bool {
    step(to: queue?.previousIndex(), session: session)
  }

  package var canSetPlaybackMode: Bool {
    canStartNonSessionOperation
      && queueContext.map(Self.allowsUserQueueEditing) != false
  }

  @discardableResult
  package func setPlaybackMode(_ mode: PlaybackMode) -> Bool {
    guard canSetPlaybackMode else { return false }
    playbackMode = mode
    return true
  }

  package func canEditQueue(
    accountID: Int64,
    revision: UInt64,
    session: any SessionProviding
  ) -> Bool {
    acceptsQueueCommand(
      accountID: accountID,
      revision: revision,
      session: session
    )
  }

  package func canQueueNext(
    context: PlaybackContext,
    accountID: Int64,
    revision: UInt64,
    session: any SessionProviding
  ) -> Bool {
    if queue == nil {
      return acceptsQueueCreation(
        context: context,
        accountID: accountID,
        revision: revision,
        session: session
      )
    }
    return acceptsQueueCommand(
      accountID: accountID,
      revision: revision,
      session: session
    )
  }

  /// Places one unique song directly after the current entry. With an active
  /// queue this changes no audio state and never resolves a URL; an existing
  /// row is moved instead of duplicated. Without a queue, fixed Kumone
  /// behavior starts the song through the ordinary formal playback path.
  @discardableResult
  package func queueNext(
    _ track: Track, context: PlaybackContext, accountID: Int64, revision: UInt64,
    session: any SessionProviding
  ) -> Bool {
    enqueue(
      [track], next: true, context: context, accountID: accountID, revision: revision,
      session: session)
  }

  @discardableResult
  package func enqueue(
    _ tracks: [Track], next: Bool, context: PlaybackContext, accountID: Int64, revision: UInt64,
    session: any SessionProviding
  ) -> Bool {
    guard
      canQueueNext(context: context, accountID: accountID, revision: revision, session: session),
      !tracks.isEmpty
    else { return false }
    guard let held = queue else {
      return play(tracks: tracks, startIndex: 0, context: context, session: session)
    }
    let currentID = queueTracks[held.currentIndex].id
    var seen = Set<Int64>()
    let incoming = tracks.filter { $0.id != currentID && seen.insert($0.id).inserted }
    let incomingIDs = Set(incoming.map(\.id))
    let oldTracks = queueTracks
    var updated = next ? oldTracks.filter { !incomingIDs.contains($0.id) } : oldTracks
    let insertion = next ? updated.firstIndex(where: { $0.id == currentID })! + 1 : updated.count
    let additions =
      next ? incoming : incoming.filter { item in !oldTracks.contains { $0.id == item.id } }
    guard !additions.isEmpty else { return true }
    var contexts = queueTrackContexts
    for track in additions { contexts[track.id] = context }
    updated.insert(contentsOf: additions, at: insertion)
    let newIndices = Dictionary(
      uniqueKeysWithValues: updated.enumerated().map { ($0.element.id, $0.offset) })
    let mapping = Dictionary(
      uniqueKeysWithValues: oldTracks.enumerated().map { ($0.offset, newIndices[$0.element.id]!) })
    let current = newIndices[currentID]!
    var order: [Int] = []
    if held.mode == .shuffle {
      order = held.shuffleOrder.filter { !next || !incomingIDs.contains(oldTracks[$0].id) }.map {
        mapping[$0]!
      }
      let addedIndices = additions.map { newIndices[$0.id]! }
      let slot = next ? order.firstIndex(of: current)! + 1 : order.count
      order.insert(contentsOf: next ? addedIndices : addedIndices.shuffled(using: &rng), at: slot)
    }
    guard
      let changed = PlaybackQueue(
        count: updated.count, startIndex: current, mode: held.mode, shuffleOrder: order)
    else { return false }
    guard changed != held || updated != oldTracks || contexts != queueTrackContexts else {
      return true
    }
    remapAttempt(currentIndex: current, entryCount: updated.count) { mapping[$0] }
    queueTracks = updated
    queueTrackContexts = contexts
    queue = changed
    queueWasEdited()
    return true
  }

  @discardableResult
  package func reorderUpcoming(
    songIDs: [Int64], accountID: Int64, revision: UInt64, session: any SessionProviding
  ) -> Bool {
    guard acceptsQueueCommand(accountID: accountID, revision: revision, session: session),
      let held = queue
    else { return false }
    let upcoming = held.upcomingIndices
    guard songIDs.count == upcoming.count, Set(songIDs) == Set(upcoming.map { queueTracks[$0].id })
    else { return false }
    let old = queueTracks
    let indices = Dictionary(
      uniqueKeysWithValues: old.enumerated().map { ($0.element.id, $0.offset) })
    if held.mode == .shuffle {
      let prefix = held.shuffleOrder.prefix(
        through: held.shuffleOrder.firstIndex(of: held.currentIndex)!)
      queue = PlaybackQueue(
        count: held.count, startIndex: held.currentIndex, mode: held.mode,
        shuffleOrder: Array(prefix) + songIDs.map { indices[$0]! })
    } else {
      queueTracks = Array(old.prefix(held.currentIndex + 1)) + songIDs.map { old[indices[$0]!] }
      let newIndices = Dictionary(
        uniqueKeysWithValues: queueTracks.enumerated().map { ($0.element.id, $0.offset) })
      remapAttempt(currentIndex: held.currentIndex, entryCount: held.count) {
        newIndices[old[$0].id]
      }
    }
    queueWasEdited()
    return true
  }

  /// Jumps through the same local-first path as Previous/Next.
  @discardableResult
  package func playQueueEntry(
    songID: Int64,
    accountID: Int64,
    revision: UInt64,
    session: any SessionProviding
  ) -> Bool {
    guard
      acceptsQueueCommand(
        accountID: accountID,
        revision: revision,
        session: session
      ), let target = queueTracks.firstIndex(where: { $0.id == songID }),
      target != queue?.currentIndex
    else { return false }
    return step(to: target, session: session)
  }

  @discardableResult
  package func removeQueueEntry(
    songID: Int64,
    accountID: Int64,
    revision: UInt64,
    session: any SessionProviding
  ) -> Bool {
    guard
      acceptsQueueCommand(
        accountID: accountID,
        revision: revision,
        session: session
      ), let index = queueTracks.firstIndex(where: { $0.id == songID })
    else { return false }
    return removeQueueEntry(
      at: index,
      session: session,
      emptyStatus: "Queue is empty",
      clearPersistedQueueWhenEmpty: true
    )
  }

  /// Keeps only the current song. With one entry every mode remains valid and
  /// no hidden played row can wrap back into an allegedly cleared Up Next.
  @discardableResult
  package func clearUpcoming(
    accountID: Int64,
    revision: UInt64,
    session: any SessionProviding
  ) -> Bool {
    guard
      acceptsQueueCommand(
        accountID: accountID,
        revision: revision,
        session: session
      ), let heldQueue = queue,
      queueTracks.indices.contains(heldQueue.currentIndex)
    else { return false }
    guard heldQueue.count > 1 else { return true }

    let oldCurrentIndex = heldQueue.currentIndex
    let current = queueTracks[oldCurrentIndex]
    guard
      let single = PlaybackQueue(
        count: 1,
        startIndex: 0,
        mode: heldQueue.mode,
        using: &rng
      )
    else { return false }
    remapAttempt(currentIndex: 0, entryCount: 1) { oldIndex in
      oldIndex == oldCurrentIndex ? 0 : nil
    }
    queueTracks = [current]
    queueTrackContexts = [current.id: queueTrackContexts[current.id]!]
    queue = single
    queueWasEdited()
    return true
  }

  package static func allowsUserQueueEditing(_ context: PlaybackContext) -> Bool {
    if case .personalFM = context { return false }
    return true
  }

  /// Queue commands and SwiftUI rows identify songs by id. Keep the selected
  /// occurrence while establishing one unique identity for every queue row.
  package static func uniqueQueue(
    _ tracks: [Track],
    selectedIndex: Int
  ) -> (tracks: [Track], currentIndex: Int)? {
    guard tracks.indices.contains(selectedIndex) else { return nil }
    let selectedID = tracks[selectedIndex].id
    var seen = Set<Int64>()
    var result: [Track] = []
    var currentIndex = 0
    for (index, track) in tracks.enumerated() {
      if track.id == selectedID, index != selectedIndex { continue }
      guard seen.insert(track.id).inserted else { continue }
      if index == selectedIndex { currentIndex = result.count }
      result.append(track)
    }
    return (result, currentIndex)
  }

  package func acceptsQueueCommand(
    accountID: Int64,
    revision: UInt64,
    session: any SessionProviding
  ) -> Bool {
    guard canStartNonSessionOperation,
      session.account?.userID == accountID,
      queueAccountID == accountID,
      queueRevision == revision,
      let context = queueContext,
      Self.allowsUserQueueEditing(context),
      queue != nil
    else { return false }
    return true
  }

  package func acceptsQueueCreation(
    context: PlaybackContext,
    accountID: Int64,
    revision: UInt64,
    session: any SessionProviding
  ) -> Bool {
    guard canStartNonSessionOperation,
      session.account?.userID == accountID,
      queueAccountID == nil,
      queueRevision == revision,
      Self.allowsUserQueueEditing(context),
      queue == nil
    else { return false }
    return true
  }

  package func remapAttempt(
    currentIndex: Int,
    entryCount: Int,
    using transform: (Int) -> Int?
  ) {
    guard var retry = attempt else { return }
    guard transform(retry.queueIndex) != nil else {
      attempt = nil
      return
    }
    retry.remapQueue(
      currentIndex: currentIndex,
      entryCount: entryCount,
      using: transform
    )
    attempt = retry
  }

  package func queueWasEdited() {
    queueRevision &+= 1
    onQueueEdited?()
  }

  package func queueDidAdvance() {
    // QueuePersistence's periodic position tick records the current index.
    // Advancing the cursor is not a content/order edit, so it must not bump
    // the optimistic command revision or request an extra immediate write.
  }

  package func queueWasReplaced() {
    queueRevision &+= 1
  }
}

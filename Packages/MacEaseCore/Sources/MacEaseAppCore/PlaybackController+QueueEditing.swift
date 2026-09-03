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
      _ track: Track,
      context: PlaybackContext,
      accountID: Int64,
      revision: UInt64,
      session: any SessionProviding
    ) -> Bool {
      guard canQueueNext(
        context: context,
        accountID: accountID,
        revision: revision,
        session: session
      ) else { return false }
      guard let heldQueue = queue else {
        // Kumone starts the requested song when Play Next has no current queue.
        // Use MacEase's ordinary local-first lifecycle instead of manufacturing
        // a pending or playing state that AudioOutput has not confirmed.
        return play(
          tracks: [track],
          startIndex: 0,
          context: context,
          session: session
        )
      }
  
      if let sourceIndex = queueTracks.firstIndex(where: { $0.id == track.id }) {
        if sourceIndex == heldQueue.currentIndex { return true }
        var updatedQueue = heldQueue
        guard let destinationIndex = updatedQueue.moveNext(from: sourceIndex) else {
          return false
        }
        var updatedTracks = queueTracks
        let existing = updatedTracks.remove(at: sourceIndex)
        updatedTracks.insert(existing, at: destinationIndex)
        let remapped = PlaybackQueue.remapForMoveNext(
          source: sourceIndex,
          destination: destinationIndex
        )
        remapAttempt(
          currentIndex: updatedQueue.currentIndex,
          entryCount: updatedQueue.count,
          using: { remapped($0) }
        )
        guard updatedQueue != heldQueue || updatedTracks != queueTracks else {
          return true
        }
        queueTracks = updatedTracks
        queue = updatedQueue
        queueWasEdited()
        return true
      }
  
      var updatedQueue = heldQueue
      let insertionIndex = updatedQueue.insertNext()
      var updatedTracks = queueTracks
      updatedTracks.insert(track, at: insertionIndex)
      remapAttempt(
        currentIndex: updatedQueue.currentIndex,
        entryCount: updatedQueue.count
      ) { oldIndex in
        oldIndex >= insertionIndex ? oldIndex + 1 : oldIndex
      }
      queueTracks = updatedTracks
      queue = updatedQueue
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
      guard acceptsQueueCommand(
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
      guard acceptsQueueCommand(
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
      guard acceptsQueueCommand(
        accountID: accountID,
        revision: revision,
        session: session
      ), let heldQueue = queue,
        queueTracks.indices.contains(heldQueue.currentIndex)
      else { return false }
      guard heldQueue.count > 1 else { return true }
  
      let oldCurrentIndex = heldQueue.currentIndex
      let current = queueTracks[oldCurrentIndex]
      guard let single = PlaybackQueue(
        count: 1,
        startIndex: 0,
        mode: heldQueue.mode,
        using: &rng
      ) else { return false }
      remapAttempt(currentIndex: 0, entryCount: 1) { oldIndex in
        oldIndex == oldCurrentIndex ? 0 : nil
      }
      queueTracks = [current]
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

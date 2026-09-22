import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

@MainActor
private struct QueueEditingRig {
  let transport = FakeTransport()
  let vault: FakeVault
  let arbiter = OperationArbiter()
  let output = FakeAudioOutput()
  let session: FakeSession
  let playback: PlaybackController
  let events = QueueLifecycleEvents()

  init() {
    let credential = makeCredential()
    vault = FakeVault(stored: credential)
    session = FakeSession(credential: credential)
    playback = PlaybackController(
      transport: transport,
      vault: vault,
      arbiter: arbiter,
      output: output
    )
    playback.attach(session: session)
    playback.onLifecycleEvent = { [events] event in events.values.append(event) }
  }

  func play(
    _ ids: [Int64],
    startIndex: Int = 0,
    mode: PlaybackMode = .sequential,
    context: PlaybackContext = .dailyRecommendations
  ) async {
    playback.playbackMode = mode
    await transport.setSongURL(
      .success(makeResolvedAsset(songID: ids[startIndex]))
    )
    playback.play(
      tracks: makeTracks(ids),
      startIndex: startIndex,
      context: context,
      session: session
    )
    await playback.settleForTesting()
  }
}

@MainActor
private final class QueueLifecycleEvents {
  var values: [PlaybackLifecycleEvent] = []
}

@Test @MainActor func mixedQueueSourcesSurviveEditsStorageAndPlayback() async throws {
  for mode in [PlaybackMode.sequential, .shuffle] {
    let rig = QueueEditingRig()
    let playlist = PlaybackContext.playlist(id: 7, name: "A")
    let search = PlaybackContext.searchResults(keywords: "B")
    let album = PlaybackContext.album(id: 8, name: "C")
    await rig.play([1, 2], mode: mode, context: playlist)
    #expect(rig.playback.enqueue(
      makeTracks([3, 4]), next: false, context: search, accountID: testAccount.userID,
      revision: rig.playback.queueRevision, session: rig.session))
    #expect(rig.playback.queueNext(
      makeTracks([2])[0], context: album, accountID: testAccount.userID,
      revision: rig.playback.queueRevision, session: rig.session))
    #expect(rig.playback.reorderUpcoming(
      songIDs: [4, 2, 3], accountID: testAccount.userID,
      revision: rig.playback.queueRevision, session: rig.session))
    #expect(rig.playback.removeQueueEntry(
      songID: 3, accountID: testAccount.userID, revision: rig.playback.queueRevision,
      session: rig.session))
    #expect(rig.playback.queueTrackContexts == [1: playlist, 2: album, 4: search])
    #expect(rig.events.values.count == 1)

    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("queue-sources-\(UUID()).sqlite").path
    defer {
      for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }
    let store = try LibraryStore(path: path)
    try await store.saveQueue(try #require(rig.playback.persistedQueue()), accountID: testAccount.userID)
    let reopened = try LibraryStore(path: path)
    #expect(try await reopened.queue(accountID: testAccount.userID + 1) == nil)
    let saved = try #require(try await reopened.queue(accountID: testAccount.userID))
    let restored = QueueEditingRig()
    restored.playback.restore(saved, accountID: testAccount.userID)
    #expect(restored.playback.queueTrackContexts == rig.playback.queueTrackContexts)
    await restored.transport.setSongURL(.success(makeResolvedAsset(songID: 4)))
    #expect(restored.playback.playQueueEntry(
      songID: 4, accountID: testAccount.userID, revision: restored.playback.queueRevision,
      session: restored.session))
    await restored.playback.settleForTesting()
    let started = try #require(restored.events.values.compactMap { event in
      if case .started(let instance) = event { return instance }
      return nil
    }.last)
    #expect(started.context == search)
    #expect(started.scrobbleContext.source == .search)
    #expect(started.scrobbleContext.sourceID == nil)
    #expect(restored.playback.clearUpcoming(
      accountID: testAccount.userID, revision: restored.playback.queueRevision,
      session: restored.session))
    #expect(restored.playback.queueTrackContexts == [4: search])
    restored.playback.stopForSessionChange()
    #expect(restored.playback.queueTrackContexts.isEmpty)
  }
}

@Test @MainActor func appendingADuplicateDoesNotChangeTheExistingEntriesSource() async {
  let rig = QueueEditingRig()
  let playlist = PlaybackContext.playlist(id: 7, name: "A")
  await rig.play([1, 2], context: playlist)
  #expect(rig.playback.enqueue(
    makeTracks([1, 2]), next: false, context: .searchResults(keywords: "B"),
    accountID: testAccount.userID, revision: rig.playback.queueRevision, session: rig.session))
  #expect(rig.playback.queueTrackContexts == [1: playlist, 2: playlist])
}

@Test @MainActor func startingAQueueRemovesDuplicateSongIdentities() async {
  let rig = QueueEditingRig()
  await rig.play([1, 2, 1, 3, 2, 4], startIndex: 2)

  #expect(rig.playback.persistedQueue()?.tracks.map(\.id) == [2, 1, 3, 4])
  #expect(rig.playback.queue?.currentIndex == 1)
  #expect(rig.playback.currentTrack?.id == 1)
  #expect(rig.playback.queueSnapshot?.upcoming.map(\.id) == [3, 4])
}

@Test @MainActor func playNextInsertsWithoutTouchingPlaybackOrTheNetwork() async throws {
  let rig = QueueEditingRig()
  await rig.play([1, 2, 3], startIndex: 1)
  rig.output.reportPosition(27)
  let snapshot = try #require(rig.playback.queueSnapshot)
  let calls = await rig.transport.recordedCalls()
  let teardowns = rig.output.teardownCount
  let lifecycleEvents = rig.events.values

  #expect(
    rig.playback.queueNext(
      makeTracks([4])[0],
      context: .dailyRecommendations,
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )

  #expect(rig.playback.persistedQueue()?.tracks.map(\.id) == [1, 2, 4, 3])
  #expect(rig.playback.currentTrack?.id == 2)
  #expect(rig.playback.queueSnapshot?.upcoming.map(\.id) == [4, 3])
  #expect(rig.playback.phase == .playing)
  #expect(rig.playback.positionSeconds == 27)
  #expect(rig.output.teardownCount == teardowns)
  #expect(await rig.transport.recordedCalls() == calls)
  #expect(rig.events.values == lifecycleEvents)
}

@Test @MainActor func playNextMovesAnExistingSongAndRemainsIdempotent() async throws {
  let rig = QueueEditingRig()
  await rig.play([1, 2, 3, 4], startIndex: 2)
  let first = try #require(rig.playback.queueSnapshot)

  #expect(
    rig.playback.queueNext(
      makeTracks([1])[0],
      context: .dailyRecommendations,
      accountID: first.accountID,
      revision: first.revision,
      session: rig.session
    )
  )
  #expect(rig.playback.persistedQueue()?.tracks.map(\.id) == [2, 3, 1, 4])
  #expect(rig.playback.currentTrack?.id == 3)

  let second = try #require(rig.playback.queueSnapshot)
  #expect(
    rig.playback.queueNext(
      makeTracks([1])[0],
      context: .dailyRecommendations,
      accountID: second.accountID,
      revision: second.revision,
      session: rig.session
    )
  )
  #expect(rig.playback.persistedQueue()?.tracks.map(\.id) == [2, 3, 1, 4])
  #expect(Set(rig.playback.persistedQueue()?.tracks.map(\.id) ?? []).count == 4)
}

@Test @MainActor func playNextWithoutAQueueUsesTheFormalPlaybackPath() async {
  let rig = QueueEditingRig()
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 1)))

  #expect(
    rig.playback.queueNext(
      makeTracks([1])[0],
      context: .dailyRecommendations,
      accountID: testAccount.userID,
      revision: 0,
      session: rig.session
    )
  )
  await rig.playback.settleForTesting()

  #expect(rig.playback.currentTrack?.id == 1)
  #expect(rig.playback.queue?.count == 1)
  #expect(rig.playback.phase == .playing)
  #expect(await rig.transport.recordedCalls() == [.resolveSongURL(1, .standard)])
  let starts = rig.events.values.filter {
    if case .started = $0 { true } else { false }
  }
  #expect(starts.count == 1)
}

@Test @MainActor func clickingAnUpcomingEntryUsesTheFormalPlaybackPath() async throws {
  let rig = QueueEditingRig()
  await rig.play([1, 2, 3])
  let snapshot = try #require(rig.playback.queueSnapshot)
  let teardowns = rig.output.teardownCount
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 3)))

  #expect(
    rig.playback.playQueueEntry(
      songID: 3,
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )
  await rig.playback.settleForTesting()

  #expect(rig.playback.currentTrack?.id == 3)
  #expect(rig.output.teardownCount == teardowns + 1)
  #expect(rig.playback.phase == .playing)
  #expect(
    await rig.transport.recordedCalls() == [
      .resolveSongURL(1, .standard),
      .resolveSongURL(3, .standard),
    ])
  let starts = rig.events.values.compactMap { event -> Int64? in
    guard case .started(let instance) = event else { return nil }
    return instance.track.id
  }
  #expect(starts == [1, 3])
}

@Test(arguments: PlaybackMode.allCases)
@MainActor
func queueJumpUsesTheFormalPathInEveryMode(mode: PlaybackMode) async throws {
  let rig = QueueEditingRig()
  await rig.play([1, 2, 3, 4], mode: mode)
  let snapshot = try #require(rig.playback.queueSnapshot)
  let target = try #require(snapshot.upcoming.first)
  await rig.transport.setSongURL(
    .success(makeResolvedAsset(songID: target.id))
  )

  #expect(
    rig.playback.playQueueEntry(
      songID: target.id,
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )
  await rig.playback.settleForTesting()

  #expect(rig.playback.currentTrack?.id == target.id)
  #expect(rig.playback.queue?.mode == mode)
}

@Test @MainActor func removingANonCurrentEntryOnlyRemapsQueueState() async throws {
  let rig = QueueEditingRig()
  await rig.play([1, 2, 3, 4], startIndex: 1, mode: .shuffle)
  rig.output.reportPosition(31)
  let snapshot = try #require(rig.playback.queueSnapshot)
  let target = try #require(snapshot.upcoming.last)
  let calls = await rig.transport.recordedCalls()
  let teardowns = rig.output.teardownCount
  let events = rig.events.values

  #expect(
    rig.playback.removeQueueEntry(
      songID: target.id,
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )

  #expect(rig.playback.currentTrack?.id == 2)
  #expect(rig.playback.phase == .playing)
  #expect(rig.playback.positionSeconds == 31)
  #expect(rig.output.teardownCount == teardowns)
  #expect(await rig.transport.recordedCalls() == calls)
  #expect(rig.events.values == events)
  #expect(rig.playback.queue?.shuffleOrder.sorted() == Array(0..<3))
}

@Test @MainActor func removingTheCurrentEntryFinishesOnceAndStartsItsSuccessor() async throws {
  let rig = QueueEditingRig()
  await rig.play([1, 2, 3], startIndex: 1)
  let snapshot = try #require(rig.playback.queueSnapshot)
  let teardowns = rig.output.teardownCount
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 3)))

  #expect(
    rig.playback.removeQueueEntry(
      songID: 2,
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )
  await rig.playback.settleForTesting()

  #expect(rig.playback.currentTrack?.id == 3)
  #expect(rig.output.teardownCount == teardowns + 1)
  #expect(rig.playback.persistedQueue()?.tracks.map(\.id) == [1, 3])
  let finished = rig.events.values.compactMap { event -> Int64? in
    guard case .finished(let instance, _, _) = event else { return nil }
    return instance.track.id
  }
  let started = rig.events.values.compactMap { event -> Int64? in
    guard case .started(let instance) = event else { return nil }
    return instance.track.id
  }
  #expect(finished == [2])
  #expect(started == [2, 3])
}

@Test(arguments: PlaybackMode.allCases)
@MainActor
func removingTheCurrentEntryKeepsEveryModeValid(
  mode: PlaybackMode
) async throws {
  let rig = QueueEditingRig()
  await rig.play([1, 2, 3, 4], startIndex: 1, mode: mode)
  let snapshot = try #require(rig.playback.queueSnapshot)
  let successor = try #require(snapshot.upcoming.first)
  await rig.transport.setSongURL(
    .success(makeResolvedAsset(songID: successor.id))
  )

  #expect(
    rig.playback.removeQueueEntry(
      songID: snapshot.current.id,
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )
  await rig.playback.settleForTesting()

  #expect(rig.playback.currentTrack?.id == successor.id)
  #expect(rig.playback.queue?.mode == mode)
  #expect(rig.playback.queue?.count == 3)
  if mode == .shuffle {
    #expect(rig.playback.queue?.shuffleOrder.sorted() == Array(0..<3))
  }
  let finishes = rig.events.values.filter {
    if case .finished = $0 { true } else { false }
  }
  #expect(finishes.count == 1)
}

@Test @MainActor func removingTheOnlyCurrentEntryUsesTheStoppedBoundaryOnce() async throws {
  let rig = QueueEditingRig()
  await rig.play([1])
  let snapshot = try #require(rig.playback.queueSnapshot)
  let teardowns = rig.output.teardownCount

  #expect(
    rig.playback.removeQueueEntry(
      songID: 1,
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )

  #expect(rig.playback.queue == nil)
  #expect(rig.playback.phase == .idle)
  #expect(rig.output.teardownCount == teardowns + 1)
  let finishes = rig.events.values.filter {
    if case .finished = $0 { true } else { false }
  }
  #expect(finishes.count == 1)
}

@Test @MainActor func removingCurrentRefusesWhenItsRemoteSuccessorCannotStart() async throws {
  let rig = QueueEditingRig()
  await rig.play([1, 2])
  let snapshot = try #require(rig.playback.queueSnapshot)
  let tracks = rig.playback.persistedQueue()?.tracks
  let events = rig.events.values
  let teardowns = rig.output.teardownCount
  let intentRevision = rig.playback.intentRevision
  let blockers = (0..<OperationArbiter.defaultMaximumConcurrentReads).map { index in
    rig.arbiter.begin(name: "Read \(index)", effect: .read)!
  }

  #expect(
    !rig.playback.removeQueueEntry(
      songID: 1,
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )

  #expect(rig.playback.persistedQueue()?.tracks == tracks)
  #expect(rig.playback.currentTrack?.id == 1)
  #expect(rig.playback.phase == .playing)
  #expect(rig.output.teardownCount == teardowns)
  #expect(rig.events.values == events)
  #expect(rig.playback.intentRevision == intentRevision)
  for blocker in blockers { #expect(rig.arbiter.end(blocker, outcome: .applied) == .applied) }
}

@Test(arguments: PlaybackMode.allCases)
@MainActor
func clearingUpcomingKeepsOneValidCurrentEntryInEveryMode(
  mode: PlaybackMode
) async throws {
  let rig = QueueEditingRig()
  await rig.play([1, 2, 3, 4], startIndex: 1, mode: mode)
  rig.output.reportPosition(18)
  let snapshot = try #require(rig.playback.queueSnapshot)
  let calls = await rig.transport.recordedCalls()
  let teardowns = rig.output.teardownCount
  let events = rig.events.values

  #expect(
    rig.playback.clearUpcoming(
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )

  #expect(rig.playback.currentTrack?.id == 2)
  #expect(rig.playback.queue?.count == 1)
  #expect(rig.playback.queue?.currentIndex == 0)
  #expect(rig.playback.queue?.mode == mode)
  #expect(rig.playback.queueSnapshot?.upcoming.isEmpty == true)
  #expect(rig.playback.positionSeconds == 18)
  #expect(rig.output.teardownCount == teardowns)
  #expect(await rig.transport.recordedCalls() == calls)
  #expect(rig.events.values == events)
}

@Test @MainActor func queueEditsRemapTheRetryBackToTheSameSong() async throws {
  let rig = QueueEditingRig()
  await rig.transport.setSongURL(.failure(URLError(.timedOut)))
  rig.playback.play(
    tracks: makeTracks([1, 2, 3]),
    startIndex: 1,
    context: .dailyRecommendations,
    session: rig.session
  )
  await rig.playback.settleForTesting()
  #expect(rig.playback.canPlayAgain)
  let snapshot = try #require(rig.playback.queueSnapshot)

  #expect(
    rig.playback.queueNext(
      makeTracks([1])[0],
      context: .dailyRecommendations,
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 2)))
  rig.playback.playAgain(session: rig.session)
  await rig.playback.settleForTesting()

  #expect(rig.playback.currentTrack?.id == 2)
  #expect(rig.playback.phase == .playing)
  #expect(
    await rig.transport.recordedCalls() == [
      .resolveSongURL(2, .standard),
      .resolveSongURL(2, .standard),
    ])
}

@Test @MainActor func removingAnEarlierEntryKeepsRetryAttachedToCurrentSong() async throws {
  let rig = QueueEditingRig()
  await rig.transport.setSongURL(.failure(URLError(.timedOut)))
  rig.playback.play(
    tracks: makeTracks([1, 2, 3, 4]),
    startIndex: 2,
    context: .dailyRecommendations,
    session: rig.session
  )
  await rig.playback.settleForTesting()
  let snapshot = try #require(rig.playback.queueSnapshot)

  #expect(
    rig.playback.removeQueueEntry(
      songID: 1,
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 3)))
  rig.playback.playAgain(session: rig.session)
  await rig.playback.settleForTesting()

  #expect(rig.playback.currentTrack?.id == 3)
  #expect(
    await rig.transport.recordedCalls() == [
      .resolveSongURL(3, .standard),
      .resolveSongURL(3, .standard),
    ])
}

@Test @MainActor func personalFMRejectsUserQueueEditsAndModeChanges() async throws {
  let rig = QueueEditingRig()
  await rig.play([1, 2, 3], context: .personalFM)
  let snapshot = try #require(rig.playback.queueSnapshot)

  #expect(!snapshot.allowsEditing)
  #expect(
    !rig.playback.queueNext(
      makeTracks([4])[0],
      context: .personalFM,
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )
  #expect(!rig.playback.setPlaybackMode(.shuffle))
  #expect(rig.playback.persistedQueue()?.tracks.map(\.id) == [1, 2, 3])
}

@Test @MainActor func heartbeatQueueEditsDoNotAskRadioForAContinuation() async throws {
  let rig = QueueEditingRig()
  let radio = RadioCoordinator(
    transport: rig.transport,
    vault: rig.vault,
    arbiter: rig.arbiter
  )
  radio.attach(playback: rig.playback)
  rig.playback.onPlaybackChanged = { [weak radio] revision in
    radio?.playbackChanged(revision: revision, session: rig.session)
  }
  await rig.play(
    [1, 2, 3],
    context: .heartbeatMode(seedName: "track-1")
  )
  let snapshot = try #require(rig.playback.queueSnapshot)
  let calls = await rig.transport.recordedCalls()

  #expect(
    rig.playback.queueNext(
      makeTracks([4])[0],
      context: .heartbeatMode(seedName: "track-1"),
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )
  await radio.settleForTesting()

  #expect(await rig.transport.recordedCalls() == calls)
  #expect(rig.playback.queueContext == .heartbeatMode(seedName: "track-1"))
}

@Test @MainActor func sessionMutationRejectsEvenALocallyAvailableQueueEdit() async throws {
  let rig = QueueEditingRig()
  await rig.play([1, 2])
  let snapshot = try #require(rig.playback.queueSnapshot)
  rig.playback.prepareForSessionMutation()

  #expect(
    !rig.playback.queueNext(
      makeTracks([3])[0],
      context: .dailyRecommendations,
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )
  #expect(rig.playback.persistedQueue()?.tracks.map(\.id) == [1, 2])
  rig.playback.finishSessionMutationPreparation()
}

@Test @MainActor func aQueueActionCapturedForAccountACannotEditAccountB() async throws {
  let rig = QueueEditingRig()
  await rig.play([1, 2])
  let stale = try #require(rig.playback.queueSnapshot)

  rig.session.account = otherAccount
  let otherCredential = makeCredential("other")
  rig.session.validatedCredential = otherCredential
  await rig.vault.setStored(otherCredential)
  await rig.transport.setSongURL(.success(makeResolvedAsset(songID: 8)))
  rig.playback.play(
    tracks: makeTracks([8, 9]),
    startIndex: 0,
    context: .downloads,
    session: rig.session
  )
  await rig.playback.settleForTesting()

  #expect(
    !rig.playback.queueNext(
      makeTracks([7])[0],
      context: .dailyRecommendations,
      accountID: stale.accountID,
      revision: stale.revision,
      session: rig.session
    )
  )
  #expect(rig.playback.persistedQueue()?.tracks.map(\.id) == [8, 9])
}

@Test @MainActor func everyAcceptedQueueEditRequestsImmediatePersistence() async throws {
  let rig = QueueEditingRig()
  await rig.play([1, 2, 3])
  var saves = 0
  rig.playback.onQueueEdited = { saves += 1 }
  let snapshot = try #require(rig.playback.queueSnapshot)

  #expect(
    rig.playback.queueNext(
      makeTracks([4])[0],
      context: .dailyRecommendations,
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )

  #expect(saves == 1)
}

@Test @MainActor func naturalAdvanceKeepsQueueCommandsUsingTheirCapturedRevision() async throws {
  let advancing = QueueEditingRig()
  await advancing.play([1, 2])
  let captured = try #require(advancing.playback.queueSnapshot)
  await advancing.transport.setSongURL(.success(makeResolvedAsset(songID: 2)))
  advancing.output.reportPlayedToEnd()
  await advancing.playback.settleForTesting()

  #expect(advancing.playback.currentTrack?.id == 2)
  #expect(advancing.playback.queueSnapshot?.revision == captured.revision)
  #expect(
    advancing.playback.queueNext(
      makeTracks([3])[0],
      context: .dailyRecommendations,
      accountID: captured.accountID,
      revision: captured.revision,
      session: advancing.session
    )
  )
  #expect(advancing.playback.queueSnapshot?.revision != captured.revision)
  #expect(
    !advancing.playback.queueNext(
      makeTracks([4])[0],
      context: .dailyRecommendations,
      accountID: captured.accountID,
      revision: captured.revision,
      session: advancing.session
    )
  )

  let removing = QueueEditingRig()
  await removing.play([1, 2])
  let removeCapture = try #require(removing.playback.queueSnapshot)
  await removing.transport.setSongURL(.success(makeResolvedAsset(songID: 2)))
  removing.output.reportPlayedToEnd()
  await removing.playback.settleForTesting()

  #expect(
    removing.playback.removeQueueEntry(
      songID: 1,
      accountID: removeCapture.accountID,
      revision: removeCapture.revision,
      session: removing.session
    )
  )
}

@Test @MainActor func theImmediatePersistenceCallbackStoresTheEditedQueue() async throws {
  let rig = QueueEditingRig()
  let store = try LibraryStore(path: LibraryStore.inMemoryPath)
  let persistence = QueuePersistence(store: store, playback: rig.playback)
  await persistence.activate(accountID: testAccount.userID)
  await rig.play([1, 2, 3])
  var saveTask: Task<Void, Never>?
  rig.playback.onQueueEdited = {
    saveTask = Task { await persistence.save() }
  }
  let snapshot = try #require(rig.playback.queueSnapshot)

  #expect(
    rig.playback.queueNext(
      makeTracks([4])[0],
      context: .dailyRecommendations,
      accountID: snapshot.accountID,
      revision: snapshot.revision,
      session: rig.session
    )
  )
  await saveTask?.value

  let stored = try await store.queue(accountID: testAccount.userID)
  #expect(stored?.tracks.map(\.id) == [1, 4, 2, 3])
  #expect(stored?.currentIndex == 0)
  await persistence.deactivate()
}

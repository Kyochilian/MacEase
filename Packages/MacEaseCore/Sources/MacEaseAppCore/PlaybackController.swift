import Foundation
import NeteaseKit
import Observation

/// Read-only queue data for UI and command routing. It is rebuilt from the
/// controller's one queue; no view owns or mutates a parallel track array.
package struct PlaybackQueueSnapshot: Equatable, Sendable {
  package let accountID: Int64
  package let revision: UInt64
  package let current: Track
  package let upcoming: [Track]
  package let mode: PlaybackMode
  package let context: PlaybackContext
  package let allowsEditing: Bool
}

/// Explicit queue playback. A queue starts only from a user action. Confirmed
/// unavailable resources recover through a fixed downward quality list and a
/// bounded set of queue entries; ordinary transport failures stop with Play
/// Again. There is no prefetch, polling or unbounded retry.
@MainActor
@Observable
package final class PlaybackController {
  package enum Phase: Equatable {
    case idle
    case resolving
    case playing
    case paused
    case finished
    case failed
  }

  package enum SleepTimerState: Equatable {
    case off
    case armed(Date)
    case finishingTrack
  }

  private enum EntrySource {
    case local(PlaybackResource)
    case remote(OperationToken)
  }

  package enum StopReason {
    case explicit
    case sessionChange
    case deletedDownload
    case emptiedQueue(status: String, clearPersistedQueue: Bool)
    case sleepTimer(status: String)
  }

  private static let volumeDefaultsKey = "playback.volume"

  @ObservationIgnored private let transport: any NeteaseTransporting
  @ObservationIgnored private let vault: any CredentialStoring
  @ObservationIgnored package let arbiter: OperationArbiter
  @ObservationIgnored private var operationToken: OperationToken?
  @ObservationIgnored private var gate = PlaybackIntentGate()
  @ObservationIgnored package var rng = SystemRandomNumberGenerator()
  @ObservationIgnored private var playTask: Task<Void, Never>?
  @ObservationIgnored private let output: any AudioOutput
  @ObservationIgnored private var hasLoadedItem = false
  /// The retry entry point for the track being attempted. Created before the
  /// resolve request, cleared only by a terminal failure or a new intent.
  @ObservationIgnored package var attempt: PlaybackAttempt?
  @ObservationIgnored private var currentAssetSummary: String?
  @ObservationIgnored package let monotonicNow: @MainActor () -> TimeInterval
  @ObservationIgnored package var playbackAccountID: Int64?
  @ObservationIgnored package var queueAccountID: Int64?
  @ObservationIgnored package var lifecycle: ActiveLifecycle?
  package var sessionMutationPending = false
  @ObservationIgnored private var activeToken: PlaybackIntentGate.Token?
  @ObservationIgnored package var queueTracks: [Track] = []
  /// Where the queue came from. A restored queue that says only "these forty
  /// tracks" cannot tell the user what they were listening to.
  @ObservationIgnored package private(set) var queueContext: PlaybackContext?
  @ObservationIgnored private weak var attachedSession: (any SessionProviding)?
  @ObservationIgnored private weak var offlineDownloads: DownloadCoordinator?
  @ObservationIgnored package var sleepTask: Task<Void, Never>?
  @ObservationIgnored package var sleepGeneration = 0
  /// Monotonic identity of the latest accepted playback intent. Queue
  /// progression does not bump it; explicit Play/Next/Previous/Play Again,
  /// Stop and terminal teardown do.
  @ObservationIgnored package private(set) var intentRevision: UInt64 = 0
  /// Playback the machine interrupted, not the user. Kept apart from an
  /// ordinary pause so the status can say why it stopped, and so a wake or a
  /// reconnect does not claim credit for a pause the user asked for.
  @ObservationIgnored private var machinePausedReason: MachinePause?
  /// Wired by the composition root. Only the user-facing `stop()` invokes it;
  /// session cleanup uses `stopForSessionChange()` and preserves the row.
  @ObservationIgnored package var onExplicitStop: (@MainActor () -> Void)?
  /// Queue edits need an immediate persistence pass rather than waiting for
  /// the slow playback-position tick.
  @ObservationIgnored package var onQueueEdited: (@MainActor () -> Void)?
  /// One narrow notification for the owner of server-generated queues. The
  /// revision tells it whether an in-flight response still belongs to the
  /// accepted intent; unchanged revisions are ordinary queue progression.
  @ObservationIgnored package var onPlaybackChanged:
    (@MainActor (UInt64) -> Void)?
  /// The only feedback seam: start is emitted after AudioOutput confirms
  /// playing, finish after the same instance is settled exactly once.
  @ObservationIgnored package var onLifecycleEvent:
    (@MainActor (PlaybackLifecycleEvent) -> Void)?

  /// Why the machine, rather than the user, stopped playback.
  package enum MachinePause: Equatable, Sendable {
    case systemSleep
    case audioOutputLost
  }

  package private(set) var phase: Phase = .idle
  package var queue: PlaybackQueue?
  package var queueRevision: UInt64 = 0
  package var sleepTimer: SleepTimerState = .off
  package private(set) var trackName: String?
  package private(set) var positionSeconds: Double = 0
  /// A read-through position for animation-rate UI such as YRC highlighting.
  /// It comes from the same AudioOutput clock as `positionSeconds`; it is not
  /// another cursor and falls back to the observed snapshot while inactive.
  package var presentationPositionSeconds: Double {
    guard phase == .playing,
      let live = output.currentPositionSeconds,
      live.isFinite,
      live >= 0
    else { return positionSeconds }
    if let durationSeconds, durationSeconds.isFinite, durationSeconds >= 0 {
      return min(live, durationSeconds)
    }
    return live
  }
  /// Bumped whenever position moved for a reason other than the clock
  /// advancing: a seek, a newly loaded item, or a teardown. `PlaybackSnapshot`
  /// carries it so a system surface that extrapolates elapsed time knows when
  /// its extrapolation became wrong.
  package private(set) var positionEpoch = 0
  package private(set) var durationSeconds: Double?
  /// Non-nil only while AVFoundation owns a completed offline file. Download
  /// deletion consults this shared root cause and stops before moving it.
  package private(set) var activeOfflineDownloadID: OfflineDownloadID?
  package private(set) var status = "Play a track from the library"
  package var quality: PlaybackQuality = .standard
  package var sleepStopsImmediately = false

  package var playbackMode: PlaybackMode = .sequential {
    didSet {
      guard playbackMode != oldValue else { return }
      let oldQueue = queue
      queue?.setMode(playbackMode, using: &rng)
      if queue != oldQueue { queueWasEdited() }
    }
  }

  package var volume: Float = 1 {
    didSet {
      output.volume = volume
      UserDefaults.standard.set(Double(volume), forKey: Self.volumeDefaultsKey)
    }
  }

  package var isMuted = false {
    didSet { output.isMuted = isMuted }
  }

  package var isResolving: Bool { phase == .resolving }
  package var isActive: Bool {
    phase == .resolving || phase == .playing || phase == .paused
  }
  package var canPlayAgain: Bool {
    // A queue restored at launch also has an entry point, and it sits at
    // `.idle` because nothing has failed. Every other `.idle` path clears the
    // attempt, so this cannot resurrect an abandoned one.
    attempt != nil && (phase == .failed || phase == .idle)
  }
  /// Whether the retry will resume playback or restore a paused track, so the
  /// button can say which.
  package var retryResumesPlayback: Bool { attempt?.desiredState != .paused }
  package var canStepNext: Bool { queue?.nextIndex() != nil }
  package var canStepPrevious: Bool { queue?.previousIndex() != nil }
  package func canPlayNext(session: any SessionProviding) -> Bool {
    canStep(to: queue?.nextIndex(), session: session)
  }
  package func canPlayPrevious(session: any SessionProviding) -> Bool {
    canStep(to: queue?.previousIndex(), session: session)
  }
  package var queuePosition: String? {
    queue.map { "\($0.currentIndex + 1) of \($0.count)" }
  }
  /// The entry a similar-songs seed refers to, when a queue is active.
  package var currentTrack: Track? {
    guard let index = queue?.currentIndex, queueTracks.indices.contains(index) else {
      return nil
    }
    return queueTracks[index]
  }

  package var queueSnapshot: PlaybackQueueSnapshot? {
    guard let queue, let context = queueContext, let accountID = queueAccountID,
      queueTracks.indices.contains(queue.currentIndex)
    else { return nil }
    return PlaybackQueueSnapshot(
      accountID: accountID,
      revision: queueRevision,
      current: queueTracks[queue.currentIndex],
      upcoming: queue.upcomingIndices.map { queueTracks[$0] },
      mode: queue.mode,
      context: context,
      allowsEditing: Self.allowsUserQueueEditing(context)
    )
  }

  /// The read-only projection a system media surface consumes. Derived on
  /// every read, so it cannot hold a stale copy of what is playing. `liked` is
  /// not known here — the library owns it — so the caller supplies it.
  package func snapshot(liked: LikedState) -> PlaybackSnapshot {
    let track = currentTrack
    let state: PlaybackSnapshot.State =
      switch phase {
      case .playing: .playing
      case .paused: .paused
      // Resolving, finished and failed have no audio. They project to stopped
      // while keeping the chosen track visible, so the system does not blank
      // out between two tracks of one queue.
      case .idle, .resolving, .finished, .failed: .stopped
      }
    return PlaybackSnapshot(
      state: state,
      trackID: track?.id,
      title: track?.name ?? trackName,
      artist: track?.artistDisplayName,
      albumTitle: track?.album?.name,
      artworkURL: track?.artworkURL,
      artworkIdentity: track?.artworkURL.map {
        "\(track?.album?.id.map(String.init) ?? "none")|\($0.absoluteString)"
      },
      durationSeconds: durationSeconds,
      elapsedSeconds: positionSeconds,
      positionEpoch: positionEpoch,
      canStepNext: canStepNext,
      canStepPrevious: canStepPrevious,
      liked: track == nil ? .unknown : liked
    )
  }

  package init(
    transport: any NeteaseTransporting,
    vault: any CredentialStoring,
    arbiter: OperationArbiter,
    output: any AudioOutput = AVPlayerAudioOutput(),
    monotonicNow: @escaping @MainActor () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    }
  ) {
    self.transport = transport
    self.vault = vault
    self.arbiter = arbiter
    self.output = output
    self.monotonicNow = monotonicNow
    if let stored = UserDefaults.standard.object(forKey: Self.volumeDefaultsKey)
      as? Double
    {
      volume = Float(min(max(stored, 0), 1))
    }
    output.volume = volume
    output.isMuted = isMuted
  }

  /// Wires the session auto-advance needs for its preflight check.
  package func attach(session: any SessionProviding) {
    attachedSession = session
  }

  package func attach(downloads: DownloadCoordinator) {
    offlineDownloads = downloads
  }

  /// Starts answering for what the machine does: sleep, wake, the output
  /// device going away and the network coming and going.
  package func observe(system observer: any SystemEventObserving) {
    observer.onEvent = { [weak self] event in
      self?.handle(system: event)
    }
    observer.start()
  }

  /// The Gate C decisions, in one place.
  ///
  /// Only two events stop playback, and both are cases where continuing would
  /// be wrong rather than merely unhelpful: audio during sleep is not heard,
  /// and audio after the headphones come out is heard by the room. Everything
  /// else reports and leaves the queue alone — in particular, losing the
  /// network does not stop a track that is already buffered, and regaining it
  /// never restarts anything on its own.
  package func handle(system event: SystemPlaybackEvent) {
    switch event {
    case .willSleep:
      pauseForMachine(.systemSleep, status: "Paused for sleep")
    case .didWake:
      guard machinePausedReason == .systemSleep else { return }
      machinePausedReason = nil
      // The song URL is short-lived and the machine was away for an unknown
      // length of time, so the held URL may already be dead. Resume is left to
      // the user, and it re-resolves if the item has expired.
      status = "Paused while asleep; press Resume to continue"
    case .audioOutputDeviceLost:
      pauseForMachine(.audioOutputLost, status: "Paused: the output device was disconnected")
    case .audioOutputDeviceChanged:
      // The previous device still exists, so this is the user choosing a
      // different destination. AVPlayer follows the system default on its own.
      guard isActive else { return }
      status = phase == .playing ? "Playing on the new output device" : status
    case .networkReachabilityChanged(let reachable):
      handleReachability(reachable)
    }
  }

  private func pauseForMachine(_ reason: MachinePause, status newStatus: String) {
    if phase == .resolving {
      // Resolution has not handed an item to AudioOutput yet. Record the
      // machine interruption on the attempt instead of touching an output
      // that cannot be paused; startPlayback will honour this desired state.
      guard attempt != nil else { return }
      attempt?.desiredState = .paused
      machinePausedReason = reason
      status = newStatus
      return
    }
    guard phase == .playing, pause() else { return }
    machinePausedReason = reason
    status = newStatus
  }

  private func handleReachability(_ reachable: Bool) {
    guard !reachable else {
      // Coming back does not resume and does not re-request. It only tells a
      // user staring at a failure that the button in front of them can now
      // work, which they otherwise have to discover by pressing it.
      guard phase == .failed, attempt != nil else { return }
      status =
        "Network is back; "
        + (retryResumesPlayback ? "Play Again" : "Restore Paused")
        + " re-resolves the song URL"
      return
    }
    guard isActive || phase == .failed else { return }
    status =
      phase == .playing
      // A playing item has buffered audio, and it keeps it. Stopping here
      // would throw away sound the user can still hear.
      ? "Network unavailable; playing from what is already buffered"
      : "Network unavailable"
  }

  @discardableResult
  package func play(
    tracks: [Track],
    startIndex: Int,
    context: PlaybackContext,
    session: any SessionProviding
  ) -> Bool {
    guard let account = session.account else {
      status = "Validate the session before playback"
      return false
    }
    guard let normalized = Self.uniqueQueue(tracks, selectedIndex: startIndex) else {
      return false
    }
    let queueTracks = normalized.tracks
    let queueStartIndex = normalized.currentIndex
    guard
      let queue = PlaybackQueue(
        count: queueTracks.count,
        startIndex: queueStartIndex,
        mode: playbackMode,
        using: &rng
      )
    else { return false }
    acceptExplicitPlaybackIntent()
    let requestedQuality = quality
    guard let source = entrySource(
      songID: queueTracks[queueStartIndex].id,
      requestedQuality: requestedQuality,
      account: account
    ) else { return false }

    self.queueTracks = queueTracks
    queueContext = context
    queueAccountID = account.userID
    self.queue = queue
    queueWasReplaced()
    clearPendingSleepStop()
    startEntry(
      at: queueStartIndex,
      account: account,
      session: session,
      auto: false,
      requestedQuality: requestedQuality,
      source: source
    )
    return true
  }

  /// Starts the saved quality represented by this row. It does not read the
  /// current online-quality picker, so a downloaded lossless item cannot miss
  /// merely because the user has since selected Standard for streaming.
  package func playDownloaded(
    _ download: OfflineDownload,
    session: any SessionProviding
  ) {
    guard let account = session.account, account.userID == download.accountID else {
      status = "This download belongs to another account"
      return
    }
    guard
      let queue = PlaybackQueue(
        count: 1,
        startIndex: 0,
        mode: playbackMode,
        using: &rng
    )
    else { return }
    acceptExplicitPlaybackIntent()
    guard let source = entrySource(
      songID: download.track.id,
      requestedQuality: download.requestedQuality,
      account: account,
      preferredDownload: download
    ) else { return }
    queueTracks = [download.track]
    queueContext = .downloads
    queueAccountID = account.userID
    self.queue = queue
    queueWasReplaced()
    clearPendingSleepStop()
    startEntry(
      at: 0,
      account: account,
      session: session,
      auto: false,
      requestedQuality: download.requestedQuality,
      source: source
    )
  }

  /// What the queue is, in a form that survives a relaunch, or nil when there
  /// is nothing worth restoring.
  ///
  /// It carries no URL. A song URL expires in minutes, so storing one would
  /// guarantee a dead address on the next launch; the track and the position
  /// are what survive, and resuming re-resolves.
  package func persistedQueue() -> PersistedQueue? {
    guard let queue, let context = queueContext, !queueTracks.isEmpty else {
      return nil
    }
    return PersistedQueue(
      tracks: queueTracks,
      currentIndex: queue.currentIndex,
      mode: playbackMode,
      context: context,
      positionSeconds: currentPosition(),
      quality: attempt?.quality ?? quality,
      wasPlaying: phase == .playing
    )
  }

  /// Puts a stored queue back without playing anything.
  ///
  /// Restoring must not issue a request: the user has just launched the app
  /// and has not asked for audio. It rebuilds the queue and leaves a retry
  /// entry point, so continuing costs the same single resolve that any other
  /// explicit play does, and lands at the position that was stored.
  package func restore(_ persisted: PersistedQueue, accountID: Int64? = nil) {
    guard !isActive, !persisted.tracks.isEmpty else { return }
    guard
      let normalized = Self.uniqueQueue(
        persisted.tracks,
        selectedIndex: persisted.currentIndex
      )
    else { return }
    guard
      let queue = PlaybackQueue(
        count: normalized.tracks.count,
        startIndex: normalized.currentIndex,
        mode: persisted.mode,
        using: &rng
      )
    else { return }

    queueTracks = normalized.tracks
    queueContext = persisted.context
    queueAccountID = accountID ?? attachedSession?.account?.userID
    self.queue = queue
    playbackMode = persisted.mode
    queueWasReplaced()
    quality = persisted.quality
    let track = normalized.tracks[normalized.currentIndex]
    trackName = track.name
    attempt = PlaybackAttempt(
      songID: track.id,
      quality: persisted.quality,
      queueIndex: normalized.currentIndex,
      queueEntryCount: normalized.tracks.count,
      resumePosition: persisted.positionSeconds,
      desiredState: persisted.wasPlaying ? .playing : .paused
    )
    movePosition(to: persisted.positionSeconds)
    status =
      "Restored \(persisted.context.label); "
      + (persisted.wasPlaying ? "Resume" : "Restore Paused")
      + " continues from \(Int(persisted.positionSeconds))s"
  }

  package func playAgain(session: any SessionProviding) {
    guard let account = session.account else {
      status = "Validate the session before playback"
      return
    }
    guard let previousAttempt = attempt else { return }
    let retry = previousAttempt.restartedRecovery(
      queueEntryCount: queue?.count ?? 1
    )
    guard queueTracks.indices.contains(retry.queueIndex),
      queueTracks[retry.queueIndex].id == retry.songID
    else { return }
    acceptExplicitPlaybackIntent()
    guard let source = entrySource(
      songID: retry.songID,
      requestedQuality: retry.quality,
      account: account
    ) else { return }

    clearPendingSleepStop()
    startEntry(
      at: retry.queueIndex,
      account: account,
      session: session,
      auto: false,
      requestedQuality: retry.quality,
      source: source,
      retry: retry
    )
  }

  /// Test seam: awaits the task the last explicit action started, so a test
  /// can assert on settled state without polling.
  package func settleForTesting() async {
    await playTask?.value
  }

  @discardableResult
  package func pause() -> Bool {
    guard phase == .playing, hasLoadedItem else { return false }
    pauseLifecycleClock()
    output.pause()
    phase = .paused
    attempt?.desiredState = .paused
    // A user pause owns the pause. `pauseForMachine` re-stamps this
    // immediately afterwards for the two cases that are not the user.
    machinePausedReason = nil
    status = "Paused"
    return true
  }

  @discardableResult
  package func resume() -> Bool {
    guard phase == .paused, hasLoadedItem else { return false }
    output.play()
    phase = .playing
    attempt?.desiredState = .playing
    machinePausedReason = nil
    status = currentAssetSummary.map { "Playing: " + $0 } ?? "Playing"
    return true
  }

  /// Local AVPlayer seek; it never issues a NetEase request. Returns whether
  /// there was something to seek within.
  @discardableResult
  package func seek(to seconds: Double) -> Bool {
    guard
      phase == .playing || phase == .paused,
      hasLoadedItem,
      let duration = durationSeconds,
      let token = activeToken
    else { return false }

    let target = min(max(seconds, 0), duration)
    movePosition(to: target)
    attempt?.resumePosition = target
    Task {
      do {
        try await output.seek(to: target)
        try checkCurrent(token)
      } catch {
        // Superseded by a newer seek or intent; the newer owner updates state.
      }
    }
    return true
  }

  package func stop() {
    stop(reason: .explicit)
  }

  /// Removes session-scoped playback without interpreting the identity change
  /// as the user discarding their saved queue.
  package func stopForSessionChange() {
    stop(reason: .sessionChange)
  }

  /// Ends the current listening instance while the old credential is still
  /// valid, but keeps the queue and retry checkpoint until the session owner
  /// knows whether its mutation succeeded. The pending flag closes the local
  /// download bypass while feedback awaits the network.
  package func prepareForSessionMutation() {
    sessionMutationPending = true
    guard queue != nil || attempt != nil || lifecycle != nil else { return }
    let desiredState = attempt?.desiredState
      ?? (phase == .paused ? DesiredPlaybackState.paused : .playing)
    attempt = attempt?.checkpointed(
      at: currentPosition(),
      desiredState: desiredState
    )
    finishLifecycle()
    gate.cancel()
    playTask?.cancel()
    playTask = nil
    if let operationToken {
      releaseResolution(operationToken, outcome: .cancelled)
    }
    machinePausedReason = nil
    clearPendingSleepStop()
    releasePlayback()
    phase = attempt == nil ? .idle : .failed
    status = attempt == nil
      ? "Session change is preparing"
      : "Playback settled for a session change; Play Again remains available"
    playbackBecameInactive()
  }

  package func finishSessionMutationPreparation() {
    sessionMutationPending = false
  }

  /// Deleting the exact local resource AVPlayer owns first tears the player
  /// down. This is not interpreted as the user's Stop button, so it does not
  /// erase the account's persisted queue.
  package func stopForDeletedDownload() {
    stop(reason: .deletedDownload)
  }

  /// A server-generated queue removed its last entry, so there is nothing left
  /// to play. Also not the user's Stop button: the account's saved queue is
  /// left where it is.
  package func stopForEmptiedQueue(status newStatus: String) {
    stop(reason: .emptiedQueue(status: newStatus, clearPersistedQueue: false))
  }

  package func stop(reason: StopReason) {
    finishLifecycle()
    advanceIntentRevision()
    gate.cancel()
    playTask?.cancel()
    playTask = nil
    if let operationToken {
      // A song-URL resolve is a read: abandoning it has no server effect.
      releaseResolution(operationToken, outcome: .cancelled)
    }
    // An explicit Stop retires the retry entry point.
    attempt = nil
    machinePausedReason = nil
    queue = nil
    queueTracks = []
    queueContext = nil
    queueAccountID = nil
    queueWasReplaced()
    clearPendingSleepStop()
    releasePlayback()
    phase = .idle
    trackName = nil
    movePosition(to: 0)
    switch reason {
    case .explicit:
      status = "Playback stopped"
      onExplicitStop?()
    case .sessionChange:
      status = "Playback stopped"
    case .deletedDownload:
      status = "Playback stopped because its downloaded file was deleted"
    case .emptiedQueue(let newStatus, let clearPersistedQueue):
      status = newStatus
      if clearPersistedQueue { onExplicitStop?() }
    case .sleepTimer(let newStatus):
      status = newStatus
    }
    notifyPlaybackChanged()
  }

  package func step(to target: Int?, session: any SessionProviding) -> Bool {
    guard let account = session.account else {
      status = "Validate the session before playback"
      return false
    }
    guard let target, queueTracks.indices.contains(target) else { return false }
    acceptExplicitPlaybackIntent()
    let requestedQuality = quality
    guard let source = entrySource(
      songID: queueTracks[target].id,
      requestedQuality: requestedQuality,
      account: account
    ) else { return false }

    clearPendingSleepStop()
    startEntry(
      at: target,
      account: account,
      session: session,
      auto: false,
      requestedQuality: requestedQuality,
      source: source
    )
    return true
  }

  private func canStep(
    to target: Int?,
    session: any SessionProviding
  ) -> Bool {
    guard canStartNonSessionOperation, let account = session.account, let target,
      queueTracks.indices.contains(target)
    else { return false }
    if offlineDownloads?.hasPlaybackResource(
      songID: queueTracks[target].id,
      requestedQuality: quality,
      accountID: account.userID
    ) == true {
      return true
    }
    // Superseding this controller's own resolution releases one read slot
    // synchronously before the replacement claims it.
    if operationToken != nil { return arbiter.active == nil }
    return arbiter.canBegin(effect: .playbackResolution)
  }

  private func startEntry(
    at index: Int,
    account: NeteaseAccount,
    session: any SessionProviding,
    auto: Bool,
    requestedQuality: PlaybackQuality,
    source: EntrySource,
    retry: PlaybackAttempt? = nil
  ) {
    guard queueTracks.indices.contains(index) else { return }
    let track = queueTracks[index]
    finishLifecycle()
    let token = beginIntent()
    let previousIndex = queue?.currentIndex
    _ = queue?.moveTo(index)
    if previousIndex != queue?.currentIndex { queueDidAdvance() }
    // Created before the request leaves, so a resolve that never answers
    // still has a Play Again entry point.
    attempt = retry ?? PlaybackAttempt(
      songID: track.id,
      quality: requestedQuality,
      queueIndex: index,
      queueEntryCount: queue?.count ?? 1
    )
    playbackAccountID = account.userID
    trackName = track.name
    phase = .resolving
    switch source {
    case .local(let resource):
      status = "Opening downloaded audio"
      playTask = Task {
        await openLocal(
          resource: resource,
          account: account,
          session: session,
          token: token
        )
      }
    case .remote(let operation):
      operationToken = operation
      status = retry != nil
        ? "Re-resolving song URL with bounded quality recovery"
        : auto
          ? "Auto-playing the next track with bounded quality recovery"
          : "Resolving song URL with bounded quality recovery"
      playTask = Task {
        await resolveAndPlay(
          account: account,
          session: session,
          token: token,
          operation: operation
        )
      }
    }
    notifyPlaybackChanged()
  }

  /// Adds server-generated continuation tracks to the queue that is already
  /// playing, without disturbing the entry playing now.
  ///
  /// Only the owner of this exact context may extend it, so a late batch from
  /// a radio the user has already left cannot be appended to whatever replaced
  /// it. Duplicate ids are dropped here rather than at each caller: the queue
  /// is the thing that must not contain the same song twice.
  /// Returns how many entries were actually added.
  @discardableResult
  package func extendQueue(
    with tracks: [Track],
    context: PlaybackContext
  ) -> Int {
    guard queueContext == context, queue != nil, !tracks.isEmpty else { return 0 }
    var seen = Set(queueTracks.map(\.id))
    let fresh = tracks.filter { seen.insert($0.id).inserted }
    guard !fresh.isEmpty else { return 0 }
    let oldCount = queueTracks.count
    queueTracks += fresh
    queue?.append(fresh.count, using: &rng)
    if let queue {
      remapAttempt(
        currentIndex: queue.currentIndex,
        entryCount: queue.count
      ) { oldIndex in
        oldIndex < oldCount ? oldIndex : nil
      }
    }
    queueWasEdited()
    return fresh.count
  }

  /// The queue as it stands, for the coordinator that feeds a
  /// server-generated one. It is the single copy: nobody keeps a parallel list
  /// that could drift from what is actually playing.
  package func queuedTracks(context: PlaybackContext) -> [Track] {
    guard queueContext == context else { return [] }
    return queueTracks
  }

  /// Removes one exact song from the queue owned by `context`. Removing a
  /// non-current entry only remaps indices; the AVPlayer item, clock, phase and
  /// position stay untouched. Removing the current entry starts the successor
  /// selected by `PlaybackQueue` through the normal local-first entry path.
  ///
  /// Returns false when the user has left that context or the target is no
  /// longer in it, so a late server acknowledgement cannot edit a replacement
  /// queue.
  @discardableResult
  package func removeTrack(
    songID: Int64,
    from context: PlaybackContext,
    session: any SessionProviding,
    emptyStatus: String
  ) -> Bool {
    guard queueContext == context, queue != nil,
      let removedIndex = queueTracks.firstIndex(where: { $0.id == songID })
    else { return false }

    return removeQueueEntry(
      at: removedIndex,
      session: session,
      emptyStatus: emptyStatus,
      clearPersistedQueueWhenEmpty: false
    )
  }

  package func removeQueueEntry(
    at removedIndex: Int,
    session: any SessionProviding,
    emptyStatus: String,
    clearPersistedQueueWhenEmpty: Bool
  ) -> Bool {
    guard let heldQueue = queue, queueTracks.indices.contains(removedIndex) else {
      return false
    }

    if heldQueue.count == 1 {
      stop(
        reason: .emptiedQueue(
          status: emptyStatus,
          clearPersistedQueue: clearPersistedQueueWhenEmpty
        )
      )
      return true
    }

    var updatedQueue = heldQueue
    guard updatedQueue.remove(at: removedIndex) else { return false }
    var remaining = queueTracks
    remaining.remove(at: removedIndex)
    let removedCurrent = heldQueue.currentIndex == removedIndex

    if !removedCurrent {
      remapAttempt(
        currentIndex: updatedQueue.currentIndex,
        entryCount: updatedQueue.count
      ) { oldIndex in
        guard oldIndex != removedIndex else { return nil }
        return oldIndex > removedIndex ? oldIndex - 1 : oldIndex
      }
      queueTracks = remaining
      queue = updatedQueue
      queueWasEdited()
      return true
    }

    guard let account = session.account else { return false }
    let successorIndex = updatedQueue.currentIndex
    let requestedQuality = quality
    let source = entrySource(
      songID: remaining[successorIndex].id,
      requestedQuality: requestedQuality,
      account: account
    )
    // A user queue edit must either enter the ordinary local-first path or do
    // nothing. Personal FM's server-confirmed trash keeps its older retryable
    // fallback because its write still owns the arbiter at this exact point.
    if source == nil, clearPersistedQueueWhenEmpty { return false }
    acceptExplicitPlaybackIntent()

    queueTracks = remaining
    queue = updatedQueue
    queueWasEdited()
    if let source {
      startEntry(
        at: successorIndex,
        account: account,
        session: session,
        auto: false,
        requestedQuality: requestedQuality,
        source: source
      )
    } else {
      // A write began only while the read side was empty, so this is an
      // exceptional race with a new exclusive operation. The confirmed trash
      // still removes the song; the successor remains explicitly retryable.
      gate.cancel()
      playTask?.cancel()
      playTask = nil
      finishLifecycle()
      releasePlayback()
      let successor = remaining[successorIndex]
      attempt = PlaybackAttempt(
        songID: successor.id,
        quality: requestedQuality,
        queueIndex: successorIndex,
        queueEntryCount: updatedQueue.count
      )
      trackName = successor.name
      movePosition(to: 0)
      phase = .failed
      status = "Song removed; Play Again starts the next queue entry"
      playbackBecameInactive()
    }
    return true
  }

  /// Selects a valid account-bound local resource before consulting the read
  /// side. Only a remote entry needs a token, and the token is actually held
  /// before any queue, player, attempt or phase is replaced.
  private func entrySource(
    songID: Int64,
    requestedQuality: PlaybackQuality,
    account: NeteaseAccount,
    preferredDownload: OfflineDownload? = nil
  ) -> EntrySource? {
    guard canStartNonSessionOperation else {
      status = "Session is changing; try playback again"
      return nil
    }

    let local = localResource(
      songID: songID,
      requestedQuality: requestedQuality,
      accountID: account.userID,
      preferredDownload: preferredDownload
    )
    if let local {
      guard local.accountID == account.userID, local.songID == songID,
        local.requestedQuality == requestedQuality
      else {
        status = "Downloaded audio does not match the current account"
        return nil
      }
      return .local(local)
    }

    // Superseding this controller's own unresolved read first gives back its
    // slot. There is no suspension between release and the new claim, so this
    // cannot turn `canStart()` into a false promise about the read ceiling.
    if let operationToken {
      // A feedback write may occupy the exclusive slot while this read is in
      // flight. Releasing our read first would cancel the only task that can
      // finish the current entry, then leave the replacement unable to claim
      // a slot. Keep the current resolve alive until the exclusive operation
      // is gone instead.
      guard arbiter.active == nil else {
        status = "Playback is busy; try again"
        return nil
      }
      playTask?.cancel()
      playTask = nil
      releaseResolution(operationToken, outcome: .cancelled)
    }
    guard let operation = claimResolution() else {
      status = "Playback is busy; try again"
      return nil
    }
    return .remote(operation)
  }

  private func localResource(
    songID: Int64,
    requestedQuality: PlaybackQuality,
    accountID: Int64,
    preferredDownload: OfflineDownload? = nil
  ) -> PlaybackResource? {
    preferredDownload.flatMap {
      offlineDownloads?.playbackResource(for: $0)
    } ?? offlineDownloads?.playbackResource(
      songID: songID,
      requestedQuality: requestedQuality,
      accountID: accountID
    )
  }

  private func claimResolution() -> OperationToken? {
    arbiter.begin(name: "Song URL", effect: .playbackResolution)
  }

  /// Releases the arbiter slot this controller holds. A stale token is
  /// ignored by the arbiter, so a late completion cannot free a newer
  /// operation's slot.
  private func releaseResolution(
    _ token: OperationToken,
    outcome: OperationOutcome
  ) {
    if operationToken == token { operationToken = nil }
    arbiter.end(token, outcome: outcome)
  }

  private func detachTokenForInvalidation(_ token: OperationToken) {
    guard operationToken == token else { return }
    operationToken = nil
  }

  private func resolveAndPlay(
    account: NeteaseAccount,
    session: any SessionProviding,
    token: PlaybackIntentGate.Token,
    operation: OperationToken,
    advanceBeforeResolve: Bool = false
  ) async {
    var outcome = OperationOutcome.failed
    defer {
      releaseResolution(operation, outcome: outcome)
      if gate.accepts(token) {
        playTask = nil
      }
    }

    var requestCredential: NeteaseCredential?
    do {
      guard
        let credential = try await currentCredential(
          account: account,
          session: session,
          token: token
        )
      else { return }
      requestCredential = credential

      if advanceBeforeResolve {
        guard
          try await advanceRecoveryEntry(
            account: account,
            token: token
          )
        else {
          exhaustRecovery()
          outcome = .applied
          return
        }
        if try await openRecoveryDownloadIfPresent(
          account: account,
          token: token
        ) {
          outcome = .applied
          return
        }
      }

      while true {
        try checkCurrent(token)
        guard let attempt else { throw CancellationError() }
        let currentSongID = attempt.songID
        let currentQuality = attempt.recovery.currentQuality
        playbackAccountID = account.userID
        status = recoveryStatus(
          prefix: "Resolving",
          attempt: attempt
        )

        let resolution = try await transport.resolveSongURL(
          songID: currentSongID,
          quality: currentQuality,
          credential: credential
        )
        try checkCurrent(token)
        guard
          try await sessionRemainsCurrent(
            account: account,
            credential: credential,
            session: session,
            token: token
          )
        else { return }

        outcome = .applied
        switch resolution {
        case .unavailable(let itemCode, let fee):
          if advanceRecoveryQuality(
            reason: "itemCode=\(itemCode), fee=\(fee.map(String.init) ?? "none")"
          ) {
            continue
          }
          guard try await advanceRecoveryEntry(account: account, token: token) else {
            exhaustRecovery()
            return
          }
          if try await openRecoveryDownloadIfPresent(
            account: account,
            token: token
          ) { return }

        case .resolved(let resolved):
          do {
            playbackAccountID = account.userID
            let playable = try await startPlayback(
              asset: resolved,
              accountID: account.userID,
              token: token
            )
            if playable { return }
            if advanceRecoveryQuality(reason: "resolved asset was not playable") {
              continue
            }
          } catch AudioOutputFailure.resourceUnavailable(let statusCode)
          where PlaybackExpiryPolicy.confirmsInvalidURL(statusCode: statusCode) {
            releasePlayback()
            if beginFreshResolveForCurrentResource() {
              status = recoveryStatus(
                prefix: "HTTP \(statusCode); re-resolving once",
                attempt: self.attempt
              )
              continue
            }
            if advanceRecoveryQuality(
              reason: "HTTP \(statusCode) after fresh resolve"
            ) {
              continue
            }
          }

          guard try await advanceRecoveryEntry(account: account, token: token) else {
            exhaustRecovery()
            return
          }
          if try await openRecoveryDownloadIfPresent(
            account: account,
            token: token
          ) { return }
        }
      }
    } catch {
      outcome = Task.isCancelled ? .cancelled : .failed
      guard gate.accepts(token), !Task.isCancelled else { return }
      await handle(
        error,
        credential: requestCredential,
        readToken: operation,
        session: session,
        token: token
      )
    }
  }

  private func startPlayback(
    asset resolved: ResolvedAudioAsset,
    accountID: Int64,
    token: PlaybackIntentGate.Token
  ) async throws -> Bool {
    // A throw here means the asset could not be loaded at all, most often
    // because the URL expired. The attempt survives so Play Again can
    // re-resolve; it is never reused with the stale URL.
    let resource = PlaybackResource(
      location: .remote(resolved.url),
      accountID: accountID,
      songID: resolved.songID,
      requestedQuality: resolved.requestedQuality,
      actualQuality: resolved.actualQuality,
      format: resolved.format,
      byteCount: resolved.byteCount,
      expiresAt: resolved.expiresIn.flatMap {
        $0 > 0 ? Date().addingTimeInterval(TimeInterval($0)) : nil
      }
    )
    return try await startPlayback(
      resource: resource,
      summary: assetSummary(resolved, attempt: attempt),
      unplayableStatus: "Resolved asset is not playable: " + assetSummary(resolved),
      token: token
    )
  }

  private func openLocal(
    resource: PlaybackResource,
    account: NeteaseAccount,
    session: any SessionProviding,
    token: PlaybackIntentGate.Token
  ) async {
    let downloadID = resource.accountID.map {
      OfflineDownloadID(
        accountID: $0,
        songID: resource.songID,
        requestedQuality: resource.requestedQuality
      )
    }
    do {
      let quality = resource.actualQuality ?? resource.requestedQuality.rawValue
      let isPlayable = try await startPlayback(
        resource: resource,
        summary: localAssetSummary(resource, actualQuality: quality),
        unplayableStatus: "Downloaded audio is not playable",
        token: token
      )
      if !isPlayable, let downloadID {
        offlineDownloads?.invalidatePlaybackResource(downloadID)
      }
      guard isPlayable else {
        await continueOnlineAfterLocalFailure(
          account: account,
          session: session,
          token: token
        )
        return
      }
    } catch {
      guard gate.accepts(token), !Task.isCancelled else { return }
      releasePlayback()
      if let downloadID {
        offlineDownloads?.invalidatePlaybackResource(downloadID)
      }
      await continueOnlineAfterLocalFailure(
        account: account,
        session: session,
        token: token
      )
    }
  }

  private func continueOnlineAfterLocalFailure(
    account: NeteaseAccount,
    session: any SessionProviding,
    token: PlaybackIntentGate.Token
  ) async {
    guard gate.accepts(token), !Task.isCancelled else { return }
    guard attempt != nil else {
      phase = .failed
      status = "Downloaded audio failed without a current playback attempt"
      playbackBecameInactive()
      return
    }
    guard let operation = claimResolution() else {
      phase = .failed
      status = "Downloaded audio was removed; online recovery is busy; use Play Again"
      finishLifecycle()
      playbackBecameInactive()
      return
    }
    operationToken = operation
    playbackAccountID = account.userID
    phase = .resolving
    status = "Downloaded audio was invalid; resolving online audio"
    await resolveAndPlay(
      account: account,
      session: session,
      token: token,
      operation: operation
    )
  }

  private func beginFreshResolveForCurrentResource() -> Bool {
    guard var attempt else { return false }
    let started = attempt.recovery.beginFreshResolve(
      songID: attempt.songID,
      quality: attempt.recovery.currentQuality
    )
    self.attempt = attempt
    return started
  }

  private func advanceRecoveryQuality(reason: String) -> Bool {
    guard var attempt, let next = attempt.recovery.advanceQuality() else {
      return false
    }
    self.attempt = attempt
    status = recoveryStatus(
      prefix: "\(reason); trying \(next.rawValue)",
      attempt: attempt
    )
    return true
  }

  private func advanceRecoveryEntry(
    account: NeteaseAccount,
    token: PlaybackIntentGate.Token
  ) async throws -> Bool {
    try checkCurrent(token)
    guard
      let target = queue?.nextIndex(),
      queueTracks.indices.contains(target),
      let currentAttempt = attempt,
      let nextAttempt = currentAttempt.advancing(
        to: queueTracks[target].id,
        queueIndex: target
      )
    else { return false }

    finishLifecycle()
    releasePlayback()
    guard queue?.moveTo(target) == true else { return false }
    queueDidAdvance()
    attempt = nextAttempt
    trackName = queueTracks[target].name
    playbackAccountID = account.userID
    phase = .resolving
    movePosition(to: 0)
    status = recoveryStatus(
      prefix: "Skipping an unavailable entry",
      attempt: nextAttempt
    )
    notifyPlaybackChanged()
    return true
  }

  private func openRecoveryDownloadIfPresent(
    account: NeteaseAccount,
    token: PlaybackIntentGate.Token
  ) async throws -> Bool {
    guard let attempt else { return false }
    guard
      let resource = localResource(
        songID: attempt.songID,
        requestedQuality: attempt.quality,
        accountID: account.userID
      )
    else { return false }
    let downloadID = OfflineDownloadID(
      accountID: account.userID,
      songID: attempt.songID,
      requestedQuality: attempt.quality
    )
    do {
      playbackAccountID = account.userID
      let actual = resource.actualQuality ?? resource.requestedQuality.rawValue
      let playable = try await startPlayback(
        resource: resource,
        summary: localAssetSummary(resource, actualQuality: actual),
        unplayableStatus: "Downloaded audio is not playable",
        token: token
      )
      if playable { return true }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      releasePlayback()
    }
    offlineDownloads?.invalidatePlaybackResource(downloadID)
    playbackAccountID = account.userID
    status = recoveryStatus(
      prefix: "Downloaded audio was invalid; trying online",
      attempt: self.attempt
    )
    return false
  }

  private func exhaustRecovery() {
    let exhaustedAttempt = attempt
    finishLifecycle()
    attempt = nil
    releasePlayback()
    phase = .failed
    status = "No playable quality remained"
      + failureQualitySummary(exhaustedAttempt)
      + "; automatic recovery stopped"
    playbackBecameInactive()
  }

  private func recoveryStatus(
    prefix: String,
    attempt: PlaybackAttempt?
  ) -> String {
    guard let attempt else { return prefix }
    let current = attempt.recovery.currentQuality
    return
      "\(prefix): requestedQuality=\(attempt.recovery.requestedQuality.rawValue), "
      + "currentQuality=\(current.rawValue), "
      + "degraded=\(current != attempt.recovery.requestedQuality), "
      + "skipped=\(attempt.recovery.skippedEntries)"
  }

  private func startPlayback(
    resource: PlaybackResource,
    summary: String,
    unplayableStatus: String,
    token: PlaybackIntentGate.Token
  ) async throws -> Bool {
    // A cancelled local task may not have reached AudioOutput before its
    // replacement intent starts. Reject it before it can tear down or observe
    // the replacement player's resource.
    try checkCurrent(token)
    observeOutput(token: token)
    if case .local = resource.location, let accountID = resource.accountID {
      activeOfflineDownloadID = OfflineDownloadID(
        accountID: accountID,
        songID: resource.songID,
        requestedQuality: resource.requestedQuality
      )
    } else {
      activeOfflineDownloadID = nil
    }
    let info = try await output.prepare(
      resource: resource,
      userAgent: "MacEasePhase0/0.1 (macOS 15)"
    )
    try checkCurrent(token)
    guard info.isPlayable else {
      releasePlayback()
      status = unplayableStatus
      return false
    }

    hasLoadedItem = true

    let resumePosition = attempt?.resumePosition ?? 0
    let desiredState = attempt?.desiredState ?? .playing
    if resumePosition > 0 {
      try await output.seek(to: resumePosition)
      try checkCurrent(token)
    }
    movePosition(to: resumePosition)
    durationSeconds = info.durationSeconds
    currentAssetSummary = summary
    switch desiredState {
    case .playing:
      output.play()
      phase = .playing
      status = "Playing: " + summary
    case .paused:
      // It failed while paused; restoring it must not start playback.
      phase = .paused
      status = "Restored paused: " + summary
    }
    return true
  }

  private func observeOutput(token: PlaybackIntentGate.Token) {
    output.onPlaybackStateChanged = { [weak self] state in
      guard let self, self.gate.accepts(token) else { return }
      switch state {
      case .playing: self.outputStartedPlaying()
      case .notPlaying: self.pauseLifecycleClock()
      }
    }
    output.onPositionUpdate = { [weak self] seconds in
      guard let self, self.gate.accepts(token) else { return }
      self.positionSeconds = seconds
      self.attempt?.resumePosition = seconds
    }
    output.onPlayedToEnd = { [weak self] in
      self?.handlePlayedToEnd(token: token)
    }
    output.onFailure = { [weak self] failure in
      self?.handleItemFailure(failure: failure, token: token)
    }
  }

  private func handleItemFailure(
    failure: AudioOutputFailure,
    token: PlaybackIntentGate.Token
  ) {
    guard gate.accepts(token) else { return }
    let failedOfflineDownload = activeOfflineDownloadID
    let failedAssetSummary = currentAssetSummary
    // Keep where the user was and whether they were listening, so the retry
    // restores the same thing rather than restarting the track.
    attempt = attempt?.checkpointed(
      at: currentPosition(),
      desiredState: phase == .paused ? .paused : .playing
    )

    let confirmedExpired: Bool = if case .resourceUnavailable(let statusCode) = failure {
      PlaybackExpiryPolicy.confirmsInvalidURL(statusCode: statusCode)
    } else {
      false
    }
    if failedOfflineDownload != nil || confirmedExpired {
      pauseLifecycleClock()
      releasePlayback()
      if let failedOfflineDownload {
        offlineDownloads?.invalidatePlaybackResource(failedOfflineDownload)
      }
      guard
        let session = attachedSession,
        let account = session.account,
        var attempt,
        let operation = claimResolution()
      else {
        finishLifecycle()
        phase = .failed
        status = "Playback recovery is busy; use Play Again"
        playbackBecameInactive()
        return
      }

      var advanceBeforeResolve = false
      if failedOfflineDownload == nil {
        let refreshed = attempt.recovery.beginFreshResolve(
          songID: attempt.songID,
          quality: attempt.recovery.currentQuality
        )
        if !refreshed, attempt.recovery.advanceQuality() == nil {
          advanceBeforeResolve = true
        }
        self.attempt = attempt
      }

      let recoveryToken = beginIntent()
      operationToken = operation
      playbackAccountID = account.userID
      phase = .resolving
      status = recoveryStatus(
        prefix: failedOfflineDownload == nil
          ? "Expired URL confirmed; recovering"
          : "Downloaded audio failed; recovering online",
        attempt: self.attempt
      )
      playTask = Task {
        await resolveAndPlay(
          account: account,
          session: session,
          token: recoveryToken,
          operation: operation,
          advanceBeforeResolve: advanceBeforeResolve
        )
      }
      return
    }

    gate.cancel()
    finishLifecycle()
    releasePlayback()
    phase = .failed
    let qualitySummary = failedAssetSummary.map { "; \($0)" }
      ?? failureQualitySummary(attempt)
    status = "Playback failed (\(failure.diagnostic))"
      + qualitySummary
      + "; Play Again re-resolves the URL"
    playbackBecameInactive()
  }

  private func handlePlayedToEnd(token: PlaybackIntentGate.Token) {
    guard gate.accepts(token) else { return }
    if sleepTimer == .finishingTrack {
      gate.cancel()
      stop(
        reason: .sleepTimer(status: "Sleep timer stopped after the current track")
      )
      return
    }
    guard let queue else {
      finishQueue(status: "Playback finished")
      return
    }
    switch queue.afterNaturalEnd() {
    case .replayCurrent:
      finishLifecycle()
      replayCurrentItem(token: token)
    case .end:
      finishQueue(status: "Queue finished; no automatic repeat")
    case .play(let index):
      guard
        let session = attachedSession,
        let account = session.account,
        queueTracks.indices.contains(index)
      else {
        finishQueue(status: "Track finished; press Next to continue the queue")
        return
      }
      let requestedQuality = quality
      guard let source = entrySource(
        songID: queueTracks[index].id,
        requestedQuality: requestedQuality,
        account: account
      ) else {
        finishQueue(status: status)
        return
      }
      startEntry(
        at: index,
        account: account,
        session: session,
        auto: true,
        requestedQuality: requestedQuality,
        source: source
      )
    }
  }

  private func finishQueue(status: String) {
    gate.cancel()
    finishLifecycle()
    // A queue that ended on its own has nothing to retry.
    attempt = nil
    releasePlayback()
    phase = .finished
    self.status = status
    playbackBecameInactive()
  }

  private func replayCurrentItem(token: PlaybackIntentGate.Token) {
    guard hasLoadedItem else {
      finishQueue(status: "Playback finished")
      return
    }
    movePosition(to: 0)
    attempt?.resumePosition = 0
    status = "Repeating the current track (no request)"
    Task {
      // A cancelled seek here only means a same-intent user seek superseded
      // seek(0); replay still owns the player unless the intent changed or
      // the user paused during the gap.
      _ = try? await output.seek(to: 0)
      guard gate.accepts(token), !Task.isCancelled, phase == .playing else { return }
      output.play()
    }
  }

  private func currentCredential(
    account: NeteaseAccount,
    session: any SessionProviding,
    token: PlaybackIntentGate.Token
  ) async throws -> NeteaseCredential? {
    let credential = try await vault.load()
    try checkCurrent(token)
    guard let credential else {
      session.reportDivergence(.storedSessionMissing)
      abandonPlayback(status: "No stored session for playback")
      return nil
    }
    guard session.matchesValidatedSession(credential, account: account) else {
      session.reportDivergence(.storedSessionChanged(hasStoredItem: true))
      abandonPlayback(status: "Session changed; validate again")
      return nil
    }
    return credential
  }

  private func sessionRemainsCurrent(
    account: NeteaseAccount,
    credential: NeteaseCredential,
    session: any SessionProviding,
    token: PlaybackIntentGate.Token
  ) async throws -> Bool {
    let stored = try await vault.load()
    try checkCurrent(token)
    guard
      stored == credential,
      session.matchesValidatedSession(credential, account: account)
    else {
      session.reportDivergence(.storedSessionChanged(hasStoredItem: stored != nil))
      abandonPlayback(status: "Session changed; validate again")
      return false
    }
    return true
  }

  private func handle(
    _ error: Error,
    credential: NeteaseCredential?,
    readToken: OperationToken,
    session: any SessionProviding,
    token: PlaybackIntentGate.Token
  ) async {
    let failedAttempt = attempt
    finishLifecycle()
    releasePlayback()
    if PlaybackFailureClassifier.kind(for: error) == .terminal {
      attempt = nil
    }
    switch error {
    case let error as NeteaseServiceError
    where error.source == .service && error.statusCode == 301:
      guard let credential else {
        phase = .failed
        status = "Song URL service error 301"
        return
      }
      detachTokenForInvalidation(readToken)
      let invalidation = await session.invalidateStoredSession(
        matching: credential,
        message: "Stored session expired; sign in again",
        readToken: readToken
      )
      guard gate.accepts(token), !Task.isCancelled else { return }
      switch invalidation {
      case .deleted:
        abandonPlayback(status: "Stored session expired; sign in again")
      case .notCurrent:
        abandonPlayback(status: "Session changed; validate again")
      case .busy:
        phase = .failed
        status = "Session busy; validate again"
      case .failed:
        abandonPlayback(status: "Session invalidation failed")
      }
    case is NeteaseServiceError:
      phase = .failed
      status = OperationFailure.classify(error).statusText(operation: "Song URL")
        + failureQualitySummary(failedAttempt)
    case NeteasePlaybackError.nonHTTPSURL(let host):
      // MacEase refused the address, so a retry would refuse it again.
      attempt = nil
      phase = .failed
      status = "Rejected non-HTTPS playback host \(host)"
        + failureQualitySummary(failedAttempt)
    case NeteasePlaybackError.unapprovedHost(let host):
      attempt = nil
      phase = .failed
      status = "Rejected unapproved playback host \(host)"
        + failureQualitySummary(failedAttempt)
    case NeteasePlaybackError.invalidResponse:
      phase = .failed
      status = "Song URL invalid response" + failureQualitySummary(failedAttempt)
    case let error as CredentialVaultError:
      phase = .failed
      status = "Keychain error \(error.diagnostic)"
        + failureQualitySummary(failedAttempt)
    default:
      phase = .failed
      status = "Song URL network or response error"
        + failureQualitySummary(failedAttempt)
    }
    if phase == .failed { playbackBecameInactive() }
  }

  private func abandonPlayback(status: String) {
    advanceIntentRevision()
    finishLifecycle()
    attempt = nil
    queue = nil
    queueTracks = []
    queueContext = nil
    queueAccountID = nil
    queueWasReplaced()
    clearPendingSleepStop()
    releasePlayback()
    phase = .idle
    trackName = nil
    movePosition(to: 0)
    self.status = status
    notifyPlaybackChanged()
  }

  /// Starts a new user intent. It deliberately does not touch `attempt`: the
  /// caller decides whether this is a new track or a retry of the old one.
  ///
  /// It also gives back the arbiter slot this controller holds, so that
  /// superseding one's own in-flight resolve (play A, then immediately play B)
  /// can claim it again. Without this the old playback was cancelled and the
  /// new claim returned nil, leaving nothing playing.
  private func beginIntent() -> PlaybackIntentGate.Token {
    let token = gate.begin()
    activeToken = token
    machinePausedReason = nil
    playTask?.cancel()
    playTask = nil
    if let operationToken {
      // A song-URL resolve is a read: abandoning it has no server effect.
      releaseResolution(operationToken, outcome: .cancelled)
    }
    releasePlayback()
    movePosition(to: 0)
    return token
  }

  private func playbackBecameInactive() {
    advanceIntentRevision()
    notifyPlaybackChanged()
  }

  /// Commits a user-visible playback choice before it tries to claim a read
  /// slot. That ordering lets the owner of an obsolete radio read cancel it
  /// synchronously, so the newer Play/Next/Previous/Play Again can use the
  /// slot even when the read ceiling is one.
  package func acceptExplicitPlaybackIntent() {
    advanceIntentRevision()
    notifyPlaybackChanged()
  }

  private func advanceIntentRevision() {
    intentRevision &+= 1
  }

  private func notifyPlaybackChanged() {
    onPlaybackChanged?(intentRevision)
  }

  /// Moves the clock for a reason other than playback advancing, so a system
  /// surface extrapolating from the rate is told its value is now wrong.
  private func movePosition(to seconds: Double) {
    positionSeconds = seconds
    positionEpoch &+= 1
  }

  private func releasePlayback() {
    output.onPlaybackStateChanged = nil
    output.onPositionUpdate = nil
    output.onPlayedToEnd = nil
    output.onFailure = nil
    currentAssetSummary = nil
    activeOfflineDownloadID = nil
    playbackAccountID = nil
    durationSeconds = nil
    hasLoadedItem = false
    output.teardown()
  }

  private func currentPosition() -> Double {
    output.currentPositionSeconds ?? attempt?.resumePosition ?? 0
  }

  private func checkCurrent(_ token: PlaybackIntentGate.Token) throws {
    try Task.checkCancellation()
    guard gate.accepts(token) else { throw CancellationError() }
  }

  private func assetSummary(
    _ asset: ResolvedAudioAsset,
    attempt: PlaybackAttempt? = nil
  ) -> String {
    let requested = attempt?.recovery.requestedQuality ?? asset.requestedQuality
    let skipped = attempt?.recovery.skippedEntries ?? 0
    return "requestedQuality=\(requested.rawValue), "
      + "actualQuality=\(asset.actualQuality ?? "none"), "
      + "degraded=\(asset.actualQuality != nil && asset.actualQuality != requested.rawValue), "
      + "skipped=\(skipped), "
      + "format=\(asset.format ?? "none"), "
      + "bitRate=\(asset.bitRate.map(String.init) ?? "none"), "
      + "trial=\(asset.trial), "
      + "scheme=\(asset.url.scheme ?? "none")"
  }

  private func localAssetSummary(
    _ resource: PlaybackResource,
    actualQuality: String
  ) -> String {
    let requested = attempt?.recovery.requestedQuality ?? resource.requestedQuality
    return "requestedQuality=\(requested.rawValue), "
      + "actualQuality=\(actualQuality), "
      + "degraded=\(actualQuality != requested.rawValue), "
      + "skipped=\(attempt?.recovery.skippedEntries ?? 0), "
      + "source=download, format=\(resource.format ?? "unknown")"
  }

  private func failureQualitySummary(_ attempt: PlaybackAttempt?) -> String {
    guard let attempt else { return "" }
    return "; requestedQuality=\(attempt.recovery.requestedQuality.rawValue), "
      + "actualQuality=none, "
      + "degraded=\(attempt.recovery.currentQuality != attempt.recovery.requestedQuality), "
      + "skipped=\(attempt.recovery.skippedEntries)"
  }
}

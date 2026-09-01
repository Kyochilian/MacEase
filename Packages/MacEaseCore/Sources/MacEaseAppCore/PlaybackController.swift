import Foundation
import NeteaseKit
import Observation

/// Explicit queue playback. A queue starts only from a user action, every
/// track transition performs exactly one `resolveSongURL` request (repeat one
/// replays the current item with none), and any failure stops the queue with
/// no automatic retry or skip. There is no prefetch and no background refresh.
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

  private static let volumeDefaultsKey = "playback.volume"

  @ObservationIgnored private let transport: any NeteaseTransporting
  @ObservationIgnored private let vault: any CredentialStoring
  @ObservationIgnored private let arbiter: OperationArbiter
  @ObservationIgnored private var operationToken: OperationToken?
  @ObservationIgnored private var gate = PlaybackIntentGate()
  @ObservationIgnored private var rng = SystemRandomNumberGenerator()
  @ObservationIgnored private var playTask: Task<Void, Never>?
  @ObservationIgnored private let output: any AudioOutput
  @ObservationIgnored private var hasLoadedItem = false
  /// The retry entry point for the track being attempted. Created before the
  /// resolve request, cleared only by a terminal failure or a new intent.
  @ObservationIgnored private var attempt: PlaybackAttempt?
  @ObservationIgnored private var currentAssetSummary: String?
  @ObservationIgnored private var activeToken: PlaybackIntentGate.Token?
  @ObservationIgnored private var queueTracks: [Track] = []
  /// Where the queue came from. A restored queue that says only "these forty
  /// tracks" cannot tell the user what they were listening to.
  @ObservationIgnored package private(set) var queueContext: PlaybackContext?
  @ObservationIgnored private weak var attachedSession: (any SessionProviding)?
  @ObservationIgnored private weak var offlineDownloads: DownloadCoordinator?
  @ObservationIgnored private var sleepTask: Task<Void, Never>?
  @ObservationIgnored private var sleepGeneration = 0
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
  /// One narrow notification for the owner of server-generated queues. The
  /// revision tells it whether an in-flight response still belongs to the
  /// accepted intent; unchanged revisions are ordinary queue progression.
  @ObservationIgnored package var onPlaybackChanged:
    (@MainActor (UInt64) -> Void)?

  /// Why the machine, rather than the user, stopped playback.
  package enum MachinePause: Equatable, Sendable {
    case systemSleep
    case audioOutputLost
  }

  package private(set) var phase: Phase = .idle
  package private(set) var queue: PlaybackQueue?
  package private(set) var sleepTimer: SleepTimerState = .off
  package private(set) var trackName: String?
  package private(set) var positionSeconds: Double = 0
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
    didSet { queue?.setMode(playbackMode, using: &rng) }
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
    output: any AudioOutput = AVPlayerAudioOutput()
  ) {
    self.transport = transport
    self.vault = vault
    self.arbiter = arbiter
    self.output = output
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

  package func play(
    tracks: [Track],
    startIndex: Int,
    context: PlaybackContext,
    session: any SessionProviding
  ) {
    guard let account = session.account else {
      status = "Validate the session before playback"
      return
    }
    guard
      let queue = PlaybackQueue(
        count: tracks.count,
        startIndex: startIndex,
        mode: playbackMode,
        using: &rng
    )
    else { return }
    guard tracks.indices.contains(startIndex) else { return }
    acceptExplicitPlaybackIntent()
    let requestedQuality = quality
    guard let source = entrySource(
      songID: tracks[startIndex].id,
      requestedQuality: requestedQuality,
      account: account
    ) else { return }

    queueTracks = tracks
    queueContext = context
    self.queue = queue
    clearPendingSleepStop()
    startEntry(
      at: startIndex,
      account: account,
      session: session,
      auto: false,
      requestedQuality: requestedQuality,
      source: source
    )
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
    self.queue = queue
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
  package func restore(_ persisted: PersistedQueue) {
    guard !isActive, !persisted.tracks.isEmpty else { return }
    guard
      let queue = PlaybackQueue(
        count: persisted.tracks.count,
        startIndex: persisted.currentIndex,
        mode: persisted.mode,
        using: &rng
      )
    else { return }

    queueTracks = persisted.tracks
    queueContext = persisted.context
    self.queue = queue
    playbackMode = persisted.mode
    quality = persisted.quality
    let track = persisted.tracks[persisted.currentIndex]
    trackName = track.name
    attempt = PlaybackAttempt(
      songID: track.id,
      quality: persisted.quality,
      queueIndex: persisted.currentIndex,
      resumePosition: persisted.positionSeconds,
      desiredState: persisted.wasPlaying ? .playing : .paused
    )
    movePosition(to: persisted.positionSeconds)
    status =
      "Restored \(persisted.context.label); "
      + (persisted.wasPlaying ? "Resume" : "Restore Paused")
      + " continues from \(Int(persisted.positionSeconds))s"
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

  package func playAgain(session: any SessionProviding) {
    guard let account = session.account else {
      status = "Validate the session before playback"
      return
    }
    guard let retry = attempt else { return }
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
    stopPlayback()
    onExplicitStop?()
  }

  /// Removes session-scoped playback without interpreting the identity change
  /// as the user discarding their saved queue.
  package func stopForSessionChange() {
    stopPlayback()
  }

  /// Deleting the exact local resource AVPlayer owns first tears the player
  /// down. This is not interpreted as the user's Stop button, so it does not
  /// erase the account's persisted queue.
  package func stopForDeletedDownload() {
    stopPlayback()
    status = "Playback stopped because its downloaded file was deleted"
  }

  /// A server-generated queue removed its last entry, so there is nothing left
  /// to play. Also not the user's Stop button: the account's saved queue is
  /// left where it is.
  package func stopForEmptiedQueue(status newStatus: String) {
    stopPlayback()
    status = newStatus
  }

  private func stopPlayback() {
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
    clearPendingSleepStop()
    releasePlayback()
    phase = .idle
    trackName = nil
    movePosition(to: 0)
    status = "Playback stopped"
    notifyPlaybackChanged()
  }

  /// A local timer; it never issues requests. Zero minutes cancels it,
  /// including a pending stop-after-track.
  package func setSleepTimer(minutes: Int) {
    sleepGeneration += 1
    sleepTask?.cancel()
    sleepTask = nil
    guard minutes > 0 else {
      sleepTimer = .off
      return
    }
    let seconds = TimeInterval(minutes * 60)
    sleepTimer = .armed(Date().addingTimeInterval(seconds))
    let generation = sleepGeneration
    sleepTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      self?.fireSleepTimer(generation: generation)
    }
  }

  private func fireSleepTimer(generation: Int) {
    guard generation == sleepGeneration, case .armed = sleepTimer else { return }
    sleepTask = nil
    guard isActive else {
      sleepTimer = .off
      return
    }
    if sleepStopsImmediately {
      sleepTimer = .off
      stop()
      status = "Sleep timer stopped playback"
    } else {
      sleepTimer = .finishingTrack
    }
  }

  private func step(to target: Int?, session: any SessionProviding) -> Bool {
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
    let token = beginIntent()
    _ = queue?.moveTo(index)
    // Created before the request leaves, so a resolve that never answers
    // still has a Play Again entry point.
    attempt = retry ?? PlaybackAttempt(
      songID: track.id,
      quality: requestedQuality,
      queueIndex: index
    )
    trackName = track.name
    phase = .resolving
    switch source {
    case .local(let resource):
      status = "Opening downloaded audio"
      playTask = Task {
        await openLocal(resource: resource, token: token)
      }
    case .remote(let operation):
      operationToken = operation
      status = retry != nil
        ? "Re-resolving song URL (1 request)"
        : auto
          ? "Auto-playing the next track (1 request)"
          : "Resolving song URL (1 request)"
      playTask = Task {
        await resolveAndPlay(
          songID: track.id,
          quality: requestedQuality,
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
    queueTracks += fresh
    queue?.append(fresh.count, using: &rng)
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
    guard queueContext == context, let heldQueue = queue,
      let removedIndex = queueTracks.firstIndex(where: { $0.id == songID })
    else { return false }

    if heldQueue.count == 1 {
      stopForEmptiedQueue(status: emptyStatus)
      return true
    }

    var updatedQueue = heldQueue
    guard updatedQueue.remove(at: removedIndex) else { return false }
    var remaining = queueTracks
    remaining.remove(at: removedIndex)
    let removedCurrent = heldQueue.currentIndex == removedIndex

    if !removedCurrent {
      queueTracks = remaining
      queue = updatedQueue
      if var retry = attempt {
        if retry.queueIndex > removedIndex {
          retry.queueIndex -= 1
          attempt = retry
        } else if retry.queueIndex == removedIndex {
          // Internal state should name the current row. If it does not, retire
          // the stale retry instead of letting it point at a different song.
          attempt = nil
        }
      }
      return true
    }

    guard let account = session.account else { return false }
    let successorIndex = updatedQueue.currentIndex
    let requestedQuality = quality
    acceptExplicitPlaybackIntent()
    let source = entrySource(
      songID: remaining[successorIndex].id,
      requestedQuality: requestedQuality,
      account: account
    )

    queueTracks = remaining
    queue = updatedQueue
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
      releasePlayback()
      let successor = remaining[successorIndex]
      attempt = PlaybackAttempt(
        songID: successor.id,
        quality: requestedQuality,
        queueIndex: successorIndex
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
    guard arbiter.active?.effect != .sessionMutation else {
      status = "Session is changing; try playback again"
      return nil
    }

    let local = preferredDownload.flatMap {
      offlineDownloads?.playbackResource(for: $0)
    } ?? offlineDownloads?.playbackResource(
      songID: songID,
      requestedQuality: requestedQuality,
      accountID: account.userID
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
      playTask?.cancel()
      playTask = nil
      releaseResolution(operationToken, outcome: .cancelled)
    }
    guard
      let operation = arbiter.begin(
        name: "Song URL",
        effect: .playbackResolution
      )
    else {
      status = "Playback is busy; try again"
      return nil
    }
    return .remote(operation)
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
    songID: Int64,
    quality: PlaybackQuality,
    account: NeteaseAccount,
    session: any SessionProviding,
    token: PlaybackIntentGate.Token,
    operation: OperationToken
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

      arbiter.markRequestSent(operation)
      let resolution = try await transport.resolveSongURL(
        songID: songID,
        quality: quality,
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

      arbiter.markSettling(operation)
      outcome = .applied
      switch resolution {
      case .unavailable(let itemCode, let fee):
        // An explicit catalogue or rights refusal: asking again changes
        // nothing, so no retry is offered.
        attempt = nil
        phase = .failed
        status =
          "Track unavailable: itemCode=\(itemCode), "
          + "fee=\(fee.map(String.init) ?? "none"); the queue is not skipped"
        playbackBecameInactive()
      case .resolved(let resolved):
        try await startPlayback(
          asset: resolved,
          accountID: account.userID,
          token: token
        )
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
  ) async throws {
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
    _ = try await startPlayback(
      resource: resource,
      summary: assetSummary(resolved),
      unplayableStatus: "Resolved asset is not playable: " + assetSummary(resolved),
      token: token
    )
  }

  private func openLocal(
    resource: PlaybackResource,
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
        summary: "downloaded quality=\(quality), format=\(resource.format ?? "unknown")",
        unplayableStatus: "Downloaded audio is not playable",
        token: token
      )
      if !isPlayable, let downloadID {
        offlineDownloads?.invalidatePlaybackResource(downloadID)
      }
    } catch {
      guard gate.accepts(token), !Task.isCancelled else { return }
      releasePlayback()
      phase = .failed
      status = "Downloaded audio could not be opened"
      playbackBecameInactive()
      if let downloadID {
        offlineDownloads?.invalidatePlaybackResource(downloadID)
      }
    }
  }

  private func startPlayback(
    resource: PlaybackResource,
    summary: String,
    unplayableStatus: String,
    token: PlaybackIntentGate.Token
  ) async throws -> Bool {
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
      phase = .failed
      status = unplayableStatus
      playbackBecameInactive()
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
    gate.cancel()
    let failedOfflineDownload = activeOfflineDownloadID
    // Keep where the user was and whether they were listening, so the retry
    // restores the same thing rather than restarting the track.
    attempt = attempt?.checkpointed(
      at: currentPosition(),
      desiredState: phase == .paused ? .paused : .playing
    )
    releasePlayback()
    if let failedOfflineDownload {
      offlineDownloads?.invalidatePlaybackResource(failedOfflineDownload)
    }
    phase = .failed
    status = failedOfflineDownload == nil
      ? "Playback failed (\(failure.diagnostic)); Play Again re-resolves the URL"
      : "Downloaded audio failed; Play Again uses online playback"
    playbackBecameInactive()
  }

  private func handlePlayedToEnd(token: PlaybackIntentGate.Token) {
    guard gate.accepts(token) else { return }
    if sleepTimer == .finishingTrack {
      gate.cancel()
      stop()
      status = "Sleep timer stopped after the current track"
      return
    }
    guard let queue else {
      finishQueue(status: "Playback finished")
      return
    }
    switch queue.afterNaturalEnd() {
    case .replayCurrent:
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
    case NeteasePlaybackError.nonHTTPSURL(let host):
      // MacEase refused the address, so a retry would refuse it again.
      attempt = nil
      phase = .failed
      status = "Rejected non-HTTPS playback host \(host)"
    case NeteasePlaybackError.unapprovedHost(let host):
      attempt = nil
      phase = .failed
      status = "Rejected unapproved playback host \(host)"
    case NeteasePlaybackError.invalidResponse:
      phase = .failed
      status = "Song URL invalid response"
    case let error as CredentialVaultError:
      phase = .failed
      status = "Keychain error \(error.diagnostic)"
    default:
      phase = .failed
      status = "Song URL network or response error"
    }
    if phase == .failed { playbackBecameInactive() }
  }

  private func abandonPlayback(status: String) {
    advanceIntentRevision()
    attempt = nil
    queue = nil
    queueTracks = []
    queueContext = nil
    clearPendingSleepStop()
    releasePlayback()
    phase = .idle
    trackName = nil
    movePosition(to: 0)
    self.status = status
    notifyPlaybackChanged()
  }

  private func clearPendingSleepStop() {
    if sleepTimer == .finishingTrack {
      sleepTimer = .off
    }
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
  private func acceptExplicitPlaybackIntent() {
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
    output.onPositionUpdate = nil
    output.onPlayedToEnd = nil
    output.onFailure = nil
    currentAssetSummary = nil
    activeOfflineDownloadID = nil
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

  private func assetSummary(_ asset: ResolvedAudioAsset) -> String {
    "requestedQuality=\(asset.requestedQuality.rawValue), "
      + "actualQuality=\(asset.actualQuality ?? "none"), "
      + "format=\(asset.format ?? "none"), "
      + "bitRate=\(asset.bitRate.map(String.init) ?? "none"), "
      + "trial=\(asset.trial), "
      + "scheme=\(asset.url.scheme ?? "none")"
  }
}

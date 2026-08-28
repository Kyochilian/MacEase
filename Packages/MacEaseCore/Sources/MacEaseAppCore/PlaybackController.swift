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
  @ObservationIgnored private var queueContext: PlaybackContext?
  @ObservationIgnored private weak var attachedSession: (any SessionProviding)?
  @ObservationIgnored private var sleepTask: Task<Void, Never>?
  @ObservationIgnored private var sleepGeneration = 0
  /// Playback the machine interrupted, not the user. Kept apart from an
  /// ordinary pause so the status can say why it stopped, and so a wake or a
  /// reconnect does not claim credit for a pause the user asked for.
  @ObservationIgnored private var machinePausedReason: MachinePause?

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
    guard canClaimResolution else { return }
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

    queueTracks = tracks
    queueContext = context
    self.queue = queue
    clearPendingSleepStop()
    startEntry(
      at: startIndex,
      account: account,
      session: session,
      auto: false
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
      quality: quality,
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
    guard canClaimResolution else { return }
    guard let account = session.account else {
      status = "Validate the session before playback"
      return
    }
    guard let retry = attempt else { return }

    let token = beginIntent()
    guard let operation = claimResolution() else { return }
    // The attempt survives `beginIntent`, which is what makes an explicit
    // retry possible after a failure that never produced a player item.
    attempt = retry
    _ = queue?.moveTo(retry.queueIndex)
    clearPendingSleepStop()
    phase = .resolving
    status = "Re-resolving song URL (1 request)"
    playTask = Task {
      await resolveAndPlay(
        songID: retry.songID,
        quality: retry.quality,
        account: account,
        session: session,
        token: token,
        operation: operation
      )
    }
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
    guard canClaimResolution else { return false }
    guard let account = session.account else {
      status = "Validate the session before playback"
      return false
    }
    guard let target, queue?.moveTo(target) == true else { return false }

    clearPendingSleepStop()
    startEntry(
      at: target,
      account: account,
      session: session,
      auto: false
    )
    return true
  }

  private func startEntry(
    at index: Int,
    account: NeteaseAccount,
    session: any SessionProviding,
    auto: Bool
  ) {
    guard queueTracks.indices.contains(index) else { return }
    let track = queueTracks[index]
    let requestedQuality = quality
    let token = beginIntent()
    guard let operation = claimResolution() else { return }
    // Created before the request leaves, so a resolve that never answers
    // still has a Play Again entry point.
    attempt = PlaybackAttempt(
      songID: track.id,
      quality: requestedQuality,
      queueIndex: index
    )
    trackName = track.name
    phase = .resolving
    status =
      auto
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

  /// True when a new resolve may start: either nothing owns the arbiter, or
  /// this controller owns it and the user is superseding their own request.
  private var canClaimResolution: Bool {
    arbiter.canStart() || operationToken != nil
  }

  private func claimResolution() -> OperationToken? {
    let token = arbiter.begin(name: "Song URL", effect: .playbackResolution)
    operationToken = token
    return token
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
      case .resolved(let resolved):
        try await startPlayback(asset: resolved, token: token)
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
    token: PlaybackIntentGate.Token
  ) async throws {
    // A throw here means the asset could not be loaded at all, most often
    // because the URL expired. The attempt survives so Play Again can
    // re-resolve; it is never reused with the stale URL.
    observeOutput(token: token)
    let info = try await output.prepare(
      url: resolved.url,
      userAgent: "MacEasePhase0/0.1 (macOS 15)"
    )
    try checkCurrent(token)
    guard info.isPlayable else {
      output.teardown()
      phase = .failed
      status = "Resolved asset is not playable: " + assetSummary(resolved)
      return
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
    currentAssetSummary = assetSummary(resolved)
    switch desiredState {
    case .playing:
      output.play()
      phase = .playing
      status = "Playing: " + assetSummary(resolved)
    case .paused:
      // It failed while paused; restoring it must not start playback.
      phase = .paused
      status = "Restored paused: " + assetSummary(resolved)
    }
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
    // Keep where the user was and whether they were listening, so the retry
    // restores the same thing rather than restarting the track.
    attempt = attempt?.checkpointed(
      at: currentPosition(),
      desiredState: phase == .paused ? .paused : .playing
    )
    releasePlayback()
    phase = .failed
    status = "Playback failed (\(failure.diagnostic)); Play Again re-resolves the URL"
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
        arbiter.canStart(),
        let account = session.account,
        self.queue?.moveTo(index) == true
      else {
        finishQueue(status: "Track finished; press Next to continue the queue")
        return
      }
      startEntry(at: index, account: account, session: session, auto: true)
    }
  }

  private func finishQueue(status: String) {
    gate.cancel()
    // A queue that ended on its own has nothing to retry.
    attempt = nil
    releasePlayback()
    phase = .finished
    self.status = status
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
  }

  private func abandonPlayback(status: String) {
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

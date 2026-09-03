import Foundation
import NeteaseKit
import Observation

/// The two queues NetEase generates rather than the user assembling: personal
/// FM and heartbeat mode.
///
/// `PlaybackController` owns the only queue copy and the playback-intent
/// revision. A radio read captures that revision before it leaves; any newer
/// accepted Play, Next, Previous, Play Again, Stop or terminal queue state
/// cancels the read and prevents its response from publishing.
@MainActor
@Observable
package final class RadioCoordinator: SessionGuardedCoordinator {
  package static let continuationThreshold = 2

  private enum ReadKind: Equatable {
    case personalFM
    case heartbeat
    case continuation
  }

  @ObservationIgnored private let transport: any NeteaseTransporting
  @ObservationIgnored package let vault: any CredentialStoring
  @ObservationIgnored private let arbiter: OperationArbiter
  @ObservationIgnored private weak var playback: PlaybackController?
  @ObservationIgnored package private(set) var generation = 0

  // Reads and the trash write have separate ownership. A late defer may end
  // only its exact token and may never clear a task that replaced it.
  @ObservationIgnored private var readTask: Task<Void, Never>?
  @ObservationIgnored private var readToken: OperationToken?
  @ObservationIgnored private var readSerial: UInt64 = 0
  @ObservationIgnored private var readKind: ReadKind?
  @ObservationIgnored private var allowedIntentRevision: UInt64?
  @ObservationIgnored private var writeTask: Task<Void, Never>?
  @ObservationIgnored private var writeToken: OperationToken?
  @ObservationIgnored private var writeSerial: UInt64 = 0
  @ObservationIgnored private var publishingRadioQueue = false
  @ObservationIgnored private var observedIntentRevision: UInt64 = 0
  @ObservationIgnored private var trashedIDs: Set<Int64> = []

  package var noStoredSessionStatus: String { "No stored session for radio" }

  package private(set) var isLoading = false
  package private(set) var isContinuing = false
  package private(set) var failedTrash: Track?
  package var status = "Start personal FM or heartbeat mode"

  /// A restored FM queue is only resumable state, not active radio. Finished,
  /// idle and failed queues likewise have no live audio intent.
  package var isPlayingFM: Bool {
    playback?.queueContext == .personalFM && playback?.isActive == true
  }

  package var currentFMTrack: Track? {
    guard isPlayingFM else { return nil }
    return playback?.currentTrack
  }

  package init(
    transport: any NeteaseTransporting,
    vault: any CredentialStoring,
    arbiter: OperationArbiter
  ) {
    self.transport = transport
    self.vault = vault
    self.arbiter = arbiter
  }

  package func attach(playback: PlaybackController) {
    self.playback = playback
    observedIntentRevision = playback.intentRevision
  }

  package func clearSessionScopedData() {
    trashedIDs = []
    failedTrash = nil
  }

  // MARK: - Playback intent

  /// The single callback wired to `PlaybackController`. An unchanged revision
  /// is ordinary automatic queue progression and may trigger continuation; a
  /// changed revision supersedes the read that captured the old one.
  package func playbackChanged(
    revision: UInt64,
    session: any SessionProviding
  ) {
    let intentChanged = revision != observedIntentRevision
    observedIntentRevision = revision
    guard !publishingRadioQueue else { return }
    if readTask != nil,
      intentChanged
        || (readKind == .continuation && !isPlayingFM)
    {
      cancelRead(status: "Radio request cancelled by newer playback")
    }
    // Explicit intent is announced once before it claims a source, then the
    // resulting queue state is announced with the same revision. Waiting for
    // that second notification prevents the old FM queue from immediately
    // reclaiming the slot just released for the new intent.
    guard !intentChanged else { return }
    playbackAdvanced(session: session)
  }

  // MARK: - Personal FM

  package func startPersonalFM(session: any SessionProviding) {
    guard let playback else { return }
    let intentRevision = playback.intentRevision
    read(
      kind: .personalFM,
      superseding: true,
      intentRevision: intentRevision,
      loadingStatus: "Starting personal FM (1 request)",
      operation: "Personal FM",
      session: session,
      stillApplicable: {
        self.playback?.intentRevision == intentRevision
      },
      fetch: { credential in
        try await self.transport.personalFM(credential: credential)
      },
      apply: { tracks in
        self.failedTrash = nil
        let fresh = Self.deduplicated(
          tracks.filter { !self.trashedIDs.contains($0.id) }
        )
        guard !fresh.isEmpty, let playback = self.playback else {
          return "Personal FM returned no tracks"
        }
        self.publishingRadioQueue = true
        playback.play(
          tracks: fresh,
          startIndex: 0,
          context: .personalFM,
          session: session
        )
        self.publishingRadioQueue = false
        return "Personal FM started with \(fresh.count) tracks"
      }
    )
  }

  /// Called for automatic queue movement as well as explicit intent changes.
  /// Only an active FM queue near its end can claim a continuation read.
  package func playbackAdvanced(session: any SessionProviding) {
    guard isPlayingFM, readTask == nil, writeTask == nil else { return }
    guard let playback, let queue = playback.queue else { return }
    let remaining = queue.count - queue.currentIndex - 1
    guard remaining <= Self.continuationThreshold else { return }

    let intentRevision = playback.intentRevision
    read(
      kind: .continuation,
      superseding: false,
      intentRevision: intentRevision,
      loadingStatus: "Fetching more personal FM (1 request)",
      operation: "Personal FM",
      session: session,
      stillApplicable: {
        self.isPlayingFM && self.playback?.intentRevision == intentRevision
      },
      fetch: { credential in
        try await self.transport.personalFM(credential: credential)
      },
      apply: { tracks in
        guard let playback = self.playback, self.isPlayingFM else {
          return "Radio request cancelled by newer playback"
        }
        let wanted = tracks.filter { !self.trashedIDs.contains($0.id) }
        let added = playback.extendQueue(
          with: Self.deduplicated(wanted),
          context: .personalFM
        )
        return added > 0
          ? "Personal FM continued with \(added) more tracks"
          : "Personal FM returned nothing new"
      }
    )
  }

  // MARK: - FM trash

  package func trashCurrentFMSong(session: any SessionProviding) {
    guard isPlayingFM, let playback, let track = playback.currentTrack else {
      return
    }
    guard readTask == nil, writeTask == nil else { return }
    guard let token = arbiter.begin(name: "Trash FM song", effect: .write) else {
      return
    }
    guard let account = session.account else {
      arbiter.end(token, outcome: .failed)
      status = "Validate the session before using personal FM"
      return
    }

    writeSerial &+= 1
    let serial = writeSerial
    let currentGeneration = generation
    writeToken = token
    isLoading = true
    status = "Removing \(track.name) from personal FM (1 request)"
    writeTask = Task {
      var outcome = OperationOutcome.failed
      var released = false
      defer {
        if !released { self.releaseWrite(token, outcome: outcome) }
        self.finishWrite(serial: serial)
      }
      do {
        guard
          let credential = try await self.currentCredential(
            account: account,
            generation: currentGeneration,
            session: session
          )
        else { return }
        self.arbiter.markRequestSent(token)
        try await self.transport.trashFMSong(
          songID: track.id,
          credential: credential
        )
        self.arbiter.markSettling(token)
        outcome = .appliedRemotelyOnly
        guard
          try await self.sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: currentGeneration,
            session: session
          )
        else { return }

        self.trashedIDs.insert(track.id)
        self.failedTrash = nil
        // A stopped, finished or replacement queue is not the queue this write
        // targeted. The server result is recorded, but local playback is left
        // exactly as the newer intent established it.
        guard self.isPlayingFM else {
          outcome = .applied
          self.status =
            "Removed \(track.name) on the server; the local queue had changed"
          return
        }
        guard playback.queuedTracks(context: .personalFM).contains(where: {
          $0.id == track.id
        }) else {
          outcome = .applied
          self.status =
            "Removed \(track.name) on the server; the local queue had changed"
          return
        }

        outcome = .applied
        self.releaseWrite(token, outcome: outcome)
        released = true
        let removed = playback.removeTrack(
          songID: track.id,
          from: .personalFM,
          session: session,
          emptyStatus: "Removed \(track.name); personal FM has nothing left to play"
        )
        self.status = removed
          ? "Removed \(track.name) from personal FM"
          : "Removed \(track.name) on the server; the local queue had changed"
      } catch is CancellationError {
        outcome = .cancelled
      } catch {
        if Task.isCancelled {
          outcome = .cancelled
        } else if let service = error as? NeteaseServiceError,
          service.provesWriteDidNotRun
        {
          outcome = .failed
        } else if self.arbiter.abandoningLosesTheOutcome(token) {
          outcome = .outcomeUnknown
        }
        guard self.generation == currentGeneration else { return }
        self.failedTrash = track
        let failure = OperationFailure.classify(
          error,
          cancelled: Task.isCancelled
        )
        guard failure.isReportable else { return }
        self.status = failure.statusText(operation: "Trash FM song")
      }
    }
  }

  // MARK: - Heartbeat mode

  package func startHeartbeatMode(
    seed: Track,
    playlistID: Int64,
    session: any SessionProviding
  ) {
    guard Self.canStartHeartbeat(seed: seed, playlistID: playlistID) else {
      status = "Heartbeat mode needs a song opened from one of your playlists"
      return
    }
    guard let playback else { return }
    let intentRevision = playback.intentRevision
    read(
      kind: .heartbeat,
      superseding: true,
      intentRevision: intentRevision,
      loadingStatus: "Starting heartbeat mode (1 request)",
      operation: "Heartbeat mode",
      session: session,
      stillApplicable: {
        self.playback?.intentRevision == intentRevision
      },
      fetch: { credential in
        try await self.transport.heartbeatQueue(
          songID: seed.id,
          playlistID: playlistID,
          startMusicID: seed.id,
          credential: credential
        )
      },
      apply: { tracks in
        let queue = Self.deduplicated(tracks)
        guard !queue.isEmpty, let playback = self.playback else {
          return "Heartbeat mode returned no tracks for \(seed.name)"
        }
        self.publishingRadioQueue = true
        playback.play(
          tracks: queue,
          startIndex: 0,
          context: .heartbeatMode(seedName: seed.name),
          session: session
        )
        self.publishingRadioQueue = false
        return "Heartbeat mode started with \(queue.count) tracks"
      }
    )
  }

  package static func canStartHeartbeat(seed: Track, playlistID: Int64) -> Bool {
    seed.id > 0 && playlistID > 0
  }

  // MARK: - Lifecycle

  package func settleForTesting() async {
    let read = readTask
    let write = writeTask
    await read?.value
    await write?.value
  }

  package func reset() {
    generation += 1
    cancelRead(status: nil)
    if !arbiter.activeWriteIsInFlight {
      cancelWrite()
    }
    isContinuing = false
    isLoading = false
    clearSessionScopedData()
    status = "Start personal FM or heartbeat mode"
  }

  // MARK: - Shared read execution

  private func read<Value: Sendable>(
    kind: ReadKind,
    superseding: Bool,
    intentRevision: UInt64,
    loadingStatus: String,
    operation: String,
    session: any SessionProviding,
    stillApplicable: @escaping @MainActor () -> Bool,
    fetch: @escaping @MainActor (NeteaseCredential) async throws -> Value,
    apply: @escaping @MainActor (Value) -> String
  ) {
    if superseding { cancelRead(status: nil) }
    guard readTask == nil, writeTask == nil else { return }
    guard let token = arbiter.begin(name: operation, effect: .read) else { return }
    guard let account = session.account else {
      arbiter.end(token, outcome: .failed)
      status = "Validate the session before using radio"
      return
    }

    readSerial &+= 1
    let serial = readSerial
    let currentGeneration = generation
    readToken = token
    readKind = kind
    allowedIntentRevision = intentRevision
    isContinuing = kind == .continuation
    isLoading = true
    status = loadingStatus
    readTask = Task {
      var outcome = OperationOutcome.failed
      var released = false
      defer {
        if !released { self.releaseRead(token, outcome: outcome) }
        self.finishRead(serial: serial)
      }
      do {
        guard
          let credential = try await self.currentCredential(
            account: account,
            generation: currentGeneration,
            session: session
          ),
          self.acceptsRead(serial: serial, intentRevision: intentRevision)
        else { return }
        let value = try await fetch(credential)
        guard
          self.acceptsRead(serial: serial, intentRevision: intentRevision),
          try await self.sessionRemainsCurrent(
            account: account,
            credential: credential,
            generation: currentGeneration,
            session: session
          ),
          self.acceptsRead(serial: serial, intentRevision: intentRevision),
          stillApplicable()
        else {
          outcome = .cancelled
          return
        }

        // The response is in hand. Give the read slot back before a startup
        // queue asks PlaybackController for its own resolution slot.
        outcome = .applied
        self.releaseRead(token, outcome: outcome)
        released = true
        self.status = apply(value)
      } catch {
        outcome = Task.isCancelled ? .cancelled : .failed
        guard self.readSerial == serial,
          self.generation == currentGeneration
        else { return }
        let failure = OperationFailure.classify(
          error,
          cancelled: Task.isCancelled
        )
        guard failure.isReportable else { return }
        self.status = failure.statusText(operation: operation)
      }
    }
  }

  private func acceptsRead(serial: UInt64, intentRevision: UInt64) -> Bool {
    readSerial == serial
      && allowedIntentRevision == intentRevision
      && playback?.intentRevision == intentRevision
      && !Task.isCancelled
  }

  private func cancelRead(status newStatus: String?) {
    guard readTask != nil || readToken != nil || readKind != nil else { return }
    readSerial &+= 1
    readTask?.cancel()
    readTask = nil
    if let token = readToken {
      readToken = nil
      arbiter.end(token, outcome: .cancelled)
    }
    readKind = nil
    allowedIntentRevision = nil
    isContinuing = false
    isLoading = writeTask != nil
    if let newStatus { status = newStatus }
  }

  private func finishRead(serial: UInt64) {
    guard readSerial == serial else { return }
    readTask = nil
    readToken = nil
    readKind = nil
    allowedIntentRevision = nil
    isContinuing = false
    isLoading = writeTask != nil
  }

  private func releaseRead(
    _ token: OperationToken,
    outcome: OperationOutcome
  ) {
    if readToken == token { readToken = nil }
    arbiter.end(token, outcome: outcome)
  }

  // MARK: - Shared write execution

  private func cancelWrite() {
    guard writeTask != nil || writeToken != nil else { return }
    writeSerial &+= 1
    writeTask?.cancel()
    writeTask = nil
    if let token = writeToken {
      writeToken = nil
      arbiter.end(token, outcome: .cancelled)
    }
    isLoading = readTask != nil
  }

  private func finishWrite(serial: UInt64) {
    guard writeSerial == serial else { return }
    writeTask = nil
    writeToken = nil
    isLoading = readTask != nil
  }

  private func releaseWrite(
    _ token: OperationToken,
    outcome: OperationOutcome
  ) {
    if writeToken == token { writeToken = nil }
    arbiter.end(token, outcome: outcome)
  }

  private static func deduplicated(_ tracks: [Track]) -> [Track] {
    var seen: Set<Int64> = []
    return tracks.filter { seen.insert($0.id).inserted }
  }
}

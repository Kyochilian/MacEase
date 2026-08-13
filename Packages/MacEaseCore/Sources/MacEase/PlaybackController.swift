import AVFoundation
import Foundation
import MacEaseSession
import NeteaseKit
import Observation

/// Explicit single-track playback. Every Play or Play Again action performs
/// exactly one `resolveSongURL` request; there is no queue, prefetch,
/// automatic retry or automatic next track.
@MainActor
@Observable
final class PlaybackController {
  enum Phase: Equatable {
    case idle
    case resolving
    case playing
    case finished
    case failed
  }

  @ObservationIgnored private let session: NeteaseSession
  @ObservationIgnored private let vault = CredentialVault()
  @ObservationIgnored private var gate = PlaybackIntentGate()
  @ObservationIgnored private var playTask: Task<Void, Never>?
  @ObservationIgnored private var player: AVPlayer?
  @ObservationIgnored private var periodicObserver: Any?
  @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
  @ObservationIgnored private var playedToEndObserver: NSObjectProtocol?
  @ObservationIgnored private var recoverySnapshot: PlaybackRecoverySnapshot?

  private(set) var phase: Phase = .idle
  private(set) var trackName: String?
  private(set) var positionSeconds: Double = 0
  private(set) var status = "Play a track from the library"
  var quality: PlaybackQuality = .standard

  var isResolving: Bool { phase == .resolving }
  var isActive: Bool { phase == .resolving || phase == .playing }
  var canPlayAgain: Bool { phase == .failed && recoverySnapshot != nil }

  init(session: NeteaseSession) {
    self.session = session
  }

  func play(trackID: Int64, name: String, loginCoordinator: LoginCoordinator) {
    guard !loginCoordinator.isBusy else { return }
    guard let account = loginCoordinator.account else {
      status = "Validate the session before playback"
      return
    }

    let token = beginIntent()
    recoverySnapshot = nil
    trackName = name
    phase = .resolving
    status = "Resolving song URL (1 request)"
    let requestedQuality = quality
    playTask = Task {
      await resolveAndPlay(
        songID: trackID,
        quality: requestedQuality,
        account: account,
        recovery: nil,
        loginCoordinator: loginCoordinator,
        token: token
      )
    }
  }

  func playAgain(loginCoordinator: LoginCoordinator) {
    guard !loginCoordinator.isBusy else { return }
    guard let account = loginCoordinator.account else {
      status = "Validate the session before playback"
      return
    }
    guard let snapshot = recoverySnapshot else { return }

    let token = beginIntent()
    phase = .resolving
    status = "Re-resolving song URL (1 request)"
    playTask = Task {
      await resolveAndPlay(
        songID: snapshot.songID,
        quality: snapshot.quality,
        account: account,
        recovery: snapshot,
        loginCoordinator: loginCoordinator,
        token: token
      )
    }
  }

  func stop() {
    gate.cancel()
    playTask?.cancel()
    playTask = nil
    recoverySnapshot = nil
    releasePlayback()
    phase = .idle
    trackName = nil
    positionSeconds = 0
    status = "Playback stopped"
  }

  private func resolveAndPlay(
    songID: Int64,
    quality: PlaybackQuality,
    account: NeteaseAccount,
    recovery: PlaybackRecoverySnapshot?,
    loginCoordinator: LoginCoordinator,
    token: PlaybackIntentGate.Token
  ) async {
    defer {
      if gate.accepts(token) {
        playTask = nil
      }
    }

    var requestCredential: NeteaseCredential?
    do {
      guard
        let credential = try await currentCredential(
          account: account,
          loginCoordinator: loginCoordinator,
          token: token
        )
      else { return }
      requestCredential = credential

      let resolution = try await session.resolveSongURL(
        songID: songID,
        quality: quality,
        credential: credential
      )
      try checkCurrent(token)
      guard
        try await sessionRemainsCurrent(
          account: account,
          credential: credential,
          loginCoordinator: loginCoordinator,
          token: token
        )
      else { return }

      switch resolution {
      case .unavailable(let itemCode, let fee):
        recoverySnapshot = nil
        phase = .failed
        status =
          "Track unavailable: itemCode=\(itemCode), "
          + "fee=\(fee.map(String.init) ?? "none")"
      case .resolved(let resolved):
        try await startPlayback(asset: resolved, recovery: recovery, token: token)
      }
    } catch {
      guard gate.accepts(token), !Task.isCancelled else { return }
      await handle(
        error,
        credential: requestCredential,
        loginCoordinator: loginCoordinator,
        token: token
      )
    }
  }

  private func startPlayback(
    asset resolved: ResolvedAudioAsset,
    recovery: PlaybackRecoverySnapshot?,
    token: PlaybackIntentGate.Token
  ) async throws {
    let asset = AVURLAsset(
      url: resolved.url,
      options: [AVURLAssetHTTPUserAgentKey: "MacEasePhase0/0.1 (macOS 15)"]
    )
    let isPlayable = try await asset.load(.isPlayable)
    try checkCurrent(token)
    guard isPlayable else {
      recoverySnapshot = nil
      phase = .failed
      status = "Resolved asset is not playable: " + assetSummary(resolved)
      return
    }

    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    self.player = player
    observe(item: item, of: player, token: token)

    let resumePosition = recovery?.position ?? 0
    recoverySnapshot = PlaybackRecoverySnapshot(
      songID: resolved.songID,
      quality: resolved.requestedQuality,
      position: resumePosition,
      shouldResume: true
    )
    if resumePosition > 0 {
      try await seek(player, to: resumePosition)
      try checkCurrent(token)
    }
    player.play()
    positionSeconds = resumePosition
    phase = .playing
    status = "Playing: " + assetSummary(resolved)
  }

  private func observe(
    item: AVPlayerItem,
    of player: AVPlayer,
    token: PlaybackIntentGate.Token
  ) {
    itemStatusObservation = item.observe(\.status, options: [.new]) {
      [weak self] item, _ in
      guard item.status == .failed else { return }
      Task { @MainActor [weak self] in
        self?.handleItemFailure(token: token)
      }
    }
    playedToEndObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification,
      object: item,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.handlePlayedToEnd(token: token)
      }
    }
    periodicObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      Task { @MainActor [weak self] in
        guard let self, self.gate.accepts(token) else { return }
        let seconds = time.seconds
        if seconds.isFinite, seconds >= 0 {
          self.positionSeconds = seconds
        }
      }
    }
  }

  private func handleItemFailure(token: PlaybackIntentGate.Token) {
    guard gate.accepts(token) else { return }
    gate.cancel()
    let position = currentPosition()
    let detail = player?.currentItem?.error.map(Self.failureDetail) ?? "unknown"
    recoverySnapshot = recoverySnapshot.map {
      PlaybackRecoverySnapshot(
        songID: $0.songID,
        quality: $0.quality,
        position: position,
        shouldResume: true
      )
    }
    releasePlayback()
    phase = .failed
    status = "Playback failed (\(detail)); Play Again re-resolves the URL"
  }

  private func handlePlayedToEnd(token: PlaybackIntentGate.Token) {
    guard gate.accepts(token) else { return }
    gate.cancel()
    recoverySnapshot = nil
    releasePlayback()
    phase = .finished
    status = "Playback finished; no automatic next track"
  }

  private func currentCredential(
    account: NeteaseAccount,
    loginCoordinator: LoginCoordinator,
    token: PlaybackIntentGate.Token
  ) async throws -> NeteaseCredential? {
    let credential = try await vault.load()
    try checkCurrent(token)
    guard let credential else {
      loginCoordinator.hasStoredSession = false
      loginCoordinator.account = nil
      loginCoordinator.status = "No stored session to validate"
      abandonPlayback(status: "No stored session for playback")
      return nil
    }
    guard loginCoordinator.matchesValidatedSession(credential, account: account) else {
      loginCoordinator.hasStoredSession = true
      loginCoordinator.account = nil
      loginCoordinator.status = "Stored session changed; validate again"
      abandonPlayback(status: "Session changed; validate again")
      return nil
    }
    return credential
  }

  private func sessionRemainsCurrent(
    account: NeteaseAccount,
    credential: NeteaseCredential,
    loginCoordinator: LoginCoordinator,
    token: PlaybackIntentGate.Token
  ) async throws -> Bool {
    let stored = try await vault.load()
    try checkCurrent(token)
    guard
      stored == credential,
      loginCoordinator.matchesValidatedSession(credential, account: account)
    else {
      loginCoordinator.hasStoredSession = stored != nil
      loginCoordinator.account = nil
      loginCoordinator.status = "Stored session changed; validate again"
      abandonPlayback(status: "Session changed; validate again")
      return false
    }
    return true
  }

  private func handle(
    _ error: Error,
    credential: NeteaseCredential?,
    loginCoordinator: LoginCoordinator,
    token: PlaybackIntentGate.Token
  ) async {
    releasePlayback()
    switch error {
    case let error as NeteaseServiceError
    where error.source == .service && error.statusCode == 301:
      guard let credential else {
        phase = .failed
        status = "Song URL service error 301"
        return
      }
      let invalidation = await loginCoordinator.invalidateStoredSession(
        matching: credential,
        message: "Stored session expired; sign in again"
      )
      guard gate.accepts(token), !Task.isCancelled else { return }
      switch invalidation {
      case .deleted:
        abandonPlayback(status: "Stored session expired; sign in again")
      case .notCurrent:
        abandonPlayback(status: "Session changed; validate again")
      case .busy:
        abandonPlayback(status: "Session busy; validate again")
      case .failed:
        abandonPlayback(status: "Session invalidation failed")
      }
    case let error as NeteaseServiceError:
      phase = .failed
      status = "Song URL \(error.source.rawValue) error \(error.statusCode)"
    case NeteasePlaybackError.nonHTTPSURL(let host):
      recoverySnapshot = nil
      phase = .failed
      status = "Rejected non-HTTPS playback host \(host)"
    case NeteasePlaybackError.unapprovedHost(let host):
      recoverySnapshot = nil
      phase = .failed
      status = "Rejected unapproved playback host \(host)"
    case NeteasePlaybackError.invalidResponse:
      phase = .failed
      status = "Song URL invalid response"
    case let error as CredentialVaultError:
      phase = .failed
      status = "Keychain error \(error.status)"
    default:
      phase = .failed
      status = "Song URL network or response error"
    }
  }

  private func abandonPlayback(status: String) {
    recoverySnapshot = nil
    releasePlayback()
    phase = .idle
    trackName = nil
    positionSeconds = 0
    self.status = status
  }

  private func beginIntent() -> PlaybackIntentGate.Token {
    let token = gate.begin()
    playTask?.cancel()
    playTask = nil
    releasePlayback()
    positionSeconds = 0
    return token
  }

  private func releasePlayback() {
    itemStatusObservation?.invalidate()
    itemStatusObservation = nil
    if let playedToEndObserver {
      NotificationCenter.default.removeObserver(playedToEndObserver)
      self.playedToEndObserver = nil
    }
    if let periodicObserver, let player {
      player.removeTimeObserver(periodicObserver)
    }
    periodicObserver = nil
    player?.currentItem?.cancelPendingSeeks()
    player?.pause()
    player = nil
  }

  private func currentPosition() -> Double {
    guard
      let seconds = player?.currentTime().seconds, seconds.isFinite, seconds >= 0
    else {
      return recoverySnapshot?.position ?? 0
    }
    return seconds
  }

  private func seek(_ player: AVPlayer, to seconds: Double) async throws {
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    let finished = await withCheckedContinuation { continuation in
      player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) {
        continuation.resume(returning: $0)
      }
    }
    guard finished else { throw CancellationError() }
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

  private static func failureDetail(_ error: Error) -> String {
    let error = error as NSError
    return "\(error.domain) \(error.code)"
  }
}

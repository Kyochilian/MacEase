import AVFoundation
import Foundation
import MacEaseSession
import NeteaseKit
import Observation

@MainActor
@Observable
final class PlaybackProbeCoordinator {
  @ObservationIgnored private let session = NeteaseSession()
  @ObservationIgnored private let vault = CredentialVault()
  @ObservationIgnored private var player: AVPlayer?
  @ObservationIgnored private var playTask: Task<Void, Never>?
  @ObservationIgnored private var intentGate = PlaybackIntentGate()
  @ObservationIgnored private var playbackContext: PlaybackRecoverySnapshot?

  var songID = "347230"
  var quality: PlaybackQuality = .standard
  var seekPosition = "0"
  var status = "Not run"

  func play(loginCoordinator: LoginCoordinator) {
    guard let songID = Int64(songID), songID > 0 else {
      status = "Enter a positive song ID"
      return
    }

    let requestedQuality = quality
    let token = beginRequest(
      operation: "play",
      quality: requestedQuality
    )
    playTask = Task { [weak self, weak loginCoordinator] in
      guard let self, let loginCoordinator else { return }
      await resolveAndPlay(
        songID: songID,
        quality: requestedQuality,
        loginCoordinator: loginCoordinator,
        token: token
      )
    }
  }

  func probeCDN(loginCoordinator: LoginCoordinator) {
    guard let songID = Int64(songID), songID > 0 else {
      status = "Enter a positive song ID"
      return
    }

    let requestedQuality = quality
    let token = beginRequest(
      operation: "CDN probe",
      quality: requestedQuality
    )
    playTask = Task { [weak self, weak loginCoordinator] in
      guard let self, let loginCoordinator else { return }
      await resolveAndProbe(
        songID: songID,
        quality: requestedQuality,
        loginCoordinator: loginCoordinator,
        token: token
      )
    }
  }

  func stop() {
    intentGate.cancel()
    playTask?.cancel()
    playTask = nil
    playbackContext = nil
    releasePlayback()
    status = "eapi AVPlayer stopped"
  }

  func seek() {
    guard let seconds = Double(seekPosition), seconds.isFinite, seconds >= 0,
      let player
    else {
      status = "Enter a non-negative seek position"
      return
    }

    let token = intentGate.begin()
    playTask?.cancel()
    playTask = nil
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    Task { [weak self, weak player] in
      guard let self, let player else { return }
      player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) {
        [weak self] finished in
        Task { @MainActor [weak self] in
          guard let self, self.intentGate.accepts(token) else { return }
          guard finished else {
            self.status = "eapi AVPlayer seek interrupted"
            return
          }
          let position = self.currentPosition()
          self.playbackContext = self.playbackContext.map {
            PlaybackRecoverySnapshot(
              songID: $0.songID,
              quality: $0.quality,
              position: position,
              shouldResume: $0.shouldResume
            )
          }
          self.status = "eapi AVPlayer seek completed: position=\(position)"
        }
      }
    }
  }

  func refreshCurrentAsset(loginCoordinator: LoginCoordinator) {
    guard let context = playbackContext else {
      status = "eapi refresh: result=noActiveTrack"
      return
    }

    let position = currentPosition()
    let snapshot = PlaybackRecoverySnapshot(
      songID: context.songID,
      quality: context.quality,
      position: position,
      shouldResume: context.shouldResume
    )
    playbackContext = snapshot
    let token = beginRequest(
      operation: "refresh",
      quality: snapshot.quality,
      preserveContext: true
    )
    playTask = Task { [weak self, weak loginCoordinator] in
      guard let self, let loginCoordinator else { return }
      await resolveAndPlay(
        songID: snapshot.songID,
        quality: snapshot.quality,
        loginCoordinator: loginCoordinator,
        token: token,
        operation: "refresh",
        recovery: snapshot
      )
    }
  }

  func handleSleep() {
    let interruptedRequest = playTask != nil
    let interruptedPlayback = playbackContext != nil || player != nil
    intentGate.cancel()
    playTask?.cancel()
    playTask = nil
    let position = currentPosition()
    let context = playbackContext
    releasePlayback()
    if let context {
      playbackContext = PlaybackRecoverySnapshot(
        songID: context.songID,
        quality: context.quality,
        position: position,
        shouldResume: false
      )
    }
    if interruptedPlayback {
      status = "eapi AVPlayer paused for system sleep"
    } else if interruptedRequest {
      status = "eapi request canceled for system sleep"
    }
  }

  func handleWake() {
    guard playbackContext != nil else { return }
    player?.pause()
    status = "eapi AVPlayer paused after wake; refresh or play to revalidate URL"
  }

  private func resolveAndPlay(
    songID: Int64,
    quality: PlaybackQuality,
    loginCoordinator: LoginCoordinator,
    token: PlaybackIntentGate.Token,
    operation: String = "play",
    recovery: PlaybackRecoverySnapshot? = nil
  ) async {
    defer {
      if intentGate.accepts(token) {
        playTask = nil
      }
    }

    var requestCredential: NeteaseCredential?
    do {
      let credential = try await vault.load()
      try checkCurrent(token)
      guard let credential else {
        status = failureStatus(
          operation: operation,
          result: "noStoredSession",
          quality: quality
        )
        return
      }
      requestCredential = credential

      let resolution = try await session.resolveSongURL(
        songID: songID,
        quality: quality,
        credential: credential
      )
      try checkCurrent(token)

      switch resolution {
      case .unavailable(let itemCode, let fee):
        status = unavailableStatus(
          operation: operation,
          quality: quality,
          itemCode: itemCode,
          fee: fee
        )
      case .resolved(let resolved):
        let asset = AVURLAsset(
          url: resolved.url,
          options: [AVURLAssetHTTPUserAgentKey: "MacEasePhase0/0.1 (macOS 15)"]
        )
        let isPlayable = try await asset.load(.isPlayable)
        try checkCurrent(token)
        guard isPlayable else {
          status = resolvedStatus(
            operation: operation,
            result: "assetNotPlayable",
            asset: resolved
          )
          return
        }

        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        self.player = player
        let resumePosition = recovery?.position ?? 0
        self.playbackContext = PlaybackRecoverySnapshot(
          songID: songID,
          quality: quality,
          position: resumePosition,
          shouldResume: recovery?.shouldResume ?? true
        )
        if resumePosition > 0 {
          try await seek(player, to: resumePosition)
          try checkCurrent(token)
        }
        if recovery?.shouldResume ?? true {
          player.play()
        }
        status = resolvedStatus(
          operation: operation,
          result: recovery == nil || recovery?.shouldResume == true
            ? "playRequested" : "refreshedPaused",
          asset: resolved
        )
      }
    } catch {
      guard intentGate.accepts(token), !Task.isCancelled else { return }
      await handle(
        error,
        credential: requestCredential,
        operation: operation,
        quality: quality,
        loginCoordinator: loginCoordinator,
        token: token
      )
    }
  }

  private func resolveAndProbe(
    songID: Int64,
    quality: PlaybackQuality,
    loginCoordinator: LoginCoordinator,
    token: PlaybackIntentGate.Token
  ) async {
    defer {
      if intentGate.accepts(token) {
        playTask = nil
      }
    }

    var requestCredential: NeteaseCredential?
    do {
      let credential = try await vault.load()
      try checkCurrent(token)
      guard let credential else {
        status = failureStatus(
          operation: "CDN probe",
          result: "noStoredSession",
          quality: quality
        )
        return
      }
      requestCredential = credential
      let resolution = try await session.resolveSongURL(
        songID: songID,
        quality: quality,
        credential: credential
      )
      try checkCurrent(token)

      switch resolution {
      case .unavailable(let itemCode, let fee):
        status = unavailableStatus(
          operation: "CDN probe",
          quality: quality,
          itemCode: itemCode,
          fee: fee
        )
      case .resolved(let resolved):
        let result = try await session.probeAudioURL(resolved)
        try checkCurrent(token)
        status =
          resolvedStatus(
            operation: "CDN probe",
            result: "probeCompleted",
            asset: resolved
          )
          + ", httpStatus=\(result.statusCode), range=\(result.rangeResponse), "
          + "contentType=\(result.contentType ?? "none"), "
          + "redirectScheme=\(result.redirectScheme ?? "none"), "
          + "redirectHost=\(result.redirectHost ?? "none")"
      }
    } catch {
      guard intentGate.accepts(token), !Task.isCancelled else { return }
      await handle(
        error,
        credential: requestCredential,
        operation: "CDN probe",
        quality: quality,
        loginCoordinator: loginCoordinator,
        token: token
      )
    }
  }

  private func handle(
    _ error: Error,
    credential: NeteaseCredential?,
    operation: String,
    quality: PlaybackQuality,
    loginCoordinator: LoginCoordinator,
    token: PlaybackIntentGate.Token
  ) async {
    guard intentGate.accepts(token), !Task.isCancelled else { return }

    switch error {
    case let error as NeteaseServiceError
    where error.source == .service && error.statusCode == 301:
      guard let credential else { return }
      playbackContext = nil
      releasePlayback()
      let invalidation = await loginCoordinator.invalidateStoredSession(
        matching: credential,
        message: "eapi session expired; sign in again"
      )
      guard intentGate.accepts(token), !Task.isCancelled else { return }
      switch invalidation {
      case .deleted:
        status = failureStatus(
          operation: operation,
          result: "sessionExpired",
          quality: quality
        )
      case .notCurrent:
        status = failureStatus(
          operation: operation,
          result: "sessionNotCurrent",
          quality: quality
        )
      case .busy:
        status = failureStatus(
          operation: operation,
          result: "sessionInvalidationBusy",
          quality: quality
        )
      case .failed:
        status = failureStatus(
          operation: operation,
          result: "sessionInvalidationFailed",
          quality: quality
        )
      }
    case let error as NeteaseServiceError:
      status = failureStatus(
        operation: operation,
        result: "\(error.source.rawValue)Error",
        quality: quality,
        detail: "status=\(error.statusCode)"
      )
    case NeteasePlaybackError.invalidResponse:
      status = failureStatus(
        operation: operation,
        result: "invalidResponse",
        quality: quality
      )
    case NeteasePlaybackError.nonHTTPSURL(let host):
      status = failureStatus(
        operation: operation,
        result: "disallowedHTTP",
        quality: quality,
        detail: "host=\(host)"
      )
    case NeteasePlaybackError.unapprovedHost(let host):
      status = failureStatus(
        operation: operation,
        result: "unapprovedHost",
        quality: quality,
        detail: "host=\(host)"
      )
    case let error as CredentialVaultError:
      status = failureStatus(
        operation: operation,
        result: "keychainError",
        quality: quality,
        detail: error.diagnostic
      )
    case is DecodingError:
      status = failureStatus(
        operation: operation,
        result: "invalidResponse",
        quality: quality
      )
    default:
      let error = error as NSError
      status = failureStatus(
        operation: operation,
        result: "networkOrPlaybackError",
        quality: quality,
        detail: "code=\(error.code)"
      )
    }
  }

  private func releasePlayback() {
    player?.currentItem?.cancelPendingSeeks()
    player?.pause()
    player = nil
  }

  private func currentPosition() -> Double {
    guard let seconds = player?.currentTime().seconds, seconds.isFinite, seconds >= 0 else {
      return playbackContext?.position ?? 0
    }
    return seconds
  }

  private func seek(_ player: AVPlayer, to seconds: Double) async throws {
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    let finished = await withCheckedContinuation { continuation in
      player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
        continuation.resume(returning: finished)
      }
    }
    guard finished else { throw CancellationError() }
  }

  private func checkCurrent(_ token: PlaybackIntentGate.Token) throws {
    try Task.checkCancellation()
    guard intentGate.accepts(token) else { throw CancellationError() }
  }

  private func beginRequest(
    operation: String,
    quality: PlaybackQuality,
    preserveContext: Bool = false
  ) -> PlaybackIntentGate.Token {
    let token = intentGate.begin()
    playTask?.cancel()
    playTask = nil
    if !preserveContext {
      playbackContext = nil
    }
    releasePlayback()
    status = "eapi \(operation) resolving: requestedQuality=\(quality.rawValue)"
    return token
  }

  private func resolvedStatus(
    operation: String,
    result: String,
    asset: ResolvedAudioAsset
  ) -> String {
    "eapi \(operation): result=\(result), resolution=resolved, "
      + "requestedQuality=\(asset.requestedQuality.rawValue), "
      + "actualQuality=\(asset.actualQuality ?? "none"), "
      + "format=\(asset.format ?? "none"), "
      + "bitRate=\(asset.bitRate.map(String.init) ?? "none"), "
      + "byteCount=\(asset.byteCount.map(String.init) ?? "none"), "
      + "expiresIn=\(asset.expiresIn.map(String.init) ?? "none"), "
      + "fee=\(asset.fee.map(String.init) ?? "none"), "
      + "trial=\(asset.trial), "
      + "sourceScheme=\(asset.sourceScheme), "
      + "playbackScheme=\(asset.url.scheme ?? "none"), "
      + "host=\(asset.url.host ?? "none")"
  }

  private func unavailableStatus(
    operation: String,
    quality: PlaybackQuality,
    itemCode: Int,
    fee: Int?
  ) -> String {
    "eapi \(operation): result=unavailable, requestedQuality=\(quality.rawValue), "
      + "actualQuality=none, format=none, bitRate=none, byteCount=none, "
      + "expiresIn=none, fee=\(fee.map(String.init) ?? "none"), trial=none, "
      + "sourceScheme=none, playbackScheme=none, host=none, itemCode=\(itemCode)"
  }

  private func failureStatus(
    operation: String,
    result: String,
    quality: PlaybackQuality,
    detail: String? = nil
  ) -> String {
    let base =
      "eapi \(operation): result=\(result), requestedQuality=\(quality.rawValue), "
      + "actualQuality=none, format=none, bitRate=none, byteCount=none, "
      + "expiresIn=none, fee=none, trial=none, sourceScheme=none, "
      + "playbackScheme=none, host=none"
    return detail.map { "\(base), \($0)" } ?? base
  }
}

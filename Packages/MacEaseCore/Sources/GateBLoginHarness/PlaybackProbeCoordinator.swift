import AVFoundation
import Foundation
import NeteaseKit
import Observation

@MainActor
@Observable
final class PlaybackProbeCoordinator {
  @ObservationIgnored private let session = NeteaseSession()
  @ObservationIgnored private let vault = CredentialVault()
  @ObservationIgnored private var player: AVPlayer?
  @ObservationIgnored private var playTask: Task<Void, Never>?
  @ObservationIgnored private var generation = 0

  var songID = "347230"
  var status = "Not run"
  var isBusy = false

  func play(loginCoordinator: LoginCoordinator) {
    guard !isBusy else { return }
    guard let songID = Int64(songID), songID > 0 else {
      status = "Enter a positive song ID"
      return
    }

    isBusy = true
    generation += 1
    let requestGeneration = generation
    releasePlayback()
    playTask = Task { [weak self, weak loginCoordinator] in
      guard let self, let loginCoordinator else { return }
      await resolveAndPlay(
        songID: songID,
        loginCoordinator: loginCoordinator,
        generation: requestGeneration
      )
    }
  }

  func probeCDN(loginCoordinator: LoginCoordinator) {
    guard !isBusy else { return }
    guard let songID = Int64(songID), songID > 0 else {
      status = "Enter a positive song ID"
      return
    }

    isBusy = true
    generation += 1
    let requestGeneration = generation
    releasePlayback()
    playTask = Task { [weak self, weak loginCoordinator] in
      guard let self, let loginCoordinator else { return }
      await resolveAndProbe(
        songID: songID,
        loginCoordinator: loginCoordinator,
        generation: requestGeneration
      )
    }
  }

  func stop() {
    generation += 1
    playTask?.cancel()
    playTask = nil
    isBusy = false
    releasePlayback()
    status = "eapi AVPlayer stopped"
  }

  private func resolveAndPlay(
    songID: Int64,
    loginCoordinator: LoginCoordinator,
    generation: Int
  ) async {
    defer {
      if self.generation == generation {
        playTask = nil
        isBusy = false
      }
    }

    var requestCredential: NeteaseCredential?
    do {
      let credential = try await vault.load()
      try Task.checkCancellation()
      guard let credential else {
        status = "No stored session for eapi playback"
        return
      }
      requestCredential = credential

      let resolution = try await session.resolveSongURL(
        songID: songID,
        quality: .standard,
        credential: credential
      )
      try Task.checkCancellation()

      switch resolution {
      case .unavailable(let itemCode, let fee):
        status = "eapi song unavailable: item code \(itemCode), fee \(fee.map(String.init) ?? "none")"
      case .resolved(let resolved):
        let asset = AVURLAsset(
          url: resolved.url,
          options: [AVURLAssetHTTPUserAgentKey: "MacEasePhase0/0.1 (macOS 15)"]
        )
        guard try await asset.load(.isPlayable) else {
          status = "eapi AVPlayer asset is not playable"
          return
        }
        try Task.checkCancellation()

        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        self.player = player
        player.play()
        status =
          "eapi AVPlayer play requested: sourceScheme=\(resolved.sourceScheme), "
          + "playbackScheme=\(resolved.url.scheme!), "
          + "host=\(resolved.url.host!), "
          + "context=honest-macos-v2, "
          + "quality=\(resolved.actualQuality ?? "unspecified"), "
          + "format=\(resolved.format ?? "unspecified"), trial=\(resolved.trial)"
      }
    } catch {
      guard !Task.isCancelled else { return }
      await handle(
        error,
        credential: requestCredential,
        loginCoordinator: loginCoordinator,
        generation: generation
      )
    }
  }

  private func resolveAndProbe(
    songID: Int64,
    loginCoordinator: LoginCoordinator,
    generation: Int
  ) async {
    defer {
      if self.generation == generation {
        playTask = nil
        isBusy = false
      }
    }

    var requestCredential: NeteaseCredential?
    do {
      let credential = try await vault.load()
      try Task.checkCancellation()
      guard let credential else {
        status = "No stored session for eapi CDN probe"
        return
      }
      requestCredential = credential
      let resolution = try await session.resolveSongURL(
        songID: songID,
        quality: .standard,
        credential: credential
      )
      try Task.checkCancellation()

      switch resolution {
      case .unavailable(let itemCode, let fee):
        status = "eapi song unavailable: item code \(itemCode), fee \(fee.map(String.init) ?? "none")"
      case .resolved(let resolved):
        let result = try await session.probeAudioURL(resolved)
        try Task.checkCancellation()
        status =
          "eapi CDN range probe: status=\(result.statusCode), "
          + "sourceScheme=\(resolved.sourceScheme), probeScheme=\(resolved.url.scheme!), "
          + "host=\(resolved.url.host!), context=honest-macos-v2, range=\(result.rangeResponse), "
          + "type=\(result.contentType ?? "none"), "
          + "redirectScheme=\(result.redirectScheme ?? "none"), "
          + "redirectHost=\(result.redirectHost ?? "none")"
      }
    } catch {
      guard !Task.isCancelled else { return }
      await handle(
        error,
        credential: requestCredential,
        loginCoordinator: loginCoordinator,
        generation: generation
      )
    }
  }

  private func handle(
    _ error: Error,
    credential: NeteaseCredential?,
    loginCoordinator: LoginCoordinator,
    generation: Int
  ) async {
    guard self.generation == generation, !Task.isCancelled else { return }

    switch error {
    case let error as NeteaseServiceError where error.statusCode == 301:
      guard let credential else { return }
      releasePlayback()
      let invalidated = await loginCoordinator.invalidateStoredSession(
        matching: credential,
        message: "eapi session expired; sign in again"
      )
      guard self.generation == generation, !Task.isCancelled else { return }
      if invalidated {
        status = "eapi session expired; sign in again"
      }
    case let error as NeteaseServiceError:
      status = "eapi service error \(error.statusCode)"
    case NeteasePlaybackError.invalidResponse:
      status = "eapi response invalid"
    case NeteasePlaybackError.nonHTTPSURL(let host):
      status = "eapi playback URL is HTTP: host=\(host)"
    case NeteasePlaybackError.unapprovedHost(let host):
      status = "eapi playback host is not approved: \(host)"
    case let error as CredentialVaultError:
      status = "Keychain error \(error.status)"
    default:
      let error = error as NSError
      status = "eapi playback failed: \(error.domain) \(error.code)"
    }
  }

  private func releasePlayback() {
    player?.pause()
    player = nil
  }
}

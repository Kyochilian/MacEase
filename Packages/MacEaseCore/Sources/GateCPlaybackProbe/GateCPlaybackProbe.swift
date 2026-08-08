import AVFoundation
import Darwin
import Foundation
import NeteaseKit

@main
@MainActor
struct GateCPlaybackProbe {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let first = arguments.first, let songID = Int64(first), songID > 0 else {
      print(
        "usage: GateCPlaybackProbe SONG_ID QUALITY... "
          + "[--exercise-first-non-mp3|--exercise-recovery]"
      )
      exit(2)
    }

    let options = Array(arguments.dropFirst())
    let flags = options.filter { $0.hasPrefix("--") }
    let allowedFlags = ["--exercise-first-non-mp3", "--exercise-recovery"]
    guard flags.allSatisfy(allowedFlags.contains) else {
      print("result=invalidArguments detail=unknownFlag")
      exit(2)
    }

    let qualityArguments = options.filter { !$0.hasPrefix("--") }
    let qualities = qualityArguments.compactMap(PlaybackQuality.init(rawValue:))
    guard qualities.count == qualityArguments.count else {
      print("result=invalidArguments detail=unknownQuality")
      exit(2)
    }
    guard Set(qualityArguments).count == qualityArguments.count else {
      print("result=invalidArguments detail=duplicateQuality")
      exit(2)
    }
    guard !qualities.isEmpty else {
      print("result=invalidArguments detail=noQuality")
      exit(2)
    }

    let shouldExercise = flags.contains("--exercise-first-non-mp3")
    let shouldRecover = flags.contains("--exercise-recovery")
    guard !(shouldExercise && shouldRecover) else {
      print("result=invalidArguments detail=conflictingExerciseModes")
      exit(2)
    }
    if shouldRecover, qualities.count != 1 {
      print("result=invalidArguments detail=recoveryRequiresOneQuality")
      exit(2)
    }

    do {
      let vault = CredentialVault()
      guard let credential = try await vault.load() else {
        print("result=noStoredSession")
        exit(3)
      }

      let session = NeteaseSession()
      var exerciseAsset: ResolvedAudioAsset?
      var firstResolvedAsset: ResolvedAudioAsset?

      for quality in qualities {
        do {
          let resolution = try await session.resolveSongURL(
            songID: songID,
            quality: quality,
            credential: credential
          )
          switch resolution {
          case .unavailable(let itemCode, let fee):
            print(
              "result=unavailable requestedQuality=\(quality.rawValue) "
                + "actualQuality=none format=none fee=\(fee.map(String.init) ?? "none") "
                + "trial=none itemCode=\(itemCode)"
            )
          case .resolved(let asset):
            print(resolvedLine(asset))
            firstResolvedAsset = firstResolvedAsset ?? asset
            if exerciseAsset == nil,
              let format = asset.format?.trimmingCharacters(in: .whitespacesAndNewlines),
              !format.isEmpty,
              format.lowercased() != "mp3"
            {
              exerciseAsset = asset
            }
          }
        } catch {
          print(failureLine(error, quality: quality))
          exit(1)
        }
      }

      if shouldRecover {
        guard let firstResolvedAsset else {
          print("recovery=notRun reason=initialAssetUnavailable")
          exit(1)
        }
        if !(await exerciseRecovery(
          firstResolvedAsset,
          session: session,
          credential: credential
        )) {
          exit(1)
        }
        return
      }

      guard shouldExercise else { return }
      guard let exerciseAsset else {
        print("exercise=notRun reason=noNewFormat")
        exit(1)
      }
      if !(await exercise(exerciseAsset, session: session)) {
        exit(1)
      }
    } catch let error as CredentialVaultError {
      print("result=keychainError status=\(error.status)")
      exit(3)
    } catch {
      print("result=credentialDecodeError")
      exit(3)
    }
  }

  private static func resolvedLine(_ asset: ResolvedAudioAsset) -> String {
    "result=resolved requestedQuality=\(asset.requestedQuality.rawValue) "
      + "actualQuality=\(asset.actualQuality ?? "none") "
      + "format=\(asset.format ?? "none") "
      + "bitRate=\(asset.bitRate.map(String.init) ?? "none") "
      + "byteCount=\(asset.byteCount.map(String.init) ?? "none") "
      + "expiresIn=\(asset.expiresIn.map(String.init) ?? "none") "
      + "fee=\(asset.fee.map(String.init) ?? "none") trial=\(asset.trial) "
      + "scheme=\(asset.sourceScheme) host=\(asset.url.host ?? "none")"
  }

  private static func failureLine(
    _ error: Error,
    quality: PlaybackQuality
  ) -> String {
    let prefix = "result=failed requestedQuality=\(quality.rawValue)"
    switch error {
    case let error as NeteaseServiceError:
      return "\(prefix) class=service status=\(error.statusCode)"
    case NeteasePlaybackError.invalidResponse:
      return "\(prefix) class=invalidResponse"
    case NeteasePlaybackError.nonHTTPSURL(let host):
      return "\(prefix) class=disallowedHTTP host=\(host)"
    case NeteasePlaybackError.unapprovedHost(let host):
      return "\(prefix) class=unapprovedHost host=\(host)"
    case let error as URLError:
      return "\(prefix) class=network code=\(error.errorCode)"
    default:
      return "\(prefix) class=networkOrResponse"
    }
  }

  private static func exercise(
    _ resolved: ResolvedAudioAsset,
    session: NeteaseSession
  ) async -> Bool {
    do {
      let probe = try await session.probeAudioURL(resolved)
      print(
        "exercise=range httpStatus=\(probe.statusCode) range=\(probe.rangeResponse) "
          + "contentType=\(probe.contentType ?? "none") "
          + "redirectScheme=\(probe.redirectScheme ?? "none") "
          + "redirectHost=\(probe.redirectHost ?? "none")"
      )
      guard probe.rangeResponse else {
        print("exercise=playNotRun reason=rangeProbeFailed")
        return false
      }

      let asset = AVURLAsset(
        url: resolved.url,
        options: [AVURLAssetHTTPUserAgentKey: "MacEasePhase0/0.1 (macOS 15)"]
      )
      guard try await asset.load(.isPlayable) else {
        print("exercise=playNotRun reason=assetNotPlayable")
        return false
      }

      let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
      player.play()
      try await Task.sleep(for: .seconds(8))
      player.pause()
      print("exercise=playStopped durationSeconds=8")
      return true
    } catch let error as URLError {
      print("exercise=failed class=network code=\(error.errorCode)")
      return false
    } catch {
      print("exercise=failed class=playbackOrResponse")
      return false
    }
  }

  private static func exerciseRecovery(
    _ initial: ResolvedAudioAsset,
    session: NeteaseSession,
    credential: NeteaseCredential
  ) async -> Bool {
    do {
      let initialPlayer = try await makePlayer(initial)
      initialPlayer.play()
      try await Task.sleep(for: .seconds(2))

      let targetPosition = 2.0
      guard await seek(initialPlayer, to: targetPosition) else {
        print("recovery=failed stage=initialSeek")
        initialPlayer.pause()
        return false
      }
      let savedPosition = position(of: initialPlayer)
      initialPlayer.pause()

      let refreshed = try await session.resolveSongURL(
        songID: initial.songID,
        quality: initial.requestedQuality,
        credential: credential
      )
      guard case .resolved(let refreshedAsset) = refreshed else {
        print("recovery=failed stage=refresh result=unavailable")
        return false
      }

      let refreshedPlayer = try await makePlayer(refreshedAsset)
      guard await seek(refreshedPlayer, to: savedPosition) else {
        print("recovery=failed stage=refreshedSeek")
        refreshedPlayer.pause()
        return false
      }
      let resumedPosition = position(of: refreshedPlayer)
      refreshedPlayer.play()
      try await Task.sleep(for: .seconds(4))
      refreshedPlayer.pause()

      print(
        "recovery=playbackResumed initialPosition=\(format(savedPosition)) "
          + "refreshedPosition=\(format(resumedPosition)) durationSeconds=4"
      )
      return true
    } catch let error as NeteaseServiceError {
      print("recovery=failed stage=refresh class=service status=\(error.statusCode)")
      return false
    } catch let error as URLError {
      print("recovery=failed class=network code=\(error.errorCode)")
      return false
    } catch {
      print("recovery=failed class=playbackOrResponse")
      return false
    }
  }

  private static func makePlayer(_ resolved: ResolvedAudioAsset) async throws -> AVPlayer {
    let asset = AVURLAsset(
      url: resolved.url,
      options: [AVURLAssetHTTPUserAgentKey: "MacEasePhase0/0.1 (macOS 15)"]
    )
    guard try await asset.load(.isPlayable) else {
      throw NeteasePlaybackError.invalidResponse
    }
    return AVPlayer(playerItem: AVPlayerItem(asset: asset))
  }

  private static func seek(_ player: AVPlayer, to seconds: Double) async -> Bool {
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    return await withCheckedContinuation { continuation in
      player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) {
        continuation.resume(returning: $0)
      }
    }
  }

  private static func position(of player: AVPlayer) -> Double {
    let seconds = player.currentTime().seconds
    return seconds.isFinite && seconds >= 0 ? seconds : 0
  }

  private static func format(_ value: Double) -> String {
    String(format: "%.2f", value)
  }
}

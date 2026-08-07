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
      print("usage: GateCPlaybackProbe SONG_ID QUALITY... [--exercise-first-non-mp3]")
      exit(2)
    }

    let shouldExercise = arguments.contains("--exercise-first-non-mp3")
    let qualities = arguments.dropFirst().filter { !$0.hasPrefix("--") }.compactMap(
      PlaybackQuality.init(rawValue:)
    )
    guard !qualities.isEmpty else {
      print("result=invalidArguments detail=noQuality")
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
            if exerciseAsset == nil, asset.format?.lowercased() != "mp3" {
              exerciseAsset = asset
            }
          }
        } catch {
          print(failureLine(error, quality: quality))
          return
        }
      }

      guard shouldExercise else { return }
      guard let exerciseAsset else {
        print("exercise=notRun reason=noNewFormat")
        return
      }
      await exercise(exerciseAsset, session: session)
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
  ) async {
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
        return
      }

      let asset = AVURLAsset(
        url: resolved.url,
        options: [AVURLAssetHTTPUserAgentKey: "MacEasePhase0/0.1 (macOS 15)"]
      )
      guard try await asset.load(.isPlayable) else {
        print("exercise=playNotRun reason=assetNotPlayable")
        return
      }

      let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
      player.play()
      try await Task.sleep(for: .seconds(8))
      player.pause()
      print("exercise=playStopped durationSeconds=8")
    } catch let error as URLError {
      print("exercise=failed class=network code=\(error.errorCode)")
    } catch {
      print("exercise=failed class=playbackOrResponse")
    }
  }
}

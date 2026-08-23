import AVFoundation
import Foundation

package struct AudioAssetInfo: Equatable, Sendable {
  package let isPlayable: Bool
  package let durationSeconds: Double?

  package init(isPlayable: Bool, durationSeconds: Double?) {
    self.isPlayable = isPlayable
    self.durationSeconds = durationSeconds
  }
}

/// The media surface `PlaybackController` is allowed to use. Keeping AVPlayer
/// behind it is what lets the recovery rules — which failures keep a retry
/// entry point and which do not — be tested without real media.
@MainActor
package protocol AudioOutput: AnyObject {
  var volume: Float { get set }
  var isMuted: Bool { get set }
  /// nil when no item is loaded or the reported time is not usable.
  var currentPositionSeconds: Double? { get }

  var onPositionUpdate: (@MainActor (Double) -> Void)? { get set }
  var onPlayedToEnd: (@MainActor () -> Void)? { get set }
  /// Reports a failure of the loaded item after playback began. The payload
  /// is a short, credential-free diagnostic.
  var onFailure: (@MainActor (String) -> Void)? { get set }

  /// Loads the resolved URL. Throwing means the asset could not be loaded at
  /// all, which is a recoverable failure: the URL may simply have expired.
  func prepare(url: URL, userAgent: String) async throws -> AudioAssetInfo
  func play()
  func pause()
  func seek(to seconds: Double) async throws
  func teardown()
}

/// The AVPlayer-backed output. It owns every observer it registers and
/// releases all of them in `teardown`.
@MainActor
package final class AVPlayerAudioOutput: AudioOutput {
  private var player: AVPlayer?
  private var periodicObserver: Any?
  private var itemStatusObservation: NSKeyValueObservation?
  private var playedToEndObserver: NSObjectProtocol?

  package var onPositionUpdate: (@MainActor (Double) -> Void)?
  package var onPlayedToEnd: (@MainActor () -> Void)?
  package var onFailure: (@MainActor (String) -> Void)?

  package var volume: Float = 1 {
    didSet { player?.volume = volume }
  }

  package var isMuted = false {
    didSet { player?.isMuted = isMuted }
  }

  package init() {}

  package var currentPositionSeconds: Double? {
    guard let seconds = player?.currentTime().seconds, seconds.isFinite, seconds >= 0
    else { return nil }
    return seconds
  }

  package func prepare(url: URL, userAgent: String) async throws -> AudioAssetInfo {
    teardown()
    let asset = AVURLAsset(
      url: url,
      options: [AVURLAssetHTTPUserAgentKey: userAgent]
    )
    let (isPlayable, duration) = try await asset.load(.isPlayable, .duration)
    guard isPlayable else {
      return AudioAssetInfo(isPlayable: false, durationSeconds: nil)
    }

    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.volume = volume
    player.isMuted = isMuted
    self.player = player
    observe(item: item, of: player)

    let seconds = duration.seconds
    return AudioAssetInfo(
      isPlayable: true,
      durationSeconds: seconds.isFinite && seconds > 0 ? seconds : nil
    )
  }

  package func play() { player?.play() }

  package func pause() { player?.pause() }

  package func seek(to seconds: Double) async throws {
    guard let player else { throw CancellationError() }
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    let finished = await withCheckedContinuation { continuation in
      player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) {
        continuation.resume(returning: $0)
      }
    }
    guard finished else { throw CancellationError() }
  }

  package func teardown() {
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

  private func observe(item: AVPlayerItem, of player: AVPlayer) {
    itemStatusObservation = item.observe(\.status, options: [.new]) {
      [weak self] item, _ in
      guard item.status == .failed else { return }
      let detail = item.error.map(Self.failureDetail) ?? "unknown"
      Task { @MainActor [weak self] in
        self?.onFailure?(detail)
      }
    }
    playedToEndObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification,
      object: item,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.onPlayedToEnd?()
      }
    }
    periodicObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      Task { @MainActor [weak self] in
        let seconds = time.seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        self?.onPositionUpdate?(seconds)
      }
    }
  }

  nonisolated private static func failureDetail(_ error: any Error) -> String {
    let error = error as NSError
    return "\(error.domain) \(error.code)"
  }
}

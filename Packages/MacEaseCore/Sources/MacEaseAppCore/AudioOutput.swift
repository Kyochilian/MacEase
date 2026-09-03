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

package enum AudioOutputPlaybackState: Equatable, Sendable {
  case playing
  case notPlaying
}

/// Failures produced by the AVFoundation boundary for which rebuilding the
/// asset or item from a freshly resolved URL is meaningful.
package enum AudioOutputFailure: Error, Equatable, Sendable {
  case assetLoad(String)
  case itemPlayback(String)
  /// A credential-free CDN response proving that this signed URL is dead.
  case resourceUnavailable(statusCode: Int)

  package var diagnostic: String {
    switch self {
    case .assetLoad(let detail): "asset load: \(detail)"
    case .itemPlayback(let detail): "item playback: \(detail)"
    case .resourceUnavailable(let statusCode):
      "resource unavailable: HTTP \(statusCode)"
    }
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
  /// Tracks AVPlayer's actual time-control state, including buffering gaps.
  var onPlaybackStateChanged: (@MainActor (AudioOutputPlaybackState) -> Void)? {
    get set
  }
  var onPlayedToEnd: (@MainActor () -> Void)? { get set }
  /// Reports a failure of the loaded item after playback began. The payload
  /// is a short, credential-free diagnostic.
  var onFailure: (@MainActor (AudioOutputFailure) -> Void)? { get set }

  /// Loads the resolved resource. AVFoundation load failures are returned as
  /// the typed transient error above; cancellation remains cancellation.
  func prepare(resource: PlaybackResource, userAgent: String) async throws
    -> AudioAssetInfo
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
  private var loadedAsset: AVURLAsset?
  private var periodicObserver: Any?
  private var itemStatusObservation: NSKeyValueObservation?
  private var timeControlStatusObservation: NSKeyValueObservation?
  private var playedToEndObserver: NSObjectProtocol?
  private var rangeLoader: AudioAssetResourceLoader?
  private var pinnedCacheKey: AudioCacheKey?
  private var generation: UInt64 = 0
  private var preparingGeneration: UInt64?
  private let rangePipeline: AudioRangePipeline?

  package var onPositionUpdate: (@MainActor (Double) -> Void)?
  package var onPlaybackStateChanged:
    (@MainActor (AudioOutputPlaybackState) -> Void)?
  package var onPlayedToEnd: (@MainActor () -> Void)?
  package var onFailure: (@MainActor (AudioOutputFailure) -> Void)?

  package var volume: Float = 1 {
    didSet { player?.volume = volume }
  }

  package var isMuted = false {
    didSet { player?.isMuted = isMuted }
  }

  package init(rangePipeline: AudioRangePipeline? = nil) {
    self.rangePipeline = rangePipeline
  }

  package var currentPositionSeconds: Double? {
    guard let seconds = player?.currentTime().seconds, seconds.isFinite, seconds >= 0
    else { return nil }
    return seconds
  }

  package func prepare(
    resource: PlaybackResource,
    userAgent: String
  ) async throws -> AudioAssetInfo {
    // A controller intent already tears down the previous item. Keep direct
    // callers safe too, without performing the same teardown twice.
    if preparingGeneration != nil || loadedAsset != nil || player != nil {
      teardown()
    }
    let generation = self.generation
    preparingGeneration = generation
    defer {
      if preparingGeneration == generation { preparingGeneration = nil }
    }
    let asset: AVURLAsset
    switch resource.location {
    case .local(let url):
      asset = AVURLAsset(url: url)
    case .remote(let url):
      if
        let rangePipeline,
        let key = resource.cacheKey
      {
        await rangePipeline.pin(key)
        guard !Task.isCancelled, self.generation == generation else {
          await rangePipeline.unpin(key)
          throw CancellationError()
        }
        pinnedCacheKey = key
        let loader = AudioAssetResourceLoader(
          resource: resource,
          key: key,
          pipeline: rangePipeline,
          userAgent: userAgent
        )
        rangeLoader = loader
        asset = AVURLAsset(url: loader.assetURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.callbackQueue)
      } else {
        asset = AVURLAsset(
          url: url,
          options: [AVURLAssetHTTPUserAgentKey: userAgent]
        )
      }
    }
    let isPlayable: Bool
    let duration: CMTime
    loadedAsset = asset
    do {
      (isPlayable, duration) = try await asset.load(.isPlayable, .duration)
    } catch {
      try Task.checkCancellation()
      guard self.generation == generation else { throw CancellationError() }
      let rangeFailure = rangeLoader?.reportedFailure
      teardown()
      throw rangeFailure ?? AudioOutputFailure.assetLoad(Self.failureDetail(error))
    }
    try Task.checkCancellation()
    guard self.generation == generation else { throw CancellationError() }
    guard isPlayable else {
      return AudioAssetInfo(isPlayable: false, durationSeconds: nil)
    }

    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.volume = volume
    player.isMuted = isMuted
    self.player = player
    observe(item: item, of: player, generation: generation)

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
    generation &+= 1
    preparingGeneration = nil
    loadedAsset?.cancelLoading()
    loadedAsset = nil
    rangeLoader?.cancelAll()
    rangeLoader = nil
    itemStatusObservation?.invalidate()
    itemStatusObservation = nil
    timeControlStatusObservation?.invalidate()
    timeControlStatusObservation = nil
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
    if let pinnedCacheKey, let rangePipeline {
      self.pinnedCacheKey = nil
      Task { await rangePipeline.unpin(pinnedCacheKey) }
    } else {
      pinnedCacheKey = nil
    }
  }

  private func observe(
    item: AVPlayerItem,
    of player: AVPlayer,
    generation: UInt64
  ) {
    timeControlStatusObservation = player.observe(
      \.timeControlStatus,
      options: [.new]
    ) { [weak self] player, _ in
      let state: AudioOutputPlaybackState =
        player.timeControlStatus == .playing ? .playing : .notPlaying
      Task { @MainActor [weak self] in
        guard let self, self.generation == generation else { return }
        self.onPlaybackStateChanged?(state)
      }
    }
    itemStatusObservation = item.observe(\.status, options: [.new]) {
      [weak self] item, _ in
      guard item.status == .failed else { return }
      let detail = item.error.map(Self.failureDetail) ?? "unknown"
      Task { @MainActor [weak self] in
        guard let self, self.generation == generation else { return }
        self.onFailure?(
          self.rangeLoader?.reportedFailure ?? .itemPlayback(detail)
        )
      }
    }
    playedToEndObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification,
      object: item,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.generation == generation else { return }
        self.onPlayedToEnd?()
      }
    }
    periodicObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      Task { @MainActor [weak self] in
        guard let self, self.generation == generation else { return }
        let seconds = time.seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        self.onPositionUpdate?(seconds)
      }
    }
  }

  nonisolated private static func failureDetail(_ error: any Error) -> String {
    let error = error as NSError
    return "\(error.domain) \(error.code)"
  }
}

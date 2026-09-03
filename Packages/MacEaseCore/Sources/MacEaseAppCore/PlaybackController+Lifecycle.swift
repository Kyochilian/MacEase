import Foundation
import NeteaseKit

@MainActor
extension PlaybackController {
    package struct ActiveLifecycle {
      let instance: PlaybackLifecycleInstance
      var accumulatedSeconds: TimeInterval = 0
      var playingSince: TimeInterval?
      var durationSeconds: Double?
    }
  

    package func outputStartedPlaying() {
      let now = monotonicNow()
      if lifecycle == nil {
        guard
          let track = currentTrack,
          let context = queueContext,
          let accountID = playbackAccountID
        else { return }
        let instance = PlaybackLifecycleInstance(
          accountID: accountID,
          track: track,
          context: context
        )
        lifecycle = ActiveLifecycle(
          instance: instance,
          playingSince: now,
          durationSeconds: durationSeconds
        )
        onLifecycleEvent?(.started(instance))
        return
      }
      guard var lifecycle, lifecycle.playingSince == nil else { return }
      lifecycle.playingSince = now
      if lifecycle.durationSeconds == nil {
        lifecycle.durationSeconds = durationSeconds
      }
      self.lifecycle = lifecycle
    }
  
    package func pauseLifecycleClock() {
      guard var lifecycle, let started = lifecycle.playingSince else { return }
      let elapsed = monotonicNow() - started
      if elapsed.isFinite {
        lifecycle.accumulatedSeconds += max(0, elapsed)
      }
      lifecycle.playingSince = nil
      self.lifecycle = lifecycle
    }
  
    package func finishLifecycle() {
      pauseLifecycleClock()
      guard let lifecycle else { return }
      self.lifecycle = nil
      let played = lifecycle.accumulatedSeconds.isFinite
        ? max(0, lifecycle.accumulatedSeconds) : 0
      let duration = lifecycle.durationSeconds.flatMap {
        $0.isFinite && $0 >= 0 ? $0 : nil
      }
      let bounded = duration.map { min(played, $0) } ?? played
      let wholeSeconds = bounded >= TimeInterval(Int.max)
        ? Int.max : Int(bounded.rounded(.down))
      onLifecycleEvent?(
        .finished(lifecycle.instance, playedSeconds: wholeSeconds)
      )
    }
  
}


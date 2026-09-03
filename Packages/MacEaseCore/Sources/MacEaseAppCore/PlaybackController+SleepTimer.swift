import Foundation

@MainActor
extension PlaybackController {
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
  
    /// Test seam for the timer's decision without waiting for wall-clock time.
    package func fireSleepTimerForTesting() {
      fireSleepTimer(generation: sleepGeneration)
    }
  
    package func fireSleepTimer(generation: Int) {
      guard generation == sleepGeneration, case .armed = sleepTimer else { return }
      sleepTask = nil
      guard isActive else {
        sleepTimer = .off
        return
      }
      if sleepStopsImmediately {
        sleepTimer = .off
        stop(reason: .sleepTimer(status: "Sleep timer stopped playback"))
      } else {
        sleepTimer = .finishingTrack
      }
    }
  
  package func clearPendingSleepStop() {
    if sleepTimer == .finishingTrack {
      sleepTimer = .off
    }
  }
}

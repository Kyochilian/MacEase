/// User-selected order strategy for an explicitly started queue.
package enum PlaybackMode: String, CaseIterable, Sendable {
  case sequential
  case repeatAll
  case repeatOne
  case shuffle
}

/// What playback does after the current track ends on its own.
package enum QueueAdvance: Equatable, Sendable {
  /// Restart the current item from zero without a new URL resolution.
  case replayCurrent
  /// Resolve and play the entry at this index (exactly one request).
  case play(Int)
  /// The queue is exhausted; playback stops.
  case end
}

/// Pure order state for one explicitly started queue. Indices refer to the
/// entry list captured when the queue started; the queue never issues
/// requests itself. Wrap-around applies only to repeatAll and shuffle, and
/// shuffle keeps one fixed permutation that starts at the current entry.
package struct PlaybackQueue: Equatable, Sendable {
  package let count: Int
  package private(set) var currentIndex: Int
  package private(set) var mode: PlaybackMode
  package private(set) var shuffleOrder: [Int]

  package init?(
    count: Int,
    startIndex: Int,
    mode: PlaybackMode,
    using generator: inout some RandomNumberGenerator
  ) {
    guard count > 0, (0..<count).contains(startIndex) else { return nil }
    self.count = count
    self.currentIndex = startIndex
    self.mode = mode
    self.shuffleOrder = []
    if mode == .shuffle {
      reshuffle(using: &generator)
    }
  }

  package mutating func setMode(
    _ newMode: PlaybackMode,
    using generator: inout some RandomNumberGenerator
  ) {
    guard newMode != mode else { return }
    mode = newMode
    if newMode == .shuffle {
      reshuffle(using: &generator)
    } else {
      shuffleOrder = []
    }
  }

  /// Commits a transition; the caller resolves the entry it names.
  package mutating func moveTo(_ index: Int) -> Bool {
    guard (0..<count).contains(index) else { return false }
    currentIndex = index
    return true
  }

  /// Entry index for an explicit Next action, or nil when none exists.
  package func nextIndex() -> Int? {
    step(by: 1)
  }

  /// Entry index for an explicit Previous action, or nil when none exists.
  package func previousIndex() -> Int? {
    step(by: -1)
  }

  /// Transition after the current track finished playing on its own.
  package func afterNaturalEnd() -> QueueAdvance {
    if mode == .repeatOne { return .replayCurrent }
    guard let next = nextIndex() else { return .end }
    return next == currentIndex ? .replayCurrent : .play(next)
  }

  private mutating func reshuffle(using generator: inout some RandomNumberGenerator) {
    var order = (0..<count).filter { $0 != currentIndex }.shuffled(using: &generator)
    order.insert(currentIndex, at: 0)
    shuffleOrder = order
  }

  private func step(by offset: Int) -> Int? {
    let wraps = mode == .repeatAll || mode == .shuffle
    if mode == .shuffle {
      guard let slot = shuffleOrder.firstIndex(of: currentIndex) else { return nil }
      let target = slot + offset
      guard (0..<count).contains(target) else {
        return wraps ? shuffleOrder[(target + count) % count] : nil
      }
      return shuffleOrder[target]
    }
    let target = currentIndex + offset
    guard (0..<count).contains(target) else {
      return wraps ? (target + count) % count : nil
    }
    return target
  }
}

import Testing

@testable import NeteaseKit

/// SplitMix64; deterministic shuffle coverage needs a seedable generator.
private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

private func makeQueue(
  count: Int,
  startIndex: Int,
  mode: PlaybackMode,
  seed: UInt64 = 7
) -> PlaybackQueue? {
  var generator = SeededGenerator(state: seed)
  return PlaybackQueue(
    count: count,
    startIndex: startIndex,
    mode: mode,
    using: &generator
  )
}

@Test func playbackQueueRejectsEmptyListAndOutOfRangeStart() {
  #expect(makeQueue(count: 0, startIndex: 0, mode: .sequential) == nil)
  #expect(makeQueue(count: 3, startIndex: -1, mode: .sequential) == nil)
  #expect(makeQueue(count: 3, startIndex: 3, mode: .repeatAll) == nil)
}

@Test func sequentialStepsInOrderWithoutWrapping() {
  var queue = makeQueue(count: 3, startIndex: 0, mode: .sequential)!

  #expect(queue.previousIndex() == nil)
  #expect(queue.nextIndex() == 1)
  #expect(queue.afterNaturalEnd() == .play(1))
  let moved = queue.moveTo(2)
  #expect(moved)
  #expect(queue.nextIndex() == nil)
  #expect(queue.afterNaturalEnd() == .end)
  #expect(queue.previousIndex() == 1)
}

@Test func repeatAllWrapsInBothDirections() {
  var queue = makeQueue(count: 3, startIndex: 2, mode: .repeatAll)!

  #expect(queue.nextIndex() == 0)
  #expect(queue.afterNaturalEnd() == .play(0))
  let moved = queue.moveTo(0)
  #expect(moved)
  #expect(queue.previousIndex() == 2)
}

@Test func repeatAllSingleEntryReplaysWithoutNewRequest() {
  let queue = makeQueue(count: 1, startIndex: 0, mode: .repeatAll)!

  #expect(queue.afterNaturalEnd() == .replayCurrent)
  #expect(queue.nextIndex() == 0)
  #expect(queue.previousIndex() == 0)
}

@Test func repeatOneReplaysCurrentAndStepsLikeSequential() {
  var queue = makeQueue(count: 3, startIndex: 1, mode: .repeatOne)!

  #expect(queue.afterNaturalEnd() == .replayCurrent)
  #expect(queue.nextIndex() == 2)
  #expect(queue.previousIndex() == 0)
  let movedToEnd = queue.moveTo(2)
  #expect(movedToEnd)
  #expect(queue.nextIndex() == nil)
  let movedToStart = queue.moveTo(0)
  #expect(movedToStart)
  #expect(queue.previousIndex() == nil)
}

@Test func shuffleOrderIsAPermutationStartingAtTheCurrentEntry() {
  let queue = makeQueue(count: 10, startIndex: 4, mode: .shuffle)!

  #expect(queue.shuffleOrder.first == 4)
  #expect(queue.shuffleOrder.sorted() == Array(0..<10))
}

@Test func shuffleWithTheSameSeedIsDeterministic() {
  let first = makeQueue(count: 10, startIndex: 4, mode: .shuffle, seed: 11)!
  let second = makeQueue(count: 10, startIndex: 4, mode: .shuffle, seed: 11)!

  #expect(first.shuffleOrder == second.shuffleOrder)
}

@Test func shuffleWalksItsPermutationAndWraps() {
  var queue = makeQueue(count: 5, startIndex: 2, mode: .shuffle)!
  let order = queue.shuffleOrder

  var visited = [queue.currentIndex]
  for _ in 1..<5 {
    let next = queue.nextIndex()!
    let moved = queue.moveTo(next)
    #expect(moved)
    visited.append(next)
  }

  #expect(visited == order)
  #expect(queue.nextIndex() == order[0])
  #expect(queue.afterNaturalEnd() == .play(order[0]))
  #expect(queue.previousIndex() == order[3])
}

@Test func shufflePreviousWrapsBackwardsFromTheFirstSlot() {
  let queue = makeQueue(count: 5, startIndex: 2, mode: .shuffle)!

  #expect(queue.previousIndex() == queue.shuffleOrder[4])
}

@Test func shuffleSingleEntryReplaysWithoutNewRequest() {
  let queue = makeQueue(count: 1, startIndex: 0, mode: .shuffle)!

  #expect(queue.shuffleOrder == [0])
  #expect(queue.afterNaturalEnd() == .replayCurrent)
}

@Test func enteringShuffleKeepsTheCurrentEntryFirst() {
  var queue = makeQueue(count: 8, startIndex: 5, mode: .sequential)!
  var generator = SeededGenerator(state: 3)

  queue.setMode(.shuffle, using: &generator)

  #expect(queue.mode == .shuffle)
  #expect(queue.currentIndex == 5)
  #expect(queue.shuffleOrder.first == 5)
  #expect(queue.shuffleOrder.sorted() == Array(0..<8))
}

@Test func leavingShuffleKeepsThePositionAndClearsTheOrder() {
  var queue = makeQueue(count: 8, startIndex: 5, mode: .shuffle)!
  var generator = SeededGenerator(state: 3)

  queue.setMode(.repeatAll, using: &generator)

  #expect(queue.mode == .repeatAll)
  #expect(queue.currentIndex == 5)
  #expect(queue.shuffleOrder.isEmpty)
  #expect(queue.nextIndex() == 6)
}

@Test func settingTheSameModeKeepsTheShuffleOrder() {
  var queue = makeQueue(count: 6, startIndex: 0, mode: .shuffle)!
  let order = queue.shuffleOrder
  var generator = SeededGenerator(state: 99)

  queue.setMode(.shuffle, using: &generator)

  #expect(queue.shuffleOrder == order)
}

@Test func moveToRejectsIndicesOutsideTheQueue() {
  var queue = makeQueue(count: 3, startIndex: 0, mode: .sequential)!

  let movedBelow = queue.moveTo(-1)
  let movedAbove = queue.moveTo(3)

  #expect(!movedBelow)
  #expect(!movedAbove)
  #expect(queue.currentIndex == 0)
}

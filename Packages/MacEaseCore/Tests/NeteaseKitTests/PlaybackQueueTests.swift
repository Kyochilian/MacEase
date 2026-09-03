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

// MARK: - User queue editing

@Test func insertingNextKeepsTheCurrentIdentityAndSequentialOrder() {
  var queue = makeQueue(count: 4, startIndex: 1, mode: .repeatAll)!

  let inserted = queue.insertNext()

  #expect(inserted == 2)
  #expect(queue.count == 5)
  #expect(queue.currentIndex == 1)
  #expect(queue.nextIndex() == 2)
  #expect(queue.upcomingIndices == [2, 3, 4])
}

@Test func insertingNextExtendsAValidShufflePermutationAtTheNextSlot() {
  var queue = makeQueue(count: 6, startIndex: 3, mode: .shuffle, seed: 19)!
  let oldCurrent = queue.currentIndex

  let inserted = queue.insertNext()

  #expect(queue.currentIndex == oldCurrent)
  #expect(queue.nextIndex() == inserted)
  #expect(queue.shuffleOrder.sorted() == Array(0..<7))
  #expect(Set(queue.shuffleOrder).count == 7)
}

@Test func movingAnEarlierEntryNextKeepsTheCurrentSongInSequentialMode() {
  var queue = makeQueue(count: 5, startIndex: 3, mode: .sequential)!

  let destination = queue.moveNext(from: 0)

  #expect(destination == 3)
  #expect(queue.currentIndex == 2)
  #expect(queue.nextIndex() == 3)
  #expect(queue.upcomingIndices == [3, 4])
}

@Test func movingAnEntryNextReordersOnlyTheShufflePermutationOnce() {
  var queue = makeQueue(count: 8, startIndex: 4, mode: .shuffle, seed: 23)!
  let source = queue.upcomingIndices.last!

  let destination = queue.moveNext(from: source)

  #expect(destination != nil)
  #expect(queue.nextIndex() == destination)
  #expect(queue.shuffleOrder.sorted() == Array(0..<8))
  #expect(Set(queue.shuffleOrder).count == 8)
}

@Test func currentAndInvalidEntriesCannotBeMovedNext() {
  var queue = makeQueue(count: 3, startIndex: 1, mode: .sequential)!
  let original = queue

  #expect(queue.moveNext(from: 1) == nil)
  #expect(queue.moveNext(from: -1) == nil)
  #expect(queue.moveNext(from: 3) == nil)
  #expect(queue == original)
}

@Test func everyMoveNextRemapsIdentityAndPermutationForEveryMode() {
  for mode in PlaybackMode.allCases {
    for count in 2...10 {
      for current in 0..<count {
        for source in 0..<count where source != current {
          var queue = makeQueue(
            count: count,
            startIndex: current,
            mode: mode,
            seed: UInt64(count * 100 + current)
          )!
          var identities = Array(0..<count)
          let currentIdentity = identities[current]
          let movedIdentity = identities.remove(at: source)
          let currentAfterRemoval = identities.firstIndex(of: currentIdentity)!
          identities.insert(movedIdentity, at: currentAfterRemoval + 1)

          let destination = queue.moveNext(from: source)

          #expect(destination == currentAfterRemoval + 1)
          #expect(identities[queue.currentIndex] == currentIdentity)
          #expect(queue.nextIndex().map { identities[$0] } == movedIdentity)
          if mode == .shuffle {
            #expect(queue.shuffleOrder.sorted() == Array(0..<count))
            #expect(Set(queue.shuffleOrder).count == count)
          } else {
            #expect(queue.shuffleOrder.isEmpty)
          }
        }
      }
    }
  }
}

// MARK: - Continuation

/// Personal FM and heartbeat mode have no end, so their queue grows while it
/// plays. Growing must not move the entry that is playing.
@Test func appendingKeepsThePositionAndExtendsTheEnd() {
  var generator = SeededGenerator(state: 5)
  var queue = makeQueue(count: 3, startIndex: 1, mode: .sequential)!

  queue.append(2, using: &generator)

  #expect(queue.count == 5)
  #expect(queue.currentIndex == 1)
  #expect(queue.nextIndex() == 2)
  let movedToEnd = queue.moveTo(4)
  #expect(movedToEnd)
  #expect(queue.nextIndex() == nil)
}

@Test func appendingNothingChangesNothing() {
  var generator = SeededGenerator(state: 5)
  var queue = makeQueue(count: 3, startIndex: 0, mode: .sequential)!
  let before = queue

  queue.append(0, using: &generator)
  queue.append(-1, using: &generator)

  #expect(queue == before)
}

/// A shuffled radio keeps the order it has already decided and shuffles only
/// what arrived, so a continuation plays after the batch it continues.
@Test func appendingAShuffledQueueOrdersOnlyTheNewEntries() {
  var generator = SeededGenerator(state: 11)
  var queue = makeQueue(count: 3, startIndex: 0, mode: .shuffle, seed: 11)!
  let existing = queue.shuffleOrder

  queue.append(2, using: &generator)

  #expect(queue.count == 5)
  #expect(Array(queue.shuffleOrder.prefix(3)) == existing)
  #expect(Set(queue.shuffleOrder) == Set(0..<5))
  #expect(queue.shuffleOrder.count == 5)
  #expect(Set(queue.shuffleOrder.suffix(2)) == Set([3, 4]))
}

/// Appending to a repeatAll queue leaves wrap-around correct over the new
/// length rather than the one it started with.
@Test func appendingKeepsWrapAroundOverTheNewLength() {
  var generator = SeededGenerator(state: 2)
  var queue = makeQueue(count: 2, startIndex: 1, mode: .repeatAll)!

  queue.append(1, using: &generator)

  #expect(queue.nextIndex() == 2)
  let movedToLast = queue.moveTo(2)
  #expect(movedToLast)
  #expect(queue.nextIndex() == 0)
}

// MARK: - Removal

@Test func removingTheCurrentSequentialEntrySelectsItsSuccessor() {
  var queue = makeQueue(count: 4, startIndex: 1, mode: .sequential)!

  let removed = queue.remove(at: 1)

  #expect(removed)
  #expect(queue.count == 3)
  #expect(queue.currentIndex == 1)
  #expect(queue.previousIndex() == 0)
  #expect(queue.nextIndex() == 2)
  #expect(queue.shuffleOrder.isEmpty)
}

@Test func removingTheLastRepeatAllEntryWrapsToTheFirst() {
  var queue = makeQueue(count: 4, startIndex: 3, mode: .repeatAll)!

  let removed = queue.remove(at: 3)

  #expect(removed)
  #expect(queue.count == 3)
  #expect(queue.currentIndex == 0)
  #expect(queue.previousIndex() == 2)
  #expect(queue.nextIndex() == 1)
}

@Test func removingFromShuffleRemapsThePermutationAndCurrentEntry() {
  var queue = makeQueue(count: 7, startIndex: 3, mode: .shuffle, seed: 19)!
  let removedIndex = queue.currentIndex
  let successor = queue.nextIndex()!
  let expectedCurrent = successor > removedIndex ? successor - 1 : successor

  let removed = queue.remove(at: removedIndex)

  #expect(removed)
  #expect(queue.count == 6)
  #expect(queue.currentIndex == expectedCurrent)
  #expect(queue.shuffleOrder.first == expectedCurrent)
  #expect(queue.shuffleOrder.sorted() == Array(0..<6))
  #expect(queue.nextIndex() != nil)
  #expect(queue.previousIndex() != nil)
}

@Test func removingANonCurrentEntryOnlyRemapsIndices() {
  var queue = makeQueue(count: 5, startIndex: 3, mode: .sequential)!

  let removed = queue.remove(at: 1)

  #expect(removed)
  #expect(queue.count == 4)
  #expect(queue.currentIndex == 2)
  #expect(queue.previousIndex() == 1)
  #expect(queue.nextIndex() == 3)
  let removedOutOfRange = queue.remove(at: 4)
  #expect(!removedOutOfRange)
}

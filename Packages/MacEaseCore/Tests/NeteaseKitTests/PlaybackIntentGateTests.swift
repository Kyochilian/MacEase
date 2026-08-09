import Testing

@testable import NeteaseKit

@Test func playbackIntentGateAcceptsOnlyLatestGeneration() {
  var gate = PlaybackIntentGate()

  let first = gate.begin()
  #expect(first.generation == 1)
  #expect(gate.generation == 1)
  #expect(gate.accepts(first))

  let second = gate.begin()
  #expect(second.generation == 2)
  #expect(gate.generation == 2)
  #expect(!gate.accepts(first))
  #expect(gate.accepts(second))
}

@Test func playbackIntentGateRejectsWritebackAfterCancel() {
  var gate = PlaybackIntentGate()

  let pending = gate.begin()
  gate.cancel()

  #expect(gate.generation == 2)
  #expect(!gate.accepts(pending))

  let replacement = gate.begin()
  #expect(replacement.generation == 3)
  #expect(gate.accepts(replacement))
  #expect(!gate.accepts(pending))
}

@Test func playbackIntentGateCancelWithoutActiveWorkStillAdvancesGeneration() {
  var gate = PlaybackIntentGate()

  gate.cancel()

  #expect(gate.generation == 1)
  let next = gate.begin()
  #expect(next.generation == 2)
  #expect(gate.accepts(next))
}

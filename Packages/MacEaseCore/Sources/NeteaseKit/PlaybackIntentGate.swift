/// Tracks the latest user playback intent without owning any task or player.
package struct PlaybackIntentGate: Sendable {
  package struct Token: Equatable, Sendable {
    package let generation: UInt64
  }

  package private(set) var generation: UInt64

  package init() {
    generation = 0
  }

  /// Starts a new intent and invalidates every token returned earlier.
  @discardableResult
  package mutating func begin() -> Token {
    generation += 1
    return Token(generation: generation)
  }

  /// Invalidates the current intent, including work that has not finished yet.
  package mutating func cancel() {
    generation += 1
  }

  /// Returns whether a result may still be written for this intent.
  package func accepts(_ token: Token) -> Bool {
    generation == token.generation
  }
}

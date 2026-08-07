import Foundation

/// Tracks the latest user playback intent without owning any task or player.
package struct PlaybackIntentGate: Sendable {
  package struct Token: Equatable, Sendable {
    package let generation: UInt64
    fileprivate let id: UUID

    fileprivate init(generation: UInt64) {
      self.generation = generation
      id = UUID()
    }
  }

  package private(set) var generation: UInt64
  private var activeToken: Token?

  package init() {
    generation = 0
    activeToken = nil
  }

  /// Starts a new intent and invalidates every token returned earlier.
  @discardableResult
  package mutating func begin() -> Token {
    generation += 1
    let token = Token(generation: generation)
    activeToken = token
    return token
  }

  /// Invalidates the current intent, including work that has not finished yet.
  package mutating func cancel() {
    generation += 1
    activeToken = nil
  }

  /// Returns whether a result may still be written for this intent.
  package func accepts(_ token: Token) -> Bool {
    activeToken == token
  }
}

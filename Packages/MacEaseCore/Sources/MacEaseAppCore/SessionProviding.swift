import Foundation
import NeteaseKit

/// Outcome of asking the session owner to drop a credential that a request
/// proved is no longer usable.
package enum SessionInvalidationResult: Equatable, Sendable {
  case deleted
  case notCurrent
  case busy
  case failed
}

/// What a coordinator observed about the stored session while it was running.
package enum SessionDivergence: Equatable, Sendable {
  /// The Keychain item vanished.
  case storedSessionMissing
  /// The Keychain item no longer equals the validated credential.
  /// `hasStoredItem` reports whether any item remained.
  case storedSessionChanged(hasStoredItem: Bool)
}

/// The session surface a coordinator is allowed to use. Coordinators never
/// write session fields directly: divergence is reported through one call so
/// the session owner stays the single place that commits a transition.
@MainActor
package protocol SessionProviding: AnyObject {
  var account: NeteaseAccount? { get }
  var isBusy: Bool { get }

  func matchesValidatedSession(
    _ credential: NeteaseCredential,
    account: NeteaseAccount
  ) -> Bool

  func reportDivergence(_ divergence: SessionDivergence)

  func invalidateStoredSession(
    matching credential: NeteaseCredential,
    message: String
  ) async -> SessionInvalidationResult
}

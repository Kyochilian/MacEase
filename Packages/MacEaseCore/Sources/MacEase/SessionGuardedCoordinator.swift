import Foundation
import MacEaseSession
import NeteaseKit

/// Shared preflight/postflight session checks for the read coordinators.
/// Every authenticated read confirms the stored Keychain item still matches
/// the validated account both before issuing the request and before
/// publishing its result; a mismatch clears the coordinator's data and
/// demands a new Validate. Generation guards drop late writes from a
/// superseded task.
@MainActor
protocol SessionGuardedCoordinator: AnyObject {
  var vault: CredentialVault { get }
  var generation: Int { get }
  var status: String { get set }
  /// Shown when the Keychain item vanished while this coordinator was idle.
  var noStoredSessionStatus: String { get }
  func clearSessionScopedData()
}

extension SessionGuardedCoordinator {
  /// Preflight: the credential to use, or nil when the session no longer
  /// matches and the request must not be sent.
  func currentCredential(
    account: NeteaseAccount,
    generation: Int,
    loginCoordinator: LoginCoordinator
  ) async throws -> NeteaseCredential? {
    guard let credential = try await vault.load() else {
      guard self.generation == generation else { return nil }
      loginCoordinator.hasStoredSession = false
      loginCoordinator.account = nil
      loginCoordinator.status = "No stored session to validate"
      clearSessionScopedData()
      status = noStoredSessionStatus
      return nil
    }
    guard self.generation == generation else { return nil }
    guard loginCoordinator.matchesValidatedSession(credential, account: account) else {
      loginCoordinator.hasStoredSession = true
      loginCoordinator.account = nil
      loginCoordinator.status = "Stored session changed; validate again"
      clearSessionScopedData()
      status = "Session changed; validate again"
      return nil
    }
    return credential
  }

  /// Postflight: whether the result may be published.
  func sessionRemainsCurrent(
    account: NeteaseAccount,
    credential: NeteaseCredential,
    generation: Int,
    loginCoordinator: LoginCoordinator
  ) async throws -> Bool {
    guard self.generation == generation else { return false }
    let storedCredential = try await vault.load()
    guard self.generation == generation else { return false }
    guard
      storedCredential == credential,
      loginCoordinator.matchesValidatedSession(credential, account: account)
    else {
      loginCoordinator.hasStoredSession = storedCredential != nil
      loginCoordinator.account = nil
      loginCoordinator.status = "Stored session changed; validate again"
      clearSessionScopedData()
      status = "Session changed; validate again"
      return false
    }
    return true
  }
}

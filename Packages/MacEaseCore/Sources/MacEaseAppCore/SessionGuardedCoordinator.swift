import Foundation
import NeteaseKit

/// Shared preflight/postflight session checks for the read coordinators.
/// Every authenticated read confirms the stored Keychain item still matches
/// the validated account both before issuing the request and before
/// publishing its result; a mismatch clears the coordinator's data and
/// demands a new Validate. Generation guards drop late writes from a
/// superseded task.
@MainActor
package protocol SessionGuardedCoordinator: AnyObject {
  var vault: any CredentialStoring { get }
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
    session: any SessionProviding
  ) async throws -> NeteaseCredential? {
    guard session.isOnline else {
      status = "Offline: connect to use your online library"
      return nil
    }
    guard let credential = try await vault.load() else {
      guard self.generation == generation else { return nil }
      session.reportDivergence(.storedSessionMissing)
      clearSessionScopedData()
      status = noStoredSessionStatus
      return nil
    }
    guard self.generation == generation else { return nil }
    guard session.matchesValidatedSession(credential, account: account) else {
      session.reportDivergence(.storedSessionChanged(hasStoredItem: true))
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
    session: any SessionProviding
  ) async throws -> Bool {
    guard self.generation == generation else { return false }
    let storedCredential = try await vault.load()
    guard self.generation == generation else { return false }
    guard
      let storedCredential,
      session.matchesValidatedSession(storedCredential, account: account)
    else {
      session.reportDivergence(
        .storedSessionChanged(hasStoredItem: storedCredential != nil)
      )
      clearSessionScopedData()
      status = "Session changed; validate again"
      return false
    }
    return true
  }
}

/// The common claim state used by coordinators that have one active operation
/// lane. Keeping the token and validated account together prevents a caller
/// from starting work with only half of the preflight completed.
@MainActor
package struct SessionOperationClaim {
  package let token: OperationToken
  package let account: NeteaseAccount
}

/// Claims one read or write for a single-operation coordinator. The caller
/// supplies its local busy flag and token storage; all account/arbiter checks
/// stay in this shared boundary.
@MainActor
package func claimSessionOperation(
  _ name: String,
  effect: OperationEffect,
  session: any SessionProviding,
  arbiter: OperationArbiter,
  isLoading: Bool,
  noAccountStatus: String,
  status: inout String,
  operationToken: inout OperationToken?
) -> SessionOperationClaim? {
  guard !isLoading, let token = arbiter.begin(name: name, effect: effect) else {
    return nil
  }
  guard let account = session.account, session.isOnline else {
    arbiter.end(token, outcome: .failed)
    status = noAccountStatus
    return nil
  }
  operationToken = token
  return SessionOperationClaim(token: token, account: account)
}

@MainActor
@discardableResult
package func releaseSessionOperation(
  _ token: OperationToken,
  currentToken: inout OperationToken?,
  arbiter: OperationArbiter,
  outcome: OperationOutcome
) -> OperationOutcome? {
  if currentToken == token { currentToken = nil }
  return arbiter.end(token, outcome: outcome)
}

@MainActor
package func finishSessionOperation(
  generation expectedGeneration: Int,
  currentGeneration: Int,
  isLoading: inout Bool,
  task: inout Task<Void, Never>?
) {
  guard expectedGeneration == currentGeneration else { return }
  isLoading = false
  task = nil
}

extension Error {
  /// An application response or a non-5xx HTTP response proves a write did
  /// not run. A 5xx may have arrived after the server applied it.
  package var provesWriteDidNotRun: Bool {
    if self is NeteaseWritePreparationError { return true }
    if let upload = self as? NeteaseUploadError {
      switch upload {
      case .beforePublication, .invalidFile, .notImportable: return true
      case .invalidResponse: return false
      }
    }
    guard let service = self as? NeteaseServiceError else { return false }
    return service.source == .service || !(500...599).contains(service.statusCode)
  }
}

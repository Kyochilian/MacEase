import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

/// P0-03: a session transition is committed in one place, and a temporary
/// failure never destroys state that was previously confirmed.

private let credentialA = makeCredential("credential-a")
private let credentialB = makeCredential("credential-b")

private func validatedSnapshot(
  _ account: NeteaseAccount = testAccount,
  credential: NeteaseCredential = credentialA
) -> SessionSnapshot {
  SessionSnapshot(presence: .validated(account), validatedCredential: credential)
}

// MARK: - Temporary failures preserve confirmed state

@Test func aTransportFailureKeepsTheValidatedAccount() {
  let before = validatedSnapshot()

  for failure: SessionFailure in [
    .transport,
    .service(NeteaseServiceError(source: .http, statusCode: 500)),
    .service(NeteaseServiceError(source: .service, statusCode: 400)),
    .keychain(.keychain(-25300)),
    .keychain(.corruptPayload),
    .cookiesUnusable("diagnostic"),
    .invalidManualHeader,
    .notAuthenticated,
    .busy,
  ] {
    let (after, result) = SessionReducer.reduce(before, .inconclusive(failure))
    #expect(after == before, "\(failure) must not change the snapshot")
    #expect(result == .rejected(failure))
    #expect(after.account == testAccount)
    #expect(after.validatedCredential == credentialA)
  }
}

@Test func aRejectedResultIsNeverMistakenForSignedOut() {
  let (_, result) = SessionReducer.reduce(
    validatedSnapshot(),
    .inconclusive(.service(NeteaseServiceError(source: .http, statusCode: 503)))
  )

  #expect(result != .signedOut)
  #expect(result != .credentialReplaced(nil))
}

// MARK: - Re-validating the same account

@Test func revalidatingTheSameAccountIsNotAnIdentityChange() {
  let (after, result) = SessionReducer.reduce(
    validatedSnapshot(),
    .validated(testAccount, credentialA)
  )

  #expect(result == .unchangedValidated(testAccount))
  #expect(after.account == testAccount)
}

/// Session-scoped data belongs to the account, not to the cookie, so a
/// refreshed credential for the same user keeps the loaded lists.
@Test func aRefreshedCredentialForTheSameAccountKeepsLoadedData() {
  let (after, result) = SessionReducer.reduce(
    validatedSnapshot(),
    .validated(testAccount, credentialB)
  )

  #expect(result == .unchangedValidated(testAccount))
  #expect(after.validatedCredential == credentialB)
}

@Test func validatingADifferentAccountReplacesTheIdentity() {
  let (after, result) = SessionReducer.reduce(
    validatedSnapshot(),
    .validated(otherAccount, credentialB)
  )

  #expect(result == .credentialReplaced(otherAccount))
  #expect(after.account == otherAccount)
  #expect(after.validatedCredential == credentialB)
}

// MARK: - Storing without validating

@Test func savingACredentialNeverCarriesTheOldAccountForward() {
  let (after, result) = SessionReducer.reduce(
    validatedSnapshot(),
    .storedNewCredential
  )

  #expect(result == .storedUnvalidated)
  #expect(after.presence == .storedUnvalidated)
  #expect(after.account == nil)
  #expect(after.validatedCredential == nil)
  #expect(after.hasStoredSession)
}

// MARK: - Sign-out and divergence

@Test func signOutClearsEverything() {
  let (after, result) = SessionReducer.reduce(validatedSnapshot(), .signedOut)

  #expect(result == .signedOut)
  #expect(after.presence == .absent)
  #expect(after.account == nil)
  #expect(after.validatedCredential == nil)
  #expect(!after.hasStoredSession)
}

@Test func aReplacedStoredItemDropsTheValidatedAccountButKeepsTheItem() {
  let (after, result) = SessionReducer.reduce(
    validatedSnapshot(),
    .storedItemChanged(hasStoredItem: true)
  )

  #expect(result == .credentialReplaced(nil))
  #expect(after.presence == .storedUnvalidated)
  #expect(after.account == nil)
  #expect(after.validatedCredential == nil)
}

@Test func aVanishedStoredItemIsAnIdentityChangeWhenAnAccountWasValidated() {
  let (after, result) = SessionReducer.reduce(
    validatedSnapshot(),
    .storedItemChanged(hasStoredItem: false)
  )

  #expect(result == .credentialReplaced(nil))
  #expect(after.presence == .absent)
}

@Test func aVanishedStoredItemWithNothingValidatedIsJustSignedOut() {
  let (after, result) = SessionReducer.reduce(
    SessionSnapshot(presence: .storedUnvalidated),
    .storedItemChanged(hasStoredItem: false)
  )

  #expect(result == .signedOut)
  #expect(after.presence == .absent)
}

@Test func divergenceMapsOntoTheSameTransition() {
  #expect(
    SessionReducer.event(for: .storedSessionMissing)
      == .storedItemChanged(hasStoredItem: false)
  )
  #expect(
    SessionReducer.event(for: .storedSessionChanged(hasStoredItem: true))
      == .storedItemChanged(hasStoredItem: true)
  )
}

// MARK: - Launch

@Test func launchWithNoStoredItemIsSignedOut() {
  let (after, result) = SessionReducer.reduce(
    SessionSnapshot(),
    .observedStoredItem(present: false)
  )

  #expect(result == .signedOut)
  #expect(after.presence == .absent)
}

@Test func launchWithAStoredItemIsUnvalidated() {
  let (after, result) = SessionReducer.reduce(
    SessionSnapshot(),
    .observedStoredItem(present: true)
  )

  #expect(result == .storedUnvalidated)
  #expect(after.presence == .storedUnvalidated)
  #expect(after.account == nil)
}

/// A relaunch read must not demote an account that is already validated in
/// this process.
@Test func observingAStoredItemDoesNotDemoteAValidatedAccount() {
  let (after, result) = SessionReducer.reduce(
    validatedSnapshot(),
    .observedStoredItem(present: true)
  )

  #expect(result == .unchangedValidated(testAccount))
  #expect(after == validatedSnapshot())
}

// MARK: - Only these results clear session-scoped data

/// The app layer switches on the result. This pins which cases mean "throw
/// away everything loaded for the previous identity".
@Test func onlyIdentityChangesAndSignOutsClearSessionScopedData() {
  func clearsData(_ result: SessionMutationResult) -> Bool {
    switch result {
    case .unchangedValidated, .rejected: false
    case .credentialReplaced, .signedOut, .storedUnvalidated: true
    }
  }

  #expect(!clearsData(.unchangedValidated(testAccount)))
  #expect(!clearsData(.rejected(.transport)))
  #expect(clearsData(.credentialReplaced(otherAccount)))
  #expect(clearsData(.credentialReplaced(nil)))
  #expect(clearsData(.signedOut))
  #expect(clearsData(.storedUnvalidated))
}

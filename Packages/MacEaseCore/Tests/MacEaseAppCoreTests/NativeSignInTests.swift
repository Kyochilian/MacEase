import Foundation
import MacEaseAppCore
import NeteaseKit
import Testing

@testable import MacEaseSession

/// P2: native sign-in, server sign-out and token refresh.
///
/// The invariants: a sign-in stores nothing it has not been given, a granted
/// session is never treated as a *validated account* without asking who it
/// belongs to, and sign-out revokes on the server before it forgets locally.

@MainActor
private struct AuthRig {
  let transport = FakeTransport()
  let vault: FakeVault
  let arbiter = OperationArbiter()
  let session: LoginCoordinator
  private(set) var identityChanges = 0

  init(stored: NeteaseCredential? = nil) {
    vault = FakeVault(stored: stored)
    session = LoginCoordinator(transport: transport, vault: vault, arbiter: arbiter)
  }
}

// MARK: - QR sign-in

@Test @MainActor func startingQRSignInAsksForOneKeyAndBuildsTheScanURL() async {
  let rig = AuthRig()
  await rig.transport.setQRSession(
    .success(
      QRLoginSession(
        key: "K1",
        url: URL(string: "https://music.163.com/login?codekey=K1")!
      )
    )
  )

  _ = await rig.session.startQRLogin()

  #expect(rig.session.qrSession?.key == "K1")
  #expect(
    rig.session.qrSession?.url.absoluteString
      == "https://music.163.com/login?codekey=K1"
  )
  #expect(rig.session.qrStatus == .waiting)
  rig.session.cancelQRLogin()
}

/// A failed key request must not leave a code on screen that nobody can scan.
@Test @MainActor func aFailedKeyRequestLeavesNoCode() async {
  let rig = AuthRig()
  await rig.transport.setQRSession(.failure(URLError(.timedOut)))

  _ = await rig.session.startQRLogin()

  #expect(rig.session.qrSession == nil)
  #expect(rig.session.qrStatus == nil)
}

@Test @MainActor func cancellingQRSignInStopsPolling() async {
  let rig = AuthRig()
  await rig.transport.setQRPolls([.success(.waiting), .success(.waiting)])
  _ = await rig.session.startQRLogin()

  rig.session.cancelQRLogin()
  // Long enough for at least one poll interval to have elapsed had the loop
  // survived cancellation.
  try? await Task.sleep(for: .milliseconds(50))

  #expect(rig.session.qrSession == nil)
  #expect(await rig.transport.recordedCalls() == [.beginQRLogin])
}

// MARK: - SMS sign-in

@Test @MainActor func sendingACodeDoesNotClaimASession() async {
  let rig = AuthRig()
  rig.session.phoneNumber = "13800138000"

  let result = await rig.session.sendVerificationCode()

  #expect(rig.session.codeWasSent)
  #expect(rig.session.account == nil)
  #expect(result == .rejected(.busy))
  #expect(await rig.transport.recordedCalls() == [.sendLoginCode("13800138000")])
}

/// A granted session says a sign-in happened. It does not say whose account it
/// is in a form this app has agreed to trust, so one account-status request
/// settles that before anything downstream works from it.
@Test @MainActor func aPhoneSignInConfirmsWhoseAccountItIs() async {
  let rig = AuthRig()
  let granted = makeCredential("phone-token")
  await rig.transport.setSignIn(.success(granted))
  rig.session.phoneNumber = "13800138000"
  rig.session.verificationCode = "123456"

  let result = await rig.session.signInWithVerificationCode()

  #expect(result == .credentialReplaced(testAccount))
  #expect(rig.session.account == testAccount)
  #expect(await rig.vault.storedForTesting() == granted)
  #expect(
    await rig.transport.recordedCalls()
      == [.signIn("13800138000", "123456"), .accountStatus]
  )
  // The form is cleared only once the sign-in actually worked.
  #expect(rig.session.verificationCode.isEmpty)
}

/// A session that was stored but whose owner could not be confirmed is stored,
/// not validated. Carrying on as if the account were known would let every
/// later read work from an identity nobody checked.
@Test @MainActor func aSignInWhoseAccountCannotBeConfirmedStaysUnvalidated() async {
  let rig = AuthRig()
  await rig.transport.setSignIn(.success(makeCredential("phone-token")))
  await rig.transport.setAccountStatus(.failure(URLError(.timedOut)))
  rig.session.phoneNumber = "13800138000"
  rig.session.verificationCode = "123456"

  let result = await rig.session.signInWithVerificationCode()

  #expect(result == .storedUnvalidated)
  #expect(rig.session.account == nil)
  #expect(rig.session.storedSessionPresence == .stored)
}

/// A code the user mistyped must not clear the phone number they typed
/// correctly.
@Test @MainActor func aRejectedCodeKeepsWhatTheUserEntered() async {
  let rig = AuthRig()
  await rig.transport.setSignIn(
    .failure(NeteaseServiceError(source: .service, statusCode: 503))
  )
  rig.session.phoneNumber = "13800138000"
  rig.session.verificationCode = "000000"

  _ = await rig.session.signInWithVerificationCode()

  #expect(rig.session.phoneNumber == "13800138000")
  #expect(rig.session.verificationCode == "000000")
  #expect(rig.session.account == nil)
}

// MARK: - Server sign-out

/// Revoke first, forget second. The other order leaves a cookie the server
/// still honours and nothing left to revoke it with.
@Test @MainActor func signingOutRevokesOnTheServerBeforeForgettingLocally() async {
  let stored = makeCredential("live")
  let rig = AuthRig(stored: stored)

  let result = await rig.session.signOutEverywhere()

  #expect(result == .signedOut)
  #expect(await rig.vault.storedForTesting() == nil)
  #expect(await rig.transport.recordedCalls() == [.signOut])
  #expect(rig.session.status == "Signed out on NetEase and locally")
}

/// The user asked to sign out, so the local session goes either way. What must
/// not happen is claiming a clean break the server never confirmed.
@Test @MainActor func aFailedServerSignOutStillClearsLocallyAndSaysSo() async {
  let rig = AuthRig(stored: makeCredential("live"))
  await rig.transport.setWriteResult(.failure(URLError(.timedOut)))

  let result = await rig.session.signOutEverywhere()

  #expect(result == .signedOut)
  #expect(await rig.vault.storedForTesting() == nil)
  #expect(rig.session.status.contains("may still be live"))
}

@Test @MainActor func signingOutWithNothingStoredSkipsTheRevocation() async {
  let rig = AuthRig()

  let result = await rig.session.signOutEverywhere()

  #expect(result == .signedOut)
  #expect(await rig.transport.callCount() == 0)
  #expect(rig.session.status.contains("no stored session to revoke"))
}

// MARK: - Refresh

@Test @MainActor func refreshStoresTheNewCookieWithoutClaimingAnAccount() async {
  let stored = makeCredential("old")
  let refreshed = makeCredential("new")
  let rig = AuthRig(stored: stored)
  await rig.transport.setRefresh(.success(refreshed))

  let result = await rig.session.refreshSession()

  #expect(result == .storedUnvalidated)
  #expect(await rig.vault.storedForTesting() == refreshed)
  #expect(rig.session.account == nil)
}

/// A refreshed cookie belongs to the credential that was sent. If the stored
/// item changed while the request was in flight, writing it would overwrite
/// somebody else's session.
@Test @MainActor func refreshRefusesToOverwriteACredentialThatChanged() async {
  let rig = AuthRig(stored: makeCredential("old"))
  await rig.transport.setRefresh(.success(makeCredential("new")))
  await rig.transport.gate.close()

  async let result = rig.session.refreshSession()
  while await rig.transport.gate.arrivalCount() == 0 { await Task.yield() }
  await rig.vault.setStored(makeCredential("replaced"))
  await rig.transport.gate.open()

  #expect(await result == .storedUnvalidated)
  #expect(await rig.vault.storedForTesting() == makeCredential("replaced"))
}

/// A 200 with no new cookie refreshed nothing. Reporting success would leave
/// the app believing it had extended a session it had not.
@Test @MainActor func aRefreshThatReturnsNoCookieIsNotASuccess() async {
  let stored = makeCredential("old")
  let rig = AuthRig(stored: stored)
  await rig.transport.setRefresh(.failure(NeteaseAuthError.noSessionInResponse))

  let result = await rig.session.refreshSession()

  #expect(result == .rejected(.notAuthenticated))
  #expect(await rig.vault.storedForTesting() == stored)
}

@Test @MainActor func refreshWithNothingStoredReportsThatRatherThanFailing() async {
  let rig = AuthRig()

  let result = await rig.session.refreshSession()

  #expect(result == .signedOut)
  #expect(await rig.transport.callCount() == 0)
}

// MARK: - Arbitration

/// Sign-in and refresh share the exclusive slot with server writes, so neither
/// can cancel a write that already reached the server.
@Test @MainActor func signInPathsRespectTheExclusiveSlot() async {
  let rig = AuthRig(stored: makeCredential())
  let held = rig.arbiter.begin(name: "Like", effect: .write)

  #expect(await rig.session.startQRLogin() == .rejected(.busy))
  #expect(await rig.session.sendVerificationCode() == .rejected(.busy))
  #expect(await rig.session.signInWithVerificationCode() == .rejected(.busy))
  #expect(await rig.session.refreshSession() == .rejected(.busy))
  #expect(await rig.session.signOutEverywhere() == .rejected(.busy))
  #expect(await rig.transport.callCount() == 0)

  if let held { rig.arbiter.end(held, outcome: .applied) }
}

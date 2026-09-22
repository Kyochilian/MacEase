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
private final class AuthRig {
  let transport = FakeTransport()
  let vault: FakeVault
  let arbiter = OperationArbiter()
  let session: LoginCoordinator
  let refreshDefaults: UserDefaults
  /// Every account the coordinator reported, in order, including nil. This is
  /// the one hook the app binds per-account local data from, so what lands
  /// here is exactly what a sign-in path is worth.
  private(set) var accountChanges: [NeteaseAccount?] = []

  init(
    stored: NeteaseCredential? = nil,
    refreshDefaults: UserDefaults = makeRefreshDefaults(),
    refreshCalendar: Calendar = .current,
    now: @escaping @MainActor () -> Date = Date.init
  ) {
    vault = FakeVault(stored: stored)
    self.refreshDefaults = refreshDefaults
    session = LoginCoordinator(
      transport: transport,
      vault: vault,
      arbiter: arbiter,
      refreshDefaults: refreshDefaults,
      refreshCalendar: refreshCalendar,
      now: now
    )
    session.onValidatedAccountChanged = { [weak self] account in
      self?.accountChanges.append(account)
    }
  }
}

private func makeRefreshDefaults() -> UserDefaults {
  let suite = "MacEaseTests.AutomaticRefresh.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

@MainActor
private final class RefreshClock {
  var now: Date

  init(now: Date) {
    self.now = now
  }
}

private func refreshTestCalendar() -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
  return calendar
}

@Test @MainActor func offlineStartupRestoresOnlyTheIdentityLinkedToTheStoredCredential() async {
  let defaults = makeRefreshDefaults()
  let credential = makeCredential("saved")
  let first = AuthRig(stored: credential, refreshDefaults: defaults)
  #expect(await first.session.validateSession() == .credentialReplaced(testAccount))
  let offline = AuthRig(stored: credential, refreshDefaults: defaults)
  await offline.transport.setAccountStatus(.failure(URLError(.notConnectedToInternet)))
  #expect(await offline.session.start() == .credentialReplaced(testAccount))
  #expect(offline.session.account == testAccount)
  #expect(!offline.session.isOnline)
  #expect(offline.session.matchesLocalSession(credential, account: testAccount))
  #expect(!offline.session.matchesValidatedSession(credential, account: testAccount))
  let replacement = AuthRig(stored: makeCredential("different"), refreshDefaults: defaults)
  await replacement.transport.setAccountStatus(.failure(URLError(.notConnectedToInternet)))
  _ = await replacement.session.start()
  #expect(replacement.session.account == nil)
}

@Test @MainActor func sameAccountRefreshDoesNotPrepareAnIdentitySwitchOrRebindStorage() async {
  let rig = AuthRig(stored: makeCredential("old"))
  _ = await rig.session.validateSession()
  var preparations = 0
  var resets = 0
  rig.session.onPrepareIdentityMutation = { preparations += 1 }
  rig.session.onIdentityChanged = { resets += 1 }
  #expect(await rig.session.refreshSession() == .unchangedValidated(testAccount))
  #expect(preparations == 0)
  #expect(resets == 0)
  #expect(rig.accountChanges == [testAccount])
}

@Test @MainActor func aReadDuringRenewalPersistenceDoesNotMistakeItForAccountReplacement() async {
  let old = makeCredential("old")
  let refreshed = makeCredential("new")
  let rig = AuthRig(stored: old)
  _ = await rig.session.validateSession()
  await rig.transport.setRefresh(.success(refreshed))
  await rig.vault.saveGate.close()
  let renewal = Task { await rig.session.refreshSessionIfNeeded() }
  for _ in 0..<2000 {
    if await rig.vault.saveGate.arrivalCount() > 0 { break }
    await Task.yield()
  }
  #expect(await rig.vault.storedForTesting() == refreshed)
  let library = PlaylistLibraryCoordinator(
    transport: rig.transport, vault: rig.vault, arbiter: rig.arbiter)
  await rig.transport.setPlaylistDetail(
    .success(
      PlaylistDetail(
        id: 5, name: "Playlist", trackIDs: [1], tracks: makeTracks([1]))))
  library.loadTracks(for: makePlaylists([5])[0], session: rig.session)
  await library.settleForTesting()
  #expect(library.tracks.map(\.id) == [1])
  #expect(rig.session.account == testAccount)
  await rig.vault.saveGate.open()
  _ = await renewal.value
  // A Keychain read may have captured the predecessor before the save and
  // resumed on MainActor after the commit. It still names the same account.
  #expect(rig.session.matchesValidatedSession(old, account: testAccount))
  #expect(rig.session.matchesValidatedSession(refreshed, account: testAccount))
  #expect(!rig.session.matchesValidatedSession(makeCredential("unrelated"), account: testAccount))
  #expect(!rig.session.matchesValidatedSession(refreshed, account: otherAccount))
}

@Test @MainActor
func reconnectingAnOfflineIdentityInitializesOnlineServicesWithoutClearingPlayback() async {
  let defaults = makeRefreshDefaults()
  let credential = makeCredential("stored")
  let first = AuthRig(stored: credential, refreshDefaults: defaults)
  _ = await first.session.validateSession()
  let relaunch = AuthRig(stored: credential, refreshDefaults: defaults)
  await relaunch.transport.setAccountStatus(.failure(URLError(.notConnectedToInternet)))
  _ = await relaunch.session.start()
  var resets = 0
  relaunch.session.onIdentityChanged = { resets += 1 }
  await relaunch.transport.setAccountStatus(.success(.authenticated(testAccount)))
  #expect(await relaunch.session.validateSession() == .unchangedValidated(testAccount))
  await relaunch.session.settleAutomaticRefreshForTesting()
  #expect(relaunch.accountChanges == [testAccount, testAccount])
  #expect(resets == 0)
  #expect(relaunch.session.isOnline)
}

@Test @MainActor func startup301RetiresTheSavedOfflineIdentity() async {
  let defaults = makeRefreshDefaults()
  let credential = makeCredential("expired")
  let rig = AuthRig(stored: credential, refreshDefaults: defaults)
  _ = await rig.session.validateSession()
  await rig.transport.setAccountStatus(
    .failure(NeteaseServiceError(source: .service, statusCode: 301)))
  #expect(await rig.session.start() == .signedOut)
  #expect(rig.session.account == nil)
  let relaunch = AuthRig(stored: credential, refreshDefaults: defaults)
  await relaunch.transport.setAccountStatus(.failure(URLError(.notConnectedToInternet)))
  _ = await relaunch.session.start()
  #expect(relaunch.session.account == nil)
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

/// A confirmed code is a sign-in like any other: the credential is stored, the
/// account is confirmed, and the account change is reported once — which is
/// what binds the queue and the playlists this account left behind.
@Test @MainActor func aConfirmedCodeSignsInAndReportsTheAccountOnce() async {
  let rig = AuthRig()
  let granted = makeCredential("qr-token")
  await rig.transport.setQRPolls([.success(.authorised(granted))])
  _ = await rig.session.startQRLogin()

  #expect(await rig.session.pollQRLoginOnce() == .finished)

  #expect(rig.session.account == testAccount)
  #expect(await rig.vault.storedForTesting() == granted)
  #expect(rig.accountChanges == [testAccount])
  // The code comes down once it has been spent.
  #expect(rig.session.qrSession == nil)
  #expect(rig.session.status == "QR sign-in complete")
  #expect(
    await rig.transport.recordedCalls()
      == [.beginQRLogin, .pollQRLogin("key"), .accountStatus]
  )
}

/// The poll is a read, and it must not go out while a write owns the exclusive
/// slot: the answer could be an authorisation, and adopting one would replace
/// the credential and clear every module underneath a write that is already on
/// its way to NetEase. Nothing is sent, and the code stays live for the next
/// cycle.
@Test @MainActor func qrStatusPollingContinuesDuringALibraryWrite() async {
  let rig = AuthRig()
  await rig.transport.setQRPolls([.success(.scanned)])
  _ = await rig.session.startQRLogin()
  let write = rig.arbiter.begin(name: "Like", effect: .write)!
  #expect(await rig.session.pollQRLoginOnce() == .continued)
  #expect(rig.session.qrStatus == .scanned)
  #expect(rig.arbiter.active?.id == write.id)
  rig.arbiter.end(write, outcome: .applied)
  rig.session.cancelQRLogin()
}

@Test @MainActor func aConfirmedCodeWaitsForAnOverlappingWriteBeforeAdoption() async throws {
  let rig = AuthRig()
  await rig.transport.setQRPolls([.success(.authorised(makeCredential("qr-token")))])
  _ = await rig.session.startQRLogin()
  let write = try #require(rig.arbiter.begin(name: "Like", effect: .write))
  let cycle = Task { await rig.session.pollQRLoginOnce() }
  for _ in 0..<2000 {
    if rig.session.status == "Sign-in confirmed; finishing the current change" { break }
    await Task.yield()
  }
  #expect(rig.session.account == nil)
  #expect(rig.arbiter.active?.id == write.id)
  rig.arbiter.end(write, outcome: .applied)
  #expect(await cycle.value == .finished)
  #expect(rig.session.account == testAccount)
  #expect(rig.arbiter.canStart())
  #expect(rig.arbiter.activeReadCount == 0)
}

/// NetEase granted a session MacEase could not confirm. The code has been
/// spent, so it must not sit on screen reading "Signed in" over an account
/// nobody validated, and no account may be reported as bound.
@Test @MainActor func aCodeWhoseAccountCannotBeConfirmedTakesTheCodeDown() async {
  let rig = AuthRig()
  await rig.transport.setQRPolls([.success(.authorised(makeCredential("qr-token")))])
  await rig.transport.setAccountStatus(.failure(URLError(.timedOut)))
  _ = await rig.session.startQRLogin()

  #expect(await rig.session.pollQRLoginOnce() == .finished)

  #expect(rig.session.account == nil)
  #expect(rig.session.storedSessionPresence == .stored)
  #expect(rig.session.qrSession == nil)
  #expect(rig.session.qrStatus == nil)
  #expect(rig.accountChanges.isEmpty)
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

@Test @MainActor func aKeychainReadFailureDoesNotPretendThereWasNoSession() async {
  let rig = AuthRig(stored: makeCredential("live"))
  await rig.vault.setLoadError(CredentialVaultError.keychain(-25308))

  let result = await rig.session.signOutEverywhere()

  #expect(result == .storedPresenceUnknown)
  #expect(await rig.transport.recordedCalls().isEmpty)
  #expect(!rig.session.status.contains("no stored session to revoke"))
  #expect(rig.session.status.contains("unable to read the stored session"))
}

// MARK: - Refresh

@Test @MainActor func automaticRefreshRunsOncePerLocalDayForOneAccount() async {
  let clock = RefreshClock(now: Date(timeIntervalSince1970: 1_800_000_000))
  let rig = AuthRig(
    stored: makeCredential("old"),
    refreshCalendar: refreshTestCalendar(),
    now: { clock.now }
  )
  #expect(await rig.session.validateSession() == .credentialReplaced(testAccount))
  await rig.transport.setRefresh(.success(makeCredential("day-one")))

  _ = await rig.session.refreshSessionIfNeeded()
  _ = await rig.session.refreshSessionIfNeeded()
  #expect(
    await rig.transport.recordedCalls().filter { $0 == .refreshSession }.count == 1
  )

  clock.now.addTimeInterval(24 * 60 * 60)
  await rig.transport.setRefresh(.success(makeCredential("day-two")))
  _ = await rig.session.refreshSessionIfNeeded()

  #expect(
    await rig.transport.recordedCalls().filter { $0 == .refreshSession }.count == 2
  )
  #expect(rig.session.account == testAccount)
}

@Test @MainActor func automaticRefreshDatesAreIsolatedByAccount() async {
  let defaults = makeRefreshDefaults()
  let date = Date(timeIntervalSince1970: 1_800_000_000)
  let calendar = refreshTestCalendar()
  let first = AuthRig(
    stored: makeCredential("a"),
    refreshDefaults: defaults,
    refreshCalendar: calendar,
    now: { date }
  )
  let second = AuthRig(
    stored: makeCredential("b"),
    refreshDefaults: defaults,
    refreshCalendar: calendar,
    now: { date }
  )
  await second.transport.setAccountStatus(.success(.authenticated(otherAccount)))

  #expect(await first.session.validateSession() == .credentialReplaced(testAccount))
  #expect(await second.session.validateSession() == .credentialReplaced(otherAccount))
  _ = await first.session.refreshSessionIfNeeded()
  _ = await second.session.refreshSessionIfNeeded()

  #expect(
    await first.transport.recordedCalls().filter { $0 == .refreshSession }.count == 1
  )
  #expect(
    await second.transport.recordedCalls().filter { $0 == .refreshSession }.count == 1
  )
  #expect(first.session.account == testAccount)
  #expect(second.session.account == otherAccount)
}

@Test @MainActor func failedAutomaticRefreshDoesNotRetryOrSignOutThatDay() async {
  let rig = AuthRig(stored: makeCredential("valid"))
  #expect(await rig.session.validateSession() == .credentialReplaced(testAccount))
  await rig.transport.setRefresh(.failure(URLError(.timedOut)))

  _ = await rig.session.refreshSessionIfNeeded()
  _ = await rig.session.refreshSessionIfNeeded()

  #expect(
    await rig.transport.recordedCalls().filter { $0 == .refreshSession }.count == 1
  )
  #expect(rig.session.account == testAccount)
  #expect(rig.session.storedSessionPresence == .stored)
  #expect(await rig.vault.storedForTesting() == makeCredential("valid"))
}

@Test @MainActor func unvalidatedStoredCredentialIsNotAutomaticallyRefreshed() async {
  let rig = AuthRig(stored: makeCredential("unverified"))

  #expect(await rig.session.refreshSessionIfNeeded() == nil)
  #expect(await rig.transport.recordedCalls().isEmpty)
  #expect(await rig.vault.storedForTesting() == makeCredential("unverified"))
}

@Test @MainActor func refreshRevalidationCannotRecursivelyRefreshAgain() async {
  let rig = AuthRig(stored: makeCredential("old"))
  await rig.transport.setRefresh(.success(makeCredential("new")))
  #expect(await rig.session.start() == .credentialReplaced(testAccount))
  await rig.session.settleAutomaticRefreshForTesting()

  #expect(
    await rig.transport.recordedCalls() == [
      .accountStatus,
      .refreshSession,
      .accountStatus,
    ]
  )
  #expect(rig.session.account == testAccount)
  #expect(await rig.vault.storedForTesting() == makeCredential("new"))
}

@Test @MainActor func automaticRefreshWaitsForLoginFlowsAndTheArbiter() async {
  let rig = AuthRig(stored: makeCredential("valid"))
  #expect(await rig.session.validateSession() == .credentialReplaced(testAccount))

  _ = await rig.session.startQRLogin()
  #expect(await rig.session.refreshSessionIfNeeded() == nil)
  rig.session.cancelQRLogin()

  rig.session.phoneNumber = "13800138000"
  _ = await rig.session.sendVerificationCode()
  #expect(await rig.session.refreshSessionIfNeeded() == nil)

  let held = rig.arbiter.begin(name: "Like", effect: .write)
  #expect(await rig.session.refreshSessionIfNeeded() == nil)
  if let held { rig.arbiter.end(held, outcome: .applied) }

  #expect(
    await rig.transport.recordedCalls().filter { $0 == .refreshSession }.isEmpty
  )
}

@Test @MainActor func refreshConfirmsTheAccountBeforeReplacingTheCookie() async {
  let stored = makeCredential("old")
  let refreshed = makeCredential("new")
  let rig = AuthRig(stored: stored)
  await rig.transport.setRefresh(.success(refreshed))

  let result = await rig.session.refreshSession()

  #expect(result == .credentialReplaced(testAccount))
  #expect(await rig.vault.storedForTesting() == refreshed)
  #expect(rig.session.account == testAccount)
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

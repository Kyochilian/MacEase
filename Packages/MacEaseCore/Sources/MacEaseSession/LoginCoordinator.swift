import AppKit
import Foundation
import MacEaseAppCore
import NeteaseKit
import Observation
import WebKit

@MainActor
@Observable
package final class LoginCoordinator: NSObject, SessionProviding, WKNavigationDelegate,
  WKUIDelegate
{
  private static let loginURL = URL(string: "https://music.163.com/login")!

  /// How often a QR sign-in asks whether the phone has confirmed. Short enough
  /// that the app does not feel stuck after a scan, long enough that a code
  /// left open for its full lifetime is a few dozen requests rather than
  /// thousands.
  package static let qrPollIntervalSeconds = 2.0

  /// What one poll of a sign-in code did, so the timer loop and the tests
  /// agree on the rules rather than each having its own idea of them.
  package enum QRPollCycle: Equatable, Sendable {
    /// Nothing was sent: an exclusive operation owns the arbiter, or the read
    /// side is full. The code stays live and the next cycle asks again.
    case deferred
    /// Asked, and the answer was not the last one.
    case continued
    /// There is nothing left to ask.
    case finished
  }

  @ObservationIgnored private let dataStore: WKWebsiteDataStore
  @ObservationIgnored private let transport: any NeteaseTransporting
  @ObservationIgnored private let vault: any CredentialStoring
  @ObservationIgnored private let arbiter: OperationArbiter
  @ObservationIgnored private let refreshDefaults: UserDefaults
  @ObservationIgnored private let refreshCalendar: Calendar
  @ObservationIgnored private let now: @MainActor () -> Date
  @ObservationIgnored private var operationToken: OperationToken?
  @ObservationIgnored private var automaticRefreshEnabled = false
  @ObservationIgnored private var automaticRefreshTask: Task<Void, Never>?
  @ObservationIgnored package let webView: WKWebView

  /// The only mutable session state. The reducer replaces it whole; no path
  /// edits presence and the validated credential separately.
  private var snapshot = SessionSnapshot()
  // The last verified same-account rotation spans the asynchronous Keychain
  // save and reads already returning from it. Both cookies represent this
  // identity; keeping one predecessor avoids turning renewal into sign-out.
  @ObservationIgnored private var verifiedRenewal:
    (accountID: Int64, previous: NeteaseCredential, next: NeteaseCredential)?

  /// Display only. No logic reads or compares it.
  package var status = "Ready"
  package var manualCookieHeader = ""

  /// The QR sign-in in progress, and how far it has got. Both are nil until
  /// the user asks for a code.
  package private(set) var qrSession: QRLoginSession?
  package private(set) var qrStatus: QRLoginStatus?
  @ObservationIgnored private var qrPollTask: Task<Void, Never>?

  /// SMS sign-in form state. The code is only ever a code: MacEase never asks
  /// for the NetEase password, which a third-party client has no business
  /// holding even for the moment it would take to hash it.
  package var phoneNumber = ""
  package var countryCode = "86"
  package var verificationCode = ""
  package private(set) var codeWasSent = false

  package var account: NeteaseAccount? { snapshot.account }
  package var isOnline: Bool { snapshot.validatedCredential != nil }
  package var storedSessionPresence: StoredSessionPresence {
    snapshot.storedSessionPresence
  }

  /// Session actions share the exclusive slot with server writes, so this is
  /// derived rather than a fourth independent busy flag.
  package var isBusy: Bool {
    !arbiter.canBegin(effect: .sessionMutation) || identityMutationPreparationIsActive
  }

  package init(
    transport: any NeteaseTransporting,
    vault: any CredentialStoring,
    arbiter: OperationArbiter,
    refreshDefaults: UserDefaults = .standard,
    refreshCalendar: Calendar = .current,
    now: @escaping @MainActor () -> Date = Date.init
  ) {
    let dataStore = WKWebsiteDataStore.nonPersistent()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = dataStore

    self.dataStore = dataStore
    self.transport = transport
    self.vault = vault
    self.arbiter = arbiter
    self.refreshDefaults = refreshDefaults
    self.refreshCalendar = refreshCalendar
    self.now = now
    self.webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()

    webView.navigationDelegate = self
    webView.uiDelegate = self
  }

  @discardableResult
  package func start() async -> SessionMutationResult {
    automaticRefreshEnabled = true
    return await validateSession()
  }

  package func loadLoginPage() {
    guard !isBusy else { return }
    status = "Loading official login page"
    load(Self.loginURL)
  }

  package func saveSession() async -> SessionMutationResult {
    guard await beginIdentityOperation("Save session") else {
      return .rejected(.busy)
    }
    defer { endOperation() }

    let cookies = await dataStore.httpCookieStore.allCookies()
    let allowed = cookies.compactMap(NeteaseCookie.init)
    let musicU = allowed.filter { $0.name == .musicU }
    let csrf = allowed.filter { $0.name == .csrf }

    guard musicU.count == 1 else {
      let diagnostic =
        musicU.isEmpty
        ? musicUCookieDiagnostic(cookies)
        : "Duplicate MUSIC_U cookies rejected"
      status = diagnostic
      return commit(.inconclusive(.cookiesUnusable(diagnostic)))
    }
    guard csrf.count <= 1 else {
      let diagnostic = "Duplicate __csrf cookies rejected"
      status = diagnostic
      return commit(.inconclusive(.cookiesUnusable(diagnostic)))
    }
    guard let credential = NeteaseCredential(musicU: musicU[0], csrf: csrf.first) else {
      let diagnostic = "Extracted cookies did not form a usable session"
      status = diagnostic
      return commit(.inconclusive(.cookiesUnusable(diagnostic)))
    }

    return await adopt(credential, source: "Web")
  }

  package func clearSession() async -> SessionMutationResult {
    guard await beginIdentityOperation("Clear session") else {
      return .rejected(.busy)
    }
    defer { endOperation() }

    webView.stopLoading()
    await transport.resetSessionContext()

    var keychainError: (any Error)?
    do {
      try await vault.delete()
    } catch {
      keychainError = error
    }

    await dataStore.removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
      modifiedSince: .distantPast
    )
    webView.loadHTMLString("", baseURL: Self.loginURL)

    if let keychainError {
      // WebKit data is gone but the Keychain item may not be. Say that rather
      // than claiming a clean slate.
      status =
        keychainErrorMessage(keychainError)
        + "; WebKit data cleared, the stored session may remain"
      return commit(.storedItemPresenceUnknown)
    }
    status = "Keychain and WebKit session cleared"
    return commit(.signedOut)
  }

  package func importSession() async -> SessionMutationResult {
    guard await beginIdentityOperation("Import session") else {
      return .rejected(.busy)
    }
    defer { endOperation() }

    guard let credential = NeteaseCredential(cookieHeader: manualCookieHeader) else {
      status = "Manual Cookie header needs one MUSIC_U without duplicates or control characters"
      return commit(.inconclusive(.invalidManualHeader))
    }

    let state: AccountSessionState
    do {
      state = try await transport.accountStatus(credential: credential)
    } catch let error as NeteaseServiceError {
      status = "Manual Cookie validation \(error.source.rawValue) error \(error.statusCode)"
      return commit(.inconclusive(.service(error)))
    } catch {
      status = "Manual Cookie validation network or response error"
      return commit(.inconclusive(.transport))
    }

    guard case .authenticated(let account) = state else {
      status = "Manual Cookie session invalid; not saved"
      return commit(.inconclusive(.notAuthenticated))
    }

    do {
      try await vault.save(credential)
      // Cleared only once the header is known to have produced a session, so
      // a failed import does not lose what the user pasted.
      manualCookieHeader = ""
      status = "Manual Cookie session authenticated and saved"
      return commit(.validated(account, credential))
    } catch {
      status = keychainErrorMessage(error)
      return commit(.inconclusive(failure(error)))
    }
  }

  // MARK: - QR sign-in

  /// Asks for a fresh sign-in code (1 request) and starts polling it.
  ///
  /// This is the one repeating request in MacEase, and it exists because the
  /// endpoint has no other shape: the phone confirms out of band, so the
  /// desktop has to ask. It stops on its own at the first terminal answer —
  /// authorised or expired — and on any transport failure. Nothing re-arms it.
  package func startQRLogin() async -> SessionMutationResult {
    clearQRSession()
    guard await beginIdentityOperation("QR sign-in") else {
      return .rejected(.busy)
    }
    var keepsPreparationForPolling = false
    defer {
      endOperation(finishesIdentityPreparation: !keepsPreparationForPolling)
    }

    do {
      let session = try await transport.beginQRLogin()
      qrSession = session
      qrStatus = .waiting
      status = "Scan the code with the NetEase Cloud Music app"
      beginPolling()
      // A validated account that intentionally entered account switching
      // stays closed to new playback until this QR flow is cancelled or
      // reaches a terminal answer. Otherwise a local file could start after
      // the old feedback was settled and before authorisation is adopted.
      keepsPreparationForPolling = true
      return commit(.inconclusive(.busy))
    } catch let error as NeteaseServiceError {
      status = "QR sign-in \(error.source.rawValue) error \(error.statusCode)"
      return commit(.inconclusive(.service(error)))
    } catch {
      status = "QR sign-in could not reach NetEase"
      return commit(.inconclusive(.transport))
    }
  }

  package func cancelQRLogin() {
    clearQRSession()
    status = "QR sign-in cancelled"
  }

  private func cancelQRPolling() {
    qrPollTask?.cancel()
    qrPollTask = nil
  }

  /// Takes the code off screen and stops asking about it.
  private func clearQRSession() {
    cancelQRPolling()
    qrSession = nil
    qrStatus = nil
    finishIdentityMutationPreparation()
  }

  /// Starts the timer loop. There is only ever one: every path that replaces
  /// or takes down the code cancels the running task first, so no loop can
  /// outlive the code it was started for.
  private func beginPolling() {
    qrPollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.qrPollIntervalSeconds))
        guard !Task.isCancelled else { return }
        guard let self else { return }
        guard await self.pollQRLoginOnce() != .finished else { return }
      }
    }
  }

  /// One poll of the code in progress: the arbitration, the request, and what
  /// to do with the answer. The timer loop is the only production caller; it
  /// is `package` so the rules can be exercised directly instead of through a
  /// wall clock.
  ///
  /// A poll is a read and claims the arbiter as one. While a server write or
  /// another session mutation owns the exclusive slot nothing is sent at all:
  /// the answer could be an authorisation, and adopting one replaces the
  /// credential and clears every module's session-scoped data — underneath a
  /// write that may already be on its way to NetEase. Deferring costs one
  /// interval; the code stays live and the polling state is untouched.
  @discardableResult
  package func pollQRLoginOnce() async -> QRPollCycle {
    guard let key = qrSession?.key else { return .finished }
    guard
      let readToken = arbiter.begin(name: "QR sign-in poll", effect: .read)
    else { return .deferred }

    let polled: QRLoginStatus
    do {
      polled = try await transport.pollQRLogin(key: key)
    } catch {
      arbiter.end(readToken, outcome: .failed)
      // A failed poll stops the loop rather than retrying forever against an
      // endpoint that may be refusing this client.
      guard qrSession?.key == key else { return .finished }
      qrStatus = nil
      finishIdentityMutationPreparation()
      status = OperationFailure.classify(error, cancelled: Task.isCancelled)
        .statusText(operation: "QR sign-in")
      return .finished
    }
    guard qrSession?.key == key else {
      arbiter.end(readToken, outcome: .cancelled)
      return .finished
    }

    qrStatus = polled
    switch polled {
    case .waiting:
      arbiter.end(readToken, outcome: .applied)
      return .continued
    case .scanned:
      arbiter.end(readToken, outcome: .applied)
      status = "Scanned; confirm the sign-in on your phone"
      return .continued
    case .expired:
      arbiter.end(readToken, outcome: .applied)
      finishIdentityMutationPreparation()
      status = "The code expired; ask for a new one"
      return .finished
    case .authorised(let credential):
      return await adoptAuthorisedQRSession(credential, readToken: readToken)
    }
  }

  /// Turns the read this poll already holds into the session mutation that
  /// adopts the credential, so there is no moment between learning the code
  /// was confirmed and owning the exclusive slot.
  ///
  /// Promotion is refused only while an exclusive operation is already
  /// running, and a write cannot be one: `begin` will not start a write while
  /// any read is held, and this poll has held one since before the response
  /// arrived. What is left is another promotion — a session being invalidated
  /// — and a code adopted into an identity that is being torn down would land
  /// on the wrong account, so it is refused and the user asked again.
  private func adoptAuthorisedQRSession(
    _ credential: NeteaseCredential,
    readToken: OperationToken
  ) async -> QRPollCycle {
    let key = qrSession?.key
    let token: OperationToken?
    if let promoted = arbiter.promote(readToken, name: "QR sign-in") {
      token = promoted
    } else {
      arbiter.end(readToken, outcome: .applied)
      status = "Sign-in confirmed; finishing the current change"
      token = await arbiter.beginWhenAvailable(name: "QR sign-in", effect: .sessionMutation)
    }
    guard let mutationToken = token else {
      clearQRSession()
      status = "Sign-in could not finish; try again"
      return .finished
    }
    guard qrSession?.key == key, key != nil, !Task.isCancelled else {
      arbiter.end(mutationToken, outcome: .cancelled)
      return .finished
    }
    defer { arbiter.end(mutationToken, outcome: .applied) }

    switch await adopt(credential, source: "QR") {
    case .unchangedValidated, .credentialReplaced:
      // The account is confirmed; `adopt` has already taken the code down.
      return .finished
    case .signedOut, .storedUnvalidated, .storedPresenceUnknown, .rejected:
      // NetEase granted a session MacEase could not establish. The code has
      // been spent either way, so it comes down rather than sitting there
      // reading "Signed in" over a session nobody confirmed.
      clearQRSession()
      return .finished
    }
  }

  // MARK: - SMS sign-in

  /// Asks the service to text a code (1 request).
  package func sendVerificationCode() async -> SessionMutationResult {
    guard beginOperation("Send code") else { return .rejected(.busy) }
    defer { endOperation() }

    do {
      try await transport.sendLoginCode(
        phone: phoneNumber.trimmingCharacters(in: .whitespaces),
        countryCode: countryCode.trimmingCharacters(in: .whitespaces)
      )
      codeWasSent = true
      status = "Code sent; enter it to sign in"
      return commit(.inconclusive(.busy))
    } catch NeteaseAuthError.invalidPhoneNumber {
      status = "Enter a phone number and country code made of digits only"
      return commit(.inconclusive(.invalidManualHeader))
    } catch let error as NeteaseServiceError {
      status = "Sending the code failed: \(error.source.rawValue) \(error.statusCode)"
      return commit(.inconclusive(.service(error)))
    } catch {
      status = "Sending the code could not reach NetEase"
      return commit(.inconclusive(.transport))
    }
  }

  /// Exchanges the texted code for a session (1 request), then stores it.
  package func signInWithVerificationCode() async -> SessionMutationResult {
    guard await beginIdentityOperation("Phone sign-in") else {
      return .rejected(.busy)
    }
    defer { endOperation() }

    do {
      let credential = try await transport.signIn(
        phone: phoneNumber.trimmingCharacters(in: .whitespaces),
        code: verificationCode.trimmingCharacters(in: .whitespaces),
        countryCode: countryCode.trimmingCharacters(in: .whitespaces)
      )
      return await adopt(credential, source: "Phone")
    } catch NeteaseAuthError.invalidPhoneNumber {
      status = "Enter a phone number and code made of digits only"
      return commit(.inconclusive(.invalidManualHeader))
    } catch NeteaseAuthError.noSessionInResponse {
      status = "NetEase accepted the code but returned no session"
      return commit(.inconclusive(.notAuthenticated))
    } catch let error as NeteaseServiceError {
      status = "Phone sign-in \(error.source.rawValue) error \(error.statusCode)"
      return commit(.inconclusive(.service(error)))
    } catch {
      status = "Phone sign-in could not reach NetEase"
      return commit(.inconclusive(.transport))
    }
  }

  // MARK: - Server sign-out and refresh

  /// Ends the session on the server, then locally (2 requests at most).
  ///
  /// Order matters. Deleting the Keychain item first would leave a cookie the
  /// server still honours and nothing left to revoke it with. If the server
  /// call fails the local state is still cleared — the user asked to sign out
  /// — but the status says the cookie may still be live rather than claiming a
  /// clean break.
  package func signOutEverywhere() async -> SessionMutationResult {
    guard await beginIdentityOperation("Sign out") else {
      return .rejected(.busy)
    }
    defer { endOperation() }

    var serverMessage = "Signed out on NetEase and locally"
    var loadError: (any Error)?
    do {
      if let credential = try await vault.load() {
        do {
          try await transport.signOut(credential: credential)
        } catch {
          serverMessage =
            "Signed out locally; NetEase did not confirm, so the session may still be live"
        }
      } else {
        serverMessage = "Signed out locally; there was no stored session to revoke"
      }
    } catch {
      loadError = error
      serverMessage =
        "Unable to read the stored session; the NetEase session may still be live"
    }

    webView.stopLoading()
    var keychainError: (any Error)?
    do {
      try await vault.delete()
    } catch {
      keychainError = error
    }
    await dataStore.removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
      modifiedSince: .distantPast
    )
    resetSignInForms()
    webView.loadHTMLString("", baseURL: Self.loginURL)

    if let keychainError {
      status =
        keychainErrorMessage(keychainError)
        + "; WebKit data cleared, the stored session may remain"
      return commit(.storedItemPresenceUnknown)
    }
    if let loadError {
      status =
        keychainErrorMessage(loadError)
        + "; unable to read the stored session, so the NetEase session may still be live"
      return commit(.storedItemPresenceUnknown)
    }
    status = serverMessage
    await transport.resetSessionContext()
    return commit(.signedOut)
  }

  /// Exchanges the stored session for a fresh one (1 request).
  ///
  /// The refreshed cookie is stored only after the service returns one. A
  /// refresh that answers 200 without a new cookie refreshed nothing, and
  /// overwriting a working credential with itself would hide that.
  package func refreshSession() async -> SessionMutationResult {
    await refreshSession(automaticFor: nil)
  }

  /// Refreshes a saved, validated account at most once per local calendar day.
  /// The attempt is persisted immediately before the request, so a failure or
  /// the validation that follows a successful refresh cannot start a loop.
  @discardableResult
  package func refreshSessionIfNeeded() async -> SessionMutationResult? {
    guard
      let account = snapshot.account,
      snapshot.validatedCredential != nil,
      qrSession == nil,
      !codeWasSent,
      !automaticRefreshWasAttemptedToday(for: account)
    else { return nil }
    return await refreshSession(automaticFor: account)
  }

  package func applicationDidBecomeActive() {
    guard automaticRefreshEnabled, automaticRefreshTask == nil else { return }
    automaticRefreshTask = Task { [weak self] in
      guard let self else { return }
      defer { self.automaticRefreshTask = nil }
      if self.account != nil, !self.isOnline {
        _ = await self.validateSession()
      } else {
        _ = await self.refreshSessionIfNeeded()
      }
    }
  }

  private func refreshSession(
    automaticFor expectedAccount: NeteaseAccount?
  ) async -> SessionMutationResult {
    if expectedAccount != nil {
      guard
        let token = await arbiter.beginWhenAvailable(
          name: "Refresh session", effect: .sessionRefresh, timeout: .seconds(600)
        )
      else { return .rejected(.busy) }
      operationToken = token
    } else if !beginOperation("Refresh session") {
      return .rejected(.busy)
    }
    defer { endOperation() }

    let stored: NeteaseCredential?
    do {
      stored = try await vault.load()
    } catch {
      status = keychainErrorMessage(error)
      return commit(.inconclusive(failure(error)))
    }
    guard let stored else {
      status = "No stored session to refresh"
      return commit(.storedItemChanged(hasStoredItem: false))
    }

    if let expectedAccount {
      guard
        snapshot.account?.userID == expectedAccount.userID,
        snapshot.validatedCredential == stored,
        qrSession == nil,
        !codeWasSent,
        !automaticRefreshWasAttemptedToday(for: expectedAccount)
      else { return .rejected(.busy) }
      refreshDefaults.set(now(), forKey: automaticRefreshKey(for: expectedAccount))
    }

    let expectedSnapshot = snapshot
    do {
      let refreshed = try await transport.refreshSession(credential: stored)
      // The item may have been replaced while the request was in flight; the
      // refreshed cookie belongs to the one that was sent, not to whatever is
      // there now.
      guard try await vault.load() == stored else {
        status = "Stored session changed; validate again"
        return commit(.storedItemChanged(hasStoredItem: true))
      }
      guard
        case .authenticated(let account) = try await transport.accountStatus(
          credential: refreshed
        )
      else {
        return await deleteStoredSession(
          matching: stored, message: "Session expired; sign in again",
          expectedSnapshot: expectedSnapshot
        ).result
      }
      let current = try await vault.load()
      guard current == stored, snapshot == expectedSnapshot else {
        return commit(.storedItemChanged(hasStoredItem: current != nil))
      }
      let previousRenewal = verifiedRenewal
      if snapshot.account?.userID == account.userID {
        verifiedRenewal = (account.userID, stored, refreshed)
      }
      do {
        try await vault.save(refreshed)
      } catch {
        verifiedRenewal = previousRenewal
        throw error
      }
      guard snapshot == expectedSnapshot else { return .rejected(.busy) }
      status = "Session refreshed"
      return commit(.validated(account, refreshed))
    } catch NeteaseAuthError.noSessionInResponse {
      status = "NetEase accepted the refresh but returned no new session"
      return commit(.inconclusive(.notAuthenticated))
    } catch let error as NeteaseServiceError {
      if error.source == .service, error.statusCode == 301 {
        return await deleteStoredSession(
          matching: stored, message: "Session expired; sign in again",
          expectedSnapshot: expectedSnapshot
        ).result
      }
      status = "Refresh \(error.source.rawValue) error \(error.statusCode)"
      return commit(.inconclusive(.service(error)))
    } catch let error as CredentialVaultError {
      status = keychainErrorMessage(error)
      return commit(.inconclusive(.keychain(error)))
    } catch {
      status = "Refresh could not reach NetEase"
      return commit(.inconclusive(.transport))
    }
  }

  private func automaticRefreshWasAttemptedToday(
    for account: NeteaseAccount
  ) -> Bool {
    guard
      let attempted = refreshDefaults.object(
        forKey: automaticRefreshKey(for: account)
      ) as? Date
    else { return false }
    return refreshCalendar.isDate(attempted, inSameDayAs: now())
  }

  private func automaticRefreshKey(for account: NeteaseAccount) -> String {
    "MacEase.AutomaticSessionRefresh.\(account.userID)"
  }

  /// Awaits the launch-triggered refresh and the one recursive eligibility
  /// check caused by revalidation. Production never waits on this seam.
  package func settleAutomaticRefreshForTesting() async {
    for _ in 0..<3 {
      guard let task = automaticRefreshTask else { return }
      await task.value
      await Task.yield()
    }
  }

  /// Stores a credential a sign-in produced and confirms whose it is.
  ///
  /// The sign-in response says a session was granted; it does not say which
  /// account, in a form this app has already agreed to trust. One
  /// account-status request settles that, so nothing downstream has to work
  /// from an identity nobody checked.
  private func adopt(
    _ credential: NeteaseCredential,
    source: String
  ) async -> SessionMutationResult {
    do {
      try await vault.save(credential)
    } catch {
      status = keychainErrorMessage(error)
      return commit(.inconclusive(failure(error)))
    }

    let state: AccountSessionState
    do {
      state = try await transport.accountStatus(credential: credential)
    } catch let error as NeteaseServiceError {
      status = "\(source) sign-in stored; validation \(error.source.rawValue) \(error.statusCode)"
      return commit(.storedNewCredential)
    } catch {
      status = "\(source) sign-in stored; validate the session to confirm the account"
      return commit(.storedNewCredential)
    }

    guard case .authenticated(let account) = state else {
      status = "\(source) sign-in returned a session NetEase does not recognise"
      return commit(.storedNewCredential)
    }
    resetSignInForms()
    status = "\(source) sign-in complete"
    return commit(.validated(account, credential))
  }

  private func resetSignInForms() {
    clearQRSession()
    verificationCode = ""
    codeWasSent = false
  }

  /// Reads and validates into locals, then commits once. A timeout, a Keychain
  /// error or a non-301 service error leaves the previously confirmed account,
  /// its playback and its loaded lists exactly as they were.
  package func validateSession() async -> SessionMutationResult {
    guard beginOperation("Validate session") else { return .rejected(.busy) }
    defer { endOperation() }
    var expectedSnapshot = snapshot

    var credential: NeteaseCredential?
    do {
      guard let loaded = try await vault.load() else {
        status = "Sign in to your music library"
        return commit(.storedItemChanged(hasStoredItem: false))
      }
      credential = loaded
      if snapshot.account == nil {
        commit(.observedStoredItem(present: true))
        expectedSnapshot = snapshot
      }

      switch try await transport.accountStatus(credential: loaded) {
      case .authenticated(let account):
        let current = try await vault.load()
        guard current == loaded else {
          status = "Stored session changed; validate again"
          return commit(.storedItemChanged(hasStoredItem: current != nil))
        }
        status = "Account status authenticated"
        return commit(.validated(account, loaded))
      case .signedOut:
        return await deleteStoredSession(
          matching: loaded,
          message: "Stored session expired; sign in again",
          expectedSnapshot: expectedSnapshot
        ).result
      }
    } catch let error as NeteaseServiceError {
      // Service 301 with the credential in hand is the one evidence-backed
      // sign-out; every other error leaves the session alone.
      if error.source == .service, error.statusCode == 301, let credential {
        return await deleteStoredSession(
          matching: credential,
          message: "Stored session expired; sign in again",
          expectedSnapshot: expectedSnapshot
        ).result
      }
      status = "Account status \(error.source.rawValue) error \(error.statusCode)"
      return commit(.inconclusive(.service(error)))
    } catch let error as CredentialVaultError {
      status = keychainErrorMessage(error)
      return commit(.inconclusive(.keychain(error)))
    } catch {
      if let error = error as? URLError,
        [
          .notConnectedToInternet, .networkConnectionLost, .timedOut,
          .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        ].contains(error.code),
        snapshot.account == nil, let credential,
        (try? await vault.load()) == credential,
        let account = storedLocalAccount(matching: credential)
      {
        status = "Offline: your downloaded music is available"
        return commit(.restoredOffline(account, credential))
      }
      status = "Account status network or response error"
      return commit(.inconclusive(.transport))
    }
  }

  /// Called from another coordinator's 301 error path with its active read
  /// token. Promotion does not wait for other reads, so an unrelated read can
  /// no longer decide whether a proven-dead credential is retired.
  ///
  /// If a write owns the exclusive slot the Keychain delete cannot run without
  /// risking that write, but the identity fact must not be thrown away either:
  /// the credential stops being validated immediately, and the stored item is
  /// reported as being of unknown state rather than silently left as if it
  /// were still good.
  package func invalidateStoredSession(
    matching credential: NeteaseCredential,
    message: String,
    readToken: OperationToken
  ) async -> SessionInvalidationResult {
    guard snapshot.validatedCredential == credential else { return .notCurrent }
    guard
      let mutationToken = arbiter.promote(
        readToken,
        name: "Invalidate session"
      )
    else {
      // The server disproved this credential. Keeping it validated until the
      // user happens to press Validate would let later requests use it.
      let expected = snapshot
      await transport.resetSessionContext()
      guard snapshot == expected else { return .notCurrent }
      status = "Stored session expired while a write was in flight; sign in again"
      commit(.storedItemPresenceUnknown)
      return .failed
    }
    defer { arbiter.end(mutationToken, outcome: .applied) }
    return await deleteStoredSession(
      matching: credential,
      message: message,
      expectedSnapshot: snapshot
    ).invalidation
  }

  /// Gate B has no app-level read arbiter. It claims the ordinary session
  /// mutation slot before applying the same conditional invalidation.
  package func invalidateStoredSession(
    matching credential: NeteaseCredential,
    message: String
  ) async -> SessionInvalidationResult {
    guard snapshot.validatedCredential == credential else { return .notCurrent }
    guard
      let token = arbiter.begin(
        name: "Invalidate session",
        effect: .sessionMutation
      )
    else {
      return .busy
    }
    defer { arbiter.end(token, outcome: .applied) }
    return await deleteStoredSession(
      matching: credential,
      message: message,
      expectedSnapshot: snapshot
    ).invalidation
  }

  package func matchesValidatedSession(
    _ credential: NeteaseCredential,
    account: NeteaseAccount
  ) -> Bool {
    guard snapshot.account?.userID == account.userID else { return false }
    if snapshot.validatedCredential == credential { return true }
    guard let renewal = verifiedRenewal, renewal.accountID == account.userID,
      snapshot.validatedCredential == renewal.previous
        || snapshot.validatedCredential == renewal.next
    else { return false }
    return credential == renewal.previous || credential == renewal.next
  }

  package func matchesLocalSession(
    _ credential: NeteaseCredential,
    account: NeteaseAccount
  ) -> Bool {
    matchesValidatedSession(credential, account: account)
      || snapshot.account?.userID == account.userID
        && (snapshot.validatedCredential ?? snapshot.offlineCredential) == credential
  }

  private static let localIdentityKey = "MacEase.LastVerifiedIdentity"

  private func storedLocalAccount(matching credential: NeteaseCredential) -> NeteaseAccount? {
    guard let stored = refreshDefaults.dictionary(forKey: Self.localIdentityKey),
      stored["credential"] as? String == credential.fingerprint,
      let userID = (stored["userID"] as? NSNumber)?.int64Value, userID > 0
    else { return nil }
    return NeteaseAccount(userID: userID)
  }

  /// Called by the app to clear every module's session-scoped data when the
  /// identity in effect changes. It is set once at wiring time.
  @ObservationIgnored package var onIdentityChanged: (@MainActor () -> Void)?

  /// Explicit credential-replacing actions let playback settle feedback while
  /// the old validated credential still exists and before this coordinator
  /// takes the exclusive session-mutation slot. Validation and divergence do
  /// not use this hook: they discover an external identity fact rather than
  /// initiating a switch, and must not stop healthy playback speculatively.
  @ObservationIgnored package var onPrepareIdentityMutation: (@MainActor () async -> Void)?
  @ObservationIgnored package var onFinishIdentityMutationPreparation: (@MainActor () -> Void)?
  private var identityMutationPreparationIsActive = false

  /// Called by the app when the validated account itself changes, including to
  /// none. It is the one place per-account local data is bound, so QR, SMS,
  /// Import and Validate all reach it without any of them carrying its own
  /// copy of the decision — and none of them can be wired up and another left
  /// out. It runs after `onIdentityChanged`, so binding always follows
  /// clearing.
  @ObservationIgnored package var onValidatedAccountChanged: (@MainActor (NeteaseAccount?) -> Void)?

  /// The single place a coordinator's observation of the stored item is
  /// committed to session state. Coordinators never write these fields.
  package func reportDivergence(_ divergence: SessionDivergence) {
    let result = commit(SessionReducer.event(for: divergence))
    switch result {
    case .signedOut:
      status = "No stored session to validate"
    default:
      status = "Stored session changed; validate again"
    }
  }

  private func deleteStoredSession(
    matching credential: NeteaseCredential,
    message: String,
    expectedSnapshot: SessionSnapshot
  ) async -> (invalidation: SessionInvalidationResult, result: SessionMutationResult) {
    guard deletionIsCurrent(expectedSnapshot) else {
      return noLongerCurrentDeletion
    }
    do {
      let deleted = try await vault.delete(matching: credential)
      guard deletionIsCurrent(expectedSnapshot) else {
        return noLongerCurrentDeletion
      }
      guard deleted else {
        // A different credential is stored now; it must not be deleted. A
        // failed confirming read leaves its presence unknown.
        do {
          let remaining = try await vault.load() != nil
          guard deletionIsCurrent(expectedSnapshot) else {
            return noLongerCurrentDeletion
          }
          status = "Stored session changed; validate again"
          return (.notCurrent, commit(.storedItemChanged(hasStoredItem: remaining)))
        } catch {
          guard deletionIsCurrent(expectedSnapshot) else {
            return noLongerCurrentDeletion
          }
          status = "Stored session changed; Keychain state is unknown"
          return (.notCurrent, commit(.storedItemPresenceUnknown))
        }
      }
    } catch {
      guard deletionIsCurrent(expectedSnapshot) else {
        return noLongerCurrentDeletion
      }
      // The service confirmed this credential is dead, so it must stop being
      // treated as validated even though the item may still be on disk.
      status =
        keychainErrorMessage(error)
        + "; the session is no longer valid but may remain stored"
      return (.failed, commit(.storedItemPresenceUnknown))
    }
    guard deletionIsCurrent(expectedSnapshot) else {
      return noLongerCurrentDeletion
    }
    status = message
    await transport.resetSessionContext()
    guard deletionIsCurrent(expectedSnapshot) else { return noLongerCurrentDeletion }
    webView.loadHTMLString("", baseURL: Self.loginURL)
    return (.deleted, commit(.signedOut))
  }

  private func deletionIsCurrent(_ expectedSnapshot: SessionSnapshot) -> Bool {
    snapshot == expectedSnapshot
  }

  private var noLongerCurrentDeletion:
    (invalidation: SessionInvalidationResult, result: SessionMutationResult)
  {
    (.notCurrent, .rejected(.busy))
  }

  @discardableResult
  private func commit(_ event: SessionEvent) -> SessionMutationResult {
    let previousAccount = snapshot.account
    let wasOnline = isOnline
    switch event {
    case .validated(let account, let credential):
      refreshDefaults.set(
        ["userID": account.userID, "credential": credential.fingerprint],
        forKey: Self.localIdentityKey
      )
    case .storedNewCredential, .signedOut, .storedItemChanged, .storedItemPresenceUnknown:
      refreshDefaults.removeObject(forKey: Self.localIdentityKey)
    default: break
    }
    let (next, result) = SessionReducer.reduce(snapshot, event)
    snapshot = next
    switch result {
    case .credentialReplaced, .signedOut, .storedUnvalidated, .storedPresenceUnknown:
      verifiedRenewal = nil
      // Clear all session-scoped modules before the session operation releases
      // the arbiter, so no new request can observe half-transitioned app state.
      onIdentityChanged?()
    case .unchangedValidated, .rejected:
      break
    }
    // Binding per-account local data follows from the account having actually
    // changed, not from which operation ran, so a path that establishes an
    // account cannot forget to bind it.
    if snapshot.account?.userID != previousAccount?.userID || (!wasOnline && isOnline) {
      onValidatedAccountChanged?(snapshot.account)
    }
    if automaticRefreshEnabled, case .validated = event {
      applicationDidBecomeActive()
    }
    return result
  }

  private func failure(_ error: any Error) -> SessionFailure {
    if let error = error as? CredentialVaultError { return .keychain(error) }
    if let error = error as? NeteaseServiceError { return .service(error) }
    return .transport
  }

  package func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    guard let url = navigationAction.request.url else {
      return .cancel
    }
    let decision = LoginNavigationPolicy.decision(
      for: url,
      userActivated: navigationAction.navigationType == .linkActivated
    )
    switch decision {
    case .allowInWebView:
      return .allow
    case .openExternalBrowser:
      NSWorkspace.shared.open(url)
    case .cancel:
      break
    }
    return .cancel
  }

  package func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url {
      let decision = LoginNavigationPolicy.decision(
        for: url,
        userActivated: navigationAction.navigationType == .linkActivated
      )
      switch decision {
      case .allowInWebView:
        webView.load(navigationAction.request)
      case .openExternalBrowser:
        NSWorkspace.shared.open(url)
      case .cancel:
        break
      }
    }
    return nil
  }

  package func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    status = "Login page failed to load"
  }

  private func load(_ url: URL) {
    webView.load(URLRequest(url: url))
  }

  private func keychainErrorMessage(_ error: Error) -> String {
    if let error = error as? CredentialVaultError {
      return "Keychain error \(error.diagnostic)"
    }
    return "Credential encoding error"
  }

  private func musicUCookieDiagnostic(_ cookies: [HTTPCookie]) -> String {
    let hasCSRF = cookies.contains { $0.name == NeteaseCookie.Name.csrf.rawValue }
    guard
      let cookie = cookies.first(where: {
        $0.name == NeteaseCookie.Name.musicU.rawValue
      })
    else {
      return "MUSIC_U absent; __csrf present=\(hasCSRF)"
    }

    let expired = cookie.expiresDate.map { $0 <= Date() } ?? false
    let sameSite = cookie.properties?[.sameSitePolicy] as? String ?? "unspecified"
    return "MUSIC_U rejected: domain=\(cookie.domain), path=\(cookie.path), "
      + "Secure=\(cookie.isSecure), HttpOnly=\(cookie.isHTTPOnly), "
      + "nonempty=\(!cookie.value.isEmpty), expired=\(expired), SameSite=\(sameSite)"
  }

  /// Claims the arbiter for a session mutation. It fails while a server write
  /// owns the exclusive slot, which stops Save/Validate/Clear/Import from
  /// cancelling a write that already reached the server.
  private func beginOperation(_ name: String) -> Bool {
    guard !identityMutationPreparationIsActive else { return false }
    return claimOperation(name)
  }

  private func claimOperation(_ name: String) -> Bool {
    guard let token = arbiter.begin(name: name, effect: .sessionMutation) else {
      return false
    }
    operationToken = token
    return true
  }

  private func beginIdentityOperation(_ name: String) async -> Bool {
    guard !identityMutationPreparationIsActive else { return false }
    guard await prepareForIdentityMutation() else { return false }
    guard claimOperation(name) else {
      finishIdentityMutationPreparation()
      return false
    }
    return true
  }

  private func prepareForIdentityMutation() async -> Bool {
    guard arbiter.canStart(), arbiter.activeReadCount == 0 else { return false }
    guard snapshot.account != nil, let onPrepareIdentityMutation else {
      return true
    }
    identityMutationPreparationIsActive = true
    await onPrepareIdentityMutation()
    // The callback suspends while feedback settles. A concurrent operation
    // may have entered during that suspension, so the ordinary begin check
    // remains authoritative and this early result is only a fast refusal.
    guard arbiter.canStart(), arbiter.activeReadCount == 0 else {
      finishIdentityMutationPreparation()
      return false
    }
    return true
  }

  private func endOperation(
    outcome: OperationOutcome = .applied,
    finishesIdentityPreparation: Bool = true
  ) {
    if let token = operationToken {
      operationToken = nil
      arbiter.end(token, outcome: outcome)
    }
    if finishesIdentityPreparation {
      finishIdentityMutationPreparation()
    }
  }

  private func finishIdentityMutationPreparation() {
    guard identityMutationPreparationIsActive else { return }
    identityMutationPreparationIsActive = false
    onFinishIdentityMutationPreparation?()
  }
}

extension NeteaseCookie {
  fileprivate init?(_ cookie: HTTPCookie) {
    guard let name = Name(rawValue: cookie.name) else {
      return nil
    }
    guard cookie.domain == "music.163.com" || cookie.domain == ".music.163.com" else {
      return nil
    }
    guard cookie.path == "/" else {
      return nil
    }
    guard !cookie.value.isEmpty else {
      return nil
    }
    if let expiresDate = cookie.expiresDate, expiresDate <= Date() {
      return nil
    }
    switch name {
    case .musicU:
      guard cookie.isHTTPOnly else { return nil }
    case .csrf:
      guard cookie.isSecure else { return nil }
    }

    self.init(
      name: name,
      value: cookie.value
    )
  }
}

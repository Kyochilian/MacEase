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

  @ObservationIgnored private let dataStore: WKWebsiteDataStore
  @ObservationIgnored private let transport: any NeteaseTransporting
  @ObservationIgnored private let vault: any CredentialStoring
  @ObservationIgnored private let arbiter: OperationArbiter
  @ObservationIgnored private var operationToken: OperationToken?
  @ObservationIgnored package let webView: WKWebView

  /// The only mutable session state. The reducer replaces it whole; no path
  /// edits presence and the validated credential separately.
  private var snapshot = SessionSnapshot()

  /// Display only. No logic reads or compares it.
  package var status = "Ready"
  package var manualCookieHeader = ""

  package var account: NeteaseAccount? { snapshot.account }
  package var hasStoredSession: Bool { snapshot.hasStoredSession }

  /// Session work is arbitrated with every other NetEase request, so this is
  /// derived rather than a fourth independent busy flag.
  package var isBusy: Bool { arbiter.isBusy }

  package init(
    transport: any NeteaseTransporting,
    vault: any CredentialStoring,
    arbiter: OperationArbiter
  ) {
    let dataStore = WKWebsiteDataStore.nonPersistent()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = dataStore

    self.dataStore = dataStore
    self.transport = transport
    self.vault = vault
    self.arbiter = arbiter
    self.webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()

    webView.navigationDelegate = self
    webView.uiDelegate = self
  }

  @discardableResult
  package func start() async -> SessionMutationResult {
    guard beginOperation("Session start") else { return .rejected(.busy) }
    defer { endOperation() }

    let result: SessionMutationResult
    do {
      let stored = try await vault.load()
      result = commit(.observedStoredItem(present: stored != nil))
      status =
        stored != nil
        ? "Stored API session loaded; validation pending"
        : "Loading official login page"
    } catch {
      result = commit(.inconclusive(failure(error)))
      status = keychainErrorMessage(error)
    }
    load(Self.loginURL)
    return result
  }

  package func loadLoginPage() {
    guard !isBusy else { return }
    status = "Loading official login page"
    load(Self.loginURL)
  }

  package func saveSession() async -> SessionMutationResult {
    guard beginOperation("Save session") else { return .rejected(.busy) }
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

    do {
      try await vault.save(credential)
      status = "Saved \(credential.cookies.count) whitelisted cookie names"
      // Storage is proven, identity is not: the previous account must not be
      // carried over onto a credential nobody has validated.
      return commit(.storedNewCredential)
    } catch {
      status = keychainErrorMessage(error)
      return commit(.inconclusive(failure(error)))
    }
  }

  package func clearSession() async -> SessionMutationResult {
    guard beginOperation("Clear session") else { return .rejected(.busy) }
    defer { endOperation() }

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
    load(Self.loginURL)

    if let keychainError {
      // WebKit data is gone but the Keychain item may not be. Say that rather
      // than claiming a clean slate.
      status =
        keychainErrorMessage(keychainError)
        + "; WebKit data cleared, the stored session may remain"
      return commit(.storedItemChanged(hasStoredItem: true))
    }
    status = "Keychain and WebKit session cleared"
    return commit(.signedOut)
  }

  package func importSession() async -> SessionMutationResult {
    guard beginOperation("Import session") else { return .rejected(.busy) }
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

  /// Reads and validates into locals, then commits once. A timeout, a Keychain
  /// error or a non-301 service error leaves the previously confirmed account,
  /// its playback and its loaded lists exactly as they were.
  package func validateSession() async -> SessionMutationResult {
    guard beginOperation("Validate session") else { return .rejected(.busy) }
    defer { endOperation() }

    var credential: NeteaseCredential?
    do {
      guard let loaded = try await vault.load() else {
        status = "No stored session to validate"
        return commit(.storedItemChanged(hasStoredItem: false))
      }
      credential = loaded

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
          message: "Stored session expired; sign in again"
        ).result
      }
    } catch let error as NeteaseServiceError {
      // Service 301 with the credential in hand is the one evidence-backed
      // sign-out; every other error leaves the session alone.
      if error.source == .service, error.statusCode == 301, let credential {
        return await deleteStoredSession(
          matching: credential,
          message: "Stored session expired; sign in again"
        ).result
      }
      status = "Account status \(error.source.rawValue) error \(error.statusCode)"
      return commit(.inconclusive(.service(error)))
    } catch let error as CredentialVaultError {
      status = keychainErrorMessage(error)
      return commit(.inconclusive(.keychain(error)))
    } catch {
      status = "Account status network or response error"
      return commit(.inconclusive(.transport))
    }
  }

  /// Called from inside another coordinator's error path, which already owns
  /// the arbiter, and touches only the Keychain and the login page. It
  /// therefore does not claim an operation slot of its own.
  package func invalidateStoredSession(
    matching credential: NeteaseCredential,
    message: String
  ) async -> SessionInvalidationResult {
    await deleteStoredSession(matching: credential, message: message).invalidation
  }

  package func matchesValidatedSession(
    _ credential: NeteaseCredential,
    account: NeteaseAccount
  ) -> Bool {
    snapshot.account == account && snapshot.validatedCredential == credential
  }

  /// Called by the app to clear every module's session-scoped data when the
  /// identity in effect changes. It is set once at wiring time.
  @ObservationIgnored package var onIdentityChanged: (@MainActor () -> Void)?

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
    // The reporting coordinator clears itself; its siblings still hold data
    // for an identity that is no longer in effect.
    onIdentityChanged?()
  }

  private func deleteStoredSession(
    matching credential: NeteaseCredential,
    message: String
  ) async -> (invalidation: SessionInvalidationResult, result: SessionMutationResult) {
    do {
      guard try await vault.delete(matching: credential) else {
        // A different credential is stored now; it must not be deleted. If the
        // confirming read itself fails, the item's presence is unknown, so
        // assume it is still there rather than reporting a clean slate.
        let remaining: Bool
        do {
          remaining = try await vault.load() != nil
        } catch {
          remaining = true
        }
        status = "Stored session changed; validate again"
        return (.notCurrent, commit(.storedItemChanged(hasStoredItem: remaining)))
      }
    } catch {
      // The service confirmed this credential is dead, so it must stop being
      // treated as validated even though the item may still be on disk.
      status =
        keychainErrorMessage(error)
        + "; the session is no longer valid but may remain stored"
      return (.failed, commit(.storedItemChanged(hasStoredItem: true)))
    }
    status = message
    load(Self.loginURL)
    return (.deleted, commit(.signedOut))
  }

  @discardableResult
  private func commit(_ event: SessionEvent) -> SessionMutationResult {
    let (next, result) = SessionReducer.reduce(snapshot, event)
    snapshot = next
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

  /// Claims the arbiter for a session mutation. It fails while any other
  /// NetEase request is in flight, which is what stops a Save, Validate,
  /// Clear or Import from cancelling a write that already reached the server.
  private func beginOperation(_ name: String) -> Bool {
    guard let token = arbiter.begin(name: name, effect: .sessionMutation) else {
      return false
    }
    operationToken = token
    return true
  }

  private func endOperation(outcome: OperationOutcome = .applied) {
    guard let token = operationToken else { return }
    operationToken = nil
    arbiter.end(token, outcome: outcome)
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
  }}

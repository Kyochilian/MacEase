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
  @ObservationIgnored private var validatedCredential: NeteaseCredential?
  @ObservationIgnored package let webView: WKWebView

  package var status = "Ready"
  package var hasStoredSession = false
  package var manualCookieHeader = ""
  package var account: NeteaseAccount?

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

  package func start() async {
    guard beginOperation("Session start") else { return }
    defer { endOperation() }

    do {
      hasStoredSession = try await vault.load() != nil
      status =
        hasStoredSession
        ? "Stored API session loaded; validation pending"
        : "Loading official login page"
    } catch {
      status = keychainErrorMessage(error)
    }
    load(Self.loginURL)
  }

  package func loadLoginPage() {
    guard !isBusy else { return }
    status = "Loading official login page"
    load(Self.loginURL)
  }

  package func saveSession() async {
    guard beginOperation("Save session") else { return }
    defer { endOperation() }

    let cookies = await dataStore.httpCookieStore.allCookies()
    let allowed = cookies.compactMap(NeteaseCookie.init)
    let musicU = allowed.filter { $0.name == .musicU }
    let csrf = allowed.filter { $0.name == .csrf }

    guard musicU.count == 1 else {
      status =
        musicU.isEmpty
        ? musicUCookieDiagnostic(cookies)
        : "Duplicate MUSIC_U cookies rejected"
      return
    }
    guard csrf.count <= 1 else {
      status = "Duplicate __csrf cookies rejected"
      return
    }

    guard let credential = NeteaseCredential(musicU: musicU[0], csrf: csrf.first) else {
      status = "Extracted cookies did not form a usable session"
      return
    }

    do {
      try await vault.save(credential)
      hasStoredSession = true
      account = nil
      validatedCredential = nil
      status = "Saved \(credential.cookies.count) whitelisted cookie names"
    } catch {
      status = keychainErrorMessage(error)
    }
  }

  package func clearSession() async {
    guard beginOperation("Clear session") else { return }
    defer { endOperation() }

    webView.stopLoading()
    account = nil
    validatedCredential = nil

    var keychainError: String?
    do {
      try await vault.delete()
    } catch {
      keychainError = keychainErrorMessage(error)
    }

    await dataStore.removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
      modifiedSince: .distantPast
    )
    hasStoredSession = keychainError != nil
    status = keychainError ?? "Keychain and WebKit session cleared"
    load(Self.loginURL)
  }

  package func importSession() async {
    guard beginOperation("Import session") else { return }
    defer { endOperation() }

    let header = manualCookieHeader
    manualCookieHeader = ""
    guard let credential = NeteaseCredential(cookieHeader: header) else {
      status = "Manual Cookie header needs one MUSIC_U without duplicates or control characters"
      return
    }

    let state: AccountSessionState
    do {
      state = try await transport.accountStatus(credential: credential)
    } catch let error as NeteaseServiceError {
      status = "Manual Cookie validation \(error.source.rawValue) error \(error.statusCode)"
      return
    } catch {
      status = "Manual Cookie validation network or response error"
      return
    }

    guard case .authenticated(let account) = state else {
      status = "Manual Cookie session invalid; not saved"
      return
    }

    do {
      try await vault.save(credential)
      hasStoredSession = true
      self.account = account
      validatedCredential = credential
      status = "Manual Cookie session authenticated and saved"
    } catch {
      status = keychainErrorMessage(error)
    }
  }

  package func validateSession() async {
    guard beginOperation("Validate session") else { return }
    defer { endOperation() }

    account = nil
    validatedCredential = nil
    var credential: NeteaseCredential?
    do {
      guard let loaded = try await vault.load() else {
        hasStoredSession = false
        status = "No stored session to validate"
        return
      }
      credential = loaded
      hasStoredSession = true

      switch try await transport.accountStatus(credential: loaded) {
      case .authenticated(let account):
        let currentCredential = try await vault.load()
        guard currentCredential == loaded else {
          hasStoredSession = currentCredential != nil
          status = "Stored session changed; validate again"
          return
        }
        self.account = account
        validatedCredential = loaded
        status = "Account status authenticated"
      case .signedOut:
        _ = await deleteStoredSession(
          matching: loaded,
          message: "Stored session expired; sign in again"
        )
      }
    } catch let error as NeteaseServiceError {
      if error.source == .service, error.statusCode == 301, let credential {
        _ = await deleteStoredSession(
          matching: credential,
          message: "Stored session expired; sign in again"
        )
      } else {
        status = "Account status \(error.source.rawValue) error \(error.statusCode)"
      }
    } catch let error as CredentialVaultError {
      status = keychainErrorMessage(error)
    } catch {
      status = "Account status network or response error"
    }
  }

  /// Called from inside another coordinator's error path, which already owns
  /// the arbiter, and touches only the Keychain and the login page. It
  /// therefore does not claim an operation slot of its own.
  package func invalidateStoredSession(
    matching credential: NeteaseCredential,
    message: String
  ) async -> SessionInvalidationResult {
    await deleteStoredSession(matching: credential, message: message)
  }

  package func matchesValidatedSession(
    _ credential: NeteaseCredential,
    account: NeteaseAccount
  ) -> Bool {
    self.account == account && validatedCredential == credential
  }

  /// The single place a coordinator's observation of the stored item is
  /// committed to session state. Coordinators never write these fields.
  package func reportDivergence(_ divergence: SessionDivergence) {
    account = nil
    validatedCredential = nil
    switch divergence {
    case .storedSessionMissing:
      hasStoredSession = false
      status = "No stored session to validate"
    case .storedSessionChanged(let hasStoredItem):
      hasStoredSession = hasStoredItem
      status = "Stored session changed; validate again"
    }
  }

  private func deleteStoredSession(
    matching credential: NeteaseCredential,
    message: String
  ) async -> SessionInvalidationResult {
    do {
      guard try await vault.delete(matching: credential) else {
        hasStoredSession = try await vault.load() != nil
        account = nil
        validatedCredential = nil
        status = "Stored session changed; validate again"
        return .notCurrent
      }
    } catch {
      status = keychainErrorMessage(error)
      account = nil
      validatedCredential = nil
      return .failed
    }
    hasStoredSession = false
    account = nil
    validatedCredential = nil
    status = message
    load(Self.loginURL)
    return .deleted
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

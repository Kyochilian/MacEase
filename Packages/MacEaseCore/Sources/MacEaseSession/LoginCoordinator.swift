import AppKit
import Foundation
import NeteaseKit
import Observation
import WebKit

package enum SessionInvalidationResult {
  case deleted
  case notCurrent
  case failed
}

@MainActor
@Observable
package final class LoginCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
  private static let loginURL = URL(string: "https://music.163.com/login")!

  @ObservationIgnored private let dataStore: WKWebsiteDataStore
  @ObservationIgnored private let session: NeteaseSession
  @ObservationIgnored private let vault: CredentialVault
  @ObservationIgnored package let webView: WKWebView

  package var status = "Ready"
  package var hasStoredSession = false
  package var isBusy = false
  package var manualCookieHeader = ""
  package var account: NeteaseAccount?

  package override init() {
    let dataStore = WKWebsiteDataStore.nonPersistent()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = dataStore

    self.dataStore = dataStore
    self.session = NeteaseSession()
    self.vault = CredentialVault()
    self.webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()

    webView.navigationDelegate = self
    webView.uiDelegate = self
  }

  package func start() async {
    guard beginOperation() else { return }
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
    guard beginOperation() else { return }
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

    let credential = NeteaseCredential(musicU: musicU[0], csrf: csrf.first)

    do {
      try await vault.save(credential)
      hasStoredSession = true
      account = nil
      status = "Saved \(credential.cookies.count) whitelisted cookie names"
    } catch {
      status = keychainErrorMessage(error)
    }
  }

  package func clearSession() async {
    guard beginOperation() else { return }
    defer { endOperation() }

    webView.stopLoading()
    account = nil

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
    guard beginOperation() else { return }
    defer { endOperation() }

    let header = manualCookieHeader
    manualCookieHeader = ""
    guard let credential = NeteaseCredential(cookieHeader: header) else {
      status = "Manual Cookie header must include one nonempty MUSIC_U"
      return
    }

    let state: AccountSessionState
    do {
      state = try await session.accountStatus(credential: credential)
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
      status = "Manual Cookie session authenticated and saved"
    } catch {
      status = keychainErrorMessage(error)
    }
  }

  package func validateSession() async {
    guard beginOperation() else { return }
    defer { endOperation() }

    account = nil
    do {
      guard let credential = try await vault.load() else {
        hasStoredSession = false
        status = "No stored session to validate"
        return
      }
      hasStoredSession = true

      switch try await session.accountStatus(credential: credential) {
      case .authenticated(let account):
        let currentCredential = try await vault.load()
        guard currentCredential == credential else {
          hasStoredSession = currentCredential != nil
          status = "Stored session changed; validate again"
          return
        }
        self.account = account
        status = "Account status authenticated"
      case .signedOut:
        _ = await deleteStoredSession(
          matching: credential,
          message: "Stored session expired; sign in again"
        )
      }
    } catch let error as NeteaseServiceError {
      status = "Account status \(error.source.rawValue) error \(error.statusCode)"
    } catch let error as CredentialVaultError {
      status = keychainErrorMessage(error)
    } catch {
      status = "Account status network or response error"
    }
  }

  package func invalidateStoredSession(
    matching credential: NeteaseCredential,
    message: String
  ) async -> SessionInvalidationResult {
    guard beginOperation() else { return .notCurrent }
    defer { endOperation() }
    return await deleteStoredSession(matching: credential, message: message)
  }

  private func deleteStoredSession(
    matching credential: NeteaseCredential,
    message: String
  ) async -> SessionInvalidationResult {
    do {
      guard try await vault.delete(matching: credential) else {
        hasStoredSession = try await vault.load() != nil
        account = nil
        status = "Stored session changed; validate again"
        return .notCurrent
      }
    } catch {
      status = keychainErrorMessage(error)
      account = nil
      return .failed
    }
    hasStoredSession = false
    account = nil
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
      return "Keychain error \(error.status)"
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

  private func beginOperation() -> Bool {
    if isBusy {
      return false
    }
    isBusy = true
    return true
  }

  private func endOperation() {
    isBusy = false
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

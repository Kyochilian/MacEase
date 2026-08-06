import AppKit
import Foundation
import NeteaseKit
import Observation
import WebKit

@MainActor
@Observable
final class LoginCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
  private static let loginURL = URL(string: "https://music.163.com/login")!

  @ObservationIgnored private let dataStore: WKWebsiteDataStore
  @ObservationIgnored private let session: NeteaseSession
  @ObservationIgnored private let vault: CredentialVault
  @ObservationIgnored let webView: WKWebView

  var status = "Ready"
  var hasStoredSession = false
  var isBusy = false
  var manualCookieHeader = ""

  override init() {
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

  func start() async {
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

  func loadLoginPage() {
    guard !isBusy else { return }
    status = "Loading official login page"
    load(Self.loginURL)
  }

  func saveSession() async {
    guard beginOperation() else { return }
    defer { endOperation() }

    let cookies = await dataStore.httpCookieStore.allCookies()
    let allowed = cookies.compactMap(NeteaseCookie.init)

    guard let musicU = allowed.first(where: { $0.name == .musicU }) else {
      status = musicUCookieDiagnostic(cookies)
      return
    }

    let credential = NeteaseCredential(
      musicU: musicU,
      csrf: allowed.first(where: { $0.name == .csrf })
    )

    do {
      try await vault.save(credential)
      hasStoredSession = true
      status = "Saved \(credential.cookies.count) whitelisted cookie names"
    } catch {
      status = keychainErrorMessage(error)
    }
  }

  func clearSession() async {
    guard beginOperation() else { return }
    defer { endOperation() }

    webView.stopLoading()

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

  func importSession() async {
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
      status = "Manual Cookie validation service error \(error.statusCode)"
      return
    } catch {
      status = "Manual Cookie validation network or response error"
      return
    }

    guard case .authenticated = state else {
      status = "Manual Cookie session invalid; not saved"
      return
    }

    do {
      try await vault.save(credential)
      hasStoredSession = true
      status = "Manual Cookie session authenticated and saved"
    } catch {
      status = keychainErrorMessage(error)
    }
  }

  func validateSession() async {
    guard beginOperation() else { return }
    defer { endOperation() }

    do {
      guard let credential = try await vault.load() else {
        status = "No stored session to validate"
        return
      }

      switch try await session.accountStatus(credential: credential) {
      case .authenticated:
        status = "Account status authenticated"
      case .signedOut:
        _ = await deleteStoredSession(
          matching: credential,
          message: "Stored session expired; sign in again"
        )
      }
    } catch let error as NeteaseServiceError {
      status = "Account status service error \(error.statusCode)"
    } catch {
      status = "Account status network or response error"
    }
  }

  func invalidateStoredSession(
    matching credential: NeteaseCredential,
    message: String
  ) async -> Bool {
    guard beginOperation() else { return false }
    defer { endOperation() }
    return await deleteStoredSession(matching: credential, message: message)
  }

  private func deleteStoredSession(
    matching credential: NeteaseCredential,
    message: String
  ) async -> Bool {
    do {
      guard try await vault.load() == credential else { return false }
      try await vault.delete()
    } catch {
      status = keychainErrorMessage(error)
      return false
    }
    hasStoredSession = false
    status = message
    load(Self.loginURL)
    return true
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    guard let url = navigationAction.request.url else {
      return .cancel
    }
    guard url.scheme == "https" else {
      return .cancel
    }

    if navigationAction.targetFrame?.isMainFrame == false {
      return url.host == "music.163.com" ? .allow : .cancel
    }
    if url.host == "music.163.com" {
      return .allow
    }
    if navigationAction.navigationType == .linkActivated {
      NSWorkspace.shared.open(url)
    }
    return .cancel
  }

  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if navigationAction.navigationType == .linkActivated,
      let url = navigationAction.request.url,
      url.scheme == "https"
    {
      NSWorkspace.shared.open(url)
    }
    return nil
  }

  func webView(
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

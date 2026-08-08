import Foundation

package enum LoginNavigationDecision: Equatable, Sendable {
  case allowInWebView
  case openExternalBrowser
  case cancel
}

package enum LoginNavigationPolicy {
  package static func allows(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https"
      && url.host?.lowercased() == "music.163.com"
      && (url.port == nil || url.port == 443)
  }

  package static func decision(
    for url: URL,
    userActivated: Bool
  ) -> LoginNavigationDecision {
    guard url.scheme?.lowercased() == "https" else { return .cancel }
    if allows(url) { return .allowInWebView }
    guard url.host?.isEmpty == false else { return .cancel }
    return userActivated ? .openExternalBrowser : .cancel
  }
}

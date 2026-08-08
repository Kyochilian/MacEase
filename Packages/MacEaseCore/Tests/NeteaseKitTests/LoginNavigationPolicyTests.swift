import Foundation
import Testing

@testable import NeteaseKit

@Test func loginNavigationPolicyAllowsOnlyDefaultOfficialOrigin() {
  #expect(LoginNavigationPolicy.allows(URL(string: "https://music.163.com/login")!))
  #expect(LoginNavigationPolicy.allows(URL(string: "https://music.163.com:443/login")!))
  #expect(LoginNavigationPolicy.allows(URL(string: "HTTPS://MUSIC.163.COM/login")!))
}

@Test func loginNavigationPolicyRejectsOtherSchemesHostsAndPorts() {
  let rejected = [
    "http://music.163.com/login",
    "https://sub.music.163.com/login",
    "https://music.163.com.example/login",
    "https://music.163.com:444/login",
    "file:///tmp/login.html",
  ]

  for value in rejected {
    #expect(!LoginNavigationPolicy.allows(URL(string: value)!))
  }
}

@Test func loginNavigationPolicyOpensOnlyUserActivatedHTTPSExternalLinks() {
  let external = URL(string: "https://example.com/help")!
  #expect(
    LoginNavigationPolicy.decision(for: external, userActivated: true)
      == .openExternalBrowser
  )
  #expect(
    LoginNavigationPolicy.decision(for: external, userActivated: false)
      == .cancel
  )
  #expect(
    LoginNavigationPolicy.decision(
      for: URL(string: "http://example.com/help")!,
      userActivated: true
    ) == .cancel
  )
  #expect(
    LoginNavigationPolicy.decision(
      for: URL(string: "https://example.com:444/help")!,
      userActivated: true
    ) == .openExternalBrowser
  )
  #expect(
    LoginNavigationPolicy.decision(
      for: URL(string: "https://music.163.com/login")!,
      userActivated: true
    ) == .allowInWebView
  )
}

import Foundation

@testable import NeteaseKit

/// Test-only construction from constants that are known valid. It traps only
/// when a fixture in this target is edited into a value that could never
/// appear in a real `Cookie` header, which is exactly what a test should do.
func testCookie(_ name: NeteaseCookie.Name, _ value: String) -> NeteaseCookie {
  guard let cookie = NeteaseCookie(name: name, value: value) else {
    fatalError("invalid test cookie fixture: \(name.rawValue)")
  }
  return cookie
}

func testCredential(musicU: String, csrf: String? = nil) -> NeteaseCredential {
  guard
    let credential = NeteaseCredential(
      musicU: testCookie(.musicU, musicU),
      csrf: csrf.map { testCookie(.csrf, $0) }
    )
  else {
    fatalError("invalid test credential fixture")
  }
  return credential
}

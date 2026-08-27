import Foundation
import Testing

@testable import NeteaseKit

/// P1-11: an unusable cookie value must be unrepresentable, not merely
/// rejected on the manual-import path. A value carrying CR/LF, NUL or a
/// separator would be dropped or reinterpreted by URLSession when the header
/// is assembled, so the type refuses it up front.

@Test func cookieValuesOutsideCookieOctetAreUnrepresentable() {
  let rejected = [
    "",
    " ",
    "leading space",
    "value\n",
    "value\r\nX-Injected: 1",
    "value\u{0}",
    "value\ttab",
    "semi;colon",
    "comma,separated",
    "back\\slash",
    "quote\"mark",
    "unicode\u{4E2D}",
    "\u{7F}",
  ]

  for value in rejected {
    #expect(
      NeteaseCookie(name: .musicU, value: value) == nil,
      "expected rejection of \(value.debugDescription)"
    )
  }
}

@Test func realisticCookieValuesStayRepresentable() {
  let accepted = [
    "0123456789abcdef",
    "value==",
    "a+b/c=",
    "%E4%B8%AD",
    "~!#$&'()*+-./:<=>?@[]^_`{|}",
  ]

  for value in accepted {
    #expect(
      NeteaseCookie(name: .musicU, value: value)?.value == value,
      "expected acceptance of \(value.debugDescription)"
    )
  }
}

@Test func credentialRejectsCookiesFiledUnderTheWrongName() {
  #expect(
    NeteaseCredential(
      musicU: testCookie(.csrf, "csrf-value"),
      csrf: nil
    ) == nil
  )
  #expect(
    NeteaseCredential(
      musicU: testCookie(.musicU, "music-u"),
      csrf: testCookie(.musicU, "also-music-u")
    ) == nil
  )
}

// MARK: - Keychain / decoding invariants

private func decodeCredential(_ json: String) throws -> NeteaseCredential {
  try JSONDecoder().decode(NeteaseCredential.self, from: Data(json.utf8))
}

@Test func decodingRejectsAnEmptyCookieValue() {
  #expect(throws: (any Error).self) {
    try decodeCredential(#"{"musicU":{"name":"MUSIC_U","value":""}}"#)
  }
}

@Test func decodingRejectsControlCharactersInAStoredValue() {
  #expect(throws: (any Error).self) {
    try decodeCredential(#"{"musicU":{"name":"MUSIC_U","value":"a\rb"}}"#)
  }
  #expect(throws: (any Error).self) {
    try decodeCredential(#"{"musicU":{"name":"MUSIC_U","value":"a\u0000b"}}"#)
  }
}

@Test func decodingRejectsACookieStoredUnderTheWrongName() {
  #expect(throws: (any Error).self) {
    try decodeCredential(#"{"musicU":{"name":"__csrf","value":"swapped"}}"#)
  }
  #expect(throws: (any Error).self) {
    try decodeCredential(
      #"{"musicU":{"name":"MUSIC_U","value":"ok"},"#
        + #""csrf":{"name":"MUSIC_U","value":"swapped"}}"#
    )
  }
}

/// An older schema that stored an unknown cookie name must fail loudly
/// instead of decoding into a credential with a missing field.
@Test func decodingRejectsAnUnknownCookieName() {
  #expect(throws: (any Error).self) {
    try decodeCredential(#"{"musicU":{"name":"NMTID","value":"legacy"}}"#)
  }
}

@Test func decodingAcceptsAValidStoredCredential() throws {
  let credential = try decodeCredential(
    #"{"musicU":{"name":"MUSIC_U","value":"stored"},"#
      + #""csrf":{"name":"__csrf","value":"token"}}"#
  )

  #expect(credential.musicU.value == "stored")
  #expect(credential.csrf?.value == "token")
}

@Test func encodedCredentialsRoundTrip() throws {
  let credential = testCredential(musicU: "stored", csrf: "token")
  let encoded = try JSONEncoder().encode(credential)

  #expect(try JSONDecoder().decode(NeteaseCredential.self, from: encoded) == credential)
}

// MARK: - Manual header import still enforces the same rules

@Test func manualHeaderRejectsValuesTheTypeWouldRefuse() {
  #expect(NeteaseCredential(cookieHeader: "MUSIC_U=a,b") == nil)
  #expect(NeteaseCredential(cookieHeader: #"MUSIC_U=a"b"#) == nil)
}

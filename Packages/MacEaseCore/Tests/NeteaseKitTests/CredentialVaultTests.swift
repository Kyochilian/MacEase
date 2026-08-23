import Foundation
import Testing

@testable import NeteaseKit

@Test func credentialVaultRoundTrip() async throws {
  let vault = CredentialVault(
    service: "com.macease.tests.\(UUID().uuidString)",
    account: "round-trip"
  )
  let credential = testCredential(musicU: "test-music-u", csrf: "test-csrf")

  try await vault.save(credential)
  #expect(try await vault.load() == credential)

  let replacement = testCredential(musicU: "replacement")
  try await vault.save(replacement)
  #expect(try await vault.load() == replacement)

  try await vault.delete()
  #expect(try await vault.load() == nil)
}

@Test func conditionalCredentialDeletePreservesReplacement() async throws {
  let vault = CredentialVault(
    service: "com.macease.tests.\(UUID().uuidString)",
    account: "conditional-delete"
  )
  let original = testCredential(musicU: "original")
  let replacement = testCredential(musicU: "replacement")

  try await vault.save(replacement)
  #expect(try await vault.delete(matching: original) == false)
  #expect(try await vault.load() == replacement)
  #expect(try await vault.delete(matching: replacement))
  #expect(try await vault.load() == nil)
}

@Test func conditionalCredentialDeleteSerializesAcrossVaultInstances() async throws {
  let service = "com.macease.tests.\(UUID().uuidString)"
  let deletingVault = CredentialVault(
    service: service,
    account: "concurrent-conditional-delete"
  )
  let replacingVault = CredentialVault(
    service: service,
    account: "concurrent-conditional-delete"
  )

  for iteration in 0..<50 {
    let original = testCredential(musicU: "original-\(iteration)")
    let replacement = testCredential(musicU: "replacement-\(iteration)")

    try await deletingVault.save(original)
    async let deletion = deletingVault.delete(matching: original)
    async let replacementSave: Void = replacingVault.save(replacement)
    _ = try await (deletion, replacementSave)

    #expect(try await deletingVault.load() == replacement)
  }

  try await deletingVault.delete()
}

@Test func manualCookieHeaderParsesWhitelistedValues() {
  let credential = NeteaseCredential(
    cookieHeader: "ignored=x; MUSIC_U=value==; __csrf=csrf"
  )

  #expect(credential?.musicU.value == "value==")
  #expect(credential?.csrf?.value == "csrf")
}

@Test func manualCookieHeaderRequiresUnambiguousMusicU() {
  #expect(NeteaseCredential(cookieHeader: "__csrf=csrf") == nil)
  #expect(NeteaseCredential(cookieHeader: "MUSIC_U=") == nil)
  #expect(NeteaseCredential(cookieHeader: "MUSIC_U=one; MUSIC_U=two") == nil)
  #expect(NeteaseCredential(cookieHeader: "MUSIC_U=x; __csrf=a; __csrf=b") == nil)
}

@Test func manualCookieHeaderTrimsPastedNewlinesAndSkipsEmptyValues() {
  let trailingNewline = NeteaseCredential(cookieHeader: "MUSIC_U=value; __csrf=csrf\n")
  #expect(trailingNewline?.musicU.value == "value")
  #expect(trailingNewline?.csrf?.value == "csrf")

  let emptyCSRF = NeteaseCredential(cookieHeader: "MUSIC_U=value; __csrf=")
  #expect(emptyCSRF?.musicU.value == "value")
  #expect(emptyCSRF?.csrf == nil)
}

@Test func manualCookieHeaderRejectsEmbeddedControlCharacters() {
  #expect(NeteaseCredential(cookieHeader: "MUSIC_U=abc\n__csrf=def") == nil)
  #expect(NeteaseCredential(cookieHeader: "MUSIC_U=abc\r\n X-Injected: 1") == nil)
  #expect(NeteaseCredential(cookieHeader: "MUSIC_U=a\tb") == nil)
}

@Test func formEncodingEscapesReservedCharacters() {
  let body = FormURLEncoder.encode([
    ("params", "a+b/c=&"),
    ("encSecKey", "00ff"),
  ])

  #expect(String(decoding: body, as: UTF8.self) == "params=a%2Bb%2Fc%3D%26&encSecKey=00ff")
}

@Test func formEncodingMatchesURLSearchParams() {
  let body = FormURLEncoder.encode([
    ("space", "a b"),
    ("tilde", "~"),
    ("star", "*"),
    ("unicode", "中"),
    ("reserved", "+/=&[]"),
  ])

  #expect(
    String(decoding: body, as: UTF8.self)
      == "space=a+b&tilde=%7E&star=*&unicode=%E4%B8%AD&reserved=%2B%2F%3D%26%5B%5D"
  )
}

import Foundation
import Testing

@testable import NeteaseKit

@Test func credentialVaultRoundTrip() async throws {
  let vault = CredentialVault(
    service: "com.macease.tests.\(UUID().uuidString)",
    account: "round-trip"
  )
  let credential = NeteaseCredential(
    musicU: NeteaseCookie(
      name: .musicU,
      value: "test-music-u"
    ),
    csrf: NeteaseCookie(
      name: .csrf,
      value: "test-csrf"
    )
  )

  try await vault.save(credential)
  #expect(try await vault.load() == credential)

  let replacement = NeteaseCredential(
    musicU: NeteaseCookie(name: .musicU, value: "replacement"),
    csrf: nil
  )
  try await vault.save(replacement)
  #expect(try await vault.load() == replacement)

  try await vault.delete()
  #expect(try await vault.load() == nil)
}

@Test func formEncodingEscapesReservedCharacters() {
  let body = FormURLEncoder.encode([
    ("params", "a+b/c=&"),
    ("encSecKey", "00ff"),
  ])

  #expect(String(decoding: body, as: UTF8.self) == "params=a%2Bb%2Fc%3D%26&encSecKey=00ff")
}

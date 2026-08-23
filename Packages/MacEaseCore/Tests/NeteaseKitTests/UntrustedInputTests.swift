import Foundation
import Security
import Testing

@testable import NeteaseKit

/// P0-02 regression suite: every untrusted boundary — a non-HTTP response,
/// Keychain bytes, ciphertext and compressed bodies — must classify its
/// failure and return, never terminate the process. Each test would have
/// trapped on the pre-fix `as!`, `try!` or `precondition` paths.

// MARK: - Non-HTTP transport responses

/// Answers every request with a plain `URLResponse`, which is what a non-HTTP
/// scheme or a proxy that never produced a status line looks like.
private final class NonHTTPResponseProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let response = URLResponse(
      url: request.url ?? URL(string: "https://music.163.com/")!,
      mimeType: "application/octet-stream",
      expectedContentLength: 0,
      textEncodingName: nil
    )
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private func stubbedSession() -> NeteaseSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [NonHTTPResponseProtocol.self]
  return NeteaseSession(configuration: configuration)
}

private let boundaryCredential = NeteaseCredential(
  musicU: NeteaseCookie(name: .musicU, value: "music-u-test"),
  csrf: NeteaseCookie(name: .csrf, value: "csrf-test")
)

@Test func nonHTTPResponseIsClassifiedOnTheWeAPIPath() async throws {
  let session = stubbedSession()
  await #expect(throws: NeteaseTransportError.nonHTTPResponse) {
    try await session.accountStatus(credential: boundaryCredential)
  }
}

@Test func nonHTTPResponseIsClassifiedOnTheEAPIPath() async throws {
  let session = stubbedSession()
  await #expect(throws: NeteaseTransportError.nonHTTPResponse) {
    try await session.resolveSongURL(
      songID: 347_230,
      quality: .standard,
      credential: boundaryCredential
    )
  }
}

@Test func nonHTTPResponseIsClassifiedOnTheWritePath() async throws {
  let session = stubbedSession()
  await #expect(throws: NeteaseTransportError.nonHTTPResponse) {
    try await session.createPlaylist(
      name: "boundary",
      credential: boundaryCredential
    )
  }
}

@Test func nonHTTPResponseDoesNotBecomeALyricsNetworkError() async {
  let session = stubbedSession()
  let outcome = await session.probeLyrics(songID: 347_230)

  #expect(outcome.status == .invalidResponse)
}

// MARK: - Keychain payloads

private func writeRawKeychainItem(service: String, account: String, data: Data) {
  let query: [CFString: Any] = [
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: service,
    kSecAttrAccount: account,
    kSecAttrSynchronizable: false,
    kSecValueData: data,
  ]
  SecItemDelete(query as CFDictionary)
  SecItemAdd(query as CFDictionary, nil)
}

private func deleteRawKeychainItem(service: String, account: String) {
  let query: [CFString: Any] = [
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: service,
    kSecAttrAccount: account,
    kSecAttrSynchronizable: false,
  ]
  SecItemDelete(query as CFDictionary)
}

@Test func keychainBytesThatAreNotCredentialJSONAreClassified() async throws {
  let service = "com.macease.tests.\(UUID().uuidString)"
  let account = "corrupt-payload"
  defer { deleteRawKeychainItem(service: service, account: account) }
  writeRawKeychainItem(
    service: service,
    account: account,
    data: Data("not a credential".utf8)
  )

  let vault = CredentialVault(service: service, account: account)
  await #expect(throws: CredentialVaultError.corruptPayload) {
    try await vault.load()
  }
}

@Test func keychainCredentialJSONMissingMusicUIsClassified() async throws {
  let service = "com.macease.tests.\(UUID().uuidString)"
  let account = "missing-music-u"
  defer { deleteRawKeychainItem(service: service, account: account) }
  writeRawKeychainItem(
    service: service,
    account: account,
    data: Data(#"{"csrf":{"name":"__csrf","value":"only-csrf"}}"#.utf8)
  )

  let vault = CredentialVault(service: service, account: account)
  await #expect(throws: CredentialVaultError.corruptPayload) {
    try await vault.load()
  }
}

// MARK: - AES / EAPI response bodies

@Test func emptyEAPICiphertextIsClassified() throws {
  #expect(throws: NeteaseCryptoError.invalidInput(field: "ciphertext")) {
    try NeteaseCrypto.decodeEAPIResponse(Data(), gzipped: false)
  }
}

@Test func misalignedEAPICiphertextIsClassified() throws {
  #expect(throws: NeteaseCryptoError.invalidInput(field: "ciphertext")) {
    try NeteaseCrypto.decodeEAPIResponse(
      Data(repeating: 0x41, count: 17),
      gzipped: false
    )
  }
}

/// CommonCrypto does not report bad PKCS7 padding in this mode, so the
/// contract is only that the process survives and the caller gets bytes that
/// fail the downstream JSON decode — never a trap and never trusted output.
@Test func corruptEAPIPaddingDoesNotTerminateAndFailsDownstream() throws {
  let decoded = try NeteaseCrypto.decodeEAPIResponse(
    Data(repeating: 0x00, count: 32),
    gzipped: false
  )

  #expect(throws: (any Error).self) {
    try JSONDecoder().decode([String: String].self, from: decoded)
  }
}

/// A body flagged as gzip but holding garbage must classify, not trap.
@Test func corruptEAPIPaddingWithGzipFlagIsClassified() throws {
  #expect(throws: NeteaseCryptoError.self) {
    try NeteaseCrypto.decodeEAPIResponse(
      Data(repeating: 0x00, count: 32),
      gzipped: true
    )
  }
}

@Test func aWeAPISecretKeyOfTheWrongLengthIsRejectedNotTrapped() throws {
  #expect(throws: NeteaseCryptoError.invalidInput(field: "secretKey")) {
    try NeteaseCrypto.weapi(json: #"{"a":1}"#, secretKey: "short")
  }
  #expect(throws: NeteaseCryptoError.invalidInput(field: "secretKey")) {
    try NeteaseCrypto.weapi(json: #"{"a":1}"#, secretKey: String(repeating: "a", count: 512))
  }
}

// MARK: - gzip bodies

private let validGzip = Data(
  base64Encoded: "H4sIAAAAAAAC/6tWSs5PSVWyMjIw0FFKSSxJVLKKVkqvyixQiq0FAPt+x84cAAAA"
)!
private let truncatedGzip = Data(
  base64Encoded: "H4sIAAAAAAAC/6tWSs5PSVWyMjIw0FFK"
)!
private let zlibNotGzip = Data(
  base64Encoded: "eJyrVkrOT0lVsjIyMNBRSkksSVSyilZKr8osUIqtBQB4vgie"
)!
/// 4096 identical bytes in a 40-byte stream: the expansion shape a zip bomb
/// uses, small enough to keep the test cheap.
private let expandingGzip = Data(
  base64Encoded: "H4sIAAAAAAAC/+3BAQ0AAADCoGzvX8oeDigAAADg3QBANKb+ABAAAA=="
)!

@Test func validGzipStillInflates() throws {
  #expect(
    String(decoding: try NeteaseCrypto.gunzip(validGzip), as: UTF8.self)
      == #"{"code":200,"data":["gzip"]}"#
  )
}

@Test func emptyGzipBodyIsClassified() throws {
  #expect(throws: NeteaseCryptoError.self) {
    try NeteaseCrypto.gunzip(Data())
  }
}

@Test func truncatedGzipBodyIsClassified() throws {
  #expect(throws: NeteaseCryptoError.self) {
    try NeteaseCrypto.gunzip(truncatedGzip)
  }
}

@Test func nonGzipBodyIsClassified() throws {
  #expect(throws: NeteaseCryptoError.self) {
    try NeteaseCrypto.gunzip(zlibNotGzip)
  }
  #expect(throws: NeteaseCryptoError.self) {
    try NeteaseCrypto.gunzip(Data(repeating: 0xff, count: 64))
  }
}

@Test func overExpandingGzipBodyIsRefusedAtTheBound() throws {
  #expect(throws: NeteaseCryptoError.decompressionLimitExceeded) {
    try NeteaseCrypto.gunzip(expandingGzip, limit: 1024)
  }
  #expect(try NeteaseCrypto.gunzip(expandingGzip, limit: 4096).count == 4096)
}

// MARK: - xeapi inputs

private let xeapiPublicKey = Data(
  base64Encoded: "YFpyXSpK3+6xop4X7dYhwbdZPujNvESsbEq24vgF0jw="
)!
private let xeapiTransform = Data((0..<16).map { UInt8(15 - $0) })

private func xeapiParameters(
  publicKey: Data = xeapiPublicKey,
  dynamicKey: Data = Data("0123456789abcdef".utf8),
  transform: Data = xeapiTransform,
  ephemeralPrivateKey: Data = Data((0..<32).map { UInt8($0) }),
  nonce: Data = Data((0..<12).map { UInt8($0) })
) throws -> XeAPIParameters {
  try NeteaseCrypto.xeapi(
    formBody: Data("ids=%5B347230%5D".utf8),
    publicKey: publicKey,
    version: "42",
    sk: "test-sk",
    os: "android",
    dynamicKey: dynamicKey,
    transform: transform,
    ephemeralPrivateKey: ephemeralPrivateKey,
    nonce: nonce
  )
}

@Test func xeapiRejectsEveryWrongSizedInput() throws {
  #expect(throws: NeteaseCryptoError.invalidInput(field: "publicKey")) {
    try xeapiParameters(publicKey: Data(repeating: 1, count: 31))
  }
  #expect(throws: NeteaseCryptoError.invalidInput(field: "dynamicKey")) {
    try xeapiParameters(dynamicKey: Data())
  }
  #expect(throws: NeteaseCryptoError.invalidInput(field: "transform")) {
    try xeapiParameters(transform: Data(repeating: 0, count: 8))
  }
  #expect(throws: NeteaseCryptoError.invalidInput(field: "ephemeralPrivateKey")) {
    try xeapiParameters(ephemeralPrivateKey: Data(repeating: 0, count: 64))
  }
  #expect(throws: NeteaseCryptoError.invalidInput(field: "nonce")) {
    try xeapiParameters(nonce: Data(repeating: 0, count: 16))
  }
}

/// An all-zero Curve25519 peer key is the canonical low-order point; key
/// agreement must classify it rather than trap inside CryptoKit.
@Test func xeapiClassifiesALowOrderPeerKey() throws {
  #expect(throws: NeteaseCryptoError.keyAgreementFailed) {
    try xeapiParameters(publicKey: Data(repeating: 0, count: 32))
  }
}

@Test func malformedXeAPIPublicKeyPayloadsAreClassified() throws {
  #expect(throws: NeteaseCryptoError.self) {
    try NeteaseCrypto.decodeXeAPIPublicKeyState(Data())
  }
  #expect(throws: NeteaseCryptoError.self) {
    try NeteaseCrypto.decodeXeAPIPublicKeyState(Data(repeating: 0x5a, count: 48))
  }
}

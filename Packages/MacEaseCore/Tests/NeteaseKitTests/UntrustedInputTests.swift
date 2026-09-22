import Foundation
import Security
import Testing

@testable import NeteaseKit

/// P0-02 regression suite: every untrusted boundary — transport responses,
/// Keychain bytes and decoded payload shapes — must classify its failure and
/// return, never terminate the process.

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
  return NeteaseSession(configuration: configuration, checkToken: { "test-verification" })
}

private let boundaryCredential = testCredential(musicU: "music-u-test", csrf: "csrf-test")

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
      isPrivate: false,
      credential: boundaryCredential
    )
  }
}

@Test func nonHTTPResponseIsClassifiedOnTheLyricsPath() async throws {
  let session = stubbedSession()
  await #expect(throws: NeteaseTransportError.nonHTTPResponse) {
    try await session.lyrics(
      songID: 347_230,
      credential: boundaryCredential
    )
  }
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

// MARK: - WeAPI inputs

@Test func aWeAPISecretKeyOfTheWrongLengthIsRejectedNotTrapped() throws {
  #expect(throws: NeteaseCryptoError.invalidInput(field: "secretKey")) {
    try NeteaseCrypto.weapi(json: #"{"a":1}"#, secretKey: "short")
  }
  #expect(throws: NeteaseCryptoError.invalidInput(field: "secretKey")) {
    try NeteaseCrypto.weapi(json: #"{"a":1}"#, secretKey: String(repeating: "a", count: 512))
  }
}

// MARK: - Presence markers must be objects

/// P1-01: an empty `Decodable` struct accepts any non-null JSON value, so
/// `1`, `"null"`, `[]` and `true` all used to decode as "this field is
/// present". The reference implementation's unblock path writes the string
/// `"null"` into `freeTrialInfo`, so this is not hypothetical.

private func songURLBody(_ trial: String) -> Data {
  Data(
    #"{"code":200,"data":[{"id":347230,"code":200,"#
      .appending(#""url":"https://m8.music.126.net/a.mp3","freeTrialInfo":\#(trial)}]}"#)
      .utf8
  )
}

private let okResponse = HTTPURLResponse(
  url: URL(string: "https://interfacepc.music.163.com/eapi/x")!,
  statusCode: 200,
  httpVersion: nil,
  headerFields: nil
)!

@Test func onlyAnObjectMarksATrackAsTrial() throws {
  for body in ["1", #""null""#, "[]", "true", #""""#] {
    let resolution = try NeteaseSession.classifySongURL(
      data: songURLBody(body),
      response: okResponse,
      songID: 347_230,
      requestedQuality: .standard
    )
    guard case .resolved(let asset) = resolution else {
      Issue.record("expected a resolved asset for \(body)")
      continue
    }
    #expect(!asset.trial, "\(body) must not read as a trial")
  }

  for body in ["{}", #"{"start":0,"end":30000}"#] {
    let resolution = try NeteaseSession.classifySongURL(
      data: songURLBody(body),
      response: okResponse,
      songID: 347_230,
      requestedQuality: .standard
    )
    guard case .resolved(let asset) = resolution else {
      Issue.record("expected a resolved asset for \(body)")
      continue
    }
    #expect(asset.trial, "\(body) must read as a trial")
  }
}

@Test func aNullTrialFieldIsNotATrial() throws {
  let resolution = try NeteaseSession.classifySongURL(
    data: songURLBody("null"),
    response: okResponse,
    songID: 347_230,
    requestedQuality: .standard
  )
  guard case .resolved(let asset) = resolution else {
    Issue.record("expected a resolved asset")
    return
  }
  #expect(!asset.trial)
}

@Test func onlyAnObjectCountsAsLyricsContent() throws {
  func lyrics(_ lrc: String) throws -> Lyrics {
    try NeteaseSession.classifyLyrics(
      data: Data(#"{"code":200,"lrc":\#(lrc)}"#.utf8),
      response: okResponse
    )
  }

  // Scalar and array shapes must fail instead of becoming lyric content.
  for body in ["1", #""null""#, "[]", "true"] {
    #expect(throws: DecodingError.self, "\(body) must not read as content") {
      try lyrics(body)
    }
  }
  #expect(try lyrics("{}") == .none)
  #expect(try lyrics(#"{"lyric":""}"#) == .none)
  #expect(
    try lyrics(#"{"version":1,"lyric":"[00:00.00] hi"}"#)
      == .lines([LyricLine(timeSeconds: 0, text: "hi")])
  )
}

// MARK: - Timeout policy
//
// M1-05: a request that stalls has to stop. With no retry anywhere, an
// unbounded request would hold its operation slot for the life of the process.

@Test func theSessionPinsItsOwnTimeoutsRegardlessOfTheConfigurationGivenToIt() {
  let configuration = URLSessionConfiguration.ephemeral
  // A caller trying to widen the policy, including the seven-day resource
  // default `ephemeral` would otherwise supply.
  configuration.timeoutIntervalForRequest = 3600
  configuration.timeoutIntervalForResource = 604_800
  configuration.waitsForConnectivity = true

  _ = NeteaseSession(configuration: configuration)

  #expect(configuration.timeoutIntervalForRequest == NeteaseSession.requestTimeoutSeconds)
  #expect(configuration.timeoutIntervalForResource == NeteaseSession.resourceTimeoutSeconds)
  // Queueing a request until connectivity returns would fire it later without
  // the user asking, which is the same problem as a retry.
  #expect(configuration.waitsForConnectivity == false)
}

@Test func theResourceCeilingIsNotBelowTheRequestTimeout() {
  // A resource ceiling under the per-request timeout would cut requests short
  // of the bound the request timeout promises.
  #expect(NeteaseSession.resourceTimeoutSeconds >= NeteaseSession.requestTimeoutSeconds)
}

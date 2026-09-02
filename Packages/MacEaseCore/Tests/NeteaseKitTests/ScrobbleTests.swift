import Foundation
import Testing

@testable import NeteaseKit

private let scrobbleCredential = testCredential(
  musicU: "music-u-scrobble-secret",
  csrf: "csrf-scrobble-secret"
)
private let scrobbleContext = ScrobbleContext(source: "list", sourceID: 24_381_616)
private let scrobbleHeader =
  #"{"osver":"15.5","os":"osx","appver":"0.1","buildver":"1722945678","#
  + #""__csrf":"csrf-scrobble-secret","channel":"github","#
  + #""requestId":"1722945678123_0042","MUSIC_U":"music-u-scrobble-secret"}"#

private func expectedScrobbleBody(logs: String) throws -> String {
  let encodedLogs = String(
    decoding: try JSONEncoder().encode(logs),
    as: UTF8.self
  )
  let json = #"{"logs":\#(encodedLogs),"e_r":false,"header":\#(scrobbleHeader)}"#
  return "params=" + (try NeteaseCrypto.eapi(path: "/api/feedback/weblog", json: json))
}

@Test func scrobbleStartUsesClientLogEAPIAndOnlyStartplayFields() throws {
  let request = try NeteaseSession.scrobbleRequest(
    .start(songID: 347_230, context: scrobbleContext),
    credential: scrobbleCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  let logs =
    #"[{"action":"startplay","json":{"content":"id=24381616","id":347230,"mainsite":"1","mainsiteWeb":"1","type":"song"}}]"#
  let expectedBody = try expectedScrobbleBody(logs: logs)

  #expect(
    request.url?.absoluteString
      == "https://clientlog.music.163.com/eapi/feedback/weblog"
  )
  #expect(request.httpMethod == "POST")
  #expect(request.httpShouldHandleCookies == false)
  #expect(String(decoding: request.httpBody!, as: UTF8.self) == expectedBody)
  #expect(request.value(forHTTPHeaderField: "Referer") == nil)
}

@Test func scrobbleFinishUsesPlayFieldsAndClampsNegativeTime() throws {
  let request = try NeteaseSession.scrobbleRequest(
    .finish(songID: 347_230, context: scrobbleContext, playedSeconds: -4),
    credential: scrobbleCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  let logs =
    #"[{"action":"play","json":{"content":"id=24381616","download":0,"end":"playend","id":347230,"mainsite":"1","mainsiteWeb":"1","source":"list","sourceId":24381616,"time":0,"type":"song","wifi":0}}]"#
  let expectedBody = try expectedScrobbleBody(logs: logs)

  #expect(String(decoding: request.httpBody!, as: UTF8.self) == expectedBody)
}

@Test func scrobbleSourceIsJSONEscapedBeforeEncryption() throws {
  let context = ScrobbleContext(source: "quoted \"list\"\\\n", sourceID: 7)
  let request = try NeteaseSession.scrobbleRequest(
    .finish(songID: 9, context: context, playedSeconds: 12),
    credential: scrobbleCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  let logs =
    #"[{"action":"play","json":{"content":"id=7","download":0,"end":"playend","id":9,"mainsite":"1","mainsiteWeb":"1","source":"quoted \"list\"\\\n","sourceId":7,"time":12,"type":"song","wifi":0}}]"#
  let expectedBody = try expectedScrobbleBody(logs: logs)

  #expect(String(decoding: request.httpBody!, as: UTF8.self) == expectedBody)
}

@Test func scrobbleCredentialNeverEntersURLOrPlainBody() throws {
  let request = try NeteaseSession.scrobbleRequest(
    .start(songID: 1, context: scrobbleContext),
    credential: scrobbleCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  let url = request.url?.absoluteString ?? ""
  let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)

  #expect(!url.contains("music-u-scrobble-secret"))
  #expect(!url.contains("csrf-scrobble-secret"))
  #expect(!body.contains("music-u-scrobble-secret"))
  #expect(!body.contains("csrf-scrobble-secret"))
}

@Test func scrobbleClassifiesHTTPServiceAndMalformedResponses() throws {
  func response(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: URL(string: "https://clientlog.music.163.com/eapi/feedback/weblog")!,
      statusCode: status,
      httpVersion: nil,
      headerFields: nil
    )!
  }

  try NeteaseSession.classifyScrobbleAcknowledgement(
    data: Data(#"{"code":200}"#.utf8),
    response: response(200)
  )
  #expect(throws: NeteaseServiceError(source: .http, statusCode: 503)) {
    try NeteaseSession.classifyScrobbleAcknowledgement(
      data: Data(),
      response: response(503)
    )
  }
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 301)) {
    try NeteaseSession.classifyScrobbleAcknowledgement(
      data: Data(#"{"code":301}"#.utf8),
      response: response(200)
    )
  }
  #expect(throws: NeteaseFeedbackError.invalidResponse) {
    try NeteaseSession.classifyScrobbleAcknowledgement(
      data: Data(#"{"code":"bad"}"#.utf8),
      response: response(200)
    )
  }
  #expect(!String(describing: NeteaseFeedbackError.invalidResponse).contains("secret"))
}

private final class ScrobbleURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requests: [URLRequest] = []

  static func reset() {
    lock.withLock { requests = [] }
  }

  static var requestCount: Int {
    lock.withLock { requests.count }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.withLock { Self.requests.append(request) }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(#"{"code":200}"#.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

@Test func startAndFinishAreTwoIndependentRequests() async throws {
  ScrobbleURLProtocol.reset()
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [ScrobbleURLProtocol.self]
  let session = NeteaseSession(configuration: configuration)

  try await session.scrobbleStart(
    songID: 347_230,
    context: scrobbleContext,
    credential: scrobbleCredential
  )
  #expect(ScrobbleURLProtocol.requestCount == 1)

  try await session.scrobbleFinish(
    songID: 347_230,
    context: scrobbleContext,
    playedSeconds: 42,
    credential: scrobbleCredential
  )
  #expect(ScrobbleURLProtocol.requestCount == 2)
}

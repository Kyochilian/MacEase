@preconcurrency import AVFoundation
import CommonCrypto
import Foundation
import Synchronization
import Testing

@testable import NeteaseKit

private final class ContextProtocol: URLProtocol, @unchecked Sendable {
  struct Reply: Sendable {
    var status = 200
    var cookie: String? = nil
    var json = #"{"code":200,"list":[]}"#
    var error: URLError? = nil
    var delay: TimeInterval = 0
  }
  struct State: Sendable {
    var replies: [Reply] = []
    var requests: [URLRequest] = []
  }
  static let state = Mutex(State())

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var captured = request
    if captured.httpBody == nil, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
      }
      captured.httpBody = data
    }
    let reply = Self.state.withLock { state in
      state.requests.append(captured)
      return state.replies.isEmpty ? Reply() : state.replies.removeFirst()
    }
    if let error = reply.error {
      client?.urlProtocol(self, didFailWithError: error)
      return
    }
    let send: @Sendable () -> Void = { [self] in
      let response = HTTPURLResponse(
        url: request.url!, statusCode: reply.status, httpVersion: nil,
        headerFields: reply.cookie.map { ["Set-Cookie": $0] }
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
    if reply.delay > 0 {
      DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: send)
    } else {
      send()
    }
  }
  override func stopLoading() {}
}

func decryptedBody(_ request: URLRequest) throws -> [String: Any] {
  let form = String(decoding: request.httpBody!, as: UTF8.self)
  let hex = String(form.dropFirst("params=".count))
  var bytes = Data()
  var index = hex.startIndex
  while index < hex.endIndex {
    let end = hex.index(index, offsetBy: 2)
    bytes.append(UInt8(hex[index..<end], radix: 16)!)
    index = end
  }
  let key = Data("e82ckenh8dichen8".utf8)
  var result = Data(count: bytes.count + 16)
  let capacity = result.count
  var count = 0
  let status = result.withUnsafeMutableBytes { output in
    bytes.withUnsafeBytes { input in
      key.withUnsafeBytes { key in
        CCCrypt(
          CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
          CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode), key.baseAddress, 16,
          nil, input.baseAddress, bytes.count, output.baseAddress, capacity, &count)
      }
    }
  }
  #expect(status == kCCSuccess)
  let plaintext = String(decoding: result.prefix(count), as: UTF8.self)
  let json = plaintext.components(separatedBy: "-36cd479b6b5-")[1]
  return try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
}

@Suite(.serialized) struct RequestContextTests {
  private func session(
    _ replies: [ContextProtocol.Reply],
    checkToken: @escaping @Sendable () async throws -> String = { "test-verification" }
  ) -> NeteaseSession {
    ContextProtocol.state.withLock { $0 = .init(replies: replies) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ContextProtocol.self]
    return NeteaseSession(configuration: configuration, checkToken: checkToken)
  }

  @Test func anonymousAndAuthenticatedRequestsShareSamplingWithoutSharingIdentities() async throws {
    let transport = session([
      .init(cookie: "NMTID=anonymous; Path=/", json: #"{"code":200,"unikey":"key"}"#),
      .init(json: #"{"code":801}"#),
      .init(cookie: "NMTID=account-a; Path=/", json: #"{"code":200,"nolyric":true}"#),
      .init(json: #"{"code":200}"#),
      .init(json: #"{"code":200,"nolyric":true}"#),
    ])
    _ = try await transport.beginQRLogin()
    _ = try await transport.pollQRLogin(key: "key")
    let credential = testCredential(musicU: "a", csrf: "csrf")
    _ = try await transport.lyrics(songID: 1, credential: credential)
    try await transport.renamePlaylist(playlistID: 2, name: "New", credential: credential)
    _ = try await transport.lyrics(songID: 1, credential: testCredential(musicU: "b", csrf: "csrf"))
    let requests = ContextProtocol.state.withLock { $0.requests }
    #expect(requests.count == 5)
    for (index, expected) in [nil, "anonymous", nil, "account-a", nil].enumerated() {
      let body = try decryptedBody(requests[index])
      let header = body["header"] as! [String: Any]
      #expect(header["NMTID"] as? String == expected)
      let cookie = requests[index].value(forHTTPHeaderField: "Cookie")!
      #expect(cookie.contains("NMTID=") == (expected != nil))
      if let expected { #expect(cookie.contains("NMTID=\(expected)")) }
    }
  }

  @Test func onlyEligibleHTTPResponsesConsumeTheThreeResponseBudget() async {
    let transport = session([
      .init(status: 500), .init(error: URLError(.timedOut)),
      .init(json: #"{"code":403}"#), .init(), .init(), .init(),
    ])
    let credential = testCredential(musicU: "a", csrf: "csrf")
    for _ in 0..<6 { _ = try? await transport.toplists(credential: credential) }
    let requests = ContextProtocol.state.withLock { $0.requests }
    #expect(requests.count == 6)
    #expect(
      requests.prefix(5).allSatisfy { !$0.value(forHTTPHeaderField: "Cookie")!.contains("NMTID=") })
    let cookie = requests.last!.value(forHTTPHeaderField: "Cookie")!
    let token = cookie.components(separatedBy: "NMTID=").last!
    #expect(token.hasPrefix("00O"))
    #expect(token.count == 41)
    #expect(token.dropFirst(3).allSatisfy { $0.isHexDigit })
  }

  @Test func cookieParsingRejectsConflictsForeignDomainsAndInvalidValues() {
    func token(_ cookie: String) -> String? {
      NeteaseSession.responseNMTID(
        HTTPURLResponse(
          url: URL(string: "https://interfacepc.music.163.com/eapi/test")!,
          statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": cookie]
        )!)
    }
    #expect(
      token("other=x; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/, NMTID=ok; Path=/") == "ok")
    #expect(token("NMTID=a; Path=/, NMTID=b; Path=/") == nil)
    #expect(token("NMTID=a; Domain=example.com; Path=/") == nil)
    #expect(token("NMTID=bad value; Path=/") == nil)
  }

  @Test func downloadUsesItsOwnPayloadAndAcceptsOnlyTheRequestedSong() async throws {
    let transport = session([
      .init(
        json:
          #"{"code":200,"data":{"id":1,"code":200,"url":"https://m1.music.126.net/audio.mp3","br":128000,"size":4276601,"expi":1200,"type":"mp3","fee":0,"freeTrialInfo":null,"level":"standard"}}"#
      )
    ])
    let result = try await transport.resolveDownloadURL(
      songID: 1, quality: .hires, credential: testCredential(musicU: "a", csrf: "csrf")
    )
    let request = ContextProtocol.state.withLock { $0.requests[0] }
    #expect(request.url?.path == "/eapi/song/enhance/download/url/v1")
    let body = try decryptedBody(request)
    #expect(body["id"] as? Int == 1)
    #expect(body["ids"] == nil)
    #expect(body["immerseType"] as? String == "c51")
    guard case .resolved(let asset) = result else {
      Issue.record("Expected formal download metadata")
      return
    }
    #expect(asset.requestedQuality == .hires)
    #expect(asset.actualQuality == "standard")
    #expect(!asset.trial)
  }
}

private func audioUploadFixture() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("wav")
  let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
  buffer.frameLength = 8000
  for index in 0..<8000 { buffer.floatChannelData![0][index] = 0 }
  let file = try AVAudioFile(forWriting: url, settings: format.settings)
  try file.write(from: buffer)
  return url
}

extension RequestContextTests {
  @Test func cloudDuplicateAcknowledgementIsVerifiedWithoutRepeatingPublication() async throws {
    let file = try audioUploadFixture()
    defer { try? FileManager.default.removeItem(at: file) }
    let transport = session([
      .init(json: #"{"code":200,"songId":"201","needUpload":false}"#),
      .init(
        json:
          #"{"code":200,"result":{"token":"UPLOAD test-token","objectKey":"obj/test.wav","resourceId":99,"docId":"-1"}}"#
      ),
      .init(json: #"{"code":200,"songId":"201"}"#),
      .init(json: #"{"code":201}"#),
      .init(
        json:
          #"{"code":200,"data":[{"songId":201,"songName":"File","fileName":"file.wav","fileSize":32000,"simpleSong":{}}]}"#
      ),
    ])
    let id = try await transport.uploadCloudFile(
      at: file, credential: testCredential(musicU: "a", csrf: "csrf")
    ) { _ in }
    #expect(id == 201)
    let requests = ContextProtocol.state.withLock { $0.requests }
    #expect(requests.count == 5)
    #expect(requests.filter { $0.url?.path == "/eapi/cloud/pub/v2" }.count == 1)
    #expect(requests.last?.url?.path == "/weapi/v1/cloud/get/byids")
  }

  @Test func uploadRefusalsPreserveSafeServerGuidance() async throws {
    let file = try audioUploadFixture()
    defer { try? FileManager.default.removeItem(at: file) }
    let transport = session([.init(json: #"{"code":507,"msg":"Cloud drive is full"}"#)])
    do {
      _ = try await transport.uploadCloudFile(
        at: file, credential: testCredential(musicU: "a", csrf: "csrf")
      ) { _ in }
      Issue.record("Expected a quota refusal")
    } catch let error as NeteaseServiceError {
      #expect(error.statusCode == 507)
      #expect(error.message == "Cloud drive is full")
    }
    #expect(ContextProtocol.state.withLock { $0.requests.count } == 1)
    #expect(
      NeteaseServiceError(source: .service, statusCode: 400, message: "MUSIC_U=secret").message
        == nil)
  }

  @Test func playlist512ReadsBackBeforeRetryingOnlyTheMissingIDs() async throws {
    let transport = session([
      .init(json: #"{"code":512}"#),
      .init(json: #"{"code":200,"playlist":{"id":10,"name":"P","trackIds":[{"id":1}]}}"#),
      .init(json: #"{"code":200}"#),
    ])
    try await transport.editPlaylistTracks(
      .add, playlistID: 10, trackIDs: [1, 2], credential: testCredential(musicU: "a", csrf: "csrf"))
    let requests = ContextProtocol.state.withLock { $0.requests }
    #expect(requests.count == 3)
    #expect(requests[1].url?.path == "/eapi/v6/playlist/detail")
    #expect(try decryptedBody(requests[2])["trackIds"] as? String == "[2,2]")
  }

  @Test func anUnknownPlaylistWriteIsNeverAutomaticallyRepeated() async {
    let transport = session([.init(status: 503)])
    await #expect(throws: NeteaseServiceError(source: .http, statusCode: 503)) {
      try await transport.editPlaylistTracks(
        .add, playlistID: 10, trackIDs: [1, 2],
        credential: testCredential(musicU: "a", csrf: "csrf"))
    }
    #expect(ContextProtocol.state.withLock { $0.requests.count } == 1)
  }

  @Test func aCloudFilesEmbeddedLyricsUseTheFileAndAccountIDs() async throws {
    let transport = session([.init(json: #"{"code":200,"lrc":"[00:01.00]Saved words"}"#)])
    let lyrics = try await transport.cloudLyrics(
      userID: 42, songID: 901, credential: testCredential(musicU: "a", csrf: "csrf"))
    let request = ContextProtocol.state.withLock { $0.requests[0] }
    let body = try decryptedBody(request)
    #expect(request.url?.path == "/eapi/cloud/lyric/get")
    #expect(body["userId"] as? Int == 42)
    #expect(body["songId"] as? Int == 901)
    #expect(lyrics.lines.first?.text == "Saved words")
  }

  @Test func searchFeedbackKeepsItsSourceWithoutInventingAnID() throws {
    var context = ScrobbleContext(source: .search)
    context.end = .interrupted
    let request = try NeteaseSession.scrobbleRequest(
      .finish(songID: 1, context: context, playedSeconds: 7),
      credential: testCredential(musicU: "a", csrf: "csrf"), osVersion: "15.5", buildVersion: "1",
      requestID: "1"
    )
    let body = try decryptedBody(request)
    let logs =
      try JSONSerialization.jsonObject(with: Data((body["logs"] as! String).utf8))
      as! [[String: Any]]
    let event = logs[0]["json"] as! [String: Any]
    #expect(event["source"] as? String == "search")
    #expect(event["sourceId"] == nil)
    #expect(event["end"] as? String == "interrupt")
    #expect(event["time"] as? Int == 7)
  }

  @Test func retiredAuxiliaryResponsesCannotSeedTheReplacementSession() async throws {
    let transport = session([
      .init(cookie: "NMTID=old; Path=/", json: #"{"code":200,"nolyric":true}"#, delay: 0.1),
      .init(cookie: "NMTID=new; Path=/", json: #"{"code":200,"nolyric":true}"#, delay: 0.2),
      .init(json: #"{"code":200,"nolyric":true}"#),
    ])
    let credential = testCredential(musicU: "same-account", csrf: "csrf")
    let old = Task { try await transport.lyrics(songID: 1, credential: credential) }
    while ContextProtocol.state.withLock({ $0.requests.isEmpty }) { await Task.yield() }
    await transport.resetSessionContext()
    async let current = transport.lyrics(songID: 2, credential: credential)
    _ = try await old.value
    _ = try await current
    _ = try await transport.lyrics(songID: 3, credential: credential)
    let cookie = ContextProtocol.state.withLock {
      $0.requests.last?.value(forHTTPHeaderField: "Cookie")
    }
    #expect(cookie?.contains("NMTID=new") == true)
    #expect(cookie?.contains("NMTID=old") == false)
  }

  @Test func aFailedVerificationSendsNoSubscriptionWrite() async throws {
    let transport = session([], checkToken: { throw URLError(.timedOut) })
    await #expect(throws: NeteaseWritePreparationError.verificationUnavailable) {
      try await transport.setPlaylistSubscribed(
        true, playlistID: 1, credential: testCredential(musicU: "a", csrf: "csrf"))
    }
    #expect(ContextProtocol.state.withLock { $0.requests.isEmpty })
  }

  @Test func formalDownloadsUpgradeTheVerifiedLegacyCDNAndKeepFileIdentity() throws {
    let response = HTTPURLResponse(
      url: URL(string: "https://interfacepc.music.163.com/eapi/song/enhance/download/url/v1")!,
      statusCode: 200, httpVersion: nil, headerFields: nil)!
    let result = try NeteaseSession.classifyDownloadURL(
      data: Data(
        #"{"code":200,"data":{"id":33894312,"url":"http://m8.music.126.net/audio.mp3","br":128000,"size":4276601,"md5":"a0634034446f904929e37dc2686ba91b","code":200,"expi":1200,"type":"mp3","fee":0,"freeTrialInfo":null,"level":"standard"}}"#
          .utf8),
      response: response, songID: 33_894_312, requestedQuality: .standard
    )
    guard case .resolved(let asset) = result else {
      Issue.record("Expected a full download")
      return
    }
    #expect(asset.url.scheme == "https")
    #expect(asset.sourceScheme == "http")
    #expect(asset.fileMD5 == "a0634034446f904929e37dc2686ba91b")
  }

  @Test func cloudUploadUsesOneAllocationAndPublishesOnlyAfterTheFileTransfer() async throws {
    let file = try audioUploadFixture()
    defer { try? FileManager.default.removeItem(at: file) }
    let transport = session([
      .init(json: #"{"code":200,"songId":"201","needUpload":true}"#),
      .init(
        json:
          #"{"code":200,"result":{"token":"UPLOAD test-token","objectKey":"obj/test.wav","resourceId":99,"docId":"-1"}}"#
      ),
      .init(json: #"{"upload":["http://nosup-hz1.127.net"]}"#),
      .init(json: #"{"offset":32100}"#),
      .init(json: #"{"code":200,"songId":"201"}"#),
      .init(json: #"{"code":200}"#),
    ])
    let phases = Mutex<[CloudUploadProgress]>([])
    let id = try await transport.uploadCloudFile(
      at: file, credential: testCredential(musicU: "private-credential", csrf: "csrf")
    ) { phase in
      phases.withLock { $0.append(phase) }
    }
    #expect(id == 201)
    let requests = ContextProtocol.state.withLock { $0.requests }
    #expect(requests.count == 6)
    #expect(requests.filter { $0.url?.path.hasSuffix("nos/token/alloc") == true }.count == 1)
    #expect(requests[2].value(forHTTPHeaderField: "Cookie") == nil)
    #expect(requests[3].value(forHTTPHeaderField: "Cookie") == nil)
    #expect(requests[3].value(forHTTPHeaderField: "x-nos-token") == "UPLOAD test-token")
    #expect(requests[3].url?.scheme == "https")
    #expect(requests.last?.url?.path == "/eapi/cloud/pub/v2")
    #expect(phases.withLock { $0.first } == .preparing)
    #expect(phases.withLock { $0.last } == .publishing)
  }

  @Test func aNOSFailureCannotPublishAnUntransferredCloudFile() async throws {
    let file = try audioUploadFixture()
    defer { try? FileManager.default.removeItem(at: file) }
    let transport = session([
      .init(json: #"{"code":200,"songId":"201","needUpload":true}"#),
      .init(
        json:
          #"{"code":200,"result":{"token":"UPLOAD test-token","objectKey":"obj/test.wav","resourceId":99,"docId":"-1"}}"#
      ),
      .init(json: #"{"upload":["https://nosup-hz1.127.net"]}"#),
      .init(json: #"{"errCode":403}"#),
    ])
    await #expect(throws: NeteaseUploadError.beforePublication) {
      _ = try await transport.uploadCloudFile(
        at: file, credential: testCredential(musicU: "a", csrf: "csrf")
      ) { _ in }
    }
    let requests = ContextProtocol.state.withLock { $0.requests }
    #expect(requests.count == 4)
    #expect(!requests.contains { $0.url?.path == "/eapi/cloud/pub/v2" })
  }
}

@Test func musicLinksValidateTheirOriginAndResourceIdentity() {
  #expect(NeteaseMusicLink(url: URL(string: "https://music.163.com/#/song?id=123")!) == .song(123))
  #expect(
    NeteaseMusicLink(url: URL(string: "https://y.music.163.com/m/album?id=456")!) == .album(456))
  for value in [
    "https://music.163.com.evil.invalid/song?id=1", "https://user@music.163.com/song?id=1",
    "https://music.163.com/song?id=1&id=2", "https://music.163.com/song?id=-1",
    "https://music.163.com/song?id=9999999999999999999999999", "file:///song?id=1",
  ] { #expect(NeteaseMusicLink(url: URL(string: value)!) == nil) }
}

extension RequestContextTests {
  @Test func requestDiagnosticsMeasureCompletionWithoutLoggingCredentialsOrQuery() async throws {
    ContextProtocol.state.withLock { $0 = .init(replies: [.init()]) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ContextProtocol.self]
    let events = Mutex<[RequestDiagnostic]>([])
    let session = NeteaseSession(configuration: configuration, diagnostics: { event in
      events.withLock { $0.append(event) }
    })
    _ = try await session.send(credential: nil) { _ in
      var request = URLRequest(url: URL(string: "https://music.163.com/api/example?token=secret-query")!)
      request.setValue("MUSIC_U=secret-cookie", forHTTPHeaderField: "Cookie")
      request.httpBody = Data("secret-body".utf8)
      return request
    }
    let event = try #require(events.withLock { $0.last(where: { $0.phase == "complete" }) })
    #expect(event.path == "/api/example")
    #expect(event.status == 200)
    #expect(event.totalMS != nil)
    #expect(event.preparationMS != nil)
    #expect(event.bytes > 0)
    #expect(!event.line.contains("secret"))
    #expect(!event.line.contains("MUSIC_U"))
    #expect(!event.line.contains("?"))
  }

  @Test func requestDiagnosticsIncludeFailedRequests() async {
    ContextProtocol.state.withLock { $0 = .init(replies: [.init(error: URLError(.timedOut))]) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ContextProtocol.self]
    let events = Mutex<[RequestDiagnostic]>([])
    let session = NeteaseSession(configuration: configuration, diagnostics: { event in
      events.withLock { $0.append(event) }
    })
    do {
      _ = try await session.send(credential: nil) { _ in
        URLRequest(url: URL(string: "https://music.163.com/api/example")!)
      }
      Issue.record("Expected timeout")
    } catch {
      let complete = events.withLock { $0.filter { $0.phase == "complete" } }
      #expect(complete.count == 1)
      #expect(complete.first?.errorCode == URLError.timedOut.rawValue)
      #expect(complete.first?.totalMS != nil)
    }
  }
}

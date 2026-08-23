import Foundation
import Testing

@testable import NeteaseKit

private let playbackCredential = testCredential(musicU: "music-u-test", csrf: "csrf-test")

@Test func songURLRequestGoldenVector() throws {
  let request = try NeteaseSession.songURLRequest(
    songID: 347230,
    quality: .standard,
    credential: playbackCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )

  #expect(
    request.url?.absoluteString
      == "https://interfacepc.music.163.com/eapi/song/enhance/player/url/v1"
  )
  #expect(request.httpMethod == "POST")
  #expect(request.httpShouldHandleCookies == false)
  #expect(
    request.value(forHTTPHeaderField: "Cookie")
      == "osver=15.5; os=osx; appver=0.1; buildver=1722945678; __csrf=csrf-test; channel=github; requestId=1722945678123_0042; MUSIC_U=music-u-test"
  )
  #expect(request.value(forHTTPHeaderField: "Referer") == nil)
  let headerNames = Set(request.allHTTPHeaderFields!.keys)
  #expect(headerNames == ["Content-Type", "User-Agent", "Cookie"])
  #expect(
    String(decoding: request.httpBody!, as: UTF8.self)
      == "params=FA90B329E9614F79E79598F37DC2EDB487F00D1BC4C9B24CD57E6C318B9073569338432CD7D98D1A3626E997A2C53121C461EE0E88D3D1BF3F42E78643807A29B83D00D24CECA2C01F229A64E4D80CBB43B3579770BB9A18CB701D3B0BC6D065CA453B3E5878AAD47AEF2C2F5728AA7ACA152B69922C48ECBDF75FB89A1CC4CC64309129EC8E3D81629CDF6515FB74936ECA0597DC33E61124C9EC08F9E37B41C36C69E8D897B4F9A61B02B52595D17E51A105882A6877715992DB465ED76D99F483512E3D00E357A06427C53221B17FBA9D66488F286893DBB48EBA76F4D9E377209758B6A60CDBD84119950BBA7E9C4F69B47CE9E4992D8F63153988B9E31F31E5C286AC302F47C60B5BD192C38835DD8C008D86A5EE3F847B9AD8F271683FD5985F48C97983CB3D52301C55001628C7E8C527833D276F22B4A46CB3B95C2C150DB9646C7F120577A72337DC9D48B4"
  )
}

@Test func songURLRequestKeepsEmptyCSRFContext() throws {
  let credential = testCredential(musicU: "music-u-test")
  let request = try NeteaseSession.songURLRequest(
    songID: 347230,
    quality: .standard,
    credential: credential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )

  #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("; __csrf=; ") == true)
}

@Test func songURLRequestUsesSelectedQualityLevel() throws {
  let levels: [(quality: PlaybackQuality, expected: String)] = [
    (.standard, "standard"),
    (.higher, "higher"),
    (.exhigh, "exhigh"),
    (.lossless, "lossless"),
    (.hires, "hires"),
  ]
  let header =
    #"{"osver":"15.5","os":"osx","appver":"0.1","buildver":"1722945678","#
    + #""__csrf":"csrf-test","channel":"github","#
    + #""requestId":"1722945678123_0042","MUSIC_U":"music-u-test"}"#

  #expect(PlaybackQuality.allCases == levels.map(\.quality))
  for (quality, expectedLevel) in levels {
    let request = try NeteaseSession.songURLRequest(
      songID: 347230,
      quality: quality,
      credential: playbackCredential,
      osVersion: "15.5",
      buildVersion: "1722945678",
      requestID: "1722945678123_0042"
    )
    let json =
      #"{"ids":"[347230]","level":"\#(expectedLevel)","encodeType":"flac","e_r":false,"header":\#(header)}"#
    let expectedParams = try NeteaseCrypto.eapi(
      path: "/api/song/enhance/player/url/v1",
      json: json
    )

    #expect(quality.rawValue == expectedLevel)
    #expect(
      String(decoding: request.httpBody!, as: UTF8.self) == "params=\(expectedParams)"
    )
  }
}

@Test func songURLClassifiesResolvedAndUnavailable() throws {
  let response = HTTPURLResponse(
    url: URL(string: "https://interfacepc.music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!
  let resolved = try NeteaseSession.classifySongURL(
    data: Data(
      #"{"code":200,"data":[{"id":347230,"url":"https://m10.music.126.net/audio.mp3","code":200,"level":"standard","type":"mp3","br":128000,"size":1000,"expi":1200,"fee":0,"freeTrialInfo":null}]}"#
        .utf8
    ),
    response: response,
    songID: 347230,
    requestedQuality: .standard
  )
  let unavailable = try NeteaseSession.classifySongURL(
    data: Data(
      #"{"code":200,"data":[{"id":347230,"url":null,"code":404,"fee":1}]}"#.utf8
    ),
    response: response,
    songID: 347230,
    requestedQuality: .standard
  )

  #expect(
    resolved
      == .resolved(
        ResolvedAudioAsset(
          songID: 347230,
          url: URL(string: "https://m10.music.126.net/audio.mp3")!,
          sourceScheme: "https",
          requestedQuality: .standard,
          actualQuality: "standard",
          format: "mp3",
          bitRate: 128000,
          byteCount: 1000,
          expiresIn: 1200,
          fee: 0,
          trial: false
        )
      )
  )
  #expect(unavailable == .unavailable(itemCode: 404, fee: 1))
}

@Test func songURLPreservesQualityFormatAndTrialMetadata() throws {
  let response = HTTPURLResponse(
    url: URL(string: "https://interfacepc.music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!
  let payload =
    #"{"code":200,"data":[{"id":347230,"#
    + #""url":"https://m10.music.126.net/audio.flac","code":200,"#
    + #""level":"lossless","type":null,"encodeType":"flac","br":999000,"#
    + #""size":45678901,"expi":1800,"fee":1,"#
    + #""freeTrialInfo":{"start":0,"end":30}}]}"#
  let resolution = try NeteaseSession.classifySongURL(
    data: Data(payload.utf8),
    response: response,
    songID: 347230,
    requestedQuality: .hires
  )

  guard case .resolved(let asset) = resolution else {
    Issue.record("Expected a resolved FLAC asset")
    return
  }
  #expect(asset.requestedQuality == .hires)
  #expect(asset.actualQuality == "lossless")
  #expect(asset.format == "flac")
  #expect(asset.bitRate == 999000)
  #expect(asset.byteCount == 45_678_901)
  #expect(asset.expiresIn == 1800)
  #expect(asset.fee == 1)
  #expect(asset.trial)
}

@Test func songURLRejectsInvalidAndNonHTTPSResponses() throws {
  let response = HTTPURLResponse(
    url: URL(string: "https://interfacepc.music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!

  #expect(throws: NeteasePlaybackError.invalidResponse) {
    try NeteaseSession.classifySongURL(
      data: Data(#"{"code":200,"data":[]}"#.utf8),
      response: response,
      songID: 347230,
      requestedQuality: .standard
    )
  }
  let httpResolved = try? NeteaseSession.classifySongURL(
    data: Data(
      #"{"code":200,"data":[{"id":347230,"url":"http://m10.music.126.net/audio.mp3","code":200}]}"#
        .utf8
    ),
    response: response,
    songID: 347230,
    requestedQuality: .standard
  )
  guard case .resolved(let httpAsset) = httpResolved else {
    Issue.record("Expected music.126.net HTTP URL to resolve")
    return
  }
  #expect(httpAsset.url.absoluteString == "http://m10.music.126.net/audio.mp3")
  #expect(httpAsset.sourceScheme == "http")
  #expect(throws: NeteasePlaybackError.nonHTTPSURL("music.163.com")) {
    try NeteaseSession.classifySongURL(
      data: Data(
        #"{"code":200,"data":[{"id":347230,"url":"http://music.163.com/audio.mp3","code":200}]}"#
          .utf8
      ),
      response: response,
      songID: 347230,
      requestedQuality: .standard
    )
  }
  #expect(throws: NeteasePlaybackError.unapprovedHost("cdn.example.com")) {
    try NeteaseSession.classifySongURL(
      data: Data(
        #"{"code":200,"data":[{"id":347230,"url":"https://cdn.example.com/audio.mp3","code":200}]}"#
          .utf8
      ),
      response: response,
      songID: 347230,
      requestedQuality: .standard
    )
  }
  #expect(throws: NeteasePlaybackError.unapprovedHost("music.126.net.attacker")) {
    try NeteaseSession.classifySongURL(
      data: Data(
        #"{"code":200,"data":[{"id":347230,"url":"https://music.126.net.attacker/audio.mp3","code":200}]}"#
          .utf8
      ),
      response: response,
      songID: 347230,
      requestedQuality: .standard
    )
  }
}

@Test func songURLAllowsRemainingWhitelistBranchesCaseInsensitively() throws {
  let response = HTTPURLResponse(
    url: URL(string: "https://interfacepc.music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!

  func resolve(_ url: String) throws -> SongURLResolution {
    try NeteaseSession.classifySongURL(
      data: Data(
        #"{"code":200,"data":[{"id":347230,"url":"\#(url)","code":200}]}"#.utf8
      ),
      response: response,
      songID: 347230,
      requestedQuality: .standard
    )
  }

  guard case .resolved(let https163) = try resolve("https://music.163.com/audio.mp3") else {
    Issue.record("Expected music.163.com HTTPS URL to resolve")
    return
  }
  #expect(https163.sourceScheme == "https")

  guard case .resolved(let bare126) = try resolve("http://music.126.net/audio.mp3") else {
    Issue.record("Expected bare music.126.net HTTP URL to resolve")
    return
  }
  #expect(bare126.sourceScheme == "http")

  guard
    case .resolved(let uppercase) = try resolve("HTTPS://M10.MUSIC.126.NET/audio.flac")
  else {
    Issue.record("Expected uppercase whitelisted URL to resolve")
    return
  }
  #expect(uppercase.sourceScheme == "https")

  #expect(throws: NeteasePlaybackError.nonHTTPSURL("music.163.com")) {
    try resolve("HTTP://MUSIC.163.COM/audio.mp3")
  }
}

@Test func songURLPreservesServiceStatus() throws {
  let failedHTTPResponse = HTTPURLResponse(
    url: URL(string: "https://interfacepc.music.163.com")!,
    statusCode: 503,
    httpVersion: nil,
    headerFields: nil
  )!

  #expect(throws: NeteaseServiceError(source: .http, statusCode: 503)) {
    try NeteaseSession.classifySongURL(
      data: Data(),
      response: failedHTTPResponse,
      songID: 347230,
      requestedQuality: .standard
    )
  }

  let successfulHTTPResponse = HTTPURLResponse(
    url: URL(string: "https://interfacepc.music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 301)) {
    try NeteaseSession.classifySongURL(
      data: Data(#"{"code":301}"#.utf8),
      response: successfulHTTPResponse,
      songID: 347230,
      requestedQuality: .standard
    )
  }
}

@Test func audioURLProbeUsesCredentialFreeRangeRequest() {
  let asset = ResolvedAudioAsset(
    songID: 347230,
    url: URL(string: "https://m704.music.126.net/audio.mp3")!,
    sourceScheme: "http",
    requestedQuality: .standard,
    actualQuality: "standard",
    format: "mp3",
    bitRate: 128000,
    byteCount: 1000,
    expiresIn: 1200,
    fee: 0,
    trial: false
  )
  let request = NeteaseSession.audioProbeRequest(asset: asset)

  #expect(request.httpMethod == "GET")
  #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-1")
  #expect(
    request.value(forHTTPHeaderField: "User-Agent")
      == "MacEasePhase0/0.1 (macOS 15)"
  )
  #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
  #expect(request.value(forHTTPHeaderField: "Referer") == nil)
}

@Test func audioURLProbeClassifiesRangeAndRedirectMetadata() {
  let rangeResponse = HTTPURLResponse(
    url: URL(string: "https://m704.music.126.net/audio.mp3")!,
    statusCode: 206,
    httpVersion: nil,
    headerFields: [
      "Content-Range": "bytes 0-1/1000",
      "Content-Type": "audio/mpeg",
    ]
  )!
  let redirectResponse = HTTPURLResponse(
    url: URL(string: "https://m704.music.126.net/audio.mp3")!,
    statusCode: 302,
    httpVersion: nil,
    headerFields: [
      "Location": "https://m8.music.126.net/redirected.mp3"
    ]
  )!

  #expect(
    NeteaseSession.classifyAudioProbe(response: rangeResponse)
      == AudioURLProbeResult(
        statusCode: 206,
        rangeResponse: true,
        contentType: "audio/mpeg",
        redirectScheme: nil,
        redirectHost: nil
      )
  )
  #expect(
    NeteaseSession.classifyAudioProbe(response: redirectResponse)
      == AudioURLProbeResult(
        statusCode: 302,
        rangeResponse: false,
        contentType: nil,
        redirectScheme: "https",
        redirectHost: "m8.music.126.net"
      )
  )
}

import Foundation
import Testing

@testable import NeteaseKit

private let likedCredential = NeteaseCredential(
  musicU: NeteaseCookie(name: .musicU, value: "music-u-test"),
  csrf: NeteaseCookie(name: .csrf, value: "csrf-test")
)

@Test func likeSongRequestSendsTheLockedWriteContract() throws {
  let liked = try NeteaseSession.likeSongRequest(
    songID: 33_894_312,
    liked: true,
    credential: likedCredential,
    secretKey: "0123456789abcdef"
  )
  // `like` is a JSON boolean and `time` a string, per the locked like.js.
  let likedParameters = try NeteaseCrypto.weapi(
    json:
      #"{"alg":"itembased","trackId":33894312,"like":true,"time":"3","csrf_token":"csrf-test"}"#,
    secretKey: "0123456789abcdef"
  )

  #expect(liked.url?.absoluteString == "https://music.163.com/weapi/radio/like")
  #expect(liked.httpMethod == "POST")
  // The write path adds MacEase's own honest platform identity (the read paths
  // are live-verified without it). No fabricated device or tracking ID.
  let cookie = liked.value(forHTTPHeaderField: "Cookie") ?? ""
  #expect(cookie.hasPrefix("MUSIC_U=music-u-test; __csrf=csrf-test; "))
  #expect(cookie.contains("os=osx"))
  #expect(cookie.contains("appver=0.1"))
  #expect(cookie.contains("channel=github"))
  #expect(!cookie.contains("deviceId"))
  #expect(!cookie.contains("NMTID"))
  #expect(!cookie.contains("_ntes_nuid"))
  #expect(
    String(decoding: liked.httpBody!, as: UTF8.self)
      == String(
        decoding: FormURLEncoder.encode([
          ("params", likedParameters.params),
          ("encSecKey", likedParameters.encSecKey),
        ]),
        as: UTF8.self
      )
  )

  let unliked = try NeteaseSession.likeSongRequest(
    songID: 33_894_312,
    liked: false,
    credential: likedCredential,
    secretKey: "0123456789abcdef"
  )
  let unlikedParameters = try NeteaseCrypto.weapi(
    json:
      #"{"alg":"itembased","trackId":33894312,"like":false,"time":"3","csrf_token":"csrf-test"}"#,
    secretKey: "0123456789abcdef"
  )
  #expect(
    String(decoding: unliked.httpBody!, as: UTF8.self)
      == String(
        decoding: FormURLEncoder.encode([
          ("params", unlikedParameters.params),
          ("encSecKey", unlikedParameters.encSecKey),
        ]),
        as: UTF8.self
      )
  )
  #expect(unliked.httpBody != liked.httpBody)
}

@Test func likeSongTreatsOnlyCode200AsSuccess() throws {
  let okResponse = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!
  let failedHTTPResponse = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 502,
    httpVersion: nil,
    headerFields: nil
  )!

  try NeteaseSession.classifyLikeSong(
    data: Data(#"{"code":200}"#.utf8),
    response: okResponse
  )
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 301)) {
    try NeteaseSession.classifyLikeSong(
      data: Data(#"{"code":301}"#.utf8),
      response: okResponse
    )
  }
  #expect(throws: NeteaseServiceError(source: .http, statusCode: 502)) {
    try NeteaseSession.classifyLikeSong(data: Data(), response: failedHTTPResponse)
  }
}

@Test func likedSongIDsRequestUsesExplicitUserAndSessionContext() throws {
  let request = try NeteaseSession.likedSongIDsRequest(
    userID: 987_654_321,
    credential: likedCredential,
    secretKey: "0123456789abcdef"
  )
  let parameters = try NeteaseCrypto.weapi(
    json: #"{"uid":"987654321","csrf_token":"csrf-test"}"#,
    secretKey: "0123456789abcdef"
  )

  #expect(request.url?.absoluteString == "https://music.163.com/weapi/song/like/get")
  #expect(request.httpMethod == "POST")
  #expect(request.httpShouldHandleCookies == false)
  #expect(request.value(forHTTPHeaderField: "Referer") == "https://music.163.com/")
  #expect(request.value(forHTTPHeaderField: "Cookie") == "MUSIC_U=music-u-test; __csrf=csrf-test")
  #expect(
    String(decoding: request.httpBody!, as: UTF8.self)
      == String(
        decoding: FormURLEncoder.encode([
          ("params", parameters.params),
          ("encSecKey", parameters.encSecKey),
        ]),
        as: UTF8.self
      )
  )
}

@Test func likedSongIDsDecodesTheUnorderedIDList() throws {
  let response = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!
  let ids = try NeteaseSession.classifyLikedSongIDs(
    data: Data(#"{"code":200,"checkPoint":1722945678000,"ids":[3,1,2]}"#.utf8),
    response: response
  )

  #expect(ids == [3, 1, 2])

  let empty = try NeteaseSession.classifyLikedSongIDs(
    data: Data(#"{"code":200,"ids":[]}"#.utf8),
    response: response
  )
  #expect(empty.isEmpty)
}

@Test func likedSongIDsRejectsAMissingIDList() throws {
  let response = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!

  #expect(throws: DecodingError.self) {
    try NeteaseSession.classifyLikedSongIDs(
      data: Data(#"{"code":200}"#.utf8),
      response: response
    )
  }
}

@Test func likedSongIDsDistinguishesServiceAndHTTPErrors() throws {
  let failedHTTPResponse = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 503,
    httpVersion: nil,
    headerFields: nil
  )!
  let successfulHTTPResponse = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!

  #expect(throws: NeteaseServiceError(source: .http, statusCode: 503)) {
    try NeteaseSession.classifyLikedSongIDs(
      data: Data(),
      response: failedHTTPResponse
    )
  }
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 301)) {
    try NeteaseSession.classifyLikedSongIDs(
      data: Data(#"{"code":301}"#.utf8),
      response: successfulHTTPResponse
    )
  }
}

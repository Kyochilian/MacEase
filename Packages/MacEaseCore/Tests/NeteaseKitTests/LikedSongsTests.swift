import Foundation
import Testing

@testable import NeteaseKit

private let likedCredential = NeteaseCredential(
  musicU: NeteaseCookie(name: .musicU, value: "music-u-test"),
  csrf: NeteaseCookie(name: .csrf, value: "csrf-test")
)

@Test func likedSongIDsRequestUsesExplicitUserAndSessionContext() throws {
  let request = try NeteaseSession.likedSongIDsRequest(
    userID: 987_654_321,
    credential: likedCredential,
    secretKey: "0123456789abcdef"
  )
  let parameters = NeteaseCrypto.weapi(
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

@Test func likedSongIDsRejectsAMissingIDList() {
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

@Test func likedSongIDsDistinguishesServiceAndHTTPErrors() {
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

import Foundation
import Testing

@testable import NeteaseKit

private let accountCredential = NeteaseCredential(
  musicU: NeteaseCookie(name: .musicU, value: "music-u-test"),
  csrf: NeteaseCookie(name: .csrf, value: "csrf-test")
)

@Test func accountStatusRequestUsesWhitelistedSessionContext() throws {
  let request = try NeteaseSession.accountStatusRequest(
    credential: accountCredential,
    secretKey: "0123456789abcdef"
  )
  let parameters = NeteaseCrypto.weapi(
    json: #"{"csrf_token":"csrf-test"}"#,
    secretKey: "0123456789abcdef"
  )

  #expect(request.url?.absoluteString == "https://music.163.com/weapi/w/nuser/account/get")
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

@Test func accountStatusClassifiesAuthenticationAndSignOut() throws {
  let response = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!

  let authenticated = try NeteaseSession.classifyAccountStatus(
    data: Data(#"{"code":200,"profile":{"userId":987654321}}"#.utf8),
    response: response
  )
  #expect(authenticated == .authenticated(NeteaseAccount(userID: 987_654_321)))

  let signedOut = try NeteaseSession.classifyAccountStatus(
    data: Data(#"{"code":200,"profile":null}"#.utf8),
    response: response
  )
  #expect(signedOut == .signedOut)
}

@Test func accountStatusRejectsMissingProfile() {
  let response = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!

  #expect(throws: DecodingError.self) {
    try NeteaseSession.classifyAccountStatus(
      data: Data(#"{"code":200}"#.utf8),
      response: response
    )
  }
}

@Test func accountStatusDistinguishesServiceAndHTTPRedirects() {
  let successfulHTTPResponse = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 301)) {
    try NeteaseSession.classifyAccountStatus(
      data: Data(#"{"code":301}"#.utf8),
      response: successfulHTTPResponse
    )
  }

  let redirectResponse = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 301,
    httpVersion: nil,
    headerFields: ["Location": "https://music.163.com/login"]
  )!
  #expect(throws: NeteaseServiceError(source: .http, statusCode: 301)) {
    try NeteaseSession.classifyAccountStatus(
      data: Data(),
      response: redirectResponse
    )
  }
}

@Test func userPlaylistsRequestUsesExplicitPageAndSessionContext() throws {
  let request = try NeteaseSession.userPlaylistsRequest(
    userID: 987_654_321,
    limit: 30,
    offset: 60,
    credential: accountCredential,
    secretKey: "0123456789abcdef"
  )
  let parameters = NeteaseCrypto.weapi(
    json:
      #"{"uid":"987654321","limit":30,"offset":60,"includeVideo":true,"csrf_token":"csrf-test"}"#,
    secretKey: "0123456789abcdef"
  )

  #expect(request.url?.absoluteString == "https://music.163.com/weapi/user/playlist")
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

@Test func userPlaylistsClassifiesOwnershipAndPagination() throws {
  let response = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!
  let page = try NeteaseSession.classifyUserPlaylists(
    data: Data(
      #"{"code":200,"more":true,"playlist":[{"id":1,"name":"Created","trackCount":12,"creator":{"userId":987654321}},{"id":2,"name":"Saved","trackCount":4,"creator":{"userId":123}}]}"#
        .utf8
    ),
    response: response,
    userID: 987_654_321
  )

  #expect(page.more)
  #expect(
    page.playlists == [
      UserPlaylist(id: 1, name: "Created", trackCount: 12, owned: true),
      UserPlaylist(id: 2, name: "Saved", trackCount: 4, owned: false),
    ]
  )
}

@Test func userPlaylistsDistinguishesServiceAndHTTPRedirects() {
  let successfulHTTPResponse = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 301)) {
    try NeteaseSession.classifyUserPlaylists(
      data: Data(#"{"code":301}"#.utf8),
      response: successfulHTTPResponse,
      userID: 987_654_321
    )
  }

  let redirectResponse = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 301,
    httpVersion: nil,
    headerFields: ["Location": "https://music.163.com/login"]
  )!
  #expect(throws: NeteaseServiceError(source: .http, statusCode: 301)) {
    try NeteaseSession.classifyUserPlaylists(
      data: Data(),
      response: redirectResponse,
      userID: 987_654_321
    )
  }
}

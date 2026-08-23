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
  let parameters = try NeteaseCrypto.weapi(
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

@Test func accountStatusRejectsMissingProfile() throws {
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

@Test func accountStatusDistinguishesServiceAndHTTPRedirects() throws {
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
  let parameters = try NeteaseCrypto.weapi(
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

@Test func userPlaylistsDistinguishesServiceAndHTTPRedirects() throws {
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

@Test func playlistDetailRequestUsesFixedEAPIContract() throws {
  let request = try NeteaseSession.playlistDetailRequest(
    playlistID: 24_381_616,
    credential: accountCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  let header =
    #"{"osver":"15.5","os":"osx","appver":"0.1","buildver":"1722945678","#
    + #""__csrf":"csrf-test","channel":"github","#
    + #""requestId":"1722945678123_0042","MUSIC_U":"music-u-test"}"#
  let json =
    #"{"id":24381616,"n":100000,"s":8,"e_r":false,"header":\#(header)}"#

  #expect(
    request.url?.absoluteString
      == "https://interfacepc.music.163.com/eapi/v6/playlist/detail"
  )
  #expect(request.httpMethod == "POST")
  #expect(request.httpShouldHandleCookies == false)
  #expect(request.value(forHTTPHeaderField: "Referer") == nil)
  #expect(
    request.value(forHTTPHeaderField: "Cookie")
      == "osver=15.5; os=osx; appver=0.1; buildver=1722945678; __csrf=csrf-test; channel=github; requestId=1722945678123_0042; MUSIC_U=music-u-test"
  )
  let params = try NeteaseCrypto.eapi(path: "/api/v6/playlist/detail", json: json)
  #expect(
    String(decoding: request.httpBody!, as: UTF8.self) == "params=\(params)"
  )
}

@Test func playlistDetailUsesTrackIDsAsCompleteOrder() throws {
  let response = HTTPURLResponse(
    url: URL(string: "https://interfacepc.music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!
  let detail = try NeteaseSession.classifyPlaylistDetail(
    data: Data(
      #"{"code":200,"playlist":{"id":24381616,"name":"Mix","trackIds":[{"id":3},{"id":1},{"id":2}],"tracks":[{"id":3}]}}"#
        .utf8
    ),
    response: response,
    playlistID: 24_381_616
  )

  #expect(
    detail
      == PlaylistDetail(
        id: 24_381_616,
        name: "Mix",
        trackIDs: [3, 1, 2]
      )
  )
}

@Test func songDetailsRequestUsesOneExplicitBoundedBatch() throws {
  let request = try NeteaseSession.songDetailsRequest(
    songIDs: [3, 1, 2],
    credential: accountCredential,
    secretKey: "0123456789abcdef"
  )
  let json =
    #"{"c":"[{\"id\":3},{\"id\":1},{\"id\":2}]","csrf_token":"csrf-test"}"#
  let parameters = try NeteaseCrypto.weapi(
    json: json,
    secretKey: "0123456789abcdef"
  )

  #expect(request.url?.absoluteString == "https://music.163.com/weapi/v3/song/detail")
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

  #expect(
    throws: NeteaseCatalogError.invalidSongDetailRequestCount(0)
  ) {
    try NeteaseSession.songDetailsRequest(
      songIDs: [],
      credential: accountCredential,
      secretKey: "0123456789abcdef"
    )
  }
  let maximumRequest = try NeteaseSession.songDetailsRequest(
    songIDs: Array(0..<NeteaseSession.songDetailRequestLimit).map(Int64.init),
    credential: accountCredential,
    secretKey: "0123456789abcdef"
  )
  #expect(maximumRequest.httpMethod == "POST")

  #expect(
    throws: NeteaseCatalogError.invalidSongDetailRequestCount(1001)
  ) {
    try NeteaseSession.songDetailsRequest(
      songIDs: Array(0...NeteaseSession.songDetailRequestLimit).map(Int64.init),
      credential: accountCredential,
      secretKey: "0123456789abcdef"
    )
  }
}

@Test func songDetailsDecodesMinimalTrackMetadata() throws {
  let response = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!
  let tracks = try NeteaseSession.classifySongDetails(
    data: Data(
      #"{"code":200,"songs":[{"id":1,"name":"First","ar":[]},{"id":3,"name":"Third","ar":[{"name":"A"},{"name":"B"}]},{"id":99,"name":"Extra","ar":[]}]}"#
        .utf8
    ),
    response: response,
    songIDs: [3, 1, 3]
  )

  #expect(
    tracks == [
      PlaylistTrack(id: 3, name: "Third", artists: ["A", "B"]),
      PlaylistTrack(id: 1, name: "First", artists: []),
      PlaylistTrack(id: 3, name: "Third", artists: ["A", "B"]),
    ]
  )
}

@Test func playlistDetailRejectsMismatchedIdentity() throws {
  let response = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!

  #expect(throws: NeteaseCatalogError.invalidResponse) {
    try NeteaseSession.classifyPlaylistDetail(
      data: Data(
        #"{"code":200,"playlist":{"id":2,"name":"Other","trackIds":[]}}"#.utf8
      ),
      response: response,
      playlistID: 1
    )
  }
}

@Test func songDetailsReturnsOnlyRequestedIDsPresentInTheResponse() throws {
  let response = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!
  let tracks = try NeteaseSession.classifySongDetails(
    data: Data(
      #"{"code":200,"songs":[{"id":3,"name":"Third","ar":[]}]}"#.utf8
    ),
    response: response,
    songIDs: [3, 1]
  )

  #expect(tracks == [PlaylistTrack(id: 3, name: "Third", artists: [])])
}

@Test func playlistAndSongDetailsDistinguishHTTPAndServiceErrors() throws {
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
    try NeteaseSession.classifyPlaylistDetail(
      data: Data(),
      response: failedHTTPResponse,
      playlistID: 1
    )
  }
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 301)) {
    try NeteaseSession.classifyPlaylistDetail(
      data: Data(#"{"code":301}"#.utf8),
      response: successfulHTTPResponse,
      playlistID: 1
    )
  }
  #expect(throws: NeteaseServiceError(source: .http, statusCode: 503)) {
    try NeteaseSession.classifySongDetails(
      data: Data(),
      response: failedHTTPResponse,
      songIDs: [1]
    )
  }
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 301)) {
    try NeteaseSession.classifySongDetails(
      data: Data(#"{"code":301}"#.utf8),
      response: successfulHTTPResponse,
      songIDs: [1]
    )
  }
}

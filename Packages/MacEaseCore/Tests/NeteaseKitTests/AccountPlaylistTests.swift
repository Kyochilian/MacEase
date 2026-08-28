import Foundation
import Testing

@testable import NeteaseKit

private let accountCredential = testCredential(musicU: "music-u-test", csrf: "csrf-test")

@Test func accountStatusRequestUsesApprovedSessionContext() throws {
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
    data: Data((
      #"{"code":200,"more":true,"playlist":[{"id":1,"name":"Created","trackCount":12,"creator":{"userId":987654321}},{"id":2,"name":"Saved","trackCount":4,"creator":{"userId":123}}]}"#
      ).utf8),
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
    data: Data((
      #"{"code":200,"playlist":{"id":24381616,"name":"Mix","trackIds":[{"id":3},{"id":1},{"id":2}],"tracks":[{"id":3}]}}"#
      ).utf8),
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

@Test func songDetailsDecodesTrackMetadata() throws {
  let response = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!
  let tracks = try NeteaseSession.classifySongDetails(
    data: Data((
      #"{"code":200,"songs":["#
        + #"{"id":1,"name":"First","ar":[]},"#
        + #"{"id":3,"name":"Third","dt":215000,"ar":[{"id":11,"name":"A"},{"id":12,"name":"B"}],"#
        + #""al":{"id":80,"name":"Album","picUrl":"https://p1.music.126.net/cover.jpg"}},"#
        + #"{"id":99,"name":"Extra","ar":[]}]}"#
      ).utf8),
    response: response,
    songIDs: [3, 1, 3]
  )

  let third = Track(
    id: 3,
    name: "Third",
    artists: [ArtistRef(id: 11, name: "A"), ArtistRef(id: 12, name: "B")],
    album: AlbumRef(
      id: 80,
      name: "Album",
      artworkURL: URL(string: "https://p1.music.126.net/cover.jpg")
    ),
    durationMilliseconds: 215000
  )
  #expect(tracks == [third, Track(id: 1, name: "First"), third])
  #expect(tracks[0].artistDisplayName == "A, B")
  #expect(tracks[0].durationSeconds == 215)
  #expect(tracks[1].artistDisplayName == nil)
}

/// NetEase writes "no artist page" both as a missing `id` and as `id: 0`. A
/// row that spells it either way must not become a link onto nothing.
@Test func songDetailsTreatsAbsentAndZeroIdentifiersAsNotNavigable() throws {
  let response = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!
  let tracks = try NeteaseSession.classifySongDetails(
    data: Data((
      #"{"code":200,"songs":[{"id":1,"name":"First","#
        + #""ar":[{"name":"Nameless"},{"id":0,"name":"Zero"}],"#
        + #""al":{"id":0,"name":"Single"}}]}"#
      ).utf8),
    response: response,
    songIDs: [1]
  )

  #expect(tracks[0].artists == [
    ArtistRef(id: nil, name: "Nameless"),
    ArtistRef(id: nil, name: "Zero"),
  ])
  #expect(tracks[0].album == AlbumRef(id: nil, name: "Single", artworkURL: nil))
}

/// Artwork is an address the server chose, so it is validated like any other.
/// A host MacEase does not serve from is dropped rather than failing the
/// playlist that carried it.
@Test func songDetailsRefusesArtworkFromAnUnapprovedHost() throws {
  let response = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
  )!
  let tracks = try NeteaseSession.classifySongDetails(
    data: Data((
      #"{"code":200,"songs":[{"id":1,"name":"First","ar":[],"#
        + #""al":{"id":5,"name":"A","picUrl":"https://evil.example.com/cover.jpg"}},"#
        + #"{"id":2,"name":"Second","ar":[],"#
        + #""al":{"id":6,"name":"B","picUrl":"http://p2.music.126.net/cover.jpg"}}]}"#
      ).utf8),
    response: response,
    songIDs: [1, 2]
  )

  #expect(tracks[0].artworkURL == nil)
  // Served over TLS on the same host, so the legacy http spelling is upgraded
  // rather than refused.
  #expect(
    tracks[1].artworkURL == URL(string: "https://p2.music.126.net/cover.jpg")
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

  #expect(tracks == [Track(id: 3, name: "Third", artists: [])])
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

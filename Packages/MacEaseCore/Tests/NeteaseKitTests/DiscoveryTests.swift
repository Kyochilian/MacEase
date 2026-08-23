import Foundation
import Testing

@testable import NeteaseKit

private let discoveryCredential = NeteaseCredential(
  musicU: NeteaseCookie(name: .musicU, value: "music-u-test"),
  csrf: NeteaseCookie(name: .csrf, value: "csrf-test")
)

private let okResponse = HTTPURLResponse(
  url: URL(string: "https://music.163.com")!,
  statusCode: 200,
  httpVersion: nil,
  headerFields: nil
)!

private func expectWeAPIBody(
  _ request: URLRequest,
  json: String,
  secretKey: String = "0123456789abcdef"
) throws {
  let parameters = try NeteaseCrypto.weapi(json: json, secretKey: secretKey)
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

@Test func playRecordsRequestUsesExplicitScopeAndSessionContext() throws {
  let allTime = try NeteaseSession.playRecordsRequest(
    userID: 987_654_321,
    scope: .allTime,
    credential: discoveryCredential,
    secretKey: "0123456789abcdef"
  )

  #expect(allTime.url?.absoluteString == "https://music.163.com/weapi/v1/play/record")
  #expect(allTime.httpMethod == "POST")
  #expect(allTime.value(forHTTPHeaderField: "Cookie") == "MUSIC_U=music-u-test; __csrf=csrf-test")
  try expectWeAPIBody(
    allTime,
    json: #"{"uid":"987654321","type":0,"csrf_token":"csrf-test"}"#
  )

  let lastWeek = try NeteaseSession.playRecordsRequest(
    userID: 987_654_321,
    scope: .lastWeek,
    credential: discoveryCredential,
    secretKey: "0123456789abcdef"
  )
  try expectWeAPIBody(
    lastWeek,
    json: #"{"uid":"987654321","type":1,"csrf_token":"csrf-test"}"#
  )
}

@Test func playRecordsClassifiesOnlyTheRequestedScope() throws {
  let allData = Data(
    #"{"code":200,"allData":[{"playCount":12,"score":100,"song":{"id":7,"name":"Seven","ar":[{"name":"A"}]}}]}"#
      .utf8
  )

  let entries = try NeteaseSession.classifyPlayRecords(
    data: allData,
    response: okResponse,
    scope: .allTime
  )
  #expect(
    entries == [
      PlayRecordEntry(
        track: PlaylistTrack(id: 7, name: "Seven", artists: ["A"]),
        playCount: 12
      )
    ]
  )

  #expect(throws: NeteaseCatalogError.invalidResponse) {
    try NeteaseSession.classifyPlayRecords(
      data: allData,
      response: okResponse,
      scope: .lastWeek
    )
  }
}

@Test func dailyRecommendedSongsRequestSendsOnlySessionContext() throws {
  let request = try NeteaseSession.dailyRecommendedSongsRequest(
    credential: discoveryCredential,
    secretKey: "0123456789abcdef"
  )

  #expect(
    request.url?.absoluteString
      == "https://music.163.com/weapi/v3/discovery/recommend/songs"
  )
  try expectWeAPIBody(request, json: #"{"csrf_token":"csrf-test"}"#)
}

@Test func dailyRecommendedSongsDecodeDailySongs() throws {
  let tracks = try NeteaseSession.classifyDailyRecommendedSongs(
    data: Data(
      #"{"code":200,"data":{"dailySongs":[{"id":1,"name":"First","ar":[{"name":"A"},{"name":"B"}]}]}}"#
        .utf8
    ),
    response: okResponse
  )

  #expect(tracks == [PlaylistTrack(id: 1, name: "First", artists: ["A", "B"])])
}

@Test func dailyRecommendedPlaylistsRequestAndDecode() throws {
  let request = try NeteaseSession.dailyRecommendedPlaylistsRequest(
    credential: discoveryCredential,
    secretKey: "0123456789abcdef"
  )

  #expect(
    request.url?.absoluteString
      == "https://music.163.com/weapi/v1/discovery/recommend/resource"
  )
  try expectWeAPIBody(request, json: #"{"csrf_token":"csrf-test"}"#)

  let playlists = try NeteaseSession.classifyDailyRecommendedPlaylists(
    data: Data(#"{"code":200,"recommend":[{"id":11,"name":"Morning"}]}"#.utf8),
    response: okResponse
  )
  #expect(playlists == [DiscoveredPlaylist(id: 11, name: "Morning")])
}

@Test func personalizedPlaylistsRequestUsesTheFixedPageContract() throws {
  let request = try NeteaseSession.personalizedPlaylistsRequest(
    credential: discoveryCredential,
    secretKey: "0123456789abcdef"
  )

  #expect(
    request.url?.absoluteString == "https://music.163.com/weapi/personalized/playlist"
  )
  try expectWeAPIBody(
    request,
    json: #"{"limit":30,"total":true,"n":1000,"csrf_token":"csrf-test"}"#
  )

  let playlists = try NeteaseSession.classifyPersonalizedPlaylists(
    data: Data(#"{"code":200,"result":[{"id":21,"name":"Picked"}]}"#.utf8),
    response: okResponse
  )
  #expect(playlists == [DiscoveredPlaylist(id: 21, name: "Picked")])
}

@Test func toplistsRequestUsesTheFixedEAPIContract() throws {
  let request = try NeteaseSession.toplistsRequest(
    credential: discoveryCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  let header =
    #"{"osver":"15.5","os":"osx","appver":"0.1","buildver":"1722945678","#
    + #""__csrf":"csrf-test","channel":"github","#
    + #""requestId":"1722945678123_0042","MUSIC_U":"music-u-test"}"#
  let json = #"{"e_r":false,"header":\#(header)}"#

  #expect(
    request.url?.absoluteString == "https://interfacepc.music.163.com/eapi/toplist"
  )
  #expect(request.httpMethod == "POST")
  #expect(
    request.value(forHTTPHeaderField: "Cookie")
      == "osver=15.5; os=osx; appver=0.1; buildver=1722945678; __csrf=csrf-test; channel=github; requestId=1722945678123_0042; MUSIC_U=music-u-test"
  )
  let params = try NeteaseCrypto.eapi(path: "/api/toplist", json: json)
  #expect(
    String(decoding: request.httpBody!, as: UTF8.self) == "params=\(params)"
  )
}

@Test func toplistsDecodeTheSummaryList() throws {
  let toplists = try NeteaseSession.classifyToplists(
    data: Data(
      #"{"code":200,"list":[{"id":3778678,"name":"热歌榜"},{"id":19723756,"name":"飙升榜"}]}"#
        .utf8
    ),
    response: okResponse
  )

  #expect(
    toplists == [
      DiscoveredPlaylist(id: 3_778_678, name: "热歌榜"),
      DiscoveredPlaylist(id: 19_723_756, name: "飙升榜"),
    ]
  )
}

@Test func similarSongsRequestUsesTheLockedLegacyContract() throws {
  let request = try NeteaseSession.similarSongsRequest(
    songID: 347_230,
    credential: discoveryCredential,
    secretKey: "0123456789abcdef"
  )

  // `/weapi/` + uri.substr(5) strips the leading `/api/`, as for every other
  // weapi endpoint here.
  #expect(
    request.url?.absoluteString
      == "https://music.163.com/weapi/v1/discovery/simiSong"
  )
  #expect(request.httpMethod == "POST")
  #expect(
    request.value(forHTTPHeaderField: "Cookie") == "MUSIC_U=music-u-test; __csrf=csrf-test"
  )
  try expectWeAPIBody(
    request,
    json: #"{"songid":347230,"limit":50,"offset":0,"csrf_token":"csrf-test"}"#
  )
}

@Test func similarSongsDecodeTheLegacyArtistsField() throws {
  // This legacy endpoint returns `artists`, unlike the `ar` used elsewhere.
  let tracks = try NeteaseSession.classifySimilarSongs(
    data: Data(
      #"{"code":200,"songs":[{"id":33894312,"name":"Later","artists":[{"name":"A"},{"name":"B"}],"album":{"fee":0}}]}"#
        .utf8
    ),
    response: okResponse
  )

  #expect(tracks == [PlaylistTrack(id: 33_894_312, name: "Later", artists: ["A", "B"])])
}

@Test func similarSongsRejectAnArResponseShape() throws {
  // Guards the `artists` vs `ar` distinction: an `ar`-shaped payload must
  // fail loudly rather than silently decode to empty artists.
  #expect(throws: (any Error).self) {
    try NeteaseSession.classifySimilarSongs(
      data: Data(#"{"code":200,"songs":[{"id":1,"name":"X","ar":[{"name":"A"}]}]}"#.utf8),
      response: okResponse
    )
  }
}

@Test func searchSongsUsesTheCloudsearchContract() throws {
  let request = try NeteaseSession.searchSongsRequest(
    keywords: "周杰伦",
    credential: discoveryCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  let header =
    #"{"osver":"15.5","os":"osx","appver":"0.1","buildver":"1722945678","#
    + #""__csrf":"csrf-test","channel":"github","#
    + #""requestId":"1722945678123_0042","MUSIC_U":"music-u-test"}"#
  let json =
    #"{"s":"周杰伦","type":1,"limit":30,"offset":0,"total":true,"#
    + #""e_r":false,"header":\#(header)}"#

  #expect(
    request.url?.absoluteString
      == "https://interfacepc.music.163.com/eapi/cloudsearch/pc"
  )
  let params = try NeteaseCrypto.eapi(path: "/api/cloudsearch/pc", json: json)
  #expect(
    String(decoding: request.httpBody!, as: UTF8.self) == "params=\(params)"
  )
}

@Test func searchSongsDecodeTheModernArShape() throws {
  // Cloudsearch returns `ar`, unlike the legacy simiSong endpoint's `artists`.
  let tracks = try NeteaseSession.classifySearchSongs(
    data: Data(
      #"{"code":200,"result":{"songCount":1,"songs":[{"id":509781655,"name":"想你就写信 (Live)","dt":238698,"ar":[{"id":6452,"name":"周杰伦"},{"id":12010120,"name":"李硕"}],"al":{"id":36412633,"name":"专辑"}}]}}"#
        .utf8
    ),
    response: okResponse
  )

  #expect(
    tracks == [
      PlaylistTrack(id: 509_781_655, name: "想你就写信 (Live)", artists: ["周杰伦", "李硕"])
    ]
  )
}

@Test func searchSongsRejectALegacyArtistsShape() throws {
  #expect(throws: (any Error).self) {
    try NeteaseSession.classifySearchSongs(
      data: Data(
        #"{"code":200,"result":{"songs":[{"id":1,"name":"X","artists":[{"name":"A"}]}]}}"#
          .utf8
      ),
      response: okResponse
    )
  }
}

@Test func discoveryClassifiersDistinguishServiceAndHTTPErrors() throws {
  let failedHTTPResponse = HTTPURLResponse(
    url: URL(string: "https://music.163.com")!,
    statusCode: 503,
    httpVersion: nil,
    headerFields: nil
  )!

  #expect(throws: NeteaseServiceError(source: .http, statusCode: 503)) {
    try NeteaseSession.classifyPlayRecords(
      data: Data(),
      response: failedHTTPResponse,
      scope: .allTime
    )
  }
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 301)) {
    try NeteaseSession.classifyDailyRecommendedSongs(
      data: Data(#"{"code":301}"#.utf8),
      response: okResponse
    )
  }
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 301)) {
    try NeteaseSession.classifyToplists(
      data: Data(#"{"code":301}"#.utf8),
      response: okResponse
    )
  }
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 301)) {
    try NeteaseSession.classifySimilarSongs(
      data: Data(#"{"code":301}"#.utf8),
      response: okResponse
    )
  }
}

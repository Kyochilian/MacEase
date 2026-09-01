import Foundation
import Testing

@testable import NeteaseKit

/// Contract tests for the browsing, radio, search and detail endpoints.
///
/// Each one pins the path, the crypto and the fields against
/// `api-enhanced@a7e8d48`, and each classifier is exercised on a normal
/// response and on the ways NetEase actually degrades one: a missing
/// container, a null row, an unexpected type. No test here touches the
/// network, and no fixture carries a real cookie, token or signed URL.
private let catalogCredential = testCredential(musicU: "music-u-test", csrf: "csrf-test")

private let okResponse = HTTPURLResponse(
  url: URL(string: "https://music.163.com")!,
  statusCode: 200,
  httpVersion: nil,
  headerFields: nil
)!

private let serverErrorResponse = HTTPURLResponse(
  url: URL(string: "https://music.163.com")!,
  statusCode: 503,
  httpVersion: nil,
  headerFields: nil
)!

private let eapiHeader =
  #"{"osver":"15.5","os":"osx","appver":"0.1","buildver":"1722945678","#
  + #""__csrf":"csrf-test","channel":"github","#
  + #""requestId":"1722945678123_0042","MUSIC_U":"music-u-test"}"#

private func expectWeAPI(
  _ request: URLRequest,
  url: String,
  json: String,
  secretKey: String = "0123456789abcdef"
) throws {
  #expect(request.url?.absoluteString == url)
  #expect(request.httpMethod == "POST")
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

private func expectEAPI(
  _ request: URLRequest,
  path: String,
  json: String
) throws {
  #expect(
    request.url?.absoluteString
      == "https://interfacepc.music.163.com/eapi/" + path.dropFirst("/api/".count)
  )
  #expect(request.httpMethod == "POST")
  let params = try NeteaseCrypto.eapi(path: path, json: json)
  #expect(String(decoding: request.httpBody!, as: UTF8.self) == "params=\(params)")
}

// MARK: - Browsing playlists

@Test func categoryPlaylistsUsesTheDocumentedBrowseContract() throws {
  let request = try NeteaseSession.categoryPlaylistsRequest(
    category: "华语",
    order: .new,
    limit: 50,
    offset: 100,
    credential: catalogCredential,
    secretKey: "0123456789abcdef"
  )
  try expectWeAPI(
    request,
    url: "https://music.163.com/weapi/playlist/list",
    json:
      #"{"cat":"华语","order":"new","limit":50,"offset":100,"total":true,"#
      + #""csrf_token":"csrf-test"}"#
  )
}

@Test func categoryPlaylistsDecodeCoversFromEitherSpelling() throws {
  let page = try NeteaseSession.classifyCategoryPlaylists(
    data: Data((
      #"{"code":200,"more":true,"playlists":["#
        + #"{"id":1,"name":"A","coverImgUrl":"https://p1.music.126.net/a.jpg"},"#
        + #"{"id":2,"name":"B","picUrl":"http://p2.music.126.net/b.jpg"},"#
        + #"{"id":3,"name":"C"}]}"#
      ).utf8),
    response: okResponse,
    limit: 50
  )

  #expect(page.more)
  #expect(page.items.map(\.id) == [1, 2, 3])
  #expect(
    page.items[0].artworkURL == URL(string: "https://p1.music.126.net/a.jpg")
  )
  // An http cover on an approved host is upgraded rather than dropped.
  #expect(
    page.items[1].artworkURL == URL(string: "https://p2.music.126.net/b.jpg")
  )
  #expect(page.items[2].artworkURL == nil)
}

/// `more` is absent from some responses. A full page is then taken as evidence
/// another may exist, which costs at most one empty request; under-reporting
/// would strand rows.
@Test func categoryPlaylistsInferMoreFromAFullPage() throws {
  let full = try NeteaseSession.classifyCategoryPlaylists(
    data: Data(#"{"code":200,"playlists":[{"id":1,"name":"A"},{"id":2,"name":"B"}]}"#.utf8),
    response: okResponse,
    limit: 2
  )
  #expect(full.more)

  let short = try NeteaseSession.classifyCategoryPlaylists(
    data: Data(#"{"code":200,"playlists":[{"id":1,"name":"A"}]}"#.utf8),
    response: okResponse,
    limit: 2
  )
  #expect(short.more == false)
}

@Test func highQualityPlaylistsSendLasttimeAsTheCursor() throws {
  let request = try NeteaseSession.highQualityPlaylistsRequest(
    category: "全部",
    limit: 50,
    before: 1_722_945_678_000,
    credential: catalogCredential,
    secretKey: "0123456789abcdef"
  )
  try expectWeAPI(
    request,
    url: "https://music.163.com/weapi/playlist/highquality/list",
    json:
      #"{"cat":"全部","limit":50,"lasttime":1722945678000,"total":true,"#
      + #""csrf_token":"csrf-test"}"#
  )
}

/// The cursor comes from the service. Without a new one, paging would re-read
/// the page it just read, so it stops instead.
@Test func highQualityPagingStopsWhenTheCursorCannotMove() throws {
  let advanced = try NeteaseSession.classifyHighQualityPlaylists(
    data: Data((
      #"{"code":200,"more":true,"lasttime":90,"playlists":[{"id":1,"name":"A"}]}"#
      ).utf8),
    response: okResponse,
    limit: 1,
    before: 100
  )
  #expect(advanced.more)
  #expect(advanced.before == 90)

  let missingCursor = try NeteaseSession.classifyHighQualityPlaylists(
    data: Data(#"{"code":200,"more":true,"playlists":[{"id":1,"name":"A"}]}"#.utf8),
    response: okResponse,
    limit: 1,
    before: 100
  )
  #expect(missingCursor.more == false)
  #expect(missingCursor.before == 100)

  let repeatedCursor = try NeteaseSession.classifyHighQualityPlaylists(
    data: Data((
      #"{"code":200,"more":true,"lasttime":100,"playlists":[{"id":1,"name":"A"}]}"#
      ).utf8),
    response: okResponse,
    limit: 1,
    before: 100
  )
  #expect(repeatedCursor.more == false)
}

/// The radar family has no endpoint of its own: it is the ordinary detail
/// endpoint asked for the smallest answer it gives.
@Test func playlistBriefAsksTheDetailEndpointForTheHeaderOnly() throws {
  let request = try NeteaseSession.playlistBriefRequest(
    playlistID: 3_136_952_023,
    credential: catalogCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  try expectEAPI(
    request,
    path: "/api/v6/playlist/detail",
    json:
      #"{"id":3136952023,"n":1,"s":0,"e_r":false,"header":\#(eapiHeader)}"#
  )
}

@Test func playlistBriefRefusesAnAnswerAboutAnotherPlaylist() throws {
  let brief = try NeteaseSession.classifyPlaylistBrief(
    data: Data((
      #"{"code":200,"playlist":{"id":3136952023,"name":"今天从《X》听起|私人雷达","#
        + #""coverImgUrl":"https://p1.music.126.net/r.jpg"}}"#
      ).utf8),
    response: okResponse,
    playlistID: 3_136_952_023
  )
  #expect(brief.name == "今天从《X》听起|私人雷达")
  #expect(brief.artworkURL == URL(string: "https://p1.music.126.net/r.jpg"))

  #expect(throws: NeteaseCatalogError.invalidResponse) {
    try NeteaseSession.classifyPlaylistBrief(
      data: Data(#"{"code":200,"playlist":{"id":7,"name":"Other"}}"#.utf8),
      response: okResponse,
      playlistID: 3_136_952_023
    )
  }
}

@Test func recommendedNewSongsUseTheFixedRecommendContract() throws {
  let request = try NeteaseSession.recommendedNewSongsRequest(
    limit: 20,
    credential: catalogCredential,
    secretKey: "0123456789abcdef"
  )
  try expectWeAPI(
    request,
    url: "https://music.163.com/weapi/personalized/newsong",
    json:
      #"{"type":"recommend","limit":20,"areaId":0,"csrf_token":"csrf-test"}"#
  )
}

/// A recommendation row without a `song` names nothing playable, so it is
/// dropped rather than turned into a track the list cannot start.
@Test func recommendedNewSongsDropRowsWithNoSong() throws {
  let tracks = try NeteaseSession.classifyRecommendedNewSongs(
    data: Data((
      #"{"code":200,"result":[{"id":1,"name":"A","song":{"id":11,"name":"One","#
        + #""ar":[{"id":5,"name":"S"}]}},{"id":2,"name":"B"},"#
        + #"{"id":3,"name":"C","song":null}]}"#
      ).utf8),
    response: okResponse
  )
  #expect(tracks == [Track(id: 11, name: "One", artists: [ArtistRef(id: 5, name: "S")])])
}

// MARK: - Personal FM and heartbeat mode

@Test func personalFMSendsOnlySessionContext() throws {
  let request = try NeteaseSession.personalFMRequest(
    credential: catalogCredential,
    secretKey: "0123456789abcdef"
  )
  try expectWeAPI(
    request,
    url: "https://music.163.com/weapi/v1/radio/get",
    json: #"{"csrf_token":"csrf-test"}"#
  )
}

@Test func personalFMDecodesTheDataArray() throws {
  let tracks = try NeteaseSession.classifyPersonalFM(
    data: Data((
      #"{"code":200,"data":[{"id":1,"name":"One","album":{"id":9,"name":"Al"},"#
        + #""artists":[{"id":3,"name":"A"}],"duration":1000}]}"#
      ).utf8),
    response: okResponse
  )
  #expect(
    tracks == [
      Track(
        id: 1,
        name: "One",
        artists: [ArtistRef(id: 3, name: "A")],
        album: AlbumRef(id: 9, name: "Al", artworkURL: nil),
        durationMilliseconds: 1000
      )
    ]
  )
}

/// The rejection carries the fixed `alg` and `time` the authority sends, and
/// it goes out with the platform cookies every other write uses.
@Test func fmTrashUsesTheFixedRejectionContract() throws {
  let request = try NeteaseSession.fmTrashRequest(
    songID: 347_230,
    credential: catalogCredential,
    secretKey: "0123456789abcdef"
  )
  try expectWeAPI(
    request,
    url: "https://music.163.com/weapi/radio/trash/add",
    json: #"{"songId":347230,"alg":"RT","time":25,"csrf_token":"csrf-test"}"#
  )
  #expect(
    request.value(forHTTPHeaderField: "Cookie")?
      .contains("MUSIC_U=music-u-test") == true
  )
  #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("os=osx") == true)
}

@Test func heartbeatQueueSendsBothIdsAndTheFixedType() throws {
  let request = try NeteaseSession.heartbeatQueueRequest(
    songID: 33_894_312,
    playlistID: 24_381_616,
    startMusicID: 33_894_312,
    credential: catalogCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  try expectEAPI(
    request,
    path: "/api/playmode/intelligence/list",
    json:
      #"{"songId":33894312,"type":"fromPlayOne","playlistId":24381616,"#
      + #""startMusicId":33894312,"count":1,"e_r":false,"header":\#(eapiHeader)}"#
  )
}

@Test func heartbeatQueueKeepsOnlyEntriesThatNameASong() throws {
  let tracks = try NeteaseSession.classifyHeartbeatQueue(
    data: Data((
      #"{"code":200,"data":[{"songInfo":{"id":1,"name":"One"}},{"id":2},"#
        + #"{"songInfo":null}]}"#
      ).utf8),
    response: okResponse
  )
  #expect(tracks == [Track(id: 1, name: "One")])
}

// MARK: - Similar artists

@Test func similarArtistsUseTheLowerCaseArtistidField() throws {
  let request = try NeteaseSession.similarArtistsRequest(
    artistID: 6452,
    credential: catalogCredential,
    secretKey: "0123456789abcdef"
  )
  try expectWeAPI(
    request,
    url: "https://music.163.com/weapi/discovery/simiArtist",
    json: #"{"artistid":6452,"csrf_token":"csrf-test"}"#
  )
}

@Test func similarArtistsFallBackToTheSquarePhoto() throws {
  let artists = try NeteaseSession.classifySimilarArtists(
    data: Data((
      #"{"code":200,"artists":[{"id":1,"name":"A","albumSize":3,"musicSize":30,"#
        + #""img1v1Url":"https://p1.music.126.net/sq.jpg"}]}"#
      ).utf8),
    response: okResponse
  )
  #expect(
    artists == [
      Artist(
        id: 1,
        name: "A",
        artworkURL: URL(string: "https://p1.music.126.net/sq.jpg"),
        albumCount: 3,
        songCount: 30
      )
    ]
  )
}

// MARK: - Search

@Test func searchSendsTheRequestedTypeAndOffset() throws {
  for (scope, raw) in [
    (SearchScope.songs, 1), (.albums, 10), (.artists, 100), (.playlists, 1000),
  ] {
    let request = try NeteaseSession.searchRequest(
      keywords: "canary",
      scope: scope,
      limit: 30,
      offset: 60,
      credential: catalogCredential,
      osVersion: "15.5",
      buildVersion: "1722945678",
      requestID: "1722945678123_0042"
    )
    try expectEAPI(
      request,
      path: "/api/cloudsearch/pc",
      json:
        #"{"s":"canary","type":\#(raw),"limit":30,"offset":60,"total":true,"#
        + #""e_r":false,"header":\#(eapiHeader)}"#
    )
  }
}

/// Keywords go into a hand-built body, so anything the user types has to be
/// escaped rather than able to close the string it sits in.
@Test func searchEscapesKeywordsThatContainJSONSyntax() throws {
  let request = try NeteaseSession.searchRequest(
    keywords: #"a" ,"type":100,"x":"b"#,
    scope: .songs,
    limit: 30,
    offset: 0,
    credential: catalogCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  try expectEAPI(
    request,
    path: "/api/cloudsearch/pc",
    json:
      #"{"s":"a\" ,\"type\":100,\"x\":\"b","type":1,"limit":30,"offset":0,"#
      + #""total":true,"e_r":false,"header":\#(eapiHeader)}"#
  )
}

@Test func searchReadsOnlyTheContainerForTheRequestedScope() throws {
  let body = Data((
    #"{"code":200,"result":{"songCount":9,"songs":[{"id":1,"name":"S"}],"#
      + #""albumCount":8,"albums":[{"id":2,"name":"Al","size":3,"#
      + #""artist":{"id":7,"name":"Ar"}}],"#
      + #""artistCount":7,"artists":[{"id":3,"name":"Ar","albumSize":1,"musicSize":2}],"#
      + #""playlistCount":6,"playlists":[{"id":4,"name":"Pl"}]}}"#
    ).utf8)

  let songs = try NeteaseSession.classifySearch(
    data: body, response: okResponse, scope: .songs
  )
  #expect(songs.items == .songs([Track(id: 1, name: "S")]))
  #expect(songs.totalCount == 9)

  let albums = try NeteaseSession.classifySearch(
    data: body, response: okResponse, scope: .albums
  )
  #expect(
    albums.items
      == .albums([
        Album(
          id: 2,
          name: "Al",
          artists: [ArtistRef(id: 7, name: "Ar")],
          artworkURL: nil,
          trackCount: 3
        )
      ])
  )
  #expect(albums.totalCount == 8)

  let artists = try NeteaseSession.classifySearch(
    data: body, response: okResponse, scope: .artists
  )
  #expect(
    artists.items
      == .artists([
        Artist(id: 3, name: "Ar", artworkURL: nil, albumCount: 1, songCount: 2)
      ])
  )
  #expect(artists.totalCount == 7)

  let playlists = try NeteaseSession.classifySearch(
    data: body, response: okResponse, scope: .playlists
  )
  #expect(playlists.items == .playlists([DiscoveredPlaylist(id: 4, name: "Pl")]))
  #expect(playlists.totalCount == 6)
}

/// A search that matched nothing answers 200 with no `result`, which is an
/// empty page for the scope that was asked for, not a decode failure.
@Test func searchWithNoResultContainerIsAnEmptyPage() throws {
  for scope in SearchScope.allCases {
    let page = try NeteaseSession.classifySearch(
      data: Data(#"{"code":200}"#.utf8),
      response: okResponse,
      scope: scope
    )
    #expect(page.items == .empty(scope))
    #expect(page.items.scope == scope)
    #expect(page.totalCount == nil)
  }
}

@Test func searchSuggestionsFlattenTheGroupsAndDropRepeatedText() throws {
  let request = try NeteaseSession.searchSuggestionsRequest(
    keywords: "canary",
    credential: catalogCredential,
    secretKey: "0123456789abcdef"
  )
  try expectWeAPI(
    request,
    url: "https://music.163.com/weapi/search/suggest/web",
    json: #"{"s":"canary","csrf_token":"csrf-test"}"#
  )

  let suggestions = try NeteaseSession.classifySearchSuggestions(
    data: Data((
      #"{"code":200,"result":{"songs":[{"id":1,"name":"Canary","#
        + #""ar":[{"id":5,"name":"Bird"}]},{"id":2,"name":"  "}],"#
        + #""artists":[{"id":3,"name":"Canary"}],"#
        + #""albums":[{"id":4,"name":"Nest","artist":{"id":5,"name":"Bird"}}],"#
        + #""playlists":[{"id":6,"name":"Nest"}]}}"#
      ).utf8),
    response: okResponse
  )

  #expect(suggestions.map(\.keyword) == ["Canary", "Nest"])
  #expect(suggestions.map(\.id) == ["song-1", "album-4"])
  #expect(suggestions.map(\.detail) == ["Bird", "Bird"])
}

@Test func searchSuggestionsWithNoResultAreEmpty() throws {
  #expect(
    try NeteaseSession.classifySearchSuggestions(
      data: Data(#"{"code":200}"#.utf8),
      response: okResponse
    ).isEmpty
  )
}

@Test func defaultSearchKeywordTreatsBlankAsNoSuggestion() throws {
  let request = try NeteaseSession.defaultSearchKeywordRequest(
    credential: catalogCredential,
    osVersion: "15.5",
    buildVersion: "1722945678",
    requestID: "1722945678123_0042"
  )
  try expectEAPI(
    request,
    path: "/api/search/defaultkeyword/get",
    json: #"{"e_r":false,"header":\#(eapiHeader)}"#
  )

  #expect(
    try NeteaseSession.classifyDefaultSearchKeyword(
      data: Data(#"{"code":200,"data":{"showKeyword":"周杰伦 稻香"}}"#.utf8),
      response: okResponse
    ) == "周杰伦 稻香"
  )
  #expect(
    try NeteaseSession.classifyDefaultSearchKeyword(
      data: Data(#"{"code":200,"data":{"showKeyword":"   "}}"#.utf8),
      response: okResponse
    ) == nil
  )
  #expect(
    try NeteaseSession.classifyDefaultSearchKeyword(
      data: Data(#"{"code":200}"#.utf8),
      response: okResponse
    ) == nil
  )
}

// MARK: - Albums

@Test func albumDetailPutsTheIdInThePath() throws {
  let request = try NeteaseSession.albumDetailRequest(
    albumID: 32311,
    credential: catalogCredential,
    secretKey: "0123456789abcdef"
  )
  try expectWeAPI(
    request,
    url: "https://music.163.com/weapi/v1/album/32311",
    json: #"{"csrf_token":"csrf-test"}"#
  )
}

@Test func albumDetailFallsBackToTheTrackListForItsCount() throws {
  let detail = try NeteaseSession.classifyAlbumDetail(
    data: Data((
      #"{"code":200,"album":{"id":32311,"name":"Al","#
        + #""picUrl":"https://p1.music.126.net/al.jpg","#
        + #""artist":{"id":7,"name":"Ar"}},"#
        + #""songs":[{"id":1,"name":"One"},{"id":2,"name":"Two"}]}"#
      ).utf8),
    response: okResponse,
    albumID: 32311
  )
  #expect(detail.album.trackCount == 2)
  #expect(detail.album.artists == [ArtistRef(id: 7, name: "Ar")])
  #expect(detail.tracks.map(\.id) == [1, 2])

  #expect(throws: NeteaseCatalogError.invalidResponse) {
    try NeteaseSession.classifyAlbumDetail(
      data: Data(#"{"code":200,"album":{"id":9,"name":"Other"},"songs":[]}"#.utf8),
      response: okResponse,
      albumID: 32311
    )
  }
}

/// An album the account has no relationship with reports neither field. That
/// is "unknown", not "not collected": showing it as a toggle would guess.
@Test func albumDynamicKeepsUnknownDistinctFromNotCollected() throws {
  let request = try NeteaseSession.albumDynamicRequest(
    albumID: 32311,
    credential: catalogCredential,
    secretKey: "0123456789abcdef"
  )
  try expectWeAPI(
    request,
    url: "https://music.163.com/weapi/album/detail/dynamic",
    json: #"{"id":32311,"csrf_token":"csrf-test"}"#
  )

  #expect(
    try NeteaseSession.classifyAlbumDynamic(
      data: Data(#"{"code":200,"isSub":true,"subCount":12}"#.utf8),
      response: okResponse
    ) == AlbumDynamic(isCollected: true, collectCount: 12)
  )
  #expect(
    try NeteaseSession.classifyAlbumDynamic(
      data: Data(#"{"code":200}"#.utf8),
      response: okResponse
    ) == AlbumDynamic(isCollected: nil, collectCount: nil)
  )
}

@Test func newAlbumsPageAgainstTheReportedTotal() throws {
  let request = try NeteaseSession.newAlbumsRequest(
    area: .japanese,
    limit: 30,
    offset: 30,
    credential: catalogCredential,
    secretKey: "0123456789abcdef"
  )
  try expectWeAPI(
    request,
    url: "https://music.163.com/weapi/album/new",
    json:
      #"{"limit":30,"offset":30,"total":true,"area":"JP","csrf_token":"csrf-test"}"#
  )

  let more = try NeteaseSession.classifyNewAlbums(
    data: Data(#"{"code":200,"total":5,"albums":[{"id":1,"name":"A","size":1}]}"#.utf8),
    response: okResponse,
    limit: 1,
    offset: 3
  )
  #expect(more.more)

  let done = try NeteaseSession.classifyNewAlbums(
    data: Data(#"{"code":200,"total":4,"albums":[{"id":1,"name":"A","size":1}]}"#.utf8),
    response: okResponse,
    limit: 1,
    offset: 3
  )
  #expect(done.more == false)
}

// MARK: - Artists

@Test func artistDetailReadsTheArtistAndItsTopSongs() throws {
  let request = try NeteaseSession.artistDetailRequest(
    artistID: 6452,
    credential: catalogCredential,
    secretKey: "0123456789abcdef"
  )
  try expectWeAPI(
    request,
    url: "https://music.163.com/weapi/v1/artist/6452",
    json: #"{"csrf_token":"csrf-test"}"#
  )

  let detail = try NeteaseSession.classifyArtistDetail(
    data: Data((
      #"{"code":200,"artist":{"id":6452,"name":"Ar","albumSize":30,"#
        + #""musicSize":300,"picUrl":"https://p1.music.126.net/ar.jpg"},"#
        + #""hotSongs":[{"id":1,"name":"One"}]}"#
      ).utf8),
    response: okResponse,
    artistID: 6452
  )
  #expect(detail.artist.albumCount == 30)
  #expect(detail.hotSongs.map(\.id) == [1])

  #expect(throws: NeteaseCatalogError.invalidResponse) {
    try NeteaseSession.classifyArtistDetail(
      data: Data(#"{"code":200,"artist":{"id":1,"name":"Other"}}"#.utf8),
      response: okResponse,
      artistID: 6452
    )
  }
}

@Test func artistAlbumsPageByOffset() throws {
  let request = try NeteaseSession.artistAlbumsRequest(
    artistID: 6452,
    limit: 30,
    offset: 60,
    credential: catalogCredential,
    secretKey: "0123456789abcdef"
  )
  try expectWeAPI(
    request,
    url: "https://music.163.com/weapi/artist/albums/6452",
    json: #"{"limit":30,"offset":60,"total":true,"csrf_token":"csrf-test"}"#
  )

  let page = try NeteaseSession.classifyArtistAlbums(
    data: Data((
      #"{"code":200,"more":false,"hotAlbums":[{"id":1,"name":"A","size":2,"#
        + #""artists":[{"id":6452,"name":"Ar"}]}]}"#
      ).utf8),
    response: okResponse,
    limit: 30
  )
  #expect(page.more == false)
  #expect(page.items.map(\.trackCount) == [2])
}

/// The artist chart nests its rows under `list`, unlike every other paged
/// list here.
@Test func topArtistsReadTheNestedListContainer() throws {
  let request = try NeteaseSession.topArtistsRequest(
    limit: 50,
    offset: 50,
    credential: catalogCredential,
    secretKey: "0123456789abcdef"
  )
  try expectWeAPI(
    request,
    url: "https://music.163.com/weapi/toplist/artist",
    json:
      #"{"type":1,"limit":50,"offset":50,"total":true,"csrf_token":"csrf-test"}"#
  )

  let page = try NeteaseSession.classifyTopArtists(
    data: Data((
      #"{"code":200,"list":{"artists":[{"id":1,"name":"A","albumSize":1,"#
        + #""musicSize":2}]}}"#
      ).utf8),
    response: okResponse,
    limit: 1
  )
  #expect(page.items.map(\.id) == [1])
  #expect(page.more)
}

// MARK: - Failure classification

@Test func catalogClassifiersDistinguishServiceAndHTTPErrors() throws {
  #expect(throws: NeteaseServiceError(source: .http, statusCode: 503)) {
    try NeteaseSession.classifyPersonalFM(
      data: Data(),
      response: serverErrorResponse
    )
  }
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 301)) {
    try NeteaseSession.classifySearch(
      data: Data(#"{"code":301}"#.utf8),
      response: okResponse,
      scope: .songs
    )
  }
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 301)) {
    try NeteaseSession.classifyCategoryPlaylists(
      data: Data(#"{"code":301}"#.utf8),
      response: okResponse,
      limit: 50
    )
  }
  #expect(throws: NeteaseServiceError(source: .service, statusCode: 250)) {
    try NeteaseSession.classifyHeartbeatQueue(
      data: Data(#"{"code":250}"#.utf8),
      response: okResponse
    )
  }
}

/// A body that is not the shape the endpoint promises is a decode failure, not
/// an empty list quietly shown to the user as "nothing found".
@Test func malformedCatalogBodiesThrowRatherThanReadAsEmpty() throws {
  #expect(throws: (any Error).self) {
    try NeteaseSession.classifyCategoryPlaylists(
      data: Data(#"{"code":200,"playlists":{"id":1}}"#.utf8),
      response: okResponse,
      limit: 50
    )
  }
  #expect(throws: (any Error).self) {
    try NeteaseSession.classifyPersonalFM(
      data: Data(#"{"code":200}"#.utf8),
      response: okResponse
    )
  }
  #expect(throws: (any Error).self) {
    try NeteaseSession.classifyTopArtists(
      data: Data(#"{"code":200,"list":[]}"#.utf8),
      response: okResponse,
      limit: 50
    )
  }
  #expect(throws: (any Error).self) {
    try NeteaseSession.classifyAlbumDetail(
      data: Data(#"{"code":200,"album":{"name":"No id"}}"#.utf8),
      response: okResponse,
      albumID: 1
    )
  }
}

/// Nothing a request builder emits may carry the session in the URL, and every
/// authenticated call must carry it in the header instead.
@Test func catalogRequestsKeepCredentialsOutOfTheURL() throws {
  let requests = [
    try NeteaseSession.categoryPlaylistsRequest(
      category: "全部", order: .hot, limit: 50, offset: 0,
      credential: catalogCredential, secretKey: "0123456789abcdef"
    ),
    try NeteaseSession.personalFMRequest(
      credential: catalogCredential, secretKey: "0123456789abcdef"
    ),
    try NeteaseSession.albumDetailRequest(
      albumID: 1, credential: catalogCredential, secretKey: "0123456789abcdef"
    ),
    try NeteaseSession.searchRequest(
      keywords: "x", scope: .songs, limit: 30, offset: 0,
      credential: catalogCredential, osVersion: "15.5",
      buildVersion: "1722945678", requestID: "1722945678123_0042"
    ),
  ]
  for request in requests {
    let url = request.url?.absoluteString ?? ""
    #expect(!url.contains("music-u-test"))
    #expect(!url.contains("csrf-test"))
    #expect(!url.contains("?"))
    #expect(request.httpShouldHandleCookies == false)
  }
}

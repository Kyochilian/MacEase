import Foundation

/// Browsing, search and the album/artist pages, plus the two server-generated
/// playback queues — personal FM and heartbeat mode.
///
/// Every endpoint here is checked against `api-enhanced@a7e8d48`: the path,
/// the crypto (`createOption(query, 'weapi')` for weapi, an empty crypto for
/// eapi, which `util/request.js` resolves through `APP_CONF.encrypt`) and the
/// request fields come from `module/*.js`. Response containers that the local
/// authority does not record are taken from `missuo/kumone@db1a5e6`, which
/// decodes the same responses; where neither records one, the endpoint is not
/// implemented rather than guessed at.
extension NeteaseSession {
  private static let categoryPlaylistsURL = URL(
    string: "https://music.163.com/weapi/playlist/list"
  )!
  private static let highQualityPlaylistsURL = URL(
    string: "https://music.163.com/weapi/playlist/highquality/list"
  )!
  private static let newSongsURL = URL(
    string: "https://music.163.com/weapi/personalized/newsong"
  )!
  private static let personalFMURL = URL(
    string: "https://music.163.com/weapi/v1/radio/get"
  )!
  private static let fmTrashURL = URL(
    string: "https://music.163.com/weapi/radio/trash/add"
  )!
  private static let similarArtistsURL = URL(
    string: "https://music.163.com/weapi/discovery/simiArtist"
  )!
  private static let searchSuggestionsURL = URL(
    string: "https://music.163.com/weapi/search/suggest/web"
  )!
  private static let albumDynamicURL = URL(
    string: "https://music.163.com/weapi/album/detail/dynamic"
  )!
  private static let newAlbumsURL = URL(
    string: "https://music.163.com/weapi/album/new"
  )!
  private static let topArtistsURL = URL(
    string: "https://music.163.com/weapi/toplist/artist"
  )!

  private static let playlistDetailPath = "/api/v6/playlist/detail"
  private static let searchPath = "/api/cloudsearch/pc"
  private static let defaultKeywordPath = "/api/search/defaultkeyword/get"
  private static let intelligencePath = "/api/playmode/intelligence/list"

  /// How many rows one browse page holds. `module/top_playlist.js` and
  /// `module/top_playlist_highquality.js` both default to 50.
  package static let browsePageSize = 50

  // MARK: - Browsing playlists

  package func categoryPlaylists(
    category: String,
    order: PlaylistOrder,
    limit: Int = browsePageSize,
    offset: Int = 0,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<DiscoveredPlaylist> {
    let request = try Self.categoryPlaylistsRequest(
      category: category,
      order: order,
      limit: limit,
      offset: offset,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyCategoryPlaylists(
      data: data,
      response: try Self.requireHTTPResponse(response),
      limit: limit
    )
  }

  package func highQualityPlaylists(
    category: String,
    limit: Int = browsePageSize,
    before: Int64 = 0,
    credential: NeteaseCredential
  ) async throws -> HighQualityPlaylistPage {
    let request = try Self.highQualityPlaylistsRequest(
      category: category,
      limit: limit,
      before: before,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyHighQualityPlaylists(
      data: data,
      response: try Self.requireHTTPResponse(response),
      limit: limit,
      before: before
    )
  }

  /// Name and cover for one playlist, without its tracks (1 request).
  ///
  /// The radar family is four fixed global playlist ids whose title and
  /// artwork the service generates per account, so there is nothing to fetch
  /// but the header. `n: 1, s: 0` is the same detail endpoint asked for the
  /// smallest answer it will give, which is what `missuo/kumone@db1a5e6`
  /// sends for exactly this.
  package func playlistBrief(
    playlistID: Int64,
    credential: NeteaseCredential
  ) async throws -> DiscoveredPlaylist {
    let timestamp = Date().timeIntervalSince1970
    let request = try Self.playlistBriefRequest(
      playlistID: playlistID,
      credential: credential,
      osVersion: Self.osVersion,
      buildVersion: String(Int(timestamp)),
      requestID: Self.requestID(timestamp: timestamp)
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyPlaylistBrief(
      data: data,
      response: try Self.requireHTTPResponse(response),
      playlistID: playlistID
    )
  }

  package func recommendedNewSongs(
    limit: Int = 10,
    credential: NeteaseCredential
  ) async throws -> [Track] {
    let request = try Self.recommendedNewSongsRequest(
      limit: limit,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyRecommendedNewSongs(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  package static func categoryPlaylistsRequest(
    category: String,
    order: PlaylistOrder,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json =
      #"{"cat":\#(try jsonString(category)),"order":"\#(order.rawValue)","#
      + #""limit":\#(limit),"offset":\#(offset),"total":true,"#
      + #""csrf_token":\#(try csrfJSONValue(credential))}"#
    return weapiRequest(
      url: categoryPlaylistsURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyCategoryPlaylists(
    data: Data,
    response: HTTPURLResponse,
    limit: Int
  ) throws -> CatalogPage<DiscoveredPlaylist> {
    try requireSuccess(data: data, response: response)
    let payload = try JSONDecoder().decode(BrowsePlaylistsPayload.self, from: data)
    let playlists = payload.playlists.map(\.playlist)
    return CatalogPage(
      items: playlists,
      more: payload.more ?? (playlists.count >= limit)
    )
  }

  package static func highQualityPlaylistsRequest(
    category: String,
    limit: Int,
    before: Int64,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json =
      #"{"cat":\#(try jsonString(category)),"limit":\#(limit),"#
      + #""lasttime":\#(before),"total":true,"#
      + #""csrf_token":\#(try csrfJSONValue(credential))}"#
    return weapiRequest(
      url: highQualityPlaylistsURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  /// The cursor is the service's own `lasttime`. When the response omits it
  /// the cursor cannot move, so paging stops rather than re-requesting the
  /// page that was just read.
  package static func classifyHighQualityPlaylists(
    data: Data,
    response: HTTPURLResponse,
    limit: Int,
    before: Int64
  ) throws -> HighQualityPlaylistPage {
    try requireSuccess(data: data, response: response)
    let payload = try JSONDecoder().decode(
      HighQualityPlaylistsPayload.self,
      from: data
    )
    let playlists = payload.playlists.map(\.playlist)
    let cursor = payload.lasttime ?? before
    let hasCursor = payload.lasttime != nil && payload.lasttime != before
    return HighQualityPlaylistPage(
      playlists: playlists,
      more: (payload.more ?? (playlists.count >= limit)) && hasCursor,
      before: cursor
    )
  }

  package static func playlistBriefRequest(
    playlistID: Int64,
    credential: NeteaseCredential,
    osVersion: String,
    buildVersion: String,
    requestID: String
  ) throws -> URLRequest {
    let headerFields = eapiHeaderFields(
      credential: credential,
      osVersion: osVersion,
      buildVersion: buildVersion,
      requestID: requestID
    )
    let json =
      #"{"id":\#(playlistID),"n":1,"s":0,"e_r":false,"#
      + #""header":\#(try eapiHeaderJSON(headerFields))}"#
    return try eapiFormRequest(
      path: playlistDetailPath,
      json: json,
      headerFields: headerFields
    )
  }

  package static func classifyPlaylistBrief(
    data: Data,
    response: HTTPURLResponse,
    playlistID: Int64
  ) throws -> DiscoveredPlaylist {
    try requireSuccess(data: data, response: response)
    let playlist = try JSONDecoder().decode(PlaylistBriefPayload.self, from: data)
      .playlist
    guard playlist.id == playlistID else {
      throw NeteaseCatalogError.invalidResponse
    }
    return playlist.playlist
  }

  package static func recommendedNewSongsRequest(
    limit: Int,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json =
      #"{"type":"recommend","limit":\#(limit),"areaId":0,"#
      + #""csrf_token":\#(try csrfJSONValue(credential))}"#
    return weapiRequest(
      url: newSongsURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  /// Each row wraps the song it recommends. A row without one describes
  /// something this list cannot play, so it is dropped rather than turned into
  /// a track with no id.
  package static func classifyRecommendedNewSongs(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [Track] {
    try requireSuccess(data: data, response: response)
    return try JSONDecoder().decode(NewSongsPayload.self, from: data)
      .result.compactMap { $0.song?.track }
  }

  // MARK: - Personal FM and heartbeat mode

  /// The next few tracks of the account's personal radio (1 request).
  package func personalFM(
    credential: NeteaseCredential
  ) async throws -> [Track] {
    let request = try Self.personalFMRequest(credential: credential)
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyPersonalFM(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  /// Tells the service the account does not want this song again. A write: it
  /// changes what the radio will serve.
  package func trashFMSong(
    songID: Int64,
    credential: NeteaseCredential
  ) async throws {
    let request = try Self.fmTrashRequest(songID: songID, credential: credential)
    let (data, response) = try await urlSession.data(for: request)
    try Self.classifyWriteAcknowledgement(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  /// The heartbeat-mode queue generated from one song inside one playlist
  /// (1 request). Both ids are required by the contract, so there is no call
  /// shape that omits either.
  package func heartbeatQueue(
    songID: Int64,
    playlistID: Int64,
    startMusicID: Int64,
    credential: NeteaseCredential
  ) async throws -> [Track] {
    let timestamp = Date().timeIntervalSince1970
    let request = try Self.heartbeatQueueRequest(
      songID: songID,
      playlistID: playlistID,
      startMusicID: startMusicID,
      credential: credential,
      osVersion: Self.osVersion,
      buildVersion: String(Int(timestamp)),
      requestID: Self.requestID(timestamp: timestamp)
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyHeartbeatQueue(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  package static func personalFMRequest(
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json = #"{"csrf_token":\#(try csrfJSONValue(credential))}"#
    return weapiRequest(
      url: personalFMURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyPersonalFM(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [Track] {
    try requireSuccess(data: data, response: response)
    return try JSONDecoder().decode(PersonalFMPayload.self, from: data)
      .data.map(\.track)
  }

  /// `alg` and `time` are the fixed values the authority sends; they describe
  /// which recommender the rejection applies to and how long the song played,
  /// and MacEase does not invent different ones.
  package static func fmTrashRequest(
    songID: Int64,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json =
      #"{"songId":\#(songID),"alg":"RT","time":25,"#
      + #""csrf_token":\#(try csrfJSONValue(credential))}"#
    return weapiRequest(
      url: fmTrashURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential,
      platformContext: true
    )
  }

  package static func heartbeatQueueRequest(
    songID: Int64,
    playlistID: Int64,
    startMusicID: Int64,
    credential: NeteaseCredential,
    osVersion: String,
    buildVersion: String,
    requestID: String
  ) throws -> URLRequest {
    let headerFields = eapiHeaderFields(
      credential: credential,
      osVersion: osVersion,
      buildVersion: buildVersion,
      requestID: requestID
    )
    let json =
      #"{"songId":\#(songID),"type":"fromPlayOne","playlistId":\#(playlistID),"#
      + #""startMusicId":\#(startMusicID),"count":1,"e_r":false,"#
      + #""header":\#(try eapiHeaderJSON(headerFields))}"#
    return try eapiFormRequest(
      path: intelligencePath,
      json: json,
      headerFields: headerFields
    )
  }

  /// Each entry carries the track under `songInfo`. An entry without one names
  /// nothing playable and is dropped.
  package static func classifyHeartbeatQueue(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [Track] {
    try requireSuccess(data: data, response: response)
    return try JSONDecoder().decode(HeartbeatPayload.self, from: data)
      .data.compactMap { $0.songInfo?.track }
  }

  // MARK: - Similar artists

  package func similarArtists(
    artistID: Int64,
    credential: NeteaseCredential
  ) async throws -> [Artist] {
    let request = try Self.similarArtistsRequest(
      artistID: artistID,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifySimilarArtists(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  /// The field is `artistid`, all lower case, unlike the `artistId` the
  /// follow write sends. They are different endpoints from different eras.
  package static func similarArtistsRequest(
    artistID: Int64,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json =
      #"{"artistid":\#(artistID),"csrf_token":\#(try csrfJSONValue(credential))}"#
    return weapiRequest(
      url: similarArtistsURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifySimilarArtists(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [Artist] {
    try requireSuccess(data: data, response: response)
    return try JSONDecoder().decode(SimilarArtistsPayload.self, from: data)
      .artists.map(\.artist)
  }

  // MARK: - Search

  /// One page of search results for one kind of thing (1 request).
  package func search(
    keywords: String,
    scope: SearchScope,
    limit: Int = 30,
    offset: Int = 0,
    credential: NeteaseCredential
  ) async throws -> SearchPage {
    let timestamp = Date().timeIntervalSince1970
    let request = try Self.searchRequest(
      keywords: keywords,
      scope: scope,
      limit: limit,
      offset: offset,
      credential: credential,
      osVersion: Self.osVersion,
      buildVersion: String(Int(timestamp)),
      requestID: Self.requestID(timestamp: timestamp)
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifySearch(
      data: data,
      response: try Self.requireHTTPResponse(response),
      scope: scope
    )
  }

  package func searchSuggestions(
    keywords: String,
    credential: NeteaseCredential
  ) async throws -> [SearchSuggestion] {
    let request = try Self.searchSuggestionsRequest(
      keywords: keywords,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifySearchSuggestions(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  /// The keyword the service would search for if the user typed nothing
  /// (1 request). MacEase shows it and never runs it.
  package func defaultSearchKeyword(
    credential: NeteaseCredential
  ) async throws -> String? {
    let timestamp = Date().timeIntervalSince1970
    let request = try Self.defaultSearchKeywordRequest(
      credential: credential,
      osVersion: Self.osVersion,
      buildVersion: String(Int(timestamp)),
      requestID: Self.requestID(timestamp: timestamp)
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyDefaultSearchKeyword(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  package static func searchRequest(
    keywords: String,
    scope: SearchScope,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential,
    osVersion: String,
    buildVersion: String,
    requestID: String
  ) throws -> URLRequest {
    let headerFields = eapiHeaderFields(
      credential: credential,
      osVersion: osVersion,
      buildVersion: buildVersion,
      requestID: requestID
    )
    let json =
      #"{"s":\#(try jsonString(keywords)),"type":\#(scope.rawValue),"#
      + #""limit":\#(limit),"offset":\#(offset),"total":true,"e_r":false,"#
      + #""header":\#(try eapiHeaderJSON(headerFields))}"#
    return try eapiFormRequest(
      path: searchPath,
      json: json,
      headerFields: headerFields
    )
  }

  /// A search that matched nothing answers 200 with no `result` at all, which
  /// is an empty page rather than a malformed response. Only the container for
  /// the requested scope is read, so an album search cannot publish songs.
  package static func classifySearch(
    data: Data,
    response: HTTPURLResponse,
    scope: SearchScope
  ) throws -> SearchPage {
    try requireSuccess(data: data, response: response)
    guard
      let result = try JSONDecoder().decode(SearchPayload.self, from: data).result
    else {
      return SearchPage(items: .empty(scope), totalCount: nil)
    }
    let items: SearchItems
    let total: Int?
    switch scope {
    case .songs:
      items = .songs((result.songs ?? []).map(\.track))
      total = result.songCount
    case .albums:
      items = .albums((result.albums ?? []).map(\.album))
      total = result.albumCount
    case .artists:
      items = .artists((result.artists ?? []).map(\.artist))
      total = result.artistCount
    case .playlists:
      items = .playlists((result.playlists ?? []).map(\.playlist))
      total = result.playlistCount
    }
    return SearchPage(items: items, totalCount: total)
  }

  package static func searchSuggestionsRequest(
    keywords: String,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json =
      #"{"s":\#(try jsonString(keywords)),"#
      + #""csrf_token":\#(try csrfJSONValue(credential))}"#
    return weapiRequest(
      url: searchSuggestionsURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  /// Suggestions are flattened into one list in the order the service groups
  /// them. Two rows can carry the same text — a song and an album of the same
  /// name — so the row keeps its own id and only identical text is dropped.
  package static func classifySearchSuggestions(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [SearchSuggestion] {
    try requireSuccess(data: data, response: response)
    guard
      let result = try JSONDecoder().decode(
        SearchSuggestionsPayload.self,
        from: data
      ).result
    else { return [] }

    var suggestions: [SearchSuggestion] = []
    var seen: Set<String> = []
    func add(_ id: String, _ keyword: String, _ detail: String?) {
      let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
      suggestions.append(
        SearchSuggestion(id: id, keyword: trimmed, detail: detail)
      )
    }
    for row in result.songs ?? [] {
      add("song-\(row.id)", row.name, row.track.artistDisplayName)
    }
    for row in result.artists ?? [] {
      add("artist-\(row.id)", row.name, nil)
    }
    for row in result.albums ?? [] {
      add("album-\(row.id)", row.name, row.album.artistDisplayName)
    }
    for row in result.playlists ?? [] {
      add("playlist-\(row.id)", row.name, nil)
    }
    return suggestions
  }

  package static func defaultSearchKeywordRequest(
    credential: NeteaseCredential,
    osVersion: String,
    buildVersion: String,
    requestID: String
  ) throws -> URLRequest {
    let headerFields = eapiHeaderFields(
      credential: credential,
      osVersion: osVersion,
      buildVersion: buildVersion,
      requestID: requestID
    )
    let json =
      #"{"e_r":false,"header":\#(try eapiHeaderJSON(headerFields))}"#
    return try eapiFormRequest(
      path: defaultKeywordPath,
      json: json,
      headerFields: headerFields
    )
  }

  /// An empty or missing keyword is a fact, not a failure: the placeholder
  /// simply stays generic.
  package static func classifyDefaultSearchKeyword(
    data: Data,
    response: HTTPURLResponse
  ) throws -> String? {
    try requireSuccess(data: data, response: response)
    let keyword = try JSONDecoder().decode(DefaultKeywordPayload.self, from: data)
      .data?.showKeyword?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let keyword, !keyword.isEmpty else { return nil }
    return keyword
  }

  // MARK: - Albums

  package func albumDetail(
    albumID: Int64,
    credential: NeteaseCredential
  ) async throws -> AlbumDetail {
    let request = try Self.albumDetailRequest(
      albumID: albumID,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyAlbumDetail(
      data: data,
      response: try Self.requireHTTPResponse(response),
      albumID: albumID
    )
  }

  package func albumDynamic(
    albumID: Int64,
    credential: NeteaseCredential
  ) async throws -> AlbumDynamic {
    let request = try Self.albumDynamicRequest(
      albumID: albumID,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyAlbumDynamic(
      data: data,
      response: try Self.requireHTTPResponse(response)
    )
  }

  package func newAlbums(
    area: AlbumArea,
    limit: Int = 30,
    offset: Int = 0,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<Album> {
    let request = try Self.newAlbumsRequest(
      area: area,
      limit: limit,
      offset: offset,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyNewAlbums(
      data: data,
      response: try Self.requireHTTPResponse(response),
      limit: limit,
      offset: offset
    )
  }

  /// The album id travels in the path, not the body, so it is placed by
  /// integer interpolation and cannot carry anything but digits.
  package static func albumDetailRequest(
    albumID: Int64,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    guard
      let url = URL(string: "https://music.163.com/weapi/v1/album/\(albumID)")
    else { throw NeteaseCatalogError.invalidResponse }
    let json = #"{"csrf_token":\#(try csrfJSONValue(credential))}"#
    return weapiRequest(
      url: url,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyAlbumDetail(
    data: Data,
    response: HTTPURLResponse,
    albumID: Int64
  ) throws -> AlbumDetail {
    try requireSuccess(data: data, response: response)
    let payload = try JSONDecoder().decode(AlbumDetailPayload.self, from: data)
    guard payload.album.id == albumID else {
      throw NeteaseCatalogError.invalidResponse
    }
    let tracks = (payload.songs ?? []).map(\.track)
    let album = payload.album.album
    return AlbumDetail(
      album: Album(
        id: album.id,
        name: album.name,
        artists: album.artists,
        artworkURL: album.artworkURL,
        // The header's own count is missing on some rows; the track list that
        // arrived with it is then the honest number.
        trackCount: album.trackCount > 0 ? album.trackCount : tracks.count
      ),
      tracks: tracks
    )
  }

  package static func albumDynamicRequest(
    albumID: Int64,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json =
      #"{"id":\#(albumID),"csrf_token":\#(try csrfJSONValue(credential))}"#
    return weapiRequest(
      url: albumDynamicURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyAlbumDynamic(
    data: Data,
    response: HTTPURLResponse
  ) throws -> AlbumDynamic {
    try requireSuccess(data: data, response: response)
    let payload = try JSONDecoder().decode(AlbumDynamicPayload.self, from: data)
    return AlbumDynamic(isCollected: payload.isSub, collectCount: payload.subCount)
  }

  package static func newAlbumsRequest(
    area: AlbumArea,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json =
      #"{"limit":\#(limit),"offset":\#(offset),"total":true,"#
      + #""area":"\#(area.rawValue)","csrf_token":\#(try csrfJSONValue(credential))}"#
    return weapiRequest(
      url: newAlbumsURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  /// This endpoint reports a total rather than a `more` flag, so the cursor is
  /// compared against it; without one, a full page is taken as evidence that
  /// another may exist.
  package static func classifyNewAlbums(
    data: Data,
    response: HTTPURLResponse,
    limit: Int,
    offset: Int
  ) throws -> CatalogPage<Album> {
    try requireSuccess(data: data, response: response)
    let payload = try JSONDecoder().decode(NewAlbumsPayload.self, from: data)
    let albums = payload.albums.map(\.album)
    return CatalogPage(
      items: albums,
      more: payload.total.map { offset + albums.count < $0 }
        ?? (albums.count >= limit)
    )
  }

  // MARK: - Artists

  package func artistDetail(
    artistID: Int64,
    credential: NeteaseCredential
  ) async throws -> ArtistDetail {
    let request = try Self.artistDetailRequest(
      artistID: artistID,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyArtistDetail(
      data: data,
      response: try Self.requireHTTPResponse(response),
      artistID: artistID
    )
  }

  package func artistAlbums(
    artistID: Int64,
    limit: Int = 30,
    offset: Int = 0,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<Album> {
    let request = try Self.artistAlbumsRequest(
      artistID: artistID,
      limit: limit,
      offset: offset,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyArtistAlbums(
      data: data,
      response: try Self.requireHTTPResponse(response),
      limit: limit
    )
  }

  package func topArtists(
    limit: Int = 50,
    offset: Int = 0,
    credential: NeteaseCredential
  ) async throws -> CatalogPage<Artist> {
    let request = try Self.topArtistsRequest(
      limit: limit,
      offset: offset,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyTopArtists(
      data: data,
      response: try Self.requireHTTPResponse(response),
      limit: limit
    )
  }

  package static func artistDetailRequest(
    artistID: Int64,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    guard
      let url = URL(string: "https://music.163.com/weapi/v1/artist/\(artistID)")
    else { throw NeteaseCatalogError.invalidResponse }
    let json = #"{"csrf_token":\#(try csrfJSONValue(credential))}"#
    return weapiRequest(
      url: url,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyArtistDetail(
    data: Data,
    response: HTTPURLResponse,
    artistID: Int64
  ) throws -> ArtistDetail {
    try requireSuccess(data: data, response: response)
    let payload = try JSONDecoder().decode(ArtistDetailPayload.self, from: data)
    guard payload.artist.id == artistID else {
      throw NeteaseCatalogError.invalidResponse
    }
    return ArtistDetail(
      artist: payload.artist.artist,
      hotSongs: (payload.hotSongs ?? []).map(\.track)
    )
  }

  package static func artistAlbumsRequest(
    artistID: Int64,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    guard
      let url = URL(
        string: "https://music.163.com/weapi/artist/albums/\(artistID)"
      )
    else { throw NeteaseCatalogError.invalidResponse }
    let json =
      #"{"limit":\#(limit),"offset":\#(offset),"total":true,"#
      + #""csrf_token":\#(try csrfJSONValue(credential))}"#
    return weapiRequest(
      url: url,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyArtistAlbums(
    data: Data,
    response: HTTPURLResponse,
    limit: Int
  ) throws -> CatalogPage<Album> {
    try requireSuccess(data: data, response: response)
    let payload = try JSONDecoder().decode(ArtistAlbumsPayload.self, from: data)
    let albums = payload.hotAlbums.map(\.album)
    return CatalogPage(
      items: albums,
      more: payload.more ?? (albums.count >= limit)
    )
  }

  /// `type` selects which artist chart; 1 is the one the authority defaults
  /// to. The rows arrive nested under `list`.
  package static func topArtistsRequest(
    limit: Int,
    offset: Int,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json =
      #"{"type":1,"limit":\#(limit),"offset":\#(offset),"total":true,"#
      + #""csrf_token":\#(try csrfJSONValue(credential))}"#
    return weapiRequest(
      url: topArtistsURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyTopArtists(
    data: Data,
    response: HTTPURLResponse,
    limit: Int
  ) throws -> CatalogPage<Artist> {
    try requireSuccess(data: data, response: response)
    let artists = try JSONDecoder().decode(TopArtistsPayload.self, from: data)
      .list.artists.map(\.artist)
    return CatalogPage(items: artists, more: artists.count >= limit)
  }

  // MARK: - Shared plumbing

  /// JSON-escapes a value that goes into a hand-built request body, so user
  /// text can never break out of the string it belongs in.
  private static func jsonString(_ value: String) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }
}

// MARK: - Payloads

private struct BrowsePlaylistsPayload: Decodable {
  let playlists: [PlaylistRowPayload]
  let more: Bool?
}

private struct HighQualityPlaylistsPayload: Decodable {
  let playlists: [PlaylistRowPayload]
  let more: Bool?
  let lasttime: Int64?
}

private struct PlaylistBriefPayload: Decodable {
  let playlist: PlaylistRowPayload
}

private struct NewSongsPayload: Decodable {
  let result: [Item]

  struct Item: Decodable {
    let song: SongRowPayload?
  }
}

private struct PersonalFMPayload: Decodable {
  let data: [SongRowPayload]
}

private struct HeartbeatPayload: Decodable {
  let data: [Item]

  struct Item: Decodable {
    let songInfo: SongRowPayload?
  }
}

private struct SimilarArtistsPayload: Decodable {
  let artists: [ArtistRowPayload]
}

private struct SearchPayload: Decodable {
  let result: Result?

  struct Result: Decodable {
    let songs: [SongRowPayload]?
    let albums: [AlbumRowPayload]?
    let artists: [ArtistRowPayload]?
    let playlists: [PlaylistRowPayload]?
    let songCount: Int?
    let albumCount: Int?
    let artistCount: Int?
    let playlistCount: Int?
  }
}

private struct SearchSuggestionsPayload: Decodable {
  let result: Result?

  struct Result: Decodable {
    let songs: [SongRowPayload]?
    let artists: [ArtistRowPayload]?
    let albums: [AlbumRowPayload]?
    let playlists: [PlaylistRowPayload]?
  }
}

private struct DefaultKeywordPayload: Decodable {
  let data: Body?

  struct Body: Decodable {
    let showKeyword: String?
  }
}

private struct AlbumDetailPayload: Decodable {
  let album: AlbumRowPayload
  let songs: [SongRowPayload]?
}

private struct AlbumDynamicPayload: Decodable {
  let isSub: Bool?
  let subCount: Int?
}

private struct NewAlbumsPayload: Decodable {
  let albums: [AlbumRowPayload]
  let total: Int?
}

private struct ArtistDetailPayload: Decodable {
  let artist: ArtistRowPayload
  let hotSongs: [SongRowPayload]?
}

private struct ArtistAlbumsPayload: Decodable {
  let hotAlbums: [AlbumRowPayload]
  let more: Bool?
}

private struct TopArtistsPayload: Decodable {
  let list: Body

  struct Body: Decodable {
    let artists: [ArtistRowPayload]
  }
}

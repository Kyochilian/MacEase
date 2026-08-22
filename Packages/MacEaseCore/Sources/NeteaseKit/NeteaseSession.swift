import Foundation

public struct NeteaseAccount: Equatable, Sendable {
  public let userID: Int64
}

public enum AccountSessionState: Equatable, Sendable {
  case authenticated(NeteaseAccount)
  case signedOut
}

public struct NeteaseServiceError: Error, Equatable, Sendable {
  public enum Source: String, Equatable, Sendable {
    case http
    case service
  }

  public let source: Source
  public let statusCode: Int

  public init(source: Source, statusCode: Int) {
    self.source = source
    self.statusCode = statusCode
  }
}

public enum PlaybackQuality: String, CaseIterable, Sendable {
  case standard
  case higher
  case exhigh
  case lossless
  case hires
}

public struct ResolvedAudioAsset: Equatable, Sendable {
  public let songID: Int64
  public let url: URL
  public let sourceScheme: String
  public let requestedQuality: PlaybackQuality
  public let actualQuality: String?
  public let format: String?
  public let bitRate: Int?
  public let byteCount: Int64?
  public let expiresIn: Int?
  public let fee: Int?
  public let trial: Bool
}

public enum SongURLResolution: Equatable, Sendable {
  case resolved(ResolvedAudioAsset)
  case unavailable(itemCode: Int, fee: Int?)
}

public struct UserPlaylist: Equatable, Sendable {
  public let id: Int64
  public let name: String
  public let trackCount: Int
  public let owned: Bool

  package init(id: Int64, name: String, trackCount: Int, owned: Bool) {
    self.id = id
    self.name = name
    self.trackCount = trackCount
    self.owned = owned
  }
}

public struct UserPlaylistPage: Equatable, Sendable {
  public let playlists: [UserPlaylist]
  public let more: Bool
}

package struct PlaylistDetail: Equatable, Sendable {
  package let id: Int64
  package let name: String
  package let trackIDs: [Int64]
}

package struct PlaylistTrack: Equatable, Sendable {
  package let id: Int64
  package let name: String
  package let artists: [String]
}

package enum PlayRecordScope: Int, CaseIterable, Sendable {
  case allTime = 0
  case lastWeek = 1
}

package struct PlayRecordEntry: Equatable, Sendable {
  package let track: PlaylistTrack
  package let playCount: Int
}

package struct DiscoveredPlaylist: Equatable, Sendable {
  package let id: Int64
  package let name: String
}

package enum NeteaseCatalogError: Error, Equatable, Sendable {
  case invalidResponse
  case invalidSongDetailRequestCount(Int)
}

public enum NeteasePlaybackError: Error, Equatable, Sendable {
  case invalidResponse
  case nonHTTPSURL(String)
  case unapprovedHost(String)
}

public struct AudioURLProbeResult: Equatable, Sendable {
  public let statusCode: Int
  public let rangeResponse: Bool
  public let contentType: String?
  public let redirectScheme: String?
  public let redirectHost: String?
}

package enum LyricsProbeStatus: Equatable, Sendable {
  case content
  case noLyrics
  case http(Int)
  case service(Int)
  case invalidResponse
  case network
}

package struct LyricsProbeOutcome: Equatable, Sendable {
  package let status: LyricsProbeStatus
  package let setsCookie: Bool
}

public actor NeteaseSession {
  package static let songDetailRequestLimit = 1000

  private struct EndpointDescriptor: Sendable {
    let path: String
    let url: URL
  }

  private static let lyricsEndpoint = EndpointDescriptor(
    path: "/api/song/lyric/v1",
    url: URL(string: "https://interfacepc.music.163.com/eapi/song/lyric/v1")!
  )
  private static let songURLEndpoint = EndpointDescriptor(
    path: "/api/song/enhance/player/url/v1",
    url: URL(
      string: "https://interfacepc.music.163.com/eapi/song/enhance/player/url/v1"
    )!
  )
  private static let playlistDetailEndpoint = EndpointDescriptor(
    path: "/api/v6/playlist/detail",
    url: URL(string: "https://interfacepc.music.163.com/eapi/v6/playlist/detail")!
  )
  private static let toplistsEndpoint = EndpointDescriptor(
    path: "/api/toplist",
    url: URL(string: "https://interfacepc.music.163.com/eapi/toplist")!
  )
  private static let accountStatusURL = URL(
    string: "https://music.163.com/weapi/w/nuser/account/get"
  )!
  private static let userPlaylistsURL = URL(
    string: "https://music.163.com/weapi/user/playlist"
  )!
  private static let songDetailsURL = URL(
    string: "https://music.163.com/weapi/v3/song/detail"
  )!
  private static let likedSongIDsURL = URL(
    string: "https://music.163.com/weapi/song/like/get"
  )!
  private static let playRecordsURL = URL(
    string: "https://music.163.com/weapi/v1/play/record"
  )!
  private static let dailyRecommendedSongsURL = URL(
    string: "https://music.163.com/weapi/v3/discovery/recommend/songs"
  )!
  private static let dailyRecommendedPlaylistsURL = URL(
    string: "https://music.163.com/weapi/v1/discovery/recommend/resource"
  )!
  private static let personalizedPlaylistsURL = URL(
    string: "https://music.163.com/weapi/personalized/playlist"
  )!
  private static let similarSongsURL = URL(
    string: "https://music.163.com/weapi/v1/discovery/simiSong"
  )!
  private static let likeSongURL = URL(
    string: "https://music.163.com/weapi/radio/like"
  )!

  private let redirectBlocker: RedirectBlocker
  private let urlSession: URLSession

  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    let redirectBlocker = RedirectBlocker()
    self.redirectBlocker = redirectBlocker
    self.urlSession = URLSession(
      configuration: configuration,
      delegate: redirectBlocker,
      delegateQueue: nil
    )
  }

  public func accountStatus(
    credential: NeteaseCredential
  ) async throws -> AccountSessionState {
    let request = try Self.accountStatusRequest(credential: credential)
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyAccountStatus(
      data: data,
      response: response as! HTTPURLResponse
    )
  }

  public func userPlaylists(
    userID: Int64,
    limit: Int = 30,
    offset: Int = 0,
    credential: NeteaseCredential
  ) async throws -> UserPlaylistPage {
    let request = try Self.userPlaylistsRequest(
      userID: userID,
      limit: limit,
      offset: offset,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyUserPlaylists(
      data: data,
      response: response as! HTTPURLResponse,
      userID: userID
    )
  }

  package func playlistDetail(
    playlistID: Int64,
    credential: NeteaseCredential
  ) async throws -> PlaylistDetail {
    let timestamp = Date().timeIntervalSince1970
    let request = try Self.playlistDetailRequest(
      playlistID: playlistID,
      credential: credential,
      osVersion: Self.osVersion,
      buildVersion: String(Int(timestamp)),
      requestID: Self.requestID(timestamp: timestamp)
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyPlaylistDetail(
      data: data,
      response: response as! HTTPURLResponse,
      playlistID: playlistID
    )
  }

  package func songDetails(
    songIDs: [Int64],
    credential: NeteaseCredential
  ) async throws -> [PlaylistTrack] {
    let request = try Self.songDetailsRequest(
      songIDs: songIDs,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifySongDetails(
      data: data,
      response: response as! HTTPURLResponse,
      songIDs: songIDs
    )
  }

  package func likedSongIDs(
    userID: Int64,
    credential: NeteaseCredential
  ) async throws -> [Int64] {
    let request = try Self.likedSongIDsRequest(
      userID: userID,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyLikedSongIDs(
      data: data,
      response: response as! HTTPURLResponse
    )
  }

  package func playRecords(
    userID: Int64,
    scope: PlayRecordScope,
    credential: NeteaseCredential
  ) async throws -> [PlayRecordEntry] {
    let request = try Self.playRecordsRequest(
      userID: userID,
      scope: scope,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyPlayRecords(
      data: data,
      response: response as! HTTPURLResponse,
      scope: scope
    )
  }

  package func dailyRecommendedSongs(
    credential: NeteaseCredential
  ) async throws -> [PlaylistTrack] {
    let request = try Self.dailyRecommendedSongsRequest(credential: credential)
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyDailyRecommendedSongs(
      data: data,
      response: response as! HTTPURLResponse
    )
  }

  package func dailyRecommendedPlaylists(
    credential: NeteaseCredential
  ) async throws -> [DiscoveredPlaylist] {
    let request = try Self.dailyRecommendedPlaylistsRequest(credential: credential)
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyDailyRecommendedPlaylists(
      data: data,
      response: response as! HTTPURLResponse
    )
  }

  package func personalizedPlaylists(
    credential: NeteaseCredential
  ) async throws -> [DiscoveredPlaylist] {
    let request = try Self.personalizedPlaylistsRequest(credential: credential)
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyPersonalizedPlaylists(
      data: data,
      response: response as! HTTPURLResponse
    )
  }

  package func toplists(
    credential: NeteaseCredential
  ) async throws -> [DiscoveredPlaylist] {
    let timestamp = Date().timeIntervalSince1970
    let request = try Self.toplistsRequest(
      credential: credential,
      osVersion: Self.osVersion,
      buildVersion: String(Int(timestamp)),
      requestID: Self.requestID(timestamp: timestamp)
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifyToplists(
      data: data,
      response: response as! HTTPURLResponse
    )
  }

  package func similarSongs(
    songID: Int64,
    credential: NeteaseCredential
  ) async throws -> [PlaylistTrack] {
    let request = try Self.similarSongsRequest(
      songID: songID,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifySimilarSongs(
      data: data,
      response: response as! HTTPURLResponse
    )
  }

  /// The first write endpoint: it mutates the server-side liked-songs list.
  /// Registered under init.md §3.2 and approved 2026-08-22. No automatic
  /// retry: any non-200 is reported to the user and stops.
  package func setSongLiked(
    songID: Int64,
    liked: Bool,
    credential: NeteaseCredential
  ) async throws {
    let request = try Self.likeSongRequest(
      songID: songID,
      liked: liked,
      credential: credential
    )
    let (data, response) = try await urlSession.data(for: request)
    try Self.classifyLikeSong(
      data: data,
      response: response as! HTTPURLResponse
    )
  }

  public func resolveSongURL(
    songID: Int64,
    quality: PlaybackQuality,
    credential: NeteaseCredential
  ) async throws -> SongURLResolution {
    let timestamp = Date().timeIntervalSince1970
    let request = try Self.songURLRequest(
      songID: songID,
      quality: quality,
      credential: credential,
      osVersion: Self.osVersion,
      buildVersion: String(Int(timestamp)),
      requestID: Self.requestID(timestamp: timestamp)
    )
    let (data, response) = try await urlSession.data(for: request)
    return try Self.classifySongURL(
      data: data,
      response: response as! HTTPURLResponse,
      songID: songID,
      requestedQuality: quality
    )
  }

  public func probeAudioURL(_ asset: ResolvedAudioAsset) async throws -> AudioURLProbeResult {
    let (bytes, response) = try await urlSession.bytes(
      for: Self.audioProbeRequest(asset: asset)
    )
    bytes.task.cancel()
    return Self.classifyAudioProbe(response: response as! HTTPURLResponse)
  }

  package static func audioProbeRequest(asset: ResolvedAudioAsset) -> URLRequest {
    var request = URLRequest(url: asset.url)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
    request.setValue("MacEasePhase0/0.1 (macOS 15)", forHTTPHeaderField: "User-Agent")
    return request
  }

  package static func accountStatusRequest(
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json = try csrfOnlyJSON(credential: credential)
    return weapiRequest(
      url: accountStatusURL,
      parameters: weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyAccountStatus(
    data: Data,
    response: HTTPURLResponse
  ) throws -> AccountSessionState {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }

    let code = try JSONDecoder().decode(ServiceCodePayload.self, from: data).code
    guard code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: code)
    }
    let payload = try JSONDecoder().decode(AccountStatusPayload.self, from: data)
    guard let profile = payload.profile else {
      return .signedOut
    }
    return .authenticated(NeteaseAccount(userID: profile.userId))
  }

  package static func userPlaylistsRequest(
    userID: Int64,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json = try userPlaylistsJSON(
      userID: userID,
      limit: limit,
      offset: offset,
      credential: credential
    )
    return weapiRequest(
      url: userPlaylistsURL,
      parameters: weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyUserPlaylists(
    data: Data,
    response: HTTPURLResponse,
    userID: Int64
  ) throws -> UserPlaylistPage {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }

    let code = try JSONDecoder().decode(ServiceCodePayload.self, from: data).code
    guard code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: code)
    }
    let payload = try JSONDecoder().decode(UserPlaylistsPayload.self, from: data)
    return UserPlaylistPage(
      playlists: payload.playlist.map {
        UserPlaylist(
          id: $0.id,
          name: $0.name,
          trackCount: $0.trackCount,
          owned: $0.creator.userId == userID
        )
      },
      more: payload.more
    )
  }

  package static func playlistDetailRequest(
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
    let header = try eapiHeaderJSON(headerFields)
    let json =
      #"{"id":\#(playlistID),"n":100000,"s":8,"e_r":false,"header":\#(header)}"#
    return eapiRequest(
      endpoint: playlistDetailEndpoint,
      json: json,
      headerFields: headerFields
    )
  }

  package static func classifyPlaylistDetail(
    data: Data,
    response: HTTPURLResponse,
    playlistID: Int64
  ) throws -> PlaylistDetail {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }

    let code = try JSONDecoder().decode(ServiceCodePayload.self, from: data).code
    guard code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: code)
    }
    let playlist = try JSONDecoder().decode(PlaylistDetailPayload.self, from: data).playlist
    guard playlist.id == playlistID else {
      throw NeteaseCatalogError.invalidResponse
    }
    return PlaylistDetail(
      id: playlist.id,
      name: playlist.name,
      trackIDs: playlist.trackIds.map(\.id)
    )
  }

  package static func songDetailsRequest(
    songIDs: [Int64],
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json = try songDetailsJSON(songIDs: songIDs, credential: credential)
    return weapiRequest(
      url: songDetailsURL,
      parameters: weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifySongDetails(
    data: Data,
    response: HTTPURLResponse,
    songIDs: [Int64]
  ) throws -> [PlaylistTrack] {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }

    let code = try JSONDecoder().decode(ServiceCodePayload.self, from: data).code
    guard code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: code)
    }
    let songs = try JSONDecoder().decode(SongDetailsPayload.self, from: data).songs
    var tracksByID: [Int64: PlaylistTrack] = [:]
    for song in songs {
      tracksByID[song.id] = PlaylistTrack(
        id: song.id,
        name: song.name,
        artists: song.ar.map(\.name)
      )
    }
    return songIDs.compactMap { tracksByID[$0] }
  }

  package static func likedSongIDsRequest(
    userID: Int64,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json = try likedSongIDsJSON(userID: userID, credential: credential)
    return weapiRequest(
      url: likedSongIDsURL,
      parameters: weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyLikedSongIDs(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [Int64] {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }

    let code = try JSONDecoder().decode(ServiceCodePayload.self, from: data).code
    guard code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: code)
    }
    return try JSONDecoder().decode(LikedSongIDsPayload.self, from: data).ids
  }

  package static func playRecordsRequest(
    userID: Int64,
    scope: PlayRecordScope,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json = try playRecordsJSON(userID: userID, scope: scope, credential: credential)
    return weapiRequest(
      url: playRecordsURL,
      parameters: weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyPlayRecords(
    data: Data,
    response: HTTPURLResponse,
    scope: PlayRecordScope
  ) throws -> [PlayRecordEntry] {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }

    let code = try JSONDecoder().decode(ServiceCodePayload.self, from: data).code
    guard code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: code)
    }
    let payload = try JSONDecoder().decode(PlayRecordsPayload.self, from: data)
    let items: [PlayRecordsPayload.Item]? =
      switch scope {
      case .allTime: payload.allData
      case .lastWeek: payload.weekData
      }
    guard let items else {
      throw NeteaseCatalogError.invalidResponse
    }
    return items.map {
      PlayRecordEntry(
        track: PlaylistTrack(
          id: $0.song.id,
          name: $0.song.name,
          artists: $0.song.ar.map(\.name)
        ),
        playCount: $0.playCount
      )
    }
  }

  package static func dailyRecommendedSongsRequest(
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json = try csrfOnlyJSON(credential: credential)
    return weapiRequest(
      url: dailyRecommendedSongsURL,
      parameters: weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyDailyRecommendedSongs(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [PlaylistTrack] {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }

    let code = try JSONDecoder().decode(ServiceCodePayload.self, from: data).code
    guard code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: code)
    }
    let songs = try JSONDecoder().decode(DailyRecommendedSongsPayload.self, from: data)
      .data.dailySongs
    return songs.map {
      PlaylistTrack(id: $0.id, name: $0.name, artists: $0.ar.map(\.name))
    }
  }

  package static func dailyRecommendedPlaylistsRequest(
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json = try csrfOnlyJSON(credential: credential)
    return weapiRequest(
      url: dailyRecommendedPlaylistsURL,
      parameters: weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyDailyRecommendedPlaylists(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [DiscoveredPlaylist] {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }

    let code = try JSONDecoder().decode(ServiceCodePayload.self, from: data).code
    guard code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: code)
    }
    return try JSONDecoder().decode(DailyRecommendedPlaylistsPayload.self, from: data)
      .recommend.map { DiscoveredPlaylist(id: $0.id, name: $0.name) }
  }

  package static func personalizedPlaylistsRequest(
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json = try personalizedPlaylistsJSON(credential: credential)
    return weapiRequest(
      url: personalizedPlaylistsURL,
      parameters: weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyPersonalizedPlaylists(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [DiscoveredPlaylist] {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }

    let code = try JSONDecoder().decode(ServiceCodePayload.self, from: data).code
    guard code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: code)
    }
    return try JSONDecoder().decode(PersonalizedPlaylistsPayload.self, from: data)
      .result.map { DiscoveredPlaylist(id: $0.id, name: $0.name) }
  }

  package static func toplistsRequest(
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
    let header = try eapiHeaderJSON(headerFields)
    let json = #"{"e_r":false,"header":\#(header)}"#
    return eapiRequest(
      endpoint: toplistsEndpoint,
      json: json,
      headerFields: headerFields
    )
  }

  package static func classifyToplists(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [DiscoveredPlaylist] {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }

    let code = try JSONDecoder().decode(ServiceCodePayload.self, from: data).code
    guard code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: code)
    }
    return try JSONDecoder().decode(ToplistsPayload.self, from: data)
      .list.map { DiscoveredPlaylist(id: $0.id, name: $0.name) }
  }

  package static func similarSongsRequest(
    songID: Int64,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json = try similarSongsJSON(songID: songID, credential: credential)
    return weapiRequest(
      url: similarSongsURL,
      parameters: weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  /// Unlike the other track endpoints, this legacy path returns `artists`
  /// rather than `ar`.
  package static func classifySimilarSongs(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [PlaylistTrack] {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }

    let code = try JSONDecoder().decode(ServiceCodePayload.self, from: data).code
    guard code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: code)
    }
    return try JSONDecoder().decode(SimilarSongsPayload.self, from: data)
      .songs.map {
        PlaylistTrack(id: $0.id, name: $0.name, artists: $0.artists.map(\.name))
      }
  }

  package static func likeSongRequest(
    songID: Int64,
    liked: Bool,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json = try likeSongJSON(songID: songID, liked: liked, credential: credential)
    return weapiRequest(
      url: likeSongURL,
      parameters: weapiParameters(json: json, secretKey: secretKey),
      credential: credential,
      platformContext: true
    )
  }

  /// Success is `code == 200` only; the body carries no other useful field.
  package static func classifyLikeSong(
    data: Data,
    response: HTTPURLResponse
  ) throws {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }

    let code = try JSONDecoder().decode(ServiceCodePayload.self, from: data).code
    guard code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: code)
    }
  }

  package static func classifyAudioProbe(
    response: HTTPURLResponse
  ) -> AudioURLProbeResult {
    let redirect = response.value(forHTTPHeaderField: "Location").flatMap {
      URL(string: $0, relativeTo: response.url)?.absoluteURL
    }
    return AudioURLProbeResult(
      statusCode: response.statusCode,
      rangeResponse: response.statusCode == 206
        && response.value(forHTTPHeaderField: "Content-Range") != nil,
      contentType: response.value(forHTTPHeaderField: "Content-Type"),
      redirectScheme: redirect?.scheme,
      redirectHost: redirect?.host
    )
  }

  package static func songURLRequest(
    songID: Int64,
    quality: PlaybackQuality,
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
    let header = try eapiHeaderJSON(headerFields)
    let json =
      #"{"ids":"[\#(songID)]","level":"\#(quality.rawValue)","encodeType":"flac","e_r":false,"header":\#(header)}"#
    return eapiRequest(
      endpoint: songURLEndpoint,
      json: json,
      headerFields: headerFields
    )
  }

  package static func classifySongURL(
    data: Data,
    response: HTTPURLResponse,
    songID: Int64,
    requestedQuality: PlaybackQuality
  ) throws -> SongURLResolution {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }

    let payload = try JSONDecoder().decode(SongURLPayload.self, from: data)
    guard payload.code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: payload.code)
    }
    guard let item = payload.data?.first(where: { $0.id == songID }) else {
      throw NeteasePlaybackError.invalidResponse
    }
    guard item.code == 200, let value = item.url else {
      return .unavailable(itemCode: item.code, fee: item.fee)
    }
    guard
      let url = URL(string: value), let host = url.host?.lowercased(),
      let sourceScheme = url.scheme?.lowercased()
    else {
      throw NeteasePlaybackError.invalidResponse
    }
    let isMusic126 = host == "music.126.net" || host.hasSuffix(".music.126.net")
    let isMusic163 = host == "music.163.com" || host.hasSuffix(".music.163.com")
    guard isMusic126 || isMusic163 else {
      throw NeteasePlaybackError.unapprovedHost(host)
    }
    guard sourceScheme == "https" || (sourceScheme == "http" && isMusic126) else {
      throw NeteasePlaybackError.nonHTTPSURL(host)
    }

    return .resolved(
      ResolvedAudioAsset(
        songID: songID,
        url: url,
        sourceScheme: sourceScheme,
        requestedQuality: requestedQuality,
        actualQuality: item.level,
        format: item.type ?? item.encodeType,
        bitRate: item.br,
        byteCount: item.size,
        expiresIn: item.expi,
        fee: item.fee,
        trial: item.freeTrialInfo != nil
      )
    )
  }

  package static func lyricsProbeRequest(songID: Int64) -> URLRequest {
    let json =
      #"{"id":"\#(songID)","cp":false,"tv":0,"lv":0,"rv":0,"kv":0,"yv":0,"ytv":0,"yrv":0,"e_r":false,"header":{}}"#
    let params = NeteaseCrypto.eapi(path: lyricsEndpoint.path, json: json)
    var request = URLRequest(url: lyricsEndpoint.url)
    request.httpMethod = "POST"
    request.httpBody = FormURLEncoder.encode([("params", params)])
    request.httpShouldHandleCookies = false
    request.setValue(
      "application/x-www-form-urlencoded",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("MacEasePhase0/0.1 (macOS 15)", forHTTPHeaderField: "User-Agent")
    return request
  }

  package func probeLyrics(songID: Int64) async -> LyricsProbeOutcome {
    do {
      let (data, response) = try await urlSession.data(
        for: Self.lyricsProbeRequest(songID: songID)
      )
      return Self.classifyLyricsProbe(data: data, response: response as! HTTPURLResponse)
    } catch {
      return LyricsProbeOutcome(status: .network, setsCookie: false)
    }
  }

  package static func classifyLyricsProbe(
    data: Data,
    response: HTTPURLResponse
  ) -> LyricsProbeOutcome {
    let setsCookie = response.value(forHTTPHeaderField: "Set-Cookie") != nil
    guard (200..<300).contains(response.statusCode) else {
      return LyricsProbeOutcome(status: .http(response.statusCode), setsCookie: setsCookie)
    }
    guard let payload = try? JSONDecoder().decode(LyricsProbePayload.self, from: data) else {
      return LyricsProbeOutcome(status: .invalidResponse, setsCookie: setsCookie)
    }
    guard payload.code == 200 else {
      return LyricsProbeOutcome(status: .service(payload.code), setsCookie: setsCookie)
    }
    let status: LyricsProbeStatus =
      payload.lrc != nil || payload.yrc != nil
      ? .content
      : payload.nolyric == true || payload.uncollected == true
        ? .noLyrics : .invalidResponse
    return LyricsProbeOutcome(status: status, setsCookie: setsCookie)
  }

  private static func cookieHeader(_ credential: NeteaseCredential) -> String {
    credential.cookies
      .map { "\($0.name.rawValue)=\($0.value)" }
      .joined(separator: "; ")
  }

  private static func csrfOnlyJSON(
    credential: NeteaseCredential
  ) throws -> String {
    String(
      decoding: try JSONEncoder().encode(
        AccountStatusParameters(csrfToken: credential.csrf?.value ?? "")
      ),
      as: UTF8.self
    )
  }

  private static func userPlaylistsJSON(
    userID: Int64,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) throws -> String {
    let csrf = String(
      decoding: try JSONEncoder().encode(credential.csrf?.value ?? ""),
      as: UTF8.self
    )
    return
      #"{"uid":"\#(userID)","limit":\#(limit),"offset":\#(offset),"includeVideo":true,"csrf_token":\#(csrf)}"#
  }

  private static func songDetailsJSON(
    songIDs: [Int64],
    credential: NeteaseCredential
  ) throws -> String {
    guard !songIDs.isEmpty, songIDs.count <= songDetailRequestLimit else {
      throw NeteaseCatalogError.invalidSongDetailRequestCount(songIDs.count)
    }
    let identifiers = "[" + songIDs.map { #"{"id":\#($0)}"# }.joined(separator: ",") + "]"
    let c = String(
      decoding: try JSONEncoder().encode(identifiers),
      as: UTF8.self
    )
    let csrf = String(
      decoding: try JSONEncoder().encode(credential.csrf?.value ?? ""),
      as: UTF8.self
    )
    return #"{"c":\#(c),"csrf_token":\#(csrf)}"#
  }

  private static func likedSongIDsJSON(
    userID: Int64,
    credential: NeteaseCredential
  ) throws -> String {
    let csrf = String(
      decoding: try JSONEncoder().encode(credential.csrf?.value ?? ""),
      as: UTF8.self
    )
    return #"{"uid":"\#(userID)","csrf_token":\#(csrf)}"#
  }

  private static func playRecordsJSON(
    userID: Int64,
    scope: PlayRecordScope,
    credential: NeteaseCredential
  ) throws -> String {
    let csrf = String(
      decoding: try JSONEncoder().encode(credential.csrf?.value ?? ""),
      as: UTF8.self
    )
    return #"{"uid":"\#(userID)","type":\#(scope.rawValue),"csrf_token":\#(csrf)}"#
  }

  private static func personalizedPlaylistsJSON(
    credential: NeteaseCredential
  ) throws -> String {
    let csrf = String(
      decoding: try JSONEncoder().encode(credential.csrf?.value ?? ""),
      as: UTF8.self
    )
    return #"{"limit":30,"total":true,"n":1000,"csrf_token":\#(csrf)}"#
  }

  private static func similarSongsJSON(
    songID: Int64,
    credential: NeteaseCredential
  ) throws -> String {
    let csrf = String(
      decoding: try JSONEncoder().encode(credential.csrf?.value ?? ""),
      as: UTF8.self
    )
    return #"{"songid":\#(songID),"limit":50,"offset":0,"csrf_token":\#(csrf)}"#
  }

  /// `like` is a JSON boolean and `time` a string, per the locked `like.js`.
  private static func likeSongJSON(
    songID: Int64,
    liked: Bool,
    credential: NeteaseCredential
  ) throws -> String {
    let csrf = String(
      decoding: try JSONEncoder().encode(credential.csrf?.value ?? ""),
      as: UTF8.self
    )
    return
      #"{"alg":"itembased","trackId":\#(songID),"like":\#(liked),"time":"3","csrf_token":\#(csrf)}"#
  }

  private static func eapiHeaderFields(
    credential: NeteaseCredential,
    osVersion: String,
    buildVersion: String,
    requestID: String
  ) -> [(String, String)] {
    [
      ("osver", osVersion),
      ("os", "osx"),
      ("appver", "0.1"),
      ("buildver", buildVersion),
      ("__csrf", credential.csrf?.value ?? ""),
      ("channel", "github"),
      ("requestId", requestID),
      ("MUSIC_U", credential.musicU.value),
    ]
  }

  private static func eapiHeaderJSON(
    _ fields: [(String, String)]
  ) throws -> String {
    "{"
      + (try fields.map {
        let value = String(decoding: try JSONEncoder().encode($0.1), as: UTF8.self)
        return #""\#($0.0)":\#(value)"#
      }).joined(separator: ",") + "}"
  }

  private static func eapiRequest(
    endpoint: EndpointDescriptor,
    json: String,
    headerFields: [(String, String)]
  ) -> URLRequest {
    var request = URLRequest(url: endpoint.url)
    request.httpMethod = "POST"
    request.httpBody = FormURLEncoder.encode([
      ("params", NeteaseCrypto.eapi(path: endpoint.path, json: json))
    ])
    request.httpShouldHandleCookies = false
    request.setValue(
      "application/x-www-form-urlencoded",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("MacEasePhase0/0.1 (macOS 15)", forHTTPHeaderField: "User-Agent")
    request.setValue(
      headerFields.map { "\($0.0)=\($0.1)" }.joined(separator: "; "),
      forHTTPHeaderField: "Cookie"
    )
    return request
  }

  private static func weapiParameters(
    json: String,
    secretKey: String?
  ) -> WeAPIParameters {
    secretKey.map { NeteaseCrypto.weapi(json: json, secretKey: $0) }
      ?? NeteaseCrypto.weapi(json: json)
  }

  /// MacEase's own platform identity, matching what the already-verified eapi
  /// path sends. It states the real OS and MacEase's own version/channel; it
  /// never claims to be the official NetEase client and carries no fabricated
  /// device or tracking identifier.
  private static func platformCookies() -> String {
    "os=osx; osver=\(osVersion); appver=0.1; channel=github"
  }

  private static func weapiRequest(
    url: URL,
    parameters: WeAPIParameters,
    credential: NeteaseCredential,
    platformContext: Bool = false
  ) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = FormURLEncoder.encode([
      ("params", parameters.params),
      ("encSecKey", parameters.encSecKey),
    ])
    request.httpShouldHandleCookies = false
    request.setValue(
      "application/x-www-form-urlencoded",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
    request.setValue(
      platformContext
        ? cookieHeader(credential) + "; " + platformCookies()
        : cookieHeader(credential),
      forHTTPHeaderField: "Cookie"
    )
    return request
  }

  private static var osVersion: String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion)"
  }

  private static func requestID(timestamp: TimeInterval) -> String {
    "\(Int(timestamp * 1000))_\(String(format: "%04d", Int.random(in: 0..<1000)))"
  }
}

struct FormURLEncoder {
  private static let hex = Array("0123456789ABCDEF".utf8)

  static func encode(_ fields: [(String, String)]) -> Data {
    var output = Data()
    for (index, field) in fields.enumerated() {
      if index > 0 { output.append(0x26) }
      append(field.0, to: &output)
      output.append(0x3d)
      append(field.1, to: &output)
    }
    return output
  }

  private static func append(_ value: String, to output: inout Data) {
    for byte in value.utf8 {
      switch byte {
      case 0x30...0x39, 0x41...0x5a, 0x61...0x7a, 0x2a, 0x2d, 0x2e, 0x5f:
        output.append(byte)
      case 0x20:
        output.append(0x2b)
      default:
        output.append(0x25)
        output.append(hex[Int(byte >> 4)])
        output.append(hex[Int(byte & 0x0f)])
      }
    }
  }
}

private struct AccountStatusParameters: Encodable {
  let csrfToken: String

  enum CodingKeys: String, CodingKey {
    case csrfToken = "csrf_token"
  }
}

private struct ServiceCodePayload: Decodable {
  let code: Int
}

private struct AccountStatusPayload: Decodable {
  let profile: Profile?

  enum CodingKeys: CodingKey {
    case profile
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard container.contains(.profile) else {
      throw DecodingError.keyNotFound(
        CodingKeys.profile,
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Missing profile"
        )
      )
    }
    profile = try container.decodeIfPresent(Profile.self, forKey: .profile)
  }

  struct Profile: Decodable {
    let userId: Int64
  }
}

private struct UserPlaylistsPayload: Decodable {
  let more: Bool
  let playlist: [Item]

  struct Item: Decodable {
    let id: Int64
    let name: String
    let trackCount: Int
    let creator: Creator
  }

  struct Creator: Decodable {
    let userId: Int64
  }
}

private struct PlaylistDetailPayload: Decodable {
  let playlist: Playlist

  struct Playlist: Decodable {
    let id: Int64
    let name: String
    let trackIds: [TrackID]
  }

  struct TrackID: Decodable {
    let id: Int64
  }
}

private struct SongDetailsPayload: Decodable {
  let songs: [Song]

  struct Song: Decodable {
    let id: Int64
    let name: String
    let ar: [Artist]
  }

  struct Artist: Decodable {
    let name: String
  }
}

private struct LikedSongIDsPayload: Decodable {
  let ids: [Int64]
}

private struct PlayRecordsPayload: Decodable {
  let weekData: [Item]?
  let allData: [Item]?

  struct Item: Decodable {
    let playCount: Int
    let song: Song
  }

  struct Song: Decodable {
    let id: Int64
    let name: String
    let ar: [Artist]
  }

  struct Artist: Decodable {
    let name: String
  }
}

private struct DailyRecommendedSongsPayload: Decodable {
  let data: Inner

  struct Inner: Decodable {
    let dailySongs: [Song]
  }

  struct Song: Decodable {
    let id: Int64
    let name: String
    let ar: [Artist]
  }

  struct Artist: Decodable {
    let name: String
  }
}

private struct DailyRecommendedPlaylistsPayload: Decodable {
  let recommend: [Item]

  struct Item: Decodable {
    let id: Int64
    let name: String
  }
}

private struct PersonalizedPlaylistsPayload: Decodable {
  let result: [Item]

  struct Item: Decodable {
    let id: Int64
    let name: String
  }
}

private struct ToplistsPayload: Decodable {
  let list: [Item]

  struct Item: Decodable {
    let id: Int64
    let name: String
  }
}

private struct SimilarSongsPayload: Decodable {
  let songs: [Song]

  struct Song: Decodable {
    let id: Int64
    let name: String
    let artists: [Artist]
  }

  struct Artist: Decodable {
    let name: String
  }
}

private struct LyricsProbePayload: Decodable {
  let code: Int
  let lrc: LyricsMarker?
  let yrc: LyricsMarker?
  let nolyric: Bool?
  let uncollected: Bool?

  struct LyricsMarker: Decodable {}
}

private struct SongURLPayload: Decodable {
  let code: Int
  let data: [Item]?

  struct Item: Decodable {
    let id: Int64
    let url: String?
    let code: Int
    let level: String?
    let type: String?
    let encodeType: String?
    let br: Int?
    let size: Int64?
    let expi: Int?
    let fee: Int?
    let freeTrialInfo: Trial?

    struct Trial: Decodable {}
  }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
  }
}

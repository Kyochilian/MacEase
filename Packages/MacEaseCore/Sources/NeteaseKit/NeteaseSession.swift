import Foundation

public struct NeteaseAccount: Equatable, Sendable, Codable {
  public let userID: Int64
  public let nickname: String?
  public let avatarURL: URL?
  public let vipType: Int?

  package init(userID: Int64, nickname: String? = nil, avatarURL: URL? = nil, vipType: Int? = nil) {
    self.userID = userID
    self.nickname = nickname
    self.avatarURL = avatarURL
    self.vipType = vipType
  }
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
  public let message: String?

  public init(source: Source, statusCode: Int, message: String? = nil) {
    self.source = source
    self.statusCode = statusCode
    let text = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let text, !text.isEmpty, text.count <= 512,
      !["music_u", "__csrf", "cookie", "token", "http://", "https://"].contains(where: {
        text.lowercased().contains($0)
      }),
      text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    {
      self.message = text
    } else {
      self.message = nil
    }
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.source == rhs.source && lhs.statusCode == rhs.statusCode
  }
}

public enum PlaybackQuality: String, CaseIterable, Hashable, Sendable, Codable {
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
  public var fileMD5: String? = nil
}

public enum SongURLResolution: Equatable, Sendable {
  case resolved(ResolvedAudioAsset)
  case unavailable(itemCode: Int, fee: Int?)
}

public struct UserPlaylist: Equatable, Sendable, Codable {
  public let id: Int64
  public var name: String
  public var trackCount: Int
  public var owned: Bool
  /// `true` and `false` are service values 10 and 0 respectively. Missing or
  /// unrecognised response values stay nil, so MacEase never offers a privacy
  /// write from a guess.
  public var isPrivate: Bool?
  public var description: String?
  public var tags: [String]?
  public var artworkURL: URL?
  public var creatorName: String?
  public var specialType: Int?
  public var isSubscribed: Bool?
  package var isLikedSongs: Bool { specialType == 5 }
  package var canEdit: Bool { owned && specialType == 0 }

  package init(
    id: Int64,
    name: String,
    trackCount: Int,
    owned: Bool,
    isPrivate: Bool? = nil,
    description: String? = nil,
    tags: [String]? = nil,
    artworkURL: URL? = nil,
    creatorName: String? = nil,
    specialType: Int? = 0,
    isSubscribed: Bool? = nil
  ) {
    self.id = id
    self.name = name
    self.trackCount = trackCount
    self.owned = owned
    self.isPrivate = isPrivate
    self.description = description
    self.tags = tags
    self.artworkURL = artworkURL
    self.creatorName = creatorName
    self.specialType = specialType
    self.isSubscribed = isSubscribed
  }
}

public struct UserPlaylistPage: Equatable, Sendable {
  public let playlists: [UserPlaylist]
  public let more: Bool

  package init(playlists: [UserPlaylist], more: Bool) {
    self.playlists = playlists
    self.more = more
  }
}

package struct PlaylistDetail: Equatable, Sendable {
  package let id: Int64
  package let name: String
  package let trackIDs: [Int64]
  package let metadata: UserPlaylist?
  package let creatorID: Int64?
  package let tracks: [Track]

  package init(
    id: Int64, name: String, trackIDs: [Int64], metadata: UserPlaylist? = nil,
    creatorID: Int64? = nil, tracks: [Track] = []
  ) {
    self.id = id
    self.name = name
    self.trackIDs = trackIDs
    self.metadata = metadata
    self.creatorID = creatorID
    self.tracks = tracks
  }
}

package enum PlayRecordScope: Int, CaseIterable, Sendable {
  case allTime = 0
  case lastWeek = 1
}

package struct PlayRecordEntry: Equatable, Sendable {
  package let track: Track
  package let playCount: Int

  package init(track: Track, playCount: Int) {
    self.track = track
    self.playCount = playCount
  }
}

package struct DiscoveredPlaylist: Equatable, Sendable, Identifiable {
  package let id: Int64
  package let name: String
  /// The cover, when the response carried one. The recommendation endpoints
  /// omit it on some rows and the radar family is nothing but a name and a
  /// cover, so it is optional rather than required.
  package let artworkURL: URL?

  package init(id: Int64, name: String, artworkURL: URL? = nil) {
    self.id = id
    self.name = name
    self.artworkURL = artworkURL
  }
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

/// Transport-level refusals that carry no service code of their own.
public enum NeteaseTransportError: Error, Equatable, Sendable {
  /// The task completed with a response that is not HTTP, so there is no
  /// status line to classify. Never a reason to terminate the process.
  case nonHTTPResponse
  case invalidURL
}

public struct AudioURLProbeResult: Equatable, Sendable {
  public let statusCode: Int
  public let rangeResponse: Bool
  public let contentType: String?
  public let redirectScheme: String?
  public let redirectHost: String?
}

package enum PlaylistTrackEdit: String, Sendable {
  case add
  case del
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
    string: "https://music.163.com/weapi/nuser/account/get"
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
  private static let createPlaylistURL = URL(
    string: "https://music.163.com/weapi/playlist/create"
  )!
  private static let deletePlaylistURL = URL(
    string: "https://music.163.com/weapi/playlist/remove"
  )!
  private static let manipulateTracksEndpoint = EndpointDescriptor(
    path: "/api/playlist/manipulate/tracks",
    url: URL(
      string: "https://interfacepc.music.163.com/eapi/playlist/manipulate/tracks"
    )!
  )
  private static let subscribePlaylistEndpoint = EndpointDescriptor(
    path: "/api/playlist/subscribe",
    url: URL(string: "https://interfacepc.music.163.com/eapi/playlist/subscribe")!
  )
  private static let unsubscribePlaylistEndpoint = EndpointDescriptor(
    path: "/api/playlist/unsubscribe",
    url: URL(string: "https://interfacepc.music.163.com/eapi/playlist/unsubscribe")!
  )

  /// How long a single request may wait for the next byte before the task
  /// fails. Every NetEase endpoint here answers in well under a second on a
  /// working connection; a request still open after this is not slow, it is
  /// stuck. There is no retry, so this is a stop, not a backoff.
  package static let requestTimeoutSeconds: TimeInterval = 20

  /// The ceiling on one request from start to finish. `ephemeral` defaults to
  /// seven days, which for an app that never retries means a wedged request
  /// holds its operation slot until the process ends.
  package static let resourceTimeoutSeconds: TimeInterval = 60

  private let redirectBlocker: RedirectBlocker
  let urlSession: URLSession
  private let checkToken: @Sendable () async throws -> String
  private let diagnostics: @Sendable (RequestDiagnostic) -> Void
  private var auxiliaryCredential: NeteaseCredential?
  var auxiliaryGeneration = UUID()
  private var nmtid: String?
  private var nmtidResponsesRemaining = 3

  package func resetSessionContext() {
    auxiliaryCredential = nil
    auxiliaryGeneration = UUID()
    nmtid = nil
    nmtidResponsesRemaining = 3
  }

  func requestGeneration(credential: NeteaseCredential?) -> UUID {
    if auxiliaryCredential != credential {
      resetSessionContext()
      auxiliaryCredential = credential
    }
    return auxiliaryGeneration
  }

  /// api-enhanced d55d92cd0031d7c7746b7068faecd7ade1d354ac, util/request.js.
  /// Sampling uses ordinary successful HTTP responses, including service rejections.
  /// It never sends an extra request or changes the authenticated identity.
  func send(
    credential: NeteaseCredential?,
    build: (String?) throws -> URLRequest
  ) async throws -> (Data, URLResponse) {
    let started = ContinuousClock.now
    try Task.checkCancellation()
    let generation = requestGeneration(credential: credential)
    let token = nmtid ?? (nmtidResponsesRemaining == 0 ? Self.randomNMTID() : nil)
    var request = try build(token)
    let isEAPI = request.url?.path.hasPrefix("/eapi/") == true
    if !isEAPI {
      let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
      request.setValue(
        cookie + (cookie.isEmpty ? "" : "; ") + "NMTID=" + (nmtid ?? Self.randomNMTID()),
        forHTTPHeaderField: "Cookie"
      )
    }
    let prepared = ContinuousClock.now
    let observer = RequestDiagnostics(request: request, emit: diagnostics)
    let result: (Data, URLResponse)
    do {
      result = try await urlSession.data(for: request, delegate: observer)
      var event = observer.event(phase: "complete")
      event.totalMS = Self.milliseconds(started.duration(to: .now))
      event.preparationMS = Self.milliseconds(started.duration(to: prepared))
      event.status = (result.1 as? HTTPURLResponse)?.statusCode
      event.bytes = Int64(result.0.count)
      diagnostics(event)
    } catch {
      var event = observer.event(phase: "complete")
      event.totalMS = Self.milliseconds(started.duration(to: .now))
      event.preparationMS = Self.milliseconds(started.duration(to: prepared))
      event.errorCode = (error as NSError).code
      diagnostics(event)
      throw error
    }
    if !Task.isCancelled, generation == auxiliaryGeneration, isEAPI,
      token == nil, nmtid == nil, nmtidResponsesRemaining > 0,
      let response = result.1 as? HTTPURLResponse,
      (200..<300).contains(response.statusCode),
      response.url == request.url
    {
      nmtidResponsesRemaining -= 1
      nmtid = Self.responseNMTID(response)
    }
    return result
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }

  private static func randomNMTID() -> String {
    "00O" + (0..<19).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
  }

  package static func responseNMTID(_ response: HTTPURLResponse) -> String? {
    guard let url = response.url, url.scheme == "https",
      let host = url.host?.lowercased(),
      host == "music.163.com" || host.hasSuffix(".music.163.com"),
      let header = response.value(forHTTPHeaderField: "Set-Cookie")
    else { return nil }
    let rawValues = header.matches(of: #/(?:^|[,;]\s*)NMTID=([^;,]*)/#)
      .map { String($0.1) }
    guard Set(rawValues).count == 1 else { return nil }
    let values = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: url)
      .filter {
        let domain = ($0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain)
          .lowercased()
        return $0.name == "NMTID" && $0.path == "/"
          && (domain == host || domain == "music.163.com")
          && ($0.expiresDate.map { $0 > Date() } ?? true)
      }.map(\.value)
    guard let value = values.first, Set(values).count == 1,
      value == rawValues.first, value.count <= 512,
      NeteaseCookie.isValidValue(value)
    else { return nil }
    return value
  }

  public init() {
    self.init(configuration: URLSessionConfiguration.ephemeral)
  }

  /// Package-scoped so tests can install a `URLProtocol` stub. Callers cannot
  /// widen the cookie, cache or timeout policy: all are pinned here regardless
  /// of the configuration passed in.
  package init(
    configuration: URLSessionConfiguration,
    checkToken: @escaping @Sendable () async throws -> String = {
      try await NeteaseWatchman().token()
    },
    diagnostics: @escaping @Sendable (RequestDiagnostic) -> Void = RequestDiagnostic.log
  ) {
    self.checkToken = checkToken
    self.diagnostics = diagnostics
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = Self.requestTimeoutSeconds
    configuration.timeoutIntervalForResource = Self.resourceTimeoutSeconds
    // A request that fails because the network is down must surface as a
    // failure the user can see and act on, not sit in a queue waiting for
    // connectivity to return and then fire without being asked.
    configuration.waitsForConnectivity = false
    let redirectBlocker = RedirectBlocker()
    self.redirectBlocker = redirectBlocker
    self.urlSession = URLSession(
      configuration: configuration,
      delegate: redirectBlocker,
      delegateQueue: nil
    )
  }

  /// Every endpoint funnels its `URLResponse` through here. A non-HTTP
  /// response is a transport fault with no status code to classify, and the
  /// network is an untrusted boundary, so it is never force-cast.
  static func requireHTTPResponse(
    _ response: URLResponse
  ) throws -> HTTPURLResponse {
    guard let http = response as? HTTPURLResponse else {
      throw NeteaseTransportError.nonHTTPResponse
    }
    return http
  }

  public func accountStatus(
    credential: NeteaseCredential
  ) async throws -> AccountSessionState {
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.accountStatusRequest(credential: credential)
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    return try Self.classifyAccountStatus(
      data: data,
      response: httpResponse
    )
  }

  public func userPlaylists(
    userID: Int64,
    limit: Int = 30,
    offset: Int = 0,
    credential: NeteaseCredential
  ) async throws -> UserPlaylistPage {
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.userPlaylistsRequest(
        userID: userID,
        limit: limit,
        offset: offset,
        credential: credential
      )
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    return try Self.classifyUserPlaylists(
      data: data,
      response: httpResponse,
      userID: userID
    )
  }

  package func playlistDetail(
    playlistID: Int64,
    credential: NeteaseCredential
  ) async throws -> PlaylistDetail {
    let timestamp = Date().timeIntervalSince1970
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.playlistDetailRequest(
        playlistID: playlistID,
        credential: credential,
        osVersion: Self.osVersion,
        buildVersion: String(Int(timestamp)),
        requestID: Self.requestID(timestamp: timestamp),
        nmtid: nmtid
      )
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    return try Self.classifyPlaylistDetail(
      data: data,
      response: httpResponse,
      playlistID: playlistID
    )
  }

  package func songDetails(
    songIDs: [Int64],
    credential: NeteaseCredential
  ) async throws -> [Track] {
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.songDetailsRequest(
        songIDs: songIDs,
        credential: credential
      )
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    return try Self.classifySongDetails(
      data: data,
      response: httpResponse,
      songIDs: songIDs
    )
  }

  package func likedSongIDs(
    userID: Int64,
    credential: NeteaseCredential
  ) async throws -> [Int64] {
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.likedSongIDsRequest(
        userID: userID,
        credential: credential
      )
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    return try Self.classifyLikedSongIDs(
      data: data,
      response: httpResponse
    )
  }

  package func playRecords(
    userID: Int64,
    scope: PlayRecordScope,
    credential: NeteaseCredential
  ) async throws -> [PlayRecordEntry] {
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.playRecordsRequest(
        userID: userID,
        scope: scope,
        credential: credential
      )
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    return try Self.classifyPlayRecords(
      data: data,
      response: httpResponse,
      scope: scope
    )
  }

  package func dailyRecommendedSongs(
    credential: NeteaseCredential
  ) async throws -> [Track] {
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.dailyRecommendedSongsRequest(credential: credential)
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    return try Self.classifyDailyRecommendedSongs(
      data: data,
      response: httpResponse
    )
  }

  package func dailyRecommendedPlaylists(
    credential: NeteaseCredential
  ) async throws -> [DiscoveredPlaylist] {
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.dailyRecommendedPlaylistsRequest(credential: credential)
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    return try Self.classifyDailyRecommendedPlaylists(
      data: data,
      response: httpResponse
    )
  }

  package func personalizedPlaylists(
    credential: NeteaseCredential
  ) async throws -> [DiscoveredPlaylist] {
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.personalizedPlaylistsRequest(credential: credential)
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    return try Self.classifyPersonalizedPlaylists(
      data: data,
      response: httpResponse
    )
  }

  package func toplists(
    credential: NeteaseCredential
  ) async throws -> [DiscoveredPlaylist] {
    let timestamp = Date().timeIntervalSince1970
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.toplistsRequest(
        credential: credential,
        osVersion: Self.osVersion,
        buildVersion: String(Int(timestamp)),
        requestID: Self.requestID(timestamp: timestamp),
        nmtid: nmtid
      )
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    return try Self.classifyToplists(
      data: data,
      response: httpResponse
    )
  }

  package func similarSongs(
    songID: Int64,
    credential: NeteaseCredential
  ) async throws -> [Track] {
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.similarSongsRequest(
        songID: songID,
        credential: credential
      )
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    return try Self.classifySimilarSongs(
      data: data,
      response: httpResponse
    )
  }

  /// Mutates the server-side liked-songs list.
  package func setSongLiked(
    songID: Int64,
    liked: Bool,
    credential: NeteaseCredential
  ) async throws {
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.likeSongRequest(
        songID: songID,
        liked: liked,
        credential: credential
      )
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    try Self.classifyLikeSong(
      data: data,
      response: httpResponse
    )
  }

  /// Creation confirms the new identity so the user can immediately add songs.
  package func createPlaylist(
    name: String,
    isPrivate: Bool,
    credential: NeteaseCredential
  ) async throws -> UserPlaylist {
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.createPlaylistRequest(
        name: name,
        isPrivate: isPrivate,
        credential: credential
      )
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    try Self.requireSuccess(
      data: data,
      response: httpResponse
    )
    let created = try JSONDecoder().decode(CreatedPlaylistPayload.self, from: data)
    guard let id = created.playlist?.id ?? created.id, id > 0 else {
      throw NeteaseCatalogError.invalidResponse
    }
    return UserPlaylist(
      id: id, name: created.playlist?.name ?? name, trackCount: 0,
      owned: true, isPrivate: isPrivate
    )
  }

  package func deletePlaylist(
    playlistID: Int64,
    credential: NeteaseCredential
  ) async throws {
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.deletePlaylistRequest(
        playlistID: playlistID,
        credential: credential
      )
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    try Self.requireSuccess(
      data: data,
      response: httpResponse
    )
  }

  package func editPlaylistTracks(
    _ edit: PlaylistTrackEdit,
    playlistID: Int64,
    trackIDs: [Int64],
    credential: NeteaseCredential
  ) async throws {
    let generation = requestGeneration(credential: credential)
    do {
      try await sendPlaylistTracks(
        edit, playlistID: playlistID, trackIDs: trackIDs, credential: credential)
      return
    } catch let error as NeteaseServiceError
      where error.source == .service && error.statusCode == 512
    {
      // 512 is an explicit rejection. Read back before the upstream's one
      // duplicate-ID compatibility attempt, so an already applied edit is not repeated.
      guard generation == auxiliaryGeneration else {
        throw NeteaseWritePreparationError.verificationUnavailable
      }
      let current: PlaylistDetail
      do {
        current = try await playlistDetail(playlistID: playlistID, credential: credential)
      } catch { throw NeteaseServiceError(source: .service, statusCode: 512) }
      guard generation == auxiliaryGeneration, !Task.isCancelled else {
        throw NeteaseWritePreparationError.verificationUnavailable
      }
      let existing = Set(current.trackIDs)
      let remaining = trackIDs.filter {
        edit == .add ? !existing.contains($0) : existing.contains($0)
      }
      guard !remaining.isEmpty else { return }
      try await sendPlaylistTracks(
        edit, playlistID: playlistID, trackIDs: remaining + remaining, credential: credential)
    }
  }

  private func sendPlaylistTracks(
    _ edit: PlaylistTrackEdit, playlistID: Int64, trackIDs: [Int64], credential: NeteaseCredential
  ) async throws {
    let timestamp = Date().timeIntervalSince1970
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.editPlaylistTracksRequest(
        edit,
        playlistID: playlistID,
        trackIDs: trackIDs,
        credential: credential,
        osVersion: Self.osVersion,
        buildVersion: String(Int(timestamp)),
        requestID: Self.requestID(timestamp: timestamp),
        nmtid: nmtid
      )
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    try Self.requireSuccess(
      data: data,
      response: httpResponse
    )
  }

  package func renamePlaylist(
    playlistID: Int64,
    name: String,
    credential: NeteaseCredential
  ) async throws {
    let timestamp = Date().timeIntervalSince1970
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.renamePlaylistRequest(
        playlistID: playlistID,
        name: name,
        credential: credential,
        osVersion: Self.osVersion,
        buildVersion: String(Int(timestamp)),
        requestID: Self.requestID(timestamp: timestamp),
        nmtid: nmtid
      )
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    try Self.requireSuccess(
      data: data,
      response: httpResponse
    )
  }

  /// Subscribes to or unsubscribes from someone else's playlist.
  package func setPlaylistSubscribed(
    _ subscribed: Bool,
    playlistID: Int64,
    credential: NeteaseCredential
  ) async throws {
    let generation = requestGeneration(credential: credential)
    let token: String
    do {
      token = try await checkToken()
      try Task.checkCancellation()
      guard !token.isEmpty, token.count <= 4096, NeteaseCookie.isValidValue(token) else {
        throw NeteaseWritePreparationError.verificationUnavailable
      }
    } catch {
      throw NeteaseWritePreparationError.verificationUnavailable
    }
    guard generation == auxiliaryGeneration else {
      throw NeteaseWritePreparationError.verificationUnavailable
    }
    let timestamp = Date().timeIntervalSince1970
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.subscribePlaylistRequest(
        subscribed,
        playlistID: playlistID,
        credential: credential,
        osVersion: Self.osVersion,
        buildVersion: String(Int(timestamp)),
        requestID: Self.requestID(timestamp: timestamp),
        nmtid: nmtid,
        checkToken: token
      )
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    try Self.requireSuccess(
      data: data,
      response: httpResponse
    )
  }

  /// The song's lyric document (1 request).
  ///
  /// The account credential lets the service apply that account's translation
  /// entitlement when deciding whether `tlyric` is returned.
  package func lyrics(
    songID: Int64,
    credential: NeteaseCredential
  ) async throws -> Lyrics {
    let timestamp = Date().timeIntervalSince1970
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.lyricsRequest(
        songID: songID,
        credential: credential,
        osVersion: Self.osVersion,
        buildVersion: String(Int(timestamp)),
        requestID: Self.requestID(timestamp: timestamp),
        nmtid: nmtid
      )
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    return try Self.classifyLyrics(data: data, response: httpResponse)
  }

  public func resolveSongURL(
    songID: Int64,
    quality: PlaybackQuality,
    credential: NeteaseCredential
  ) async throws -> SongURLResolution {
    let timestamp = Date().timeIntervalSince1970
    let (data, response) = try await send(credential: credential) { nmtid in
      try Self.songURLRequest(
        songID: songID,
        quality: quality,
        credential: credential,
        osVersion: Self.osVersion,
        buildVersion: String(Int(timestamp)),
        requestID: Self.requestID(timestamp: timestamp),
        nmtid: nmtid
      )
    }
    let httpResponse = try Self.requireHTTPResponse(response)
    return try Self.classifySongURL(
      data: data,
      response: httpResponse,
      songID: songID,
      requestedQuality: quality
    )
  }

  public func probeAudioURL(_ asset: ResolvedAudioAsset) async throws -> AudioURLProbeResult {
    let (bytes, response) = try await urlSession.bytes(
      for: Self.audioProbeRequest(asset: asset)
    )
    bytes.task.cancel()
    return Self.classifyAudioProbe(response: try Self.requireHTTPResponse(response))
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
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyAccountStatus(
    data: Data,
    response: HTTPURLResponse
  ) throws -> AccountSessionState {
    try requireSuccess(data: data, response: response)
    let payload = try JSONDecoder().decode(AccountStatusPayload.self, from: data)
    guard let profile = payload.profile else {
      return .signedOut
    }
    guard profile.userId > 0 else { throw NeteaseAuthError.invalidResponse }
    return .authenticated(
      NeteaseAccount(
        userID: profile.userId, nickname: profile.nickname,
        avatarURL: NeteaseArtworkURL.approved(profile.avatarUrl), vipType: profile.vipType
      ))
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
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyUserPlaylists(
    data: Data,
    response: HTTPURLResponse,
    userID: Int64
  ) throws -> UserPlaylistPage {
    try requireSuccess(data: data, response: response)
    let payload = try JSONDecoder().decode(UserPlaylistsPayload.self, from: data)
    return UserPlaylistPage(
      playlists: payload.playlist.map { item in
        let isPrivate: Bool?
        switch item.privacy {
        case 10: isPrivate = true
        case 0: isPrivate = false
        default: isPrivate = nil
        }
        return UserPlaylist(
          id: item.id,
          name: item.name,
          trackCount: item.trackCount,
          owned: item.creator.userId == userID,
          isPrivate: isPrivate,
          description: item.description, tags: item.tags,
          artworkURL: NeteaseArtworkURL.approved(item.coverImgUrl),
          creatorName: item.creator.nickname, specialType: item.specialType,
          isSubscribed: item.subscribed
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
    requestID: String,
    nmtid: String? = nil
  ) throws -> URLRequest {
    let headerFields = eapiHeaderFields(
      credential: credential,
      osVersion: osVersion,
      buildVersion: buildVersion,
      requestID: requestID,
      nmtid: nmtid
    )
    let header = try eapiHeaderJSON(headerFields)
    let json =
      #"{"id":\#(playlistID),"n":100000,"s":8,"e_r":false,"header":\#(header)}"#
    return try eapiFormRequest(
      path: playlistDetailEndpoint.path,
      json: json,
      headerFields: headerFields,
      url: playlistDetailEndpoint.url
    )
  }

  package static func classifyPlaylistDetail(
    data: Data,
    response: HTTPURLResponse,
    playlistID: Int64
  ) throws -> PlaylistDetail {
    try requireSuccess(data: data, response: response)
    let payload = try JSONDecoder().decode(PlaylistDetailPayload.self, from: data)
    let playlist = payload.playlist
    guard playlist.id == playlistID else {
      throw NeteaseCatalogError.invalidResponse
    }
    var tracks = Dictionary(
      (playlist.tracks ?? []).map { ($0.id, $0.track) },
      uniquingKeysWith: { first, _ in first })
    for privilege in payload.privileges ?? [] {
      if let id = privilege.id { tracks[id]?.privilege = privilege.value }
    }
    return PlaylistDetail(
      id: playlist.id,
      name: playlist.name,
      trackIDs: playlist.trackIds.map(\.id),
      metadata: UserPlaylist(
        id: playlist.id, name: playlist.name, trackCount: playlist.trackIds.count, owned: false,
        isPrivate: playlist.privacy == 10 ? true : (playlist.privacy == 0 ? false : nil),
        description: playlist.description, tags: playlist.tags,
        artworkURL: NeteaseArtworkURL.approved(playlist.coverImgUrl),
        creatorName: playlist.creator?.nickname, specialType: playlist.specialType,
        isSubscribed: playlist.subscribed
      ),
      creatorID: playlist.creator?.userId,
      tracks: playlist.trackIds.compactMap { tracks[$0.id] }
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
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifySongDetails(
    data: Data,
    response: HTTPURLResponse,
    songIDs: [Int64]
  ) throws -> [Track] {
    try requireSuccess(data: data, response: response)
    let payload = try JSONDecoder().decode(SongDetailsPayload.self, from: data)
    var tracksByID: [Int64: Track] = [:]
    for song in payload.songs {
      tracksByID[song.id] = song.track
    }
    for privilege in payload.privileges ?? [] {
      if let id = privilege.id { tracksByID[id]?.privilege = privilege.value }
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
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyLikedSongIDs(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [Int64] {
    try requireSuccess(data: data, response: response)
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
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyPlayRecords(
    data: Data,
    response: HTTPURLResponse,
    scope: PlayRecordScope
  ) throws -> [PlayRecordEntry] {
    try requireSuccess(data: data, response: response)
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
      PlayRecordEntry(track: $0.song.track, playCount: $0.playCount)
    }
  }

  package static func dailyRecommendedSongsRequest(
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json = try csrfOnlyJSON(credential: credential)
    return weapiRequest(
      url: dailyRecommendedSongsURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyDailyRecommendedSongs(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [Track] {
    try requireSuccess(data: data, response: response)
    let songs = try JSONDecoder().decode(DailyRecommendedSongsPayload.self, from: data)
      .data.dailySongs
    return songs.map { $0.track }
  }

  package static func dailyRecommendedPlaylistsRequest(
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json = try csrfOnlyJSON(credential: credential)
    return weapiRequest(
      url: dailyRecommendedPlaylistsURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyDailyRecommendedPlaylists(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [DiscoveredPlaylist] {
    try requireSuccess(data: data, response: response)
    return try JSONDecoder().decode(DailyRecommendedPlaylistsPayload.self, from: data)
      .recommend.map(\.playlist)
  }

  package static func personalizedPlaylistsRequest(
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json = try personalizedPlaylistsJSON(credential: credential)
    return weapiRequest(
      url: personalizedPlaylistsURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  package static func classifyPersonalizedPlaylists(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [DiscoveredPlaylist] {
    try requireSuccess(data: data, response: response)
    return try JSONDecoder().decode(PersonalizedPlaylistsPayload.self, from: data)
      .result.map(\.playlist)
  }

  package static func toplistsRequest(
    credential: NeteaseCredential,
    osVersion: String,
    buildVersion: String,
    requestID: String,
    nmtid: String? = nil
  ) throws -> URLRequest {
    let headerFields = eapiHeaderFields(
      credential: credential,
      osVersion: osVersion,
      buildVersion: buildVersion,
      requestID: requestID,
      nmtid: nmtid
    )
    let header = try eapiHeaderJSON(headerFields)
    let json = #"{"e_r":false,"header":\#(header)}"#
    return try eapiFormRequest(
      path: toplistsEndpoint.path,
      json: json,
      headerFields: headerFields,
      url: toplistsEndpoint.url
    )
  }

  package static func classifyToplists(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [DiscoveredPlaylist] {
    try requireSuccess(data: data, response: response)
    return try JSONDecoder().decode(ToplistsPayload.self, from: data)
      .list.map(\.playlist)
  }

  package static func similarSongsRequest(
    songID: Int64,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let json = try similarSongsJSON(songID: songID, credential: credential)
    return weapiRequest(
      url: similarSongsURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential
    )
  }

  /// Unlike the other track endpoints, this legacy path returns `artists`
  /// rather than `ar`.
  package static func classifySimilarSongs(
    data: Data,
    response: HTTPURLResponse
  ) throws -> [Track] {
    try requireSuccess(data: data, response: response)
    return try JSONDecoder().decode(SimilarSongsPayload.self, from: data)
      .songs.map { $0.track }
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
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential,
      platformContext: true
    )
  }

  /// Success is `code == 200` only; the body carries no other useful field.
  package static func classifyLikeSong(
    data: Data,
    response: HTTPURLResponse
  ) throws {
    try requireSuccess(data: data, response: response)
  }

  /// `privacy` is `"10"` for a private playlist and `"0"` for an ordinary one,
  /// sent as strings. That is what `module/playlist_create.js` in
  /// `api-enhanced@a7e8d48` sends, over weapi, and it is the only verified way
  /// MacEase has of making a playlist private at all.
  package static func createPlaylistRequest(
    name: String,
    isPrivate: Bool,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let encodedName = String(decoding: try JSONEncoder().encode(name), as: UTF8.self)
    let csrf = try csrfJSONValue(credential)
    let json =
      #"{"name":\#(encodedName),"privacy":"\#(isPrivate ? 10 : 0)","#
      + #""type":"NORMAL","csrf_token":\#(csrf)}"#
    return weapiRequest(
      url: createPlaylistURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential,
      platformContext: true
    )
  }

  package static func deletePlaylistRequest(
    playlistID: Int64,
    credential: NeteaseCredential,
    secretKey: String? = nil
  ) throws -> URLRequest {
    let ids = String(
      decoding: try JSONEncoder().encode("[\(playlistID)]"),
      as: UTF8.self
    )
    let csrf = try csrfJSONValue(credential)
    let json = #"{"ids":\#(ids),"csrf_token":\#(csrf)}"#
    return weapiRequest(
      url: deletePlaylistURL,
      parameters: try weapiParameters(json: json, secretKey: secretKey),
      credential: credential,
      platformContext: true
    )
  }

  package static func editPlaylistTracksRequest(
    _ edit: PlaylistTrackEdit,
    playlistID: Int64,
    trackIDs: [Int64],
    credential: NeteaseCredential,
    osVersion: String,
    buildVersion: String,
    requestID: String,
    nmtid: String? = nil
  ) throws -> URLRequest {
    guard !trackIDs.isEmpty else {
      throw NeteaseCatalogError.invalidSongDetailRequestCount(0)
    }
    let headerFields = eapiHeaderFields(
      credential: credential,
      osVersion: osVersion,
      buildVersion: buildVersion,
      requestID: requestID,
      nmtid: nmtid
    )
    let header = try eapiHeaderJSON(headerFields)
    let list = "[" + trackIDs.map(String.init).joined(separator: ",") + "]"
    let encodedList = String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
    let json =
      #"{"op":"\#(edit.rawValue)","pid":\#(playlistID),"trackIds":\#(encodedList),"#
      + #""imme":"true","e_r":false,"header":\#(header)}"#
    return try eapiFormRequest(
      path: manipulateTracksEndpoint.path,
      json: json,
      headerFields: headerFields,
      url: manipulateTracksEndpoint.url
    )
  }

  /// playlist_name_update.js at d55d92cd0031d7c7746b7068faecd7ade1d354ac.
  package static func renamePlaylistRequest(
    playlistID: Int64,
    name: String,
    credential: NeteaseCredential,
    osVersion: String,
    buildVersion: String,
    requestID: String,
    nmtid: String? = nil
  ) throws -> URLRequest {
    let headerFields = eapiHeaderFields(
      credential: credential,
      osVersion: osVersion,
      buildVersion: buildVersion,
      requestID: requestID,
      nmtid: nmtid
    )
    let header = try eapiHeaderJSON(headerFields)
    let encodedName = String(decoding: try JSONEncoder().encode(name), as: UTF8.self)
    let json =
      #"{"id":\#(playlistID),"name":\#(encodedName),"e_r":false,"header":\#(header)}"#
    return try eapiFormRequest(
      path: "/api/playlist/update/name",
      json: json,
      headerFields: headerFields
    )
  }

  package static func subscribePlaylistRequest(
    _ subscribed: Bool,
    playlistID: Int64,
    credential: NeteaseCredential,
    osVersion: String,
    buildVersion: String,
    requestID: String,
    nmtid: String? = nil,
    checkToken: String? = nil
  ) throws -> URLRequest {
    var headerFields = eapiHeaderFields(
      credential: credential,
      osVersion: osVersion,
      buildVersion: buildVersion,
      requestID: requestID,
      nmtid: nmtid
    )
    if let checkToken {
      guard checkToken.count <= 4096, NeteaseCookie.isValidValue(checkToken) else {
        throw NeteaseWritePreparationError.verificationUnavailable
      }
      headerFields.append(("X-antiCheatToken", checkToken))
    }
    let header = try eapiHeaderJSON(headerFields)
    let bodyToken =
      subscribed
      ? #""checkToken":"9ca17ae2e6ffcda170e2e6ee8af14fbabdb988f225b3868eb2c15a879b9a83d274a790ac8ff54a97b889d5d42af0feaec3b92af58cff99c470a7eafd88f75e839a9ea7c14e909da883e83fb692a3abdb6b92adee9e","#
      : ""
    let json = #"{"id":\#(playlistID),\#(bodyToken)"e_r":false,"header":\#(header)}"#
    let endpoint = subscribed ? subscribePlaylistEndpoint : unsubscribePlaylistEndpoint
    return try eapiFormRequest(
      path: endpoint.path,
      json: json,
      headerFields: headerFields,
      url: endpoint.url
    )
  }

  /// Every write endpoint acknowledges with `code == 200` and carries no other
  /// field MacEase uses. Anything else is reported and stops; in particular the
  /// reference implementation's automatic resend on 512 is deliberately not
  /// copied, since automatic retries are forbidden.
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
    requestID: String,
    nmtid: String? = nil
  ) throws -> URLRequest {
    let headerFields = eapiHeaderFields(
      credential: credential,
      osVersion: osVersion,
      buildVersion: buildVersion,
      requestID: requestID,
      nmtid: nmtid
    )
    let header = try eapiHeaderJSON(headerFields)
    let json =
      #"{"ids":"[\#(songID)]","level":"\#(quality.rawValue)","encodeType":"flac","e_r":false,"header":\#(header)}"#
    return try eapiFormRequest(
      path: songURLEndpoint.path,
      json: json,
      headerFields: headerFields,
      url: songURLEndpoint.url
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
    return try classifyAudioItem(item, songID: songID, requestedQuality: requestedQuality)
  }

  static func classifyAudioItem(
    _ item: SongURLPayload.Item,
    songID: Int64,
    requestedQuality: PlaybackQuality,
    upgradeCDNToHTTPS: Bool = false
  ) throws -> SongURLResolution {
    guard item.id == songID else { throw NeteasePlaybackError.invalidResponse }
    guard item.code == 200, let value = item.url else {
      return .unavailable(itemCode: item.code, fee: item.fee)
    }
    guard
      var url = URL(string: value), let host = url.host?.lowercased(),
      let sourceScheme = url.scheme?.lowercased(), url.user == nil, url.password == nil
    else {
      throw NeteasePlaybackError.invalidResponse
    }
    guard NeteaseResourceHost.isApproved(host) else {
      throw NeteasePlaybackError.unapprovedHost(host)
    }
    guard
      sourceScheme == "https" || (sourceScheme == "http" && NeteaseResourceHost.isAudioCDN(host))
    else {
      throw NeteasePlaybackError.nonHTTPSURL(host)
    }
    if upgradeCDNToHTTPS, sourceScheme == "http" {
      guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        components.port == nil || components.port == 80
      else { throw NeteasePlaybackError.invalidResponse }
      components.scheme = "https"
      components.port = nil
      guard let upgraded = components.url else { throw NeteasePlaybackError.invalidResponse }
      url = upgraded
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
        trial: item.freeTrialInfo?.isObject == true,
        fileMD5: item.md5.flatMap { value in
          value.count == 32
            && value.utf8.allSatisfy({
              (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) ? value.lowercased() : nil
        }
      )
    )
  }

  /// The lyric request the product uses. The version fields are all `0`,
  /// which is how this endpoint is asked for every document it holds rather
  /// than for a delta against a version the client already has; `cp:false`
  /// suppresses the copyright banner, which is not lyric content.
  package static func lyricsRequest(
    songID: Int64,
    credential: NeteaseCredential,
    osVersion: String,
    buildVersion: String,
    requestID: String,
    nmtid: String? = nil
  ) throws -> URLRequest {
    let headerFields = eapiHeaderFields(
      credential: credential,
      osVersion: osVersion,
      buildVersion: buildVersion,
      requestID: requestID,
      nmtid: nmtid
    )
    let header = try eapiHeaderJSON(headerFields)
    let json =
      #"{"id":"\#(songID)","cp":false,"tv":0,"lv":0,"rv":0,"kv":0,"yv":0,"#
      + #""ytv":0,"yrv":0,"e_r":false,"header":\#(header)}"#
    return try eapiFormRequest(
      path: lyricsEndpoint.path,
      json: json,
      headerFields: headerFields,
      url: lyricsEndpoint.url
    )
  }

  /// A song with no lyrics is a fact, not a failure. An instrumental answers
  /// `nolyric`, an unindexed upload answers `uncollected`, and a track whose
  /// document is present but empty is the same thing said a third way. All
  /// three become `.none`, so the panel says "no lyrics" instead of offering a
  /// retry that cannot change the answer.
  package static func classifyLyrics(
    data: Data,
    response: HTTPURLResponse
  ) throws -> Lyrics {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }
    guard data.count <= LyricsParser.maximumResponseBytes else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "Lyric response exceeds the size limit")
      )
    }

    let payload = try JSONDecoder().decode(LyricsPayload.self, from: data)
    guard payload.code == 200 else {
      throw NeteaseServiceError(source: .service, statusCode: payload.code)
    }
    guard payload.nolyric != true, payload.uncollected != true else {
      return .none
    }
    return LyricsParser.parse(
      lrc: payload.lrc?.lyric,
      yrc: payload.yrc?.lyric,
      translation: payload.tlyric?.lyric,
      yrcTranslation: payload.ytlrc?.lyric,
      romanisation: payload.romalrc?.lyric,
      yrcRomanisation: payload.yromalrc?.lyric,
      contributor: payload.lyricUser?.nickname,
      translationContributor: payload.transUser?.nickname
    )
  }

  static func cookieHeader(_ credential: NeteaseCredential) -> String {
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

  static func eapiHeaderFields(
    credential: NeteaseCredential,
    osVersion: String,
    buildVersion: String,
    requestID: String,
    nmtid: String? = nil
  ) -> [(String, String)] {
    var fields: [(String, String)] = [
      ("osver", osVersion),
      ("os", "osx"),
      ("appver", "0.1"),
      ("buildver", buildVersion),
      ("__csrf", credential.csrf?.value ?? ""),
      ("channel", "github"),
      ("requestId", requestID),
      ("MUSIC_U", credential.musicU.value),
    ]
    if let nmtid { fields.append(("NMTID", nmtid)) }
    return fields
  }

  static func eapiHeaderJSON(
    _ fields: [(String, String)]
  ) throws -> String {
    "{"
      + (try fields.map {
        let value = String(decoding: try JSONEncoder().encode($0.1), as: UTF8.self)
        return #""\#($0.0)":\#(value)"#
      }).joined(separator: ",") + "}"
  }

  /// The shared `code == 200` gate for authenticated and catalogue responses.
  /// HTTP failures are classified before decoding a service code.
  static func requireSuccess(
    data: Data,
    response: HTTPURLResponse
  ) throws {
    guard (200..<300).contains(response.statusCode) else {
      throw NeteaseServiceError(source: .http, statusCode: response.statusCode)
    }
    let payload = try JSONDecoder().decode(ServiceCodePayload.self, from: data)
    guard payload.code == 200 else {
      throw NeteaseServiceError(
        source: .service, statusCode: payload.code, message: payload.message)
    }
  }

  static func weapiParameters(
    json: String,
    secretKey: String?
  ) throws -> WeAPIParameters {
    if let secretKey {
      return try NeteaseCrypto.weapi(json: json, secretKey: secretKey)
    }
    return try NeteaseCrypto.weapi(json: json)
  }

  static func csrfJSONValue(
    _ credential: NeteaseCredential
  ) throws -> String {
    String(
      decoding: try JSONEncoder().encode(credential.csrf?.value ?? ""),
      as: UTF8.self
    )
  }

  /// MacEase's own platform identity, matching what the already-verified eapi
  /// path sends. It states the real OS and MacEase's own version/channel; it
  /// never claims to be the official NetEase client and carries no fabricated
  /// device or tracking identifier.
  static func platformCookies() -> String {
    "os=osx; osver=\(osVersion); appver=0.1; channel=github"
  }

  static func weapiRequest(
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

  static var osVersion: String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion)"
  }

  static func requestID(timestamp: TimeInterval) -> String {
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

struct ServiceCodePayload: Decodable {
  let code: Int
  let message: String?
  enum CodingKeys: String, CodingKey { case code, msg, message }
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decode(Int.self, forKey: .code)
    message =
      (try? container.decode(String.self, forKey: .msg))
      ?? (try? container.decode(String.self, forKey: .message))
  }
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
    let nickname: String?
    let avatarUrl: String?
    let vipType: Int?
  }
}

private struct UserPlaylistsPayload: Decodable {
  let more: Bool
  let playlist: [Item]

  struct Item: Decodable {
    let id: Int64
    let name: String
    let trackCount: Int
    let privacy: Int?
    let creator: Creator
    let description: String?
    let tags: [String]?
    let coverImgUrl: String?
    let specialType: Int?
    let subscribed: Bool?
  }

  struct Creator: Decodable {
    let userId: Int64
    let nickname: String?
  }
}

private struct CreatedPlaylistPayload: Decodable {
  let id: Int64?
  let playlist: Item?
  struct Item: Decodable {
    let id: Int64
    let name: String?
  }
}

private struct PlaylistDetailPayload: Decodable {
  let playlist: Playlist
  let privileges: [SongPrivilegePayload]?

  struct Playlist: Decodable {
    let id: Int64
    let name: String
    let trackIds: [TrackID]
    let tracks: [SongRowPayload]?
    let description: String?
    let tags: [String]?
    let coverImgUrl: String?
    let specialType: Int?
    let subscribed: Bool?
    let privacy: Int?
    let creator: UserPlaylistsPayload.Creator?
  }

  struct TrackID: Decodable {
    let id: Int64
  }
}

private struct SongDetailsPayload: Decodable {
  let songs: [SongRowPayload]
  let privileges: [SongPrivilegePayload]?
}

private struct LikedSongIDsPayload: Decodable {
  let ids: [Int64]
}

private struct PlayRecordsPayload: Decodable {
  let weekData: [Item]?
  let allData: [Item]?

  struct Item: Decodable {
    let playCount: Int
    let song: SongRowPayload
  }
}

private struct DailyRecommendedSongsPayload: Decodable {
  let data: Inner

  struct Inner: Decodable {
    let dailySongs: [SongRowPayload]
  }
}

private struct DailyRecommendedPlaylistsPayload: Decodable {
  let recommend: [PlaylistRowPayload]
}

private struct PersonalizedPlaylistsPayload: Decodable {
  let result: [PlaylistRowPayload]
}

private struct ToplistsPayload: Decodable {
  let list: [PlaylistRowPayload]
}

private struct SimilarSongsPayload: Decodable {
  let songs: [SongRowPayload]
}

/// A lyric document must be an object. A missing or empty `lyric` field is an
/// empty document, while scalar and array values fail decoding.
private struct LyricsContent: Decodable {
  let lyric: String

  private enum CodingKeys: String, CodingKey {
    case lyric
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    lyric = try container.decodeIfPresent(String.self, forKey: .lyric) ?? ""
  }
}

/// Same rule, but a non-object is recorded rather than thrown: this field
/// only feeds a diagnostic string, and failing the whole song-URL resolution
/// over it would stop playback for no benefit.
struct LenientObjectMarker: Decodable {
  let isObject: Bool
  let isMalformed: Bool

  private enum NoKeys: CodingKey {}

  init(from decoder: Decoder) throws {
    isObject = (try? decoder.container(keyedBy: NoKeys.self)) != nil
    let scalar = try decoder.singleValueContainer()
    isMalformed = !isObject && !scalar.decodeNil()
  }
}

/// The product lyric payload. `yrc` carries absolute millisecond word timing;
/// its translation and romanisation companions remain line-timed documents.
private struct LyricsPayload: Decodable {
  let code: Int
  let lrc: LyricsContent?
  let yrc: LyricsContent?
  let tlyric: LyricsContent?
  let ytlrc: LyricsContent?
  let romalrc: LyricsContent?
  let yromalrc: LyricsContent?
  let lyricUser: LyricContributor?
  let transUser: LyricContributor?
  let nolyric: Bool?
  let uncollected: Bool?
}

/// Credits are decorative metadata. A malformed optional object must not make
/// otherwise valid timed lyrics fail to decode.
private struct LyricContributor: Decodable {
  let nickname: String?

  private enum CodingKeys: String, CodingKey { case nickname }

  init(from decoder: any Decoder) throws {
    guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
      nickname = nil
      return
    }
    nickname = try? container.decode(String.self, forKey: .nickname)
  }
}

struct SongURLPayload: Decodable {
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
    let freeTrialInfo: LenientObjectMarker?
    let md5: String?
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

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
}

public struct UserPlaylistPage: Equatable, Sendable {
  public let playlists: [UserPlaylist]
  public let more: Bool
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
  private static let accountStatusURL = URL(
    string: "https://music.163.com/weapi/w/nuser/account/get"
  )!
  private static let userPlaylistsURL = URL(
    string: "https://music.163.com/weapi/user/playlist"
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
    secretKey: String
  ) throws -> URLRequest {
    let json = try accountStatusJSON(credential: credential)
    return weapiRequest(
      url: accountStatusURL,
      parameters: NeteaseCrypto.weapi(json: json, secretKey: secretKey),
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
    secretKey: String
  ) throws -> URLRequest {
    let json = try userPlaylistsJSON(
      userID: userID,
      limit: limit,
      offset: offset,
      credential: credential
    )
    return weapiRequest(
      url: userPlaylistsURL,
      parameters: NeteaseCrypto.weapi(json: json, secretKey: secretKey),
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
    let headerFields = [
      ("osver", osVersion),
      ("os", "osx"),
      ("appver", "0.1"),
      ("buildver", buildVersion),
      ("__csrf", credential.csrf?.value ?? ""),
      ("channel", "github"),
      ("requestId", requestID),
      ("MUSIC_U", credential.musicU.value),
    ]
    let header =
      "{"
      + (try headerFields.map {
        let value = String(decoding: try JSONEncoder().encode($0.1), as: UTF8.self)
        return #""\#($0.0)":\#(value)"#
      }).joined(separator: ",") + "}"
    let json =
      #"{"ids":"[\#(songID)]","level":"\#(quality.rawValue)","encodeType":"flac","e_r":false,"header":\#(header)}"#
    let params = NeteaseCrypto.eapi(path: songURLEndpoint.path, json: json)

    var request = URLRequest(url: songURLEndpoint.url)
    request.httpMethod = "POST"
    request.httpBody = FormURLEncoder.encode([("params", params)])
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
      let url = URL(string: value), let host = url.host,
      let sourceScheme = url.scheme
    else {
      throw NeteasePlaybackError.invalidResponse
    }
    let isMusic126 = host == "music.126.net" || host.hasSuffix(".music.126.net")
    let isMusic163 = host == "music.163.com" || host.hasSuffix(".music.163.com")
    guard isMusic126 || isMusic163 else {
      throw NeteasePlaybackError.unapprovedHost(host)
    }
    guard url.scheme == "https" || (url.scheme == "http" && isMusic126) else {
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

  private static func accountStatusRequest(
    credential: NeteaseCredential
  ) throws -> URLRequest {
    let json = try accountStatusJSON(credential: credential)
    return weapiRequest(
      url: accountStatusURL,
      parameters: NeteaseCrypto.weapi(json: json),
      credential: credential
    )
  }

  private static func accountStatusJSON(
    credential: NeteaseCredential
  ) throws -> String {
    String(
      decoding: try JSONEncoder().encode(
        AccountStatusParameters(csrfToken: credential.csrf?.value ?? "")
      ),
      as: UTF8.self
    )
  }

  private static func userPlaylistsRequest(
    userID: Int64,
    limit: Int,
    offset: Int,
    credential: NeteaseCredential
  ) throws -> URLRequest {
    let json = try userPlaylistsJSON(
      userID: userID,
      limit: limit,
      offset: offset,
      credential: credential
    )
    return weapiRequest(
      url: userPlaylistsURL,
      parameters: NeteaseCrypto.weapi(json: json),
      credential: credential
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

  private static func weapiRequest(
    url: URL,
    parameters: WeAPIParameters,
    credential: NeteaseCredential
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
    request.setValue(cookieHeader(credential), forHTTPHeaderField: "Cookie")
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

import Foundation

public enum AccountSessionState: Sendable {
  case authenticated
  case signedOut
}

public struct NeteaseServiceError: Error, Equatable, Sendable {
  public let statusCode: Int

  public init(statusCode: Int) {
    self.statusCode = statusCode
  }
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
    let csrf = credential.csrf?.value ?? ""
    let json = String(
      decoding: try JSONEncoder().encode(AccountStatusParameters(csrfToken: csrf)),
      as: UTF8.self
    )
    let parameters = NeteaseCrypto.weapi(
      json: json
    )

    var request = URLRequest(
      url: URL(string: "https://music.163.com/weapi/w/nuser/account/get")!
    )
    request.httpMethod = "POST"
    request.httpBody = FormURLEncoder.encode([
      ("params", parameters.params),
      ("encSecKey", parameters.encSecKey),
    ])
    request.setValue(
      "application/x-www-form-urlencoded",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
    request.setValue(cookieHeader(credential), forHTTPHeaderField: "Cookie")

    let (data, response) = try await urlSession.data(for: request)
    let statusCode = (response as! HTTPURLResponse).statusCode
    if !(200..<300).contains(statusCode) {
      throw NeteaseServiceError(statusCode: statusCode)
    }

    let payload = try JSONDecoder().decode(AccountStatusPayload.self, from: data)
    guard payload.code == 200 else {
      throw NeteaseServiceError(statusCode: payload.code)
    }
    return payload.profile == nil ? .signedOut : .authenticated
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

  private func cookieHeader(_ credential: NeteaseCredential) -> String {
    credential.cookies
      .map { "\($0.name.rawValue)=\($0.value)" }
      .joined(separator: "; ")
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

private struct AccountStatusPayload: Decodable {
  let code: Int
  let profile: Profile?

  struct Profile: Decodable {}
}

private struct LyricsProbePayload: Decodable {
  let code: Int
  let lrc: LyricsMarker?
  let yrc: LyricsMarker?
  let nolyric: Bool?
  let uncollected: Bool?

  struct LyricsMarker: Decodable {}
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

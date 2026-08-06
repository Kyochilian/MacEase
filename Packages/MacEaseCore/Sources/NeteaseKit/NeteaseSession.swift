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

public actor NeteaseSession {
  private let redirectBlocker: RedirectBlocker
  private let urlSession: URLSession

  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
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

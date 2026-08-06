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
  private static let allowedCharacters = CharacterSet.alphanumerics.union(
    CharacterSet(charactersIn: "-._~")
  )

  static func encode(_ fields: [(String, String)]) -> Data {
    let form =
      fields
      .map { "\(escape($0.0))=\(escape($0.1))" }
      .joined(separator: "&")
    return Data(form.utf8)
  }

  private static func escape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: allowedCharacters)!
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

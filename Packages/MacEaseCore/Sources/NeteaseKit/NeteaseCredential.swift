import Foundation

public struct NeteaseCredential: Codable, Equatable, Sendable {
  public let musicU: NeteaseCookie
  public let csrf: NeteaseCookie?

  public init(musicU: NeteaseCookie, csrf: NeteaseCookie?) {
    self.musicU = musicU
    self.csrf = csrf
  }

  public var cookies: [NeteaseCookie] {
    if let csrf {
      return [musicU, csrf]
    }
    return [musicU]
  }

  package init?(cookieHeader: String) {
    var values: [NeteaseCookie.Name: String] = [:]

    for field in cookieHeader.split(separator: ";") {
      let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2 else { continue }

      let name = pair[0].trimmingCharacters(in: .whitespaces)
      guard let name = NeteaseCookie.Name(rawValue: name) else { continue }

      let value = pair[1].trimmingCharacters(in: .whitespaces)
      guard !value.isEmpty, values[name] == nil else { return nil }
      values[name] = value
    }

    guard let musicU = values[.musicU] else { return nil }
    self.init(
      musicU: NeteaseCookie(name: .musicU, value: musicU),
      csrf: values[.csrf].map { NeteaseCookie(name: .csrf, value: $0) }
    )
  }
}

public struct NeteaseCookie: Codable, Equatable, Sendable {
  public enum Name: String, Codable, Sendable {
    case musicU = "MUSIC_U"
    case csrf = "__csrf"
  }

  public let name: Name
  public let value: String

  public init(
    name: Name,
    value: String
  ) {
    self.name = name
    self.value = value
  }
}

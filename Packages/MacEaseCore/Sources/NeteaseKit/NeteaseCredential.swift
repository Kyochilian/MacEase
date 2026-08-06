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

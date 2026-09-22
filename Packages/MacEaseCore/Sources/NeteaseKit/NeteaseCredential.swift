import CryptoKit
import Foundation

public struct NeteaseCredential: Codable, Equatable, Sendable {
  public let musicU: NeteaseCookie
  public let csrf: NeteaseCookie?

  /// Fails when a cookie is filed under the wrong name, so a credential that
  /// would build a nonsense Cookie header cannot exist.
  public init?(musicU: NeteaseCookie, csrf: NeteaseCookie?) {
    guard musicU.name == .musicU else { return nil }
    if let csrf, csrf.name != .csrf { return nil }
    self.musicU = musicU
    self.csrf = csrf
  }

  public var cookies: [NeteaseCookie] {
    if let csrf {
      return [musicU, csrf]
    }
    return [musicU]
  }

  /// An association key for local identity, never an authentication token.
  package var fingerprint: String {
    SHA256.hash(data: Data((musicU.value + "\u{0}" + (csrf?.value ?? "")).utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  package init?(cookieHeader: String) {
    var values: [NeteaseCookie.Name: String] = [:]

    for field in cookieHeader.split(separator: ";") {
      let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2 else { continue }

      let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
      guard let name = NeteaseCookie.Name(rawValue: name) else { continue }

      let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { continue }
      guard values[name] == nil else { return nil }
      guard let cookie = NeteaseCookie(name: name, value: value) else { return nil }
      values[name] = cookie.value
    }

    guard
      let musicUValue = values[.musicU],
      let musicU = NeteaseCookie(name: .musicU, value: musicUValue)
    else { return nil }
    self.init(
      musicU: musicU,
      csrf: values[.csrf].flatMap { NeteaseCookie(name: .csrf, value: $0) }
    )
  }

  /// Keychain bytes are untrusted: re-check the same invariants the
  /// initializer enforces rather than trusting whatever was stored.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let musicU = try container.decode(NeteaseCookie.self, forKey: .musicU)
    let csrf = try container.decodeIfPresent(NeteaseCookie.self, forKey: .csrf)
    guard let credential = NeteaseCredential(musicU: musicU, csrf: csrf) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Cookie stored under the wrong name"
        )
      )
    }
    self = credential
  }
}

public struct NeteaseCookie: Codable, Equatable, Sendable {
  public enum Name: String, Codable, Sendable {
    case musicU = "MUSIC_U"
    case csrf = "__csrf"
  }

  public let name: Name
  public let value: String

  /// Fails for anything that cannot legally appear in a `Cookie` header.
  /// Only the manual-import path used to check this, so a direct call or a
  /// corrupt Keychain item could produce a value the system silently drops.
  public init?(name: Name, value: String) {
    guard Self.isValidValue(value) else { return nil }
    self.name = name
    self.value = value
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let name = try container.decode(Name.self, forKey: .name)
    let value = try container.decode(String.self, forKey: .value)
    guard let cookie = NeteaseCookie(name: name, value: value) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Cookie value is not a valid cookie-octet string"
        )
      )
    }
    self = cookie
  }

  /// RFC 6265 `cookie-octet`: printable US-ASCII except space, `"`, `,`, `;`
  /// and `\`. This excludes CR, LF, NUL and every other control character,
  /// which are the bytes that would let a value inject or truncate a header.
  package static func isValidValue(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    return value.utf8.allSatisfy { byte in
      switch byte {
      case 0x21, 0x23...0x2b, 0x2d...0x3a, 0x3c...0x5b, 0x5d...0x7e: true
      default: false
      }
    }
  }
}

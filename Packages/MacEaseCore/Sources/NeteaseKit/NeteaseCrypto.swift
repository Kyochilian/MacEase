import CommonCrypto
import CryptoKit
import Foundation
import Security

public struct WeAPIParameters: Equatable, Sendable {
  public let params: String
  public let encSecKey: String
}

/// Every way a crypto path can refuse untrusted input. None may terminate the
/// process: each failure is classified and thrown.
public enum NeteaseCryptoError: Error, Equatable, Sendable {
  /// A caller-supplied key had the wrong size.
  case invalidInput(field: String)
  /// CommonCrypto refused the operation (bad alignment, padding or key).
  case cryptoFailure(status: Int32)
  /// The RSA public key could not be built or applied.
  case rsaFailure
}

public enum NeteaseCrypto {
  package static func fileMD5(_ url: URL) async throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var digest = Insecure.MD5()
    while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
      try Task.checkCancellation()
      digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private static let base62 = Array(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  private static let iv = Data("0102030405060708".utf8)
  private static let presetKey = Data("0CoJUm6Qyw8W8jud".utf8)
  private static let eapiKey = Data("e82ckenh8dichen8".utf8)
  private static let publicKeyDER = Data(
    base64Encoded:
      "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB"
  )!

  public static func weapi(json: String) throws -> WeAPIParameters {
    var generator = SystemRandomNumberGenerator()
    // `base62` is a non-empty compile-time constant, so the element exists.
    let secretKey = String(
      (0..<kCCKeySizeAES128).map { _ in base62.randomElement(using: &generator)! }
    )
    return try weapi(json: json, secretKey: secretKey)
  }

  /// Package-only: it accepts a caller-chosen key so request golden tests can
  /// pin exact bytes. The public entry point generates its own key, so no
  /// caller outside the package can supply an invalid one.
  package static func weapi(
    json: String,
    secretKey: String
  ) throws -> WeAPIParameters {
    guard secretKey.utf8.count == kCCKeySizeAES128 else {
      throw NeteaseCryptoError.invalidInput(field: "secretKey")
    }

    let firstPass = try aes(
      Data(json.utf8),
      key: presetKey,
      iv: iv,
      options: CCOptions(kCCOptionPKCS7Padding)
    ).base64EncodedString()
    let secondPass = try aes(
      Data(firstPass.utf8),
      key: Data(secretKey.utf8),
      iv: iv,
      options: CCOptions(kCCOptionPKCS7Padding)
    ).base64EncodedString()

    return WeAPIParameters(
      params: secondPass,
      encSecKey: try rawRSA(secretKey: secretKey).hexString
    )
  }

  public static func eapi(path: String, json: String) throws -> String {
    let message = "nobody\(path)use\(json)md5forencrypt"
    let digest = Insecure.MD5.hash(data: Data(message.utf8)).hexString
    let plaintext = "\(path)-36cd479b6b5-\(json)-36cd479b6b5-\(digest)"

    return try aes(
      Data(plaintext.utf8),
      key: eapiKey,
      iv: nil,
      options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode)
    ).uppercasedHexString
  }

  private static func aes(
    _ input: Data,
    key: Data,
    iv: Data?,
    options: CCOptions
  ) throws -> Data {
    let initializationVector = iv ?? Data()
    var output = Data(count: input.count + kCCBlockSizeAES128)
    let outputCapacity = output.count
    var outputCount = 0

    let status = output.withUnsafeMutableBytes { outputBytes in
      input.withUnsafeBytes { inputBytes in
        key.withUnsafeBytes { keyBytes in
          initializationVector.withUnsafeBytes { ivBytes in
            CCCrypt(
              CCOperation(kCCEncrypt),
              CCAlgorithm(kCCAlgorithmAES),
              options,
              keyBytes.baseAddress,
              key.count,
              ivBytes.baseAddress,
              inputBytes.baseAddress,
              input.count,
              outputBytes.baseAddress,
              outputCapacity,
              &outputCount
            )
          }
        }
      }
    }

    guard status == kCCSuccess else {
      throw NeteaseCryptoError.cryptoFailure(status: status)
    }
    output.count = outputCount
    return output
  }

  private static func rawRSA(secretKey: String) throws -> Data {
    let attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass: kSecAttrKeyClassPublic,
      kSecAttrKeySizeInBits: 1024,
    ]
    guard
      let publicKey = SecKeyCreateWithData(
        publicKeyDER as CFData,
        attributes as CFDictionary,
        nil
      )
    else {
      throw NeteaseCryptoError.rsaFailure
    }
    let reversedKey = Data(String(secretKey.reversed()).utf8)
    let blockSize = SecKeyGetBlockSize(publicKey)
    guard reversedKey.count <= blockSize else {
      throw NeteaseCryptoError.rsaFailure
    }
    var block = Data(repeating: 0, count: blockSize - reversedKey.count)
    block.append(reversedKey)

    guard
      let encrypted = SecKeyCreateEncryptedData(
        publicKey,
        .rsaEncryptionRaw,
        block as CFData,
        nil
      ) as Data?
    else {
      throw NeteaseCryptoError.rsaFailure
    }
    return encrypted
  }
}

extension Data {
  fileprivate var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }

  fileprivate var uppercasedHexString: String {
    map { String(format: "%02X", $0) }.joined()
  }
}

extension Digest {
  fileprivate var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}

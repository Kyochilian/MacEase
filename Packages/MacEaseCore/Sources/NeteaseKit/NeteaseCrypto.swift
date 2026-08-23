import CommonCrypto
import CryptoKit
import Foundation
import Security
import zlib

public struct WeAPIParameters: Equatable, Sendable {
  public let params: String
  public let encSecKey: String
}

struct XeAPIParameters: Equatable, Sendable {
  let b: String
  let s: String
  let r: String
}

struct XeAPIPublicKeyState: Decodable, Equatable, Sendable {
  let publicKey: Data
  let version: String
  let sk: String
}

/// Every way a crypto path can refuse untrusted input. Server payloads,
/// Keychain bytes and compressed bodies all reach these functions, so none of
/// them may terminate the process: each failure is classified and thrown.
public enum NeteaseCryptoError: Error, Equatable, Sendable {
  /// A caller-supplied key, nonce or transform block had the wrong size.
  case invalidInput(field: String)
  /// CommonCrypto refused the operation (bad alignment, padding or key).
  case cryptoFailure(status: Int32)
  /// Curve25519 rejected the private key or the peer public key.
  case keyAgreementFailed
  /// AES-GCM could not seal the envelope.
  case sealFailed
  /// The RSA public key could not be built or applied.
  case rsaFailure
  /// zlib could not inflate the body.
  case decompressionFailed(status: Int32)
  /// The inflated body exceeded the accepted bound.
  case decompressionLimitExceeded
  /// A decrypted body was not the JSON MacEase expects.
  case responseDecodeFailed
}

public enum NeteaseCrypto {
  /// Bounds a hostile or corrupt gzip body. The largest response MacEase asks
  /// for is a playlist detail capped at 100000 track ids, a few megabytes.
  private static let maximumInflatedByteCount = 64 << 20

  private static let base62 = Array(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  private static let iv = Data("0102030405060708".utf8)
  private static let presetKey = Data("0CoJUm6Qyw8W8jud".utf8)
  private static let eapiKey = Data("e82ckenh8dichen8".utf8)
  // Compile-time constants, never derived from a response or the Keychain.
  private static let xeapiStaticKey = Data(
    base64Encoded: "qx1aQw9rsEo/Aegd3XK9kW1c5ZEkisEocUgG1/j7G4Q="
  )!
  private static let xeapiSignKey = SymmetricKey(
    data: Data(
      "mUHCwVNWJbunMqAHf5MImuirT6plvs6VSFW62MGHstFQxhBGdEoIhLItH3djc4+FB/OKty3+lL2rGeoFBpVe5g=="
        .utf8
    )
  )
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

  /// Measured on macOS 15 / Xcode 16.4: one-shot `CCCrypt` in
  /// `ECB|PKCS7` decrypt mode returns `kCCSuccess` for an empty body, for a
  /// length that is not a block multiple, and for a body whose trailing byte
  /// is not a valid pad. Alignment is therefore checked here rather than
  /// assumed; a body that survives this guard but is still garbage fails
  /// loudly at the JSON decode instead of being trusted.
  public static func decodeEAPIResponse(
    _ encrypted: Data,
    gzipped: Bool
  ) throws -> Data {
    guard !encrypted.isEmpty, encrypted.count % kCCBlockSizeAES128 == 0 else {
      throw NeteaseCryptoError.invalidInput(field: "ciphertext")
    }
    let decrypted = try aes(
      encrypted,
      key: eapiKey,
      iv: nil,
      options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
      operation: CCOperation(kCCDecrypt)
    )
    return gzipped ? try gunzip(decrypted) : decrypted
  }

  static func xeapi(
    formBody: Data,
    publicKey: Data,
    version: String,
    sk: String,
    os: String,
    dynamicKey: Data,
    transform: Data,
    ephemeralPrivateKey: Data,
    nonce: Data,
    sessionID: String = ""
  ) throws -> XeAPIParameters {
    guard publicKey.count == 32 else {
      throw NeteaseCryptoError.invalidInput(field: "publicKey")
    }
    guard dynamicKey.count == 16 else {
      throw NeteaseCryptoError.invalidInput(field: "dynamicKey")
    }
    guard transform.count == 16 else {
      throw NeteaseCryptoError.invalidInput(field: "transform")
    }
    guard ephemeralPrivateKey.count == 32 else {
      throw NeteaseCryptoError.invalidInput(field: "ephemeralPrivateKey")
    }
    guard nonce.count == 12 else {
      throw NeteaseCryptoError.invalidInput(field: "nonce")
    }

    let plaintext = Data(
      #"{"body":"\#(formBody.base64EncodedString())","queryString":"e_r=true"}"#.utf8
    )
    let firstPass = try aes(
      plaintext,
      key: xeapiStaticKey,
      iv: nil,
      options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode)
    )
    let b = try aes(
      try xeapiMidTransform(firstPass, transform: transform),
      key: dynamicKey,
      iv: nil,
      options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode)
    )

    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let sharedSecret: SharedSecret
    do {
      privateKey = try Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: ephemeralPrivateKey
      )
      sharedSecret = try privateKey.sharedSecretFromKeyAgreement(
        with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
      )
    } catch {
      throw NeteaseCryptoError.keyAgreementFailed
    }
    let envelopeKey = sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: Data(repeating: 0, count: 32),
      sharedInfo: privateKey.publicKey.rawRepresentation,
      outputByteCount: 16
    )
    let envelopePlaintext = Data(
      "\(dynamicKey.base64EncodedString())|\(os)|\(sk)".utf8
    )
    let sealed: AES.GCM.SealedBox
    do {
      sealed = try AES.GCM.seal(
        envelopePlaintext,
        using: envelopeKey,
        nonce: AES.GCM.Nonce(data: nonce)
      )
    } catch {
      throw NeteaseCryptoError.sealFailed
    }
    var s = privateKey.publicKey.rawRepresentation
    s.append(nonce)
    s.append(sealed.ciphertext)
    s.append(sealed.tag)

    let r = try aes(
      Data("\(version)|\(sessionID)".utf8),
      key: xeapiStaticKey,
      iv: nil,
      options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode)
    )

    return XeAPIParameters(
      b: b.base64EncodedString(),
      s: s.base64EncodedString(),
      r: r.base64EncodedString()
    )
  }

  static func xeapiKeySignature(timestamp: String, nonce: String) -> String {
    Data(
      HMAC<SHA256>.authenticationCode(
        for: Data("\(timestamp)\(nonce)".utf8),
        using: xeapiSignKey
      )
    ).base64EncodedString()
  }

  static func decodeXeAPIPublicKeyState(
    _ encrypted: Data
  ) throws -> XeAPIPublicKeyState {
    let decrypted = try aes(
      encrypted,
      key: xeapiStaticKey,
      iv: nil,
      options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
      operation: CCOperation(kCCDecrypt)
    )
    guard
      let state = try? JSONDecoder().decode(
        XeAPIPublicKeyState.self,
        from: decrypted
      )
    else {
      throw NeteaseCryptoError.responseDecodeFailed
    }
    // The server-chosen key feeds Curve25519 next; reject the wrong size here
    // rather than at the key-agreement call.
    guard state.publicKey.count == 32 else {
      throw NeteaseCryptoError.invalidInput(field: "publicKey")
    }
    return state
  }

  private static func aes(
    _ input: Data,
    key: Data,
    iv: Data?,
    options: CCOptions,
    operation: CCOperation = CCOperation(kCCEncrypt)
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
              operation,
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

  /// Package-scoped so the truncated, non-gzip, empty and over-expanding
  /// bodies can be exercised directly; `limit` is only overridden by those
  /// tests, every request path uses the shipped bound.
  package static func gunzip(
    _ input: Data,
    limit: Int = maximumInflatedByteCount
  ) throws -> Data {
    guard !input.isEmpty else {      throw NeteaseCryptoError.decompressionFailed(status: Z_DATA_ERROR)
    }

    var stream = z_stream()
    let initStatus = inflateInit2_(
      &stream,
      MAX_WBITS + 16,
      ZLIB_VERSION,
      Int32(MemoryLayout<z_stream>.size)
    )
    guard initStatus == Z_OK else {
      throw NeteaseCryptoError.decompressionFailed(status: initStatus)
    }
    defer { inflateEnd(&stream) }

    var output = Data()
    try input.withUnsafeBytes { inputBytes in
      guard let inputBase = inputBytes.bindMemory(to: Bytef.self).baseAddress else {
        throw NeteaseCryptoError.decompressionFailed(status: Z_DATA_ERROR)
      }
      stream.next_in = UnsafeMutablePointer(mutating: inputBase)
      stream.avail_in = uInt(inputBytes.count)

      var status = Z_OK
      repeat {
        var chunk = [UInt8](repeating: 0, count: 32 * 1024)
        status = chunk.withUnsafeMutableBytes { outputBytes -> Int32 in
          guard
            let outputBase = outputBytes.bindMemory(to: Bytef.self).baseAddress
          else {
            return Z_BUF_ERROR
          }
          stream.next_out = outputBase
          stream.avail_out = uInt(outputBytes.count)
          return inflate(&stream, Z_NO_FLUSH)
        }
        guard status == Z_OK || status == Z_STREAM_END else {
          throw NeteaseCryptoError.decompressionFailed(status: status)
        }
        output.append(contentsOf: chunk.prefix(chunk.count - Int(stream.avail_out)))
        guard output.count <= limit else {
          throw NeteaseCryptoError.decompressionLimitExceeded
        }
      } while status != Z_STREAM_END
    }
    return output
  }

  private static func xeapiMidTransform(
    _ input: Data,
    transform: Data
  ) throws -> Data {
    let transformBytes = [UInt8](transform)
    let xored = Data(
      input.enumerated().map { index, byte in
        byte ^ transformBytes[index & 0x0f]
      })
    let encoded = Data(xored.base64EncodedString().utf8)
    guard !encoded.isEmpty else {
      throw NeteaseCryptoError.invalidInput(field: "formBody")
    }
    let rotation = Int(transformBytes[0] & 0x0f) % encoded.count
    var output = transform
    output.append(encoded[rotation...])
    output.append(encoded[..<rotation])
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

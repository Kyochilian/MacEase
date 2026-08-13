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

public enum NeteaseCrypto {
  private static let base62 = Array(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  private static let iv = Data("0102030405060708".utf8)
  private static let presetKey = Data("0CoJUm6Qyw8W8jud".utf8)
  private static let eapiKey = Data("e82ckenh8dichen8".utf8)
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

  public static func weapi(json: String) -> WeAPIParameters {
    var generator = SystemRandomNumberGenerator()
    let secretKey = String(
      (0..<kCCKeySizeAES128).map { _ in base62.randomElement(using: &generator)! }
    )
    return weapi(json: json, secretKey: secretKey)
  }

  public static func weapi(json: String, secretKey: String) -> WeAPIParameters {
    precondition(secretKey.utf8.count == kCCKeySizeAES128)

    let firstPass = aes(
      Data(json.utf8),
      key: presetKey,
      iv: iv,
      options: CCOptions(kCCOptionPKCS7Padding)
    ).base64EncodedString()
    let secondPass = aes(
      Data(firstPass.utf8),
      key: Data(secretKey.utf8),
      iv: iv,
      options: CCOptions(kCCOptionPKCS7Padding)
    ).base64EncodedString()

    return WeAPIParameters(
      params: secondPass,
      encSecKey: rawRSA(secretKey: secretKey).hexString
    )
  }

  public static func eapi(path: String, json: String) -> String {
    let message = "nobody\(path)use\(json)md5forencrypt"
    let digest = Insecure.MD5.hash(data: Data(message.utf8)).hexString
    let plaintext = "\(path)-36cd479b6b5-\(json)-36cd479b6b5-\(digest)"

    return aes(
      Data(plaintext.utf8),
      key: eapiKey,
      iv: nil,
      options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode)
    ).uppercasedHexString
  }

  public static func decodeEAPIResponse(_ encrypted: Data, gzipped: Bool) -> Data {
    let decrypted = aes(
      encrypted,
      key: eapiKey,
      iv: nil,
      options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
      operation: CCOperation(kCCDecrypt)
    )
    return gzipped ? gunzip(decrypted) : decrypted
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
  ) -> XeAPIParameters {
    precondition(
      publicKey.count == 32 && dynamicKey.count == 16 && transform.count == 16
        && ephemeralPrivateKey.count == 32 && nonce.count == 12
    )

    let plaintext = Data(
      #"{"body":"\#(formBody.base64EncodedString())","queryString":"e_r=true"}"#.utf8
    )
    let firstPass = aes(
      plaintext,
      key: xeapiStaticKey,
      iv: nil,
      options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode)
    )
    let b = aes(
      xeapiMidTransform(firstPass, transform: transform),
      key: dynamicKey,
      iv: nil,
      options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode)
    )

    let privateKey = try! Curve25519.KeyAgreement.PrivateKey(
      rawRepresentation: ephemeralPrivateKey
    )
    let sharedSecret = try! privateKey.sharedSecretFromKeyAgreement(
      with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
    )
    let envelopeKey = sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: Data(repeating: 0, count: 32),
      sharedInfo: privateKey.publicKey.rawRepresentation,
      outputByteCount: 16
    )
    let envelopePlaintext = Data(
      "\(dynamicKey.base64EncodedString())|\(os)|\(sk)".utf8
    )
    let sealed = try! AES.GCM.seal(
      envelopePlaintext,
      using: envelopeKey,
      nonce: AES.GCM.Nonce(data: nonce)
    )
    var s = privateKey.publicKey.rawRepresentation
    s.append(nonce)
    s.append(sealed.ciphertext)
    s.append(sealed.tag)

    let r = aes(
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

  static func decodeXeAPIPublicKeyState(_ encrypted: Data) -> XeAPIPublicKeyState {
    let decrypted = aes(
      encrypted,
      key: xeapiStaticKey,
      iv: nil,
      options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
      operation: CCOperation(kCCDecrypt)
    )
    return try! JSONDecoder().decode(XeAPIPublicKeyState.self, from: decrypted)
  }

  private static func aes(
    _ input: Data,
    key: Data,
    iv: Data?,
    options: CCOptions,
    operation: CCOperation = CCOperation(kCCEncrypt)
  ) -> Data {
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

    precondition(status == kCCSuccess)
    output.count = outputCount
    return output
  }

  private static func gunzip(_ input: Data) -> Data {
    var stream = z_stream()
    precondition(
      inflateInit2_(
        &stream,
        MAX_WBITS + 16,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
      ) == Z_OK
    )
    defer { inflateEnd(&stream) }

    var output = Data()
    input.withUnsafeBytes { inputBytes in
      stream.next_in = UnsafeMutablePointer(
        mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress!
      )
      stream.avail_in = uInt(inputBytes.count)

      var status = Z_OK
      repeat {
        var chunk = [UInt8](repeating: 0, count: 32 * 1024)
        status = chunk.withUnsafeMutableBytes { outputBytes in
          stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress!
          stream.avail_out = uInt(outputBytes.count)
          return inflate(&stream, Z_NO_FLUSH)
        }
        precondition(status == Z_OK || status == Z_STREAM_END)
        output.append(contentsOf: chunk.prefix(chunk.count - Int(stream.avail_out)))
      } while status != Z_STREAM_END
    }
    return output
  }

  private static func xeapiMidTransform(_ input: Data, transform: Data) -> Data {
    let transformBytes = [UInt8](transform)
    let xored = Data(
      input.enumerated().map { index, byte in
        byte ^ transformBytes[index & 0x0f]
      })
    let encoded = Data(xored.base64EncodedString().utf8)
    let rotation = Int(transformBytes[0] & 0x0f) % encoded.count
    var output = transform
    output.append(encoded[rotation...])
    output.append(encoded[..<rotation])
    return output
  }

  private static func rawRSA(secretKey: String) -> Data {
    let attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass: kSecAttrKeyClassPublic,
      kSecAttrKeySizeInBits: 1024,
    ]
    let publicKey = SecKeyCreateWithData(
      publicKeyDER as CFData,
      attributes as CFDictionary,
      nil
    )!
    let reversedKey = Data(String(secretKey.reversed()).utf8)
    var block = Data(repeating: 0, count: SecKeyGetBlockSize(publicKey) - reversedKey.count)
    block.append(reversedKey)

    return SecKeyCreateEncryptedData(
      publicKey,
      .rsaEncryptionRaw,
      block as CFData,
      nil
    )! as Data
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

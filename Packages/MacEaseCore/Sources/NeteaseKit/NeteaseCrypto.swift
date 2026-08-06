import CommonCrypto
import CryptoKit
import Foundation
import Security

public struct WeAPIParameters: Equatable, Sendable {
  public let params: String
  public let encSecKey: String
}

public enum NeteaseCrypto {
  private static let iv = Data("0102030405060708".utf8)
  private static let presetKey = Data("0CoJUm6Qyw8W8jud".utf8)
  private static let eapiKey = Data("e82ckenh8dichen8".utf8)
  private static let publicKeyDER = Data(
    base64Encoded:
      "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB"
  )!

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

  private static func aes(
    _ input: Data,
    key: Data,
    iv: Data?,
    options: CCOptions
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

    precondition(status == kCCSuccess)
    output.count = outputCount
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

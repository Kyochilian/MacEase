import Foundation
import Security

public struct CredentialVaultError: Error, Equatable, Sendable {
  public let status: OSStatus

  public init(status: OSStatus) {
    self.status = status
  }
}

public actor CredentialVault {
  private let service: String
  private let account: String

  public init(
    service: String = "com.macease.session",
    account: String = "default"
  ) {
    self.service = service
    self.account = account
  }

  public func save(_ credential: NeteaseCredential) throws {
    let data = try JSONEncoder().encode(credential)
    let query = baseQuery
    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData: data] as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    if updateStatus != errSecItemNotFound {
      throw CredentialVaultError(status: updateStatus)
    }

    var item = query
    item[kSecValueData] = data
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    let status = SecItemAdd(item as CFDictionary, nil)
    if status != errSecSuccess {
      throw CredentialVaultError(status: status)
    }
  }

  public func load() throws -> NeteaseCredential? {
    var query = baseQuery
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    if status != errSecSuccess {
      throw CredentialVaultError(status: status)
    }

    return try JSONDecoder().decode(NeteaseCredential.self, from: result as! Data)
  }

  public func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    if status != errSecSuccess && status != errSecItemNotFound {
      throw CredentialVaultError(status: status)
    }
  }

  package func delete(matching credential: NeteaseCredential) throws -> Bool {
    guard try load() == credential else { return false }
    try delete()
    return true
  }

  private var baseQuery: [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecAttrSynchronizable: false,
    ]
  }
}

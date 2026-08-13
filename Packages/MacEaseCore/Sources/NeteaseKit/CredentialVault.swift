import Foundation
import Security
import Synchronization

public struct CredentialVaultError: Error, Equatable, Sendable {
  public let status: OSStatus

  public init(status: OSStatus) {
    self.status = status
  }
}

public actor CredentialVault {
  private static let keychainLock = Mutex(())

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
    try Self.keychainLock.withLock { _ in
      try saveUnlocked(credential)
    }
  }

  public func load() throws -> NeteaseCredential? {
    try Self.keychainLock.withLock { _ in
      try loadUnlocked()
    }
  }

  public func delete() throws {
    try Self.keychainLock.withLock { _ in
      try deleteUnlocked()
    }
  }

  package func delete(matching credential: NeteaseCredential) throws -> Bool {
    try Self.keychainLock.withLock { _ in
      guard try loadUnlocked() == credential else { return false }
      try deleteUnlocked()
      return true
    }
  }

  private func saveUnlocked(_ credential: NeteaseCredential) throws {
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

    let status = SecItemAdd(item as CFDictionary, nil)
    if status != errSecSuccess {
      throw CredentialVaultError(status: status)
    }
  }

  private func loadUnlocked() throws -> NeteaseCredential? {
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

  private func deleteUnlocked() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    if status != errSecSuccess && status != errSecItemNotFound {
      throw CredentialVaultError(status: status)
    }
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

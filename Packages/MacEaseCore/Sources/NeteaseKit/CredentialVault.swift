import Foundation
import Security
import Synchronization

/// Keychain contents are an untrusted boundary: an item can be absent, of the
/// wrong class, or hold bytes that are not a credential. Each case is
/// classified rather than trapped, and none of them falls back to an
/// anonymous request.
public enum CredentialVaultError: Error, Equatable, Sendable {
  /// A Security framework call failed with this `OSStatus`.
  case keychain(OSStatus)
  /// The item exists but its value is not `Data`.
  case invalidPayloadType
  /// The bytes are not a credential that satisfies its own invariants.
  case corruptPayload

  /// Short, credential-free label for status text and probe output.
  public var diagnostic: String {
    switch self {
    case .keychain(let status): "status=\(status)"
    case .invalidPayloadType: "invalidPayloadType"
    case .corruptPayload: "corruptPayload"
    }
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
      throw CredentialVaultError.keychain(updateStatus)
    }

    var item = query
    item[kSecValueData] = data

    let status = SecItemAdd(item as CFDictionary, nil)
    if status != errSecSuccess {
      throw CredentialVaultError.keychain(status)
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
      throw CredentialVaultError.keychain(status)
    }
    guard let data = result as? Data else {
      throw CredentialVaultError.invalidPayloadType
    }
    guard
      let credential = try? JSONDecoder().decode(
        NeteaseCredential.self,
        from: data
      )
    else {
      throw CredentialVaultError.corruptPayload
    }
    return credential
  }

  private func deleteUnlocked() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    if status != errSecSuccess && status != errSecItemNotFound {
      throw CredentialVaultError.keychain(status)
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

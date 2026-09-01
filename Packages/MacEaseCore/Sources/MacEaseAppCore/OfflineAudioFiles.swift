import Foundation

package actor OfflineAudioFiles {
  package struct StagedDeletion: Sendable {
    fileprivate let original: URL
    fileprivate let staged: URL
  }

  private static let partialPrefix = ".macease-partial-"
  private static let deletionPrefix = ".macease-delete-"
  private let directory: URL

  package init(directory: URL) throws {
    self.directory = directory.standardizedFileURL
    try FileManager.default.createDirectory(
      at: self.directory,
      withIntermediateDirectories: true
    )
    try Self.removeInterruptedFiles(under: self.directory)
  }

  package static func defaultDirectory() throws -> URL {
    guard
      let base = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else { throw LibraryStoreError.noApplicationSupportDirectory }
    return base
      .appendingPathComponent("MacEase", isDirectory: true)
      .appendingPathComponent("Downloads", isDirectory: true)
  }

  package func makePartialFile(accountID: Int64, format: String) throws -> URL {
    let account = try accountDirectory(accountID, create: true)
    let url = account.appendingPathComponent(
      Self.partialPrefix + UUID().uuidString + "." + Self.safeExtension(format)
    )
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw AudioRangeError.storageFailure
    }
    return url
  }

  package func append(
    _ data: Data,
    to partial: URL,
    expectedOffset: Int64
  ) throws {
    guard isSafe(partial), partial.lastPathComponent.hasPrefix(Self.partialPrefix),
      Self.fileSize(partial) == expectedOffset
    else { throw AudioRangeError.storageFailure }
    let handle = try FileHandle(forWritingTo: partial)
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      // Preserve the write error. Closing here is best-effort cleanup only.
      try? handle.close()
      throw error
    }
    guard Self.fileSize(partial) == expectedOffset + Int64(data.count) else {
      throw AudioRangeError.storageFailure
    }
  }

  package func commit(
    partial: URL,
    accountID: Int64,
    format: String
  ) throws -> (url: URL, relativePath: String) {
    let account = try accountDirectory(accountID, create: true)
    guard
      isSafe(partial),
      partial.deletingLastPathComponent().standardizedFileURL == account,
      partial.lastPathComponent.hasPrefix(Self.partialPrefix)
    else { throw AudioRangeError.storageFailure }
    let suffix = Self.safeExtension(format)
    let final = account.appendingPathComponent("\(UUID().uuidString).\(suffix)")
    try FileManager.default.moveItem(at: partial, to: final)
    return (final, try relativePath(for: final))
  }

  package func remove(_ download: OfflineDownload) throws {
    // A malformed row that names another account owns no removable file.
    guard let url = url(for: download) else { return }
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  package func removePartial(_ url: URL) throws {
    guard isSafe(url), url.lastPathComponent.hasPrefix(Self.partialPrefix) else {
      return
    }
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  package func fileURL(for download: OfflineDownload) -> URL? {
    url(for: download)
  }

  package func hasExpectedSize(_ download: OfflineDownload) -> Bool {
    guard let url = url(for: download) else { return false }
    return Self.fileSize(url) == download.byteCount
  }

  package func fileSize(_ url: URL) -> Int64? {
    guard isSafe(url) else { return nil }
    return Self.fileSize(url)
  }

  package func removeOrphans(
    accountID: Int64,
    keeping relativePaths: Set<String>
  ) throws -> Int {
    let account = try accountDirectory(accountID, create: false)
    guard FileManager.default.fileExists(atPath: account.path) else { return 0 }
    var removed = 0
    for file in try FileManager.default.contentsOfDirectory(
      at: account,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) {
      guard let relative = try? relativePath(for: file),
        !relativePaths.contains(relative)
      else { continue }
      try FileManager.default.removeItem(at: file)
      removed += 1
    }
    // Hidden interrupted artifacts are never completed downloads.
    for file in try FileManager.default.contentsOfDirectory(
      at: account,
      includingPropertiesForKeys: nil
    ) where file.lastPathComponent.hasPrefix(Self.partialPrefix)
      || file.lastPathComponent.hasPrefix(Self.deletionPrefix)
    {
      try FileManager.default.removeItem(at: file)
    }
    return removed
  }

  package func stageDeletion(_ download: OfflineDownload) throws -> StagedDeletion? {
    guard let original = url(for: download) else {
      throw AudioRangeError.storageFailure
    }
    guard FileManager.default.fileExists(atPath: original.path) else { return nil }
    let staged = original.deletingLastPathComponent().appendingPathComponent(
      Self.deletionPrefix + UUID().uuidString
    )
    try FileManager.default.moveItem(at: original, to: staged)
    return StagedDeletion(original: original, staged: staged)
  }

  package func rollback(_ deletion: StagedDeletion) throws {
    guard isSafe(deletion.original), isSafe(deletion.staged),
      FileManager.default.fileExists(atPath: deletion.staged.path)
    else { return }
    try FileManager.default.moveItem(at: deletion.staged, to: deletion.original)
  }

  package func finish(_ deletion: StagedDeletion) throws {
    guard isSafe(deletion.staged) else { return }
    if FileManager.default.fileExists(atPath: deletion.staged.path) {
      try FileManager.default.removeItem(at: deletion.staged)
    }
  }

  // MARK: Paths

  private func accountDirectory(_ accountID: Int64, create: Bool) throws -> URL {
    let url = directory.appendingPathComponent(String(accountID), isDirectory: true)
    guard isSafe(url) else { throw AudioRangeError.storageFailure }
    if create {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
      )
    }
    return url
  }

  private func url(for relativePath: String) -> URL? {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
    let url = directory.appendingPathComponent(relativePath).standardizedFileURL
    return isSafe(url) ? url : nil
  }

  private func url(for download: OfflineDownload) -> URL? {
    guard let url = url(for: download.relativePath) else { return nil }
    let account = directory
      .appendingPathComponent(String(download.accountID), isDirectory: true)
      .resolvingSymlinksInPath().path
    let accountRoot = account.hasSuffix("/") ? account : account + "/"
    guard url.resolvingSymlinksInPath().path.hasPrefix(accountRoot) else {
      return nil
    }
    return url
  }

  private func relativePath(for url: URL) throws -> String {
    let url = url.standardizedFileURL
    guard isSafe(url) else { throw AudioRangeError.storageFailure }
    return String(url.path.dropFirst(directory.path.count + 1))
  }

  private func isSafe(_ url: URL) -> Bool {
    let resolvedDirectory = directory.resolvingSymlinksInPath().path
    let root = resolvedDirectory.hasSuffix("/")
      ? resolvedDirectory
      : resolvedDirectory + "/"
    return url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root)
  }

  private static func safeExtension(_ format: String) -> String {
    let value = format.lowercased().filter {
      $0.isASCII && ($0.isLetter || $0.isNumber)
    }.prefix(12)
    return value.isEmpty ? "audio" : String(value)
  }

  private static func fileSize(_ url: URL) -> Int64? {
    guard let size = try? FileManager.default.attributesOfItem(
      atPath: url.path
    )[.size] as? NSNumber else { return nil }
    return size.int64Value
  }

  private static func removeInterruptedFiles(under root: URL) throws {
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: nil
    ) else { return }
    for case let url as URL in enumerator where
      url.lastPathComponent.hasPrefix(partialPrefix)
        || url.lastPathComponent.hasPrefix(deletionPrefix)
    {
      try FileManager.default.removeItem(at: url)
    }
  }
}

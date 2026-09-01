import CryptoKit
import Foundation

private final class AudioHTTPSRedirectDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(
      request.url?.scheme?.lowercased() == "https" ? request : nil
    )
  }
}

package protocol AudioByteFetching: Sendable {
  func fetch(
    url: URL,
    range: AudioByteRange,
    userAgent: String
  ) async throws -> AudioHTTPRangeResponse
}

/// Credential-free CDN transfer. Authentication has already ended before a
/// URL reaches this boundary.
package actor URLSessionAudioByteFetcher: AudioByteFetching {
  private let session: URLSession

  package init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 120
    configuration.waitsForConnectivity = false
    session = URLSession(
      configuration: configuration,
      delegate: AudioHTTPSRedirectDelegate(),
      delegateQueue: nil
    )
  }

  package func fetch(
    url: URL,
    range: AudioByteRange,
    userAgent: String
  ) async throws -> AudioHTTPRangeResponse {
    guard url.scheme?.lowercased() == "https" else {
      throw AudioRangeError.unsupportedResource
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue(
      "bytes=\(range.offset)-\(range.endOffset - 1)",
      forHTTPHeaderField: "Range"
    )
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse,
      response.url?.scheme?.lowercased() == "https"
    else {
      throw AudioRangeError.invalidHTTPResponse
    }
    return AudioHTTPRangeResponse(
      statusCode: response.statusCode,
      contentRange: response.value(forHTTPHeaderField: "Content-Range"),
      contentLength: response.value(forHTTPHeaderField: "Content-Length")
        .flatMap(Int64.init),
      mimeType: response.mimeType,
      data: data
    )
  }
}

/// Segment-backed, account-scoped disk cache. A segment is entered in the
/// manifest only after its bytes and the updated manifest both land.
package actor AudioRangeStore {
  private struct Segment: Codable, Equatable, Sendable {
    let offset: Int64
    let length: Int64
    let file: String

    var endOffset: Int64 { offset + length }
  }

  private struct Manifest: Codable, Sendable {
    let key: AudioCacheKey
    var segments: [Segment]
    var lastAccess: Date
  }

  private static let manifestName = "manifest.json"
  private let directory: URL
  private let now: @Sendable () -> Date
  private var limitBytes: Int64
  private var manifests: [AudioCacheKey: Manifest]
  private var pins: [AudioCacheKey: Int] = [:]
  private var failNextWrite = false

  package init(
    directory: URL,
    limitBytes: Int64,
    now: @escaping @Sendable () -> Date = Date.init
  ) throws {
    self.directory = directory.standardizedFileURL
    self.limitBytes = max(0, limitBytes)
    self.now = now
    try FileManager.default.createDirectory(
      at: self.directory,
      withIntermediateDirectories: true
    )
    var scanned = try Self.scan(directory: self.directory)
    var usage = scanned.values.reduce(0) { total, manifest in
      total + manifest.segments.reduce(0) { $0 + $1.length }
    }
    if usage > self.limitBytes {
      for manifest in scanned.values.sorted(by: { $0.lastAccess < $1.lastAccess })
      where usage > self.limitBytes {
        try FileManager.default.removeItem(
          at: self.directory.appendingPathComponent(
            Self.storageName(for: manifest.key),
            isDirectory: true
          )
        )
        scanned.removeValue(forKey: manifest.key)
        usage -= manifest.segments.reduce(0) { $0 + $1.length }
      }
    }
    manifests = scanned
  }

  package static func defaultDirectory() throws -> URL {
    guard
      let base = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
      ).first
    else { throw AudioRangeError.storageFailure }
    return base
      .appendingPathComponent("MacEase", isDirectory: true)
      .appendingPathComponent("AudioRanges", isDirectory: true)
  }

  package func pin(_ key: AudioCacheKey) {
    pins[key, default: 0] += 1
  }

  package func unpin(_ key: AudioCacheKey) {
    guard let count = pins[key] else { return }
    if count <= 1 { pins.removeValue(forKey: key) } else { pins[key] = count - 1 }
    try? evictIfNeeded()
  }

  package func setLimitBytes(_ bytes: Int64) throws {
    limitBytes = max(0, bytes)
    try evictIfNeeded()
  }

  package func diskUsageBytes() -> Int64 {
    manifests.values.reduce(0) { total, manifest in
      total + manifest.segments.reduce(0) { $0 + $1.length }
    }
  }

  /// Removes every unpinned resource and returns what remains on disk.
  package func clear() throws -> Int64 {
    for key in Array(manifests.keys) where pins[key] == nil {
      try removeResource(key)
    }
    return diskUsageBytes()
  }

  package func cachedData(
    for key: AudioCacheKey,
    range: AudioByteRange
  ) throws -> Data? {
    try validate(range, for: key)
    guard var manifest = manifests[key] else { return nil }
    var cursor = range.offset
    var result = Data()
    result.reserveCapacity(Int(range.length))

    for segment in manifest.segments.sorted(by: { $0.offset < $1.offset }) {
      if segment.endOffset <= cursor { continue }
      if segment.offset > cursor { return nil }
      let takeEnd = min(segment.endOffset, range.endOffset)
      let fileURL = resourceDirectory(for: key)
        .appendingPathComponent(segment.file)
      guard
        let size = Self.fileSize(fileURL), size == segment.length,
        let bytes = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
      else {
        try removeResource(key)
        throw AudioRangeError.corruptCache
      }
      let lower = Int(cursor - segment.offset)
      let upper = Int(takeEnd - segment.offset)
      result.append(bytes[lower..<upper])
      cursor = takeEnd
      if cursor == range.endOffset {
        manifest.lastAccess = now()
        manifests[key] = manifest
        try? writeManifest(manifest)
        return result
      }
    }
    return nil
  }

  package func firstMissingRange(
    for key: AudioCacheKey,
    within requested: AudioByteRange,
    maximumLength: Int64
  ) throws -> AudioByteRange? {
    try validate(requested, for: key)
    var cursor = requested.offset
    for segment in manifests[key]?.segments.sorted(by: { $0.offset < $1.offset }) ?? [] {
      if segment.endOffset <= cursor { continue }
      if segment.offset > cursor {
        return try AudioByteRange(
          offset: cursor,
          length: min(segment.offset - cursor, maximumLength)
        )
      }
      cursor = max(cursor, segment.endOffset)
      if cursor >= requested.endOffset { return nil }
    }
    guard cursor < requested.endOffset else { return nil }
    return try AudioByteRange(
      offset: cursor,
      length: min(requested.endOffset - cursor, maximumLength)
    )
  }

  package func store(
    _ response: ValidatedAudioRangeResponse,
    for key: AudioCacheKey
  ) throws {
    if failNextWrite {
      failNextWrite = false
      throw AudioRangeError.storageFailure
    }
    try validate(response.range, for: key)
    guard Int64(response.data.count) == response.range.length else {
      throw AudioRangeError.mismatchedLength
    }

    var manifest = manifests[key] ?? Manifest(
      key: key,
      segments: [],
      lastAccess: now()
    )
    let replacesResource = response.range.offset == 0
      && response.range.length == key.byteCount
    let replacedSegments = replacesResource ? manifest.segments : []
    if replacesResource {
      manifest.segments = []
    } else {
      guard !manifest.segments.contains(where: {
        $0.offset < response.range.endOffset
          && response.range.offset < $0.endOffset
      }) else { throw AudioRangeError.overlappingWrite }
    }

    let resourceDirectory = resourceDirectory(for: key)
    try FileManager.default.createDirectory(
      at: resourceDirectory,
      withIntermediateDirectories: true
    )
    let file =
      "segment-\(response.range.offset)-\(response.range.length)-\(UUID().uuidString).bin"
    let fileURL = resourceDirectory.appendingPathComponent(file)
    do {
      try response.data.write(to: fileURL, options: [.atomic])
      guard Self.fileSize(fileURL) == response.range.length else {
        throw AudioRangeError.storageFailure
      }
      manifest.segments.append(
        Segment(
          offset: response.range.offset,
          length: response.range.length,
          file: file
        )
      )
      manifest.segments.sort { $0.offset < $1.offset }
      manifest.lastAccess = now()
      try writeManifest(manifest)
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
      throw error
    }
    // From this point onward the new bytes and their manifest agree. A
    // cleanup or eviction failure may be reported, but must not remove the
    // segment that the committed manifest now names.
    manifests[key] = manifest
    for segment in replacedSegments where segment.file != file {
      try FileManager.default.removeItem(
        at: resourceDirectory.appendingPathComponent(segment.file)
      )
    }
    try evictIfNeeded()
  }

  // MARK: Test seams

  package func failNextWriteForTesting() { failNextWrite = true }

  package func corruptFirstSegmentForTesting(_ key: AudioCacheKey) throws {
    guard let segment = manifests[key]?.segments.first else { return }
    try Data([0]).write(
      to: resourceDirectory(for: key).appendingPathComponent(segment.file),
      options: [.atomic]
    )
  }

  package func containsForTesting(_ key: AudioCacheKey) -> Bool {
    manifests[key] != nil
  }

  // MARK: Disk

  private func validate(_ range: AudioByteRange, for key: AudioCacheKey) throws {
    guard key.byteCount > 0, range.endOffset <= key.byteCount else {
      throw AudioRangeError.rangeOutOfBounds
    }
  }

  private func resourceDirectory(for key: AudioCacheKey) -> URL {
    directory.appendingPathComponent(Self.storageName(for: key), isDirectory: true)
  }

  private func writeManifest(_ manifest: Manifest) throws {
    let data = try JSONEncoder().encode(manifest)
    try data.write(
      to: resourceDirectory(for: manifest.key)
        .appendingPathComponent(Self.manifestName),
      options: [.atomic]
    )
  }

  private func evictIfNeeded() throws {
    var usage = diskUsageBytes()
    guard usage > limitBytes else { return }
    let candidates = manifests.values
      .filter { pins[$0.key] == nil }
      .sorted { $0.lastAccess < $1.lastAccess }
    for manifest in candidates where usage > limitBytes {
      let bytes = manifest.segments.reduce(0) { $0 + $1.length }
      try removeResource(manifest.key)
      usage -= bytes
    }
  }

  private func removeResource(_ key: AudioCacheKey) throws {
    let url = resourceDirectory(for: key)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    manifests.removeValue(forKey: key)
  }

  private static func scan(directory: URL) throws -> [AudioCacheKey: Manifest] {
    var result: [AudioCacheKey: Manifest] = [:]
    let manager = FileManager.default
    let children = try manager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    for child in children {
      let manifestURL = child.appendingPathComponent(manifestName)
      guard
        let data = try? Data(contentsOf: manifestURL),
        let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
        storageName(for: manifest.key) == child.lastPathComponent,
        valid(manifest, at: child)
      else {
        try manager.removeItem(at: child)
        continue
      }
      result[manifest.key] = manifest
      let namedFiles = Set(manifest.segments.map(\.file) + [manifestName])
      for file in try manager.contentsOfDirectory(
        at: child,
        includingPropertiesForKeys: nil
      ) where !namedFiles.contains(file.lastPathComponent) {
        try manager.removeItem(at: file)
      }
    }
    return result
  }

  private static func valid(_ manifest: Manifest, at directory: URL) -> Bool {
    guard manifest.key.byteCount > 0 else { return false }
    var previousEnd: Int64 = 0
    for segment in manifest.segments.sorted(by: { $0.offset < $1.offset }) {
      guard
        segment.offset >= previousEnd,
        segment.length > 0,
        segment.offset <= Int64.max - segment.length,
        segment.endOffset <= manifest.key.byteCount,
        !segment.file.contains("/"),
        fileSize(directory.appendingPathComponent(segment.file)) == segment.length
      else { return false }
      previousEnd = segment.endOffset
    }
    return true
  }

  private static func storageName(for key: AudioCacheKey) -> String {
    let canonical = [
      String(key.accountID),
      String(key.songID),
      key.requestedQuality.rawValue,
      key.actualQuality ?? "",
      key.format,
      String(key.byteCount),
    ].joined(separator: "\u{1F}")
    return SHA256.hash(data: Data(canonical.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func fileSize(_ url: URL) -> Int64? {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let value = attributes[.size] as? NSNumber
    else { return nil }
    return value.int64Value
  }
}

/// Coordinates cache reads and the minimum missing HTTP ranges. One fetch per
/// key is active at a time; overlapping callers share it and then re-check the
/// manifest before asking for any remaining gap.
package actor AudioRangePipeline {
  package static let transferChunkBytes: Int64 = 512 * 1024

  /// Cancellation handlers cannot await the pipeline actor. This tiny locked
  /// group makes "the last waiter went away" synchronously cancel the shared
  /// task before a fast response can commit bytes.
  private final class WaiterGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: Set<UUID>
    private var task: Task<Void, any Error>?

    init(first: UUID) { waiters = [first] }

    func attach(_ task: Task<Void, any Error>) {
      lock.lock()
      self.task = task
      let shouldCancel = waiters.isEmpty
      lock.unlock()
      if shouldCancel { task.cancel() }
    }

    func add(_ waiter: UUID) {
      lock.lock()
      waiters.insert(waiter)
      lock.unlock()
    }

    func finish(_ waiter: UUID) -> Bool {
      lock.lock()
      waiters.remove(waiter)
      let empty = waiters.isEmpty
      lock.unlock()
      return empty
    }

    func cancel(_ waiter: UUID) -> Bool {
      lock.lock()
      waiters.remove(waiter)
      let empty = waiters.isEmpty
      let task = empty ? task : nil
      lock.unlock()
      task?.cancel()
      return empty
    }

    var isEmpty: Bool {
      lock.lock()
      defer { lock.unlock() }
      return waiters.isEmpty
    }
  }

  private struct InFlight {
    let id: UUID
    let sourceURL: URL
    let task: Task<Void, any Error>
    let waiters: WaiterGroup
  }

  private let store: AudioRangeStore
  private let fetcher: any AudioByteFetching
  private var inFlight: [AudioCacheKey: InFlight] = [:]

  package init(store: AudioRangeStore, fetcher: any AudioByteFetching) {
    self.store = store
    self.fetcher = fetcher
  }

  package func data(
    for resource: PlaybackResource,
    range: AudioByteRange,
    userAgent: String
  ) async throws -> Data {
    guard let key = resource.cacheKey, let url = resource.remoteURL else {
      throw AudioRangeError.unsupportedResource
    }
    guard range.endOffset <= key.byteCount else {
      throw AudioRangeError.rangeOutOfBounds
    }

    while true {
      try Task.checkCancellation()
      do {
        if let data = try await store.cachedData(for: key, range: range) {
          return data
        }
      } catch AudioRangeError.corruptCache {
        // The store removed the bad resource. Re-fetching is safe because no
        // corrupt segment was returned as a hit.
      }
      guard
        let missing = try await store.firstMissingRange(
          for: key,
          within: range,
          maximumLength: Self.transferChunkBytes
        )
      else { continue }
      try await fetch(
        key: key,
        url: url,
        range: missing,
        userAgent: userAgent
      )
    }
  }

  package func pin(_ key: AudioCacheKey) async { await store.pin(key) }

  package func unpin(_ key: AudioCacheKey) async { await store.unpin(key) }

  package func diskUsageBytes() async -> Int64 { await store.diskUsageBytes() }

  package func clear() async throws -> Int64 { try await store.clear() }

  package func setLimitBytes(_ bytes: Int64) async throws {
    try await store.setLimitBytes(bytes)
  }

  private func fetch(
    key: AudioCacheKey,
    url: URL,
    range: AudioByteRange,
    userAgent: String
  ) async throws {
    let waiter = UUID()
    let entryID: UUID
    let task: Task<Void, any Error>
    let waiters: WaiterGroup
    let sharesSource: Bool
    if let existing = inFlight[key], !existing.waiters.isEmpty {
      existing.waiters.add(waiter)
      entryID = existing.id
      task = existing.task
      waiters = existing.waiters
      sharesSource = existing.sourceURL == url
    } else {
      inFlight.removeValue(forKey: key)
      let id = UUID()
      let fetcher = self.fetcher
      let store = self.store
      let newWaiters = WaiterGroup(first: waiter)
      let newTask = Task<Void, any Error> {
        let response = try await fetcher.fetch(
          url: url,
          range: range,
          userAgent: userAgent
        )
        try Task.checkCancellation()
        let validated = try AudioHTTPRangeValidator.validate(
          response,
          requested: range,
          expectedByteCount: key.byteCount
        )
        try Task.checkCancellation()
        try await store.store(validated, for: key)
      }
      newWaiters.attach(newTask)
      inFlight[key] = InFlight(
        id: id,
        sourceURL: url,
        task: newTask,
        waiters: newWaiters
      )
      entryID = id
      task = newTask
      waiters = newWaiters
      sharesSource = true
    }

    do {
      try await withTaskCancellationHandler {
        try await task.value
        try Task.checkCancellation()
      } onCancel: {
        if waiters.cancel(waiter) {
          Task { await self.removeIfEmpty(key: key, entryID: entryID) }
        }
      }
      finishWaiter(waiter, key: key, entryID: entryID, waiters: waiters)
    } catch {
      finishWaiter(waiter, key: key, entryID: entryID, waiters: waiters)
      if !sharesSource {
        try Task.checkCancellation()
        if inFlight[key]?.id == entryID {
          inFlight.removeValue(forKey: key)
        }
        return
      }
      throw error
    }
  }

  private func removeIfEmpty(
    key: AudioCacheKey,
    entryID: UUID
  ) {
    guard let entry = inFlight[key], entry.id == entryID,
      entry.waiters.isEmpty
    else { return }
    inFlight.removeValue(forKey: key)
  }

  private func finishWaiter(
    _ waiter: UUID,
    key: AudioCacheKey,
    entryID: UUID,
    waiters: WaiterGroup
  ) {
    guard let entry = inFlight[key], entry.id == entryID else { return }
    if waiters.finish(waiter) {
      inFlight.removeValue(forKey: key)
    }
  }
}

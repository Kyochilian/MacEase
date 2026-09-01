import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

private actor FakeAudioByteFetcher: AudioByteFetching {
  enum Mode: Sendable {
    case partial
    case full
    case wrongContentRange
    case short
    case long
  }

  private let bytes: Data
  private let mode: Mode
  let gate = RequestGate()
  private var calls: [AudioByteRange] = []

  init(bytes: Data, mode: Mode = .partial) {
    self.bytes = bytes
    self.mode = mode
  }

  func fetch(
    url: URL,
    range: AudioByteRange,
    userAgent: String
  ) async throws -> AudioHTTPRangeResponse {
    calls.append(range)
    await gate.pass()
    try Task.checkCancellation()
    let lower = Int(range.offset)
    let upper = Int(range.endOffset)
    guard lower >= 0, upper <= bytes.count else {
      throw AudioRangeError.rangeOutOfBounds
    }
    let requested = bytes.subdata(in: lower..<upper)
    switch mode {
    case .partial:
      return AudioHTTPRangeResponse(
        statusCode: 206,
        contentRange:
          "bytes \(range.offset)-\(range.endOffset - 1)/\(bytes.count)",
        contentLength: range.length,
        mimeType: "audio/mpeg",
        data: requested
      )
    case .full:
      return AudioHTTPRangeResponse(
        statusCode: 200,
        contentRange: nil,
        contentLength: Int64(bytes.count),
        mimeType: "audio/mpeg",
        data: bytes
      )
    case .wrongContentRange:
      return AudioHTTPRangeResponse(
        statusCode: 206,
        contentRange:
          "bytes \(range.offset + 1)-\(range.endOffset)/\(bytes.count)",
        contentLength: range.length,
        mimeType: "audio/mpeg",
        data: requested
      )
    case .short:
      let short = requested.dropLast()
      return AudioHTTPRangeResponse(
        statusCode: 206,
        contentRange:
          "bytes \(range.offset)-\(range.endOffset - 1)/\(bytes.count)",
        contentLength: Int64(short.count),
        mimeType: "audio/mpeg",
        data: Data(short)
      )
    case .long:
      var long = requested
      long.append(0)
      return AudioHTTPRangeResponse(
        statusCode: 206,
        contentRange:
          "bytes \(range.offset)-\(range.endOffset - 1)/\(bytes.count)",
        contentLength: Int64(long.count),
        mimeType: "audio/mpeg",
        data: long
      )
    }
  }

  func recordedRanges() -> [AudioByteRange] { calls }
}

private actor ReplacingURLFetcher: AudioByteFetching {
  private let bytes: Data
  let oldGate = RequestGate()
  private var calls: [URL] = []

  init(bytes: Data) { self.bytes = bytes }

  func fetch(
    url: URL,
    range: AudioByteRange,
    userAgent: String
  ) async throws -> AudioHTTPRangeResponse {
    calls.append(url)
    if url.lastPathComponent == "old.mp3" {
      await oldGate.pass()
      throw URLError(.timedOut)
    }
    let lower = Int(range.offset)
    let upper = Int(range.endOffset)
    return AudioHTTPRangeResponse(
      statusCode: 206,
      contentRange: "bytes \(range.offset)-\(range.endOffset - 1)/\(bytes.count)",
      contentLength: range.length,
      mimeType: "audio/mpeg",
      data: bytes.subdata(in: lower..<upper)
    )
  }

  func recordedURLs() -> [URL] { calls }
}

private final class RangeTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1)

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func advance() {
    lock.lock()
    value = value.addingTimeInterval(1)
    lock.unlock()
  }
}

private func rangeBytes(_ count: Int = 64) -> Data {
  Data((0..<count).map { UInt8($0 % 251) })
}

private func rangeDirectory() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("MacEase-range-\(UUID().uuidString)", isDirectory: true)
}

private func rangeResource(
  accountID: Int64 = 42,
  songID: Int64 = 7,
  quality: PlaybackQuality = .standard,
  actualQuality: String? = "standard",
  format: String = "mp3",
  byteCount: Int64 = 64
) -> PlaybackResource {
  PlaybackResource(
    location: .remote(URL(string: "https://m8.music.126.net/signed.mp3")!),
    accountID: accountID,
    songID: songID,
    requestedQuality: quality,
    actualQuality: actualQuality,
    format: format,
    byteCount: byteCount,
    expiresAt: Date(timeIntervalSince1970: 1200)
  )
}

private func validatedSegment(
  _ bytes: Data,
  offset: Int64,
  length: Int64
) throws -> ValidatedAudioRangeResponse {
  let range = try AudioByteRange(offset: offset, length: length)
  let data = bytes.subdata(in: Int(offset)..<Int(offset + length))
  return ValidatedAudioRangeResponse(
    range: range,
    data: data,
    mimeType: "audio/mpeg"
  )
}

// MARK: - HTTP semantics

@Test func valid206AndComplete200ResponsesAreAccepted() throws {
  let bytes = rangeBytes(16)
  let requested = try AudioByteRange(offset: 4, length: 6)
  let partial = AudioHTTPRangeResponse(
    statusCode: 206,
    contentRange: "bytes 4-9/16",
    contentLength: 6,
    mimeType: "audio/mpeg",
    data: bytes.subdata(in: 4..<10)
  )
  let full = AudioHTTPRangeResponse(
    statusCode: 200,
    contentRange: nil,
    contentLength: 16,
    mimeType: "audio/mpeg",
    data: bytes
  )

  #expect(
    try AudioHTTPRangeValidator.validate(
      partial,
      requested: requested,
      expectedByteCount: 16
    ).range == requested
  )
  #expect(
    try AudioHTTPRangeValidator.validate(
      full,
      requested: requested,
      expectedByteCount: 16
    ).range == AudioByteRange(offset: 0, length: 16)
  )
}

@Test func incorrectContentRangesAndLengthsAreRejected() throws {
  let requested = try AudioByteRange(offset: 4, length: 4)
  let wrongRange = AudioHTTPRangeResponse(
    statusCode: 206,
    contentRange: "bytes 5-8/16",
    contentLength: 4,
    mimeType: nil,
    data: Data(repeating: 0, count: 4)
  )
  let short = AudioHTTPRangeResponse(
    statusCode: 206,
    contentRange: "bytes 4-7/16",
    contentLength: 3,
    mimeType: nil,
    data: Data(repeating: 0, count: 3)
  )
  let partial200 = AudioHTTPRangeResponse(
    statusCode: 200,
    contentRange: nil,
    contentLength: 4,
    mimeType: nil,
    data: Data(repeating: 0, count: 4)
  )

  #expect(throws: AudioRangeError.mismatchedContentRange) {
    try AudioHTTPRangeValidator.validate(
      wrongRange,
      requested: requested,
      expectedByteCount: 16
    )
  }
  #expect(throws: AudioRangeError.mismatchedLength) {
    try AudioHTTPRangeValidator.validate(
      short,
      requested: requested,
      expectedByteCount: 16
    )
  }
  #expect(throws: AudioRangeError.mismatchedLength) {
    try AudioHTTPRangeValidator.validate(
      partial200,
      requested: requested,
      expectedByteCount: 16
    )
  }
}

// MARK: - Hits, gaps and seeks

@Test func aCompleteRangeHitMakesNoRequest() async throws {
  let directory = rangeDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = rangeBytes()
  let resource = rangeResource()
  let key = try #require(resource.cacheKey)
  let store = try AudioRangeStore(directory: directory, limitBytes: 1024)
  try await store.store(
    validatedSegment(bytes, offset: 0, length: 64),
    for: key
  )
  let fetcher = FakeAudioByteFetcher(bytes: bytes)
  let pipeline = AudioRangePipeline(store: store, fetcher: fetcher)

  let result = try await pipeline.data(
    for: resource,
    range: AudioByteRange(offset: 8, length: 20),
    userAgent: "test"
  )

  #expect(result == bytes.subdata(in: 8..<28))
  #expect(await fetcher.recordedRanges().isEmpty)
}

@Test func aPartialHitFetchesOnlyTheMissingSuffix() async throws {
  let directory = rangeDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = rangeBytes()
  let resource = rangeResource()
  let key = try #require(resource.cacheKey)
  let store = try AudioRangeStore(directory: directory, limitBytes: 1024)
  try await store.store(
    validatedSegment(bytes, offset: 0, length: 8),
    for: key
  )
  let fetcher = FakeAudioByteFetcher(bytes: bytes)
  let pipeline = AudioRangePipeline(store: store, fetcher: fetcher)

  let result = try await pipeline.data(
    for: resource,
    range: AudioByteRange(offset: 0, length: 16),
    userAgent: "test"
  )

  #expect(result == bytes.subdata(in: 0..<16))
  #expect(
    await fetcher.recordedRanges()
      == [try AudioByteRange(offset: 8, length: 8)]
  )
}

@Test func aComplete200ResponseReplacesExistingPartialSegments() async throws {
  let directory = rangeDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = rangeBytes()
  let resource = rangeResource()
  let key = try #require(resource.cacheKey)
  let store = try AudioRangeStore(directory: directory, limitBytes: 1024)
  try await store.store(
    validatedSegment(bytes, offset: 0, length: 8),
    for: key
  )
  let fetcher = FakeAudioByteFetcher(bytes: bytes, mode: .full)
  let pipeline = AudioRangePipeline(store: store, fetcher: fetcher)

  let result = try await pipeline.data(
    for: resource,
    range: AudioByteRange(offset: 0, length: 16),
    userAgent: "test"
  )

  #expect(result == bytes.subdata(in: 0..<16))
  #expect(
    try await store.cachedData(
      for: key,
      range: AudioByteRange(offset: 0, length: Int64(bytes.count))
    ) == bytes
  )
  #expect(await store.diskUsageBytes() == Int64(bytes.count))
  #expect(await fetcher.recordedRanges() == [
    try AudioByteRange(offset: 8, length: 8)
  ])
}

@Test func randomSeekFetchesTheRequestedRangeOnly() async throws {
  let directory = rangeDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = rangeBytes()
  let store = try AudioRangeStore(directory: directory, limitBytes: 1024)
  let fetcher = FakeAudioByteFetcher(bytes: bytes)
  let pipeline = AudioRangePipeline(store: store, fetcher: fetcher)

  let result = try await pipeline.data(
    for: rangeResource(),
    range: AudioByteRange(offset: 37, length: 9),
    userAgent: "test"
  )

  #expect(result == bytes.subdata(in: 37..<46))
  #expect(
    await fetcher.recordedRanges()
      == [try AudioByteRange(offset: 37, length: 9)]
  )
}

@Test func multipleSegmentsFetchOnlyTheGap() async throws {
  let directory = rangeDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = rangeBytes()
  let resource = rangeResource()
  let key = try #require(resource.cacheKey)
  let store = try AudioRangeStore(directory: directory, limitBytes: 1024)
  try await store.store(validatedSegment(bytes, offset: 0, length: 4), for: key)
  try await store.store(validatedSegment(bytes, offset: 8, length: 4), for: key)
  let fetcher = FakeAudioByteFetcher(bytes: bytes)
  let pipeline = AudioRangePipeline(store: store, fetcher: fetcher)

  let result = try await pipeline.data(
    for: resource,
    range: AudioByteRange(offset: 0, length: 12),
    userAgent: "test"
  )

  #expect(result == bytes.subdata(in: 0..<12))
  #expect(
    await fetcher.recordedRanges()
      == [try AudioByteRange(offset: 4, length: 4)]
  )
}

// MARK: - In-flight sharing and cancellation

@Test func identicalRequestsShareOneFetch() async throws {
  let directory = rangeDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = rangeBytes()
  let resource = rangeResource()
  let key = try #require(resource.cacheKey)
  let store = try AudioRangeStore(directory: directory, limitBytes: 1024)
  await store.pin(key)
  let fetcher = FakeAudioByteFetcher(bytes: bytes)
  await fetcher.gate.close()
  let pipeline = AudioRangePipeline(store: store, fetcher: fetcher)
  let range = try AudioByteRange(offset: 0, length: 16)

  let first = Task { try await pipeline.data(for: resource, range: range, userAgent: "test") }
  while await fetcher.recordedRanges().isEmpty { await Task.yield() }
  let second = Task { try await pipeline.data(for: resource, range: range, userAgent: "test") }
  await Task.yield()
  await fetcher.gate.open()

  #expect(try await first.value == bytes.subdata(in: 0..<16))
  #expect(try await second.value == bytes.subdata(in: 0..<16))
  #expect(await fetcher.recordedRanges().count == 1)
  await store.unpin(key)
}

@Test func overlappingRequestsDoNotFetchTheOverlapTwice() async throws {
  let directory = rangeDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = rangeBytes()
  let resource = rangeResource()
  let key = try #require(resource.cacheKey)
  let store = try AudioRangeStore(directory: directory, limitBytes: 1024)
  await store.pin(key)
  let fetcher = FakeAudioByteFetcher(bytes: bytes)
  await fetcher.gate.close()
  let pipeline = AudioRangePipeline(store: store, fetcher: fetcher)

  let first = Task {
    try await pipeline.data(
      for: resource,
      range: AudioByteRange(offset: 0, length: 8),
      userAgent: "test"
    )
  }
  while await fetcher.recordedRanges().isEmpty { await Task.yield() }
  let second = Task {
    try await pipeline.data(
      for: resource,
      range: AudioByteRange(offset: 4, length: 8),
      userAgent: "test"
    )
  }
  await Task.yield()
  await fetcher.gate.open()

  _ = try await first.value
  _ = try await second.value
  #expect(
    await fetcher.recordedRanges()
      == [
        try AudioByteRange(offset: 0, length: 8),
        try AudioByteRange(offset: 8, length: 4),
      ]
  )
  await store.unpin(key)
}

@Test func cancellingTheLastWaiterPreventsACacheCommit() async throws {
  let directory = rangeDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = rangeBytes()
  let resource = rangeResource()
  let key = try #require(resource.cacheKey)
  let store = try AudioRangeStore(directory: directory, limitBytes: 1024)
  let fetcher = FakeAudioByteFetcher(bytes: bytes)
  await fetcher.gate.close()
  let pipeline = AudioRangePipeline(store: store, fetcher: fetcher)
  let task = Task {
    try await pipeline.data(
      for: resource,
      range: AudioByteRange(offset: 0, length: 16),
      userAgent: "test"
    )
  }
  while await fetcher.recordedRanges().isEmpty { await Task.yield() }

  task.cancel()
  await fetcher.gate.open()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(!(await store.containsForTesting(key)))
}

@Test func aFreshSignedURLCanRecoverFromAnOverlappingExpiredRequest() async throws {
  let directory = rangeDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = rangeBytes()
  let old = PlaybackResource(
    location: .remote(URL(string: "https://m8.music.126.net/old.mp3")!),
    accountID: 42,
    songID: 7,
    requestedQuality: .standard,
    actualQuality: "standard",
    format: "mp3",
    byteCount: Int64(bytes.count),
    expiresAt: nil
  )
  let fresh = PlaybackResource(
    location: .remote(URL(string: "https://m8.music.126.net/fresh.mp3")!),
    accountID: old.accountID,
    songID: old.songID,
    requestedQuality: old.requestedQuality,
    actualQuality: old.actualQuality,
    format: old.format,
    byteCount: old.byteCount,
    expiresAt: nil
  )
  #expect(old.cacheKey == fresh.cacheKey)
  let store = try AudioRangeStore(directory: directory, limitBytes: 1024)
  let fetcher = ReplacingURLFetcher(bytes: bytes)
  await fetcher.oldGate.close()
  let pipeline = AudioRangePipeline(store: store, fetcher: fetcher)
  let range = try AudioByteRange(offset: 0, length: 16)

  let oldTask = Task {
    try await pipeline.data(for: old, range: range, userAgent: "test")
  }
  while await fetcher.recordedURLs().isEmpty { await Task.yield() }
  let freshTask = Task {
    try await pipeline.data(for: fresh, range: range, userAgent: "test")
  }
  await Task.yield()
  await fetcher.oldGate.open()

  await #expect(throws: URLError.self) { try await oldTask.value }
  #expect(try await freshTask.value == bytes.subdata(in: 0..<16))
  #expect(
    await fetcher.recordedURLs().map(\.lastPathComponent)
      == ["old.mp3", "fresh.mp3"]
  )
}

// MARK: - Failures and corruption

@Test func invalidNetworkRangesNeverBecomeHits() async throws {
  for mode in [
    FakeAudioByteFetcher.Mode.wrongContentRange,
    .short,
    .long,
  ] {
    let directory = rangeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = rangeBytes()
    let resource = rangeResource()
    let key = try #require(resource.cacheKey)
    let store = try AudioRangeStore(directory: directory, limitBytes: 1024)
    let fetcher = FakeAudioByteFetcher(bytes: bytes, mode: mode)
    let pipeline = AudioRangePipeline(store: store, fetcher: fetcher)

    await #expect(throws: (any Error).self) {
      try await pipeline.data(
        for: resource,
        range: AudioByteRange(offset: 0, length: 8),
        userAgent: "test"
      )
    }
    #expect(!(await store.containsForTesting(key)))
  }
}

@Test func aDiskWriteFailureIsNotRegisteredAndCanRetry() async throws {
  let directory = rangeDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = rangeBytes()
  let resource = rangeResource()
  let key = try #require(resource.cacheKey)
  let store = try AudioRangeStore(directory: directory, limitBytes: 1024)
  await store.failNextWriteForTesting()
  let fetcher = FakeAudioByteFetcher(bytes: bytes)
  let pipeline = AudioRangePipeline(store: store, fetcher: fetcher)

  await #expect(throws: AudioRangeError.storageFailure) {
    try await pipeline.data(
      for: resource,
      range: AudioByteRange(offset: 0, length: 8),
      userAgent: "test"
    )
  }
  #expect(!(await store.containsForTesting(key)))

  #expect(
    try await pipeline.data(
      for: resource,
      range: AudioByteRange(offset: 0, length: 8),
      userAgent: "test"
    ) == bytes.subdata(in: 0..<8)
  )
}

@Test func aCorruptSegmentIsRemovedAndRefetched() async throws {
  let directory = rangeDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = rangeBytes()
  let resource = rangeResource()
  let key = try #require(resource.cacheKey)
  let store = try AudioRangeStore(directory: directory, limitBytes: 1024)
  try await store.store(validatedSegment(bytes, offset: 0, length: 8), for: key)
  try await store.corruptFirstSegmentForTesting(key)
  let fetcher = FakeAudioByteFetcher(bytes: bytes)
  let pipeline = AudioRangePipeline(store: store, fetcher: fetcher)

  #expect(
    try await pipeline.data(
      for: resource,
      range: AudioByteRange(offset: 0, length: 8),
      userAgent: "test"
    ) == bytes.subdata(in: 0..<8)
  )
  #expect(await fetcher.recordedRanges().count == 1)
}

@Test func corruptMetadataIsNotLoadedAfterRelaunch() async throws {
  let directory = rangeDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = rangeBytes()
  let resource = rangeResource()
  let key = try #require(resource.cacheKey)
  let first = try AudioRangeStore(directory: directory, limitBytes: 1024)
  try await first.store(validatedSegment(bytes, offset: 0, length: 8), for: key)
  try await first.corruptFirstSegmentForTesting(key)

  let reopened = try AudioRangeStore(directory: directory, limitBytes: 1024)

  #expect(!(await reopened.containsForTesting(key)))
  #expect(
    try await reopened.cachedData(
      for: key,
      range: AudioByteRange(offset: 0, length: 8)
    ) == nil
  )
}

// MARK: - Identity, LRU and clearing

@Test func accountSongQualityAndFormatAreSeparateKeys() throws {
  let base = try #require(rangeResource().cacheKey)
  let variants = [
    try #require(rangeResource(accountID: 43).cacheKey),
    try #require(rangeResource(songID: 8).cacheKey),
    try #require(rangeResource(quality: .lossless, actualQuality: "lossless").cacheKey),
    try #require(rangeResource(format: "flac").cacheKey),
  ]

  #expect(Set([base] + variants).count == 5)
}

@Test func leastRecentlyUsedUnpinnedResourceIsEvicted() async throws {
  let directory = rangeDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = rangeBytes(4)
  let clock = RangeTestClock()
  let store = try AudioRangeStore(
    directory: directory,
    limitBytes: 8,
    now: clock.now
  )
  let first = try #require(rangeResource(songID: 1, byteCount: 4).cacheKey)
  let second = try #require(rangeResource(songID: 2, byteCount: 4).cacheKey)
  let third = try #require(rangeResource(songID: 3, byteCount: 4).cacheKey)
  try await store.store(validatedSegment(bytes, offset: 0, length: 4), for: first)
  clock.advance()
  try await store.store(validatedSegment(bytes, offset: 0, length: 4), for: second)
  clock.advance()
  _ = try await store.cachedData(
    for: first,
    range: AudioByteRange(offset: 0, length: 4)
  )
  clock.advance()
  try await store.store(validatedSegment(bytes, offset: 0, length: 4), for: third)

  #expect(await store.containsForTesting(first))
  #expect(!(await store.containsForTesting(second)))
  #expect(await store.containsForTesting(third))
}

@Test func reopeningAppliesTheConfiguredLimitToExistingRanges() async throws {
  let directory = rangeDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = rangeBytes(4)
  let clock = RangeTestClock()
  let first = try #require(rangeResource(songID: 1, byteCount: 4).cacheKey)
  let second = try #require(rangeResource(songID: 2, byteCount: 4).cacheKey)
  let initial = try AudioRangeStore(
    directory: directory,
    limitBytes: 8,
    now: clock.now
  )
  try await initial.store(validatedSegment(bytes, offset: 0, length: 4), for: first)
  clock.advance()
  try await initial.store(validatedSegment(bytes, offset: 0, length: 4), for: second)

  let reopened = try AudioRangeStore(
    directory: directory,
    limitBytes: 4,
    now: clock.now
  )

  #expect(!(await reopened.containsForTesting(first)))
  #expect(await reopened.containsForTesting(second))
  #expect(await reopened.diskUsageBytes() == 4)
}

@Test func pinnedResourcesSurviveEvictionAndExplicitClear() async throws {
  let directory = rangeDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = rangeBytes(4)
  let store = try AudioRangeStore(directory: directory, limitBytes: 4)
  let pinned = try #require(rangeResource(songID: 1, byteCount: 4).cacheKey)
  let other = try #require(rangeResource(songID: 2, byteCount: 4).cacheKey)
  try await store.store(validatedSegment(bytes, offset: 0, length: 4), for: pinned)
  await store.pin(pinned)
  try await store.store(validatedSegment(bytes, offset: 0, length: 4), for: other)

  #expect(await store.containsForTesting(pinned))
  #expect(!(await store.containsForTesting(other)))
  try await store.setLimitBytes(0)
  #expect(try await store.clear() == 4)
  #expect(await store.containsForTesting(pinned))

  await store.unpin(pinned)
  #expect(!(await store.containsForTesting(pinned)))
  #expect(await store.diskUsageBytes() == 0)
}

@Test func explicitClearRemovesOnlyUnpinnedBytes() async throws {
  let directory = rangeDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = rangeBytes(4)
  let store = try AudioRangeStore(directory: directory, limitBytes: 16)
  let first = try #require(rangeResource(songID: 1, byteCount: 4).cacheKey)
  let second = try #require(rangeResource(songID: 2, byteCount: 4).cacheKey)
  try await store.store(validatedSegment(bytes, offset: 0, length: 4), for: first)
  try await store.store(validatedSegment(bytes, offset: 0, length: 4), for: second)
  await store.pin(first)

  #expect(try await store.clear() == 4)
  #expect(await store.containsForTesting(first))
  #expect(!(await store.containsForTesting(second)))
}

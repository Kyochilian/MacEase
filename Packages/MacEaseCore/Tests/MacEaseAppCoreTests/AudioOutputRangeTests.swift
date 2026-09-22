import AVFoundation
import Foundation
import NeteaseKit
import Testing

@testable import MacEaseAppCore

@Test(
  .enabled(if: ProcessInfo.processInfo.environment["MACEASE_ACCEPTANCE_AUDIO_PATH"] != nil),
  .timeLimit(.minutes(1))
)
@MainActor func suppliedAudioPassesMetadataFullDecodeAndNativeLocalSeek() async throws {
  let path = try #require(ProcessInfo.processInfo.environment["MACEASE_ACCEPTANCE_AUDIO_PATH"])
  let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
  let metadata = try await NeteaseSession.cloudFileMetadata(at: url)
  print("acceptance=localAudio stage=metadata bytes=\(metadata.fileSize) md5=\(metadata.md5)")
  let audio = try AVAudioFile(forReading: url)
  print("acceptance=localAudio stage=decoderOpened sampleRate=\(audio.processingFormat.sampleRate)")
  let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 16_384))
  var frames: Int64 = 0
  while audio.framePosition < audio.length {
    try Task.checkCancellation()
    try audio.read(into: buffer, frameCount: AVAudioFrameCount(min(16_384, audio.length - audio.framePosition)))
    guard buffer.frameLength > 0 else { break }
    frames += Int64(buffer.frameLength)
  }
  #expect(frames > 0)
  #expect(frames == audio.length)
  let decodedSeconds = Double(frames) / audio.processingFormat.sampleRate
  print("acceptance=localAudio stage=decoded frames=\(frames) seconds=\(decodedSeconds)")
  let output = AVPlayerAudioOutput()
  output.isMuted = true
  defer { output.teardown() }
  let info = try await output.prepare(
    resource: PlaybackResource(
      location: .local(url), accountID: 1, songID: 1, requestedQuality: .standard,
      actualQuality: nil, format: url.pathExtension, byteCount: metadata.fileSize, expiresAt: nil),
    userAgent: "MacEase local acceptance")
  #expect(info.isPlayable)
  print("acceptance=localAudio stage=prepared")
  let duration = try #require(info.durationSeconds)
  #expect(abs(decodedSeconds - duration) < 2)
  for position in [0, duration / 2, max(0, duration - 1)] {
    try await output.seek(to: position)
    #expect(abs((output.currentPositionSeconds ?? -10) - position) < 0.2)
  }
  print("acceptance=localAudio bytes=\(metadata.fileSize) md5=\(metadata.md5) "
    + "decodedFrames=\(frames) sampleRate=\(audio.processingFormat.sampleRate) "
    + "durationSeconds=\(duration) seeks=beginning,middle,end result=passed")
  print("acceptance=localMetadata title=\(metadata.title) artist=\(metadata.artist) album=\(metadata.album)")
}

private actor WAVRangeFetcher: AudioByteFetching {
  private let bytes: Data
  private(set) var ranges: [AudioByteRange] = []

  init(bytes: Data) { self.bytes = bytes }

  func fetch(
    url: URL,
    range: AudioByteRange,
    userAgent: String
  ) async throws -> AudioHTTPRangeResponse {
    ranges.append(range)
    let lower = Int(range.offset)
    let upper = Int(range.endOffset)
    guard lower >= 0, upper <= bytes.count else {
      throw AudioRangeError.rangeOutOfBounds
    }
    return AudioHTTPRangeResponse(
      statusCode: 206,
      contentRange:
        "bytes \(range.offset)-\(range.endOffset - 1)/\(bytes.count)",
      contentLength: range.length,
      mimeType: "audio/wav",
      data: bytes.subdata(in: lower..<upper)
    )
  }
}

private actor SupersedeWAVFetcher: AudioByteFetching {
  private let bytes: Data
  let oldGate = RequestGate()
  private(set) var oldArrived = false

  init(bytes: Data) { self.bytes = bytes }

  func fetch(
    url: URL,
    range: AudioByteRange,
    userAgent: String
  ) async throws -> AudioHTTPRangeResponse {
    if url.lastPathComponent == "old.wav" {
      oldArrived = true
      await oldGate.pass()
      try Task.checkCancellation()
    }
    let lower = Int(range.offset)
    let upper = Int(range.endOffset)
    return AudioHTTPRangeResponse(
      statusCode: 206,
      contentRange:
        "bytes \(range.offset)-\(range.endOffset - 1)/\(bytes.count)",
      contentLength: range.length,
      mimeType: "audio/wav",
      data: bytes.subdata(in: lower..<upper)
    )
  }
}

private actor HTTPFailureFetcher: AudioByteFetching {
  let statusCode: Int

  init(statusCode: Int) { self.statusCode = statusCode }

  func fetch(
    url: URL,
    range: AudioByteRange,
    userAgent: String
  ) async throws -> AudioHTTPRangeResponse {
    AudioHTTPRangeResponse(
      statusCode: statusCode,
      contentRange: nil,
      contentLength: 0,
      mimeType: nil,
      data: Data()
    )
  }
}

private func wavBytes() -> Data {
  let sampleRate: UInt32 = 8_000
  let sampleCount: UInt32 = 800
  let dataSize = sampleCount * 2
  var result = Data()
  result.append(contentsOf: "RIFF".utf8)
  appendLittleEndian(UInt32(36) + dataSize, to: &result)
  result.append(contentsOf: "WAVE".utf8)
  result.append(contentsOf: "fmt ".utf8)
  appendLittleEndian(UInt32(16), to: &result)
  appendLittleEndian(UInt16(1), to: &result)
  appendLittleEndian(UInt16(1), to: &result)
  appendLittleEndian(sampleRate, to: &result)
  appendLittleEndian(sampleRate * 2, to: &result)
  appendLittleEndian(UInt16(2), to: &result)
  appendLittleEndian(UInt16(16), to: &result)
  result.append(contentsOf: "data".utf8)
  appendLittleEndian(dataSize, to: &result)
  result.append(Data(repeating: 0, count: Int(dataSize)))
  return result
}

private func appendLittleEndian<T: FixedWidthInteger>(
  _ value: T,
  to data: inout Data
) {
  var value = value.littleEndian
  withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

@Test func eofProbeFinishesWithoutRequestingAByte() throws {
  let range = try AudioAssetResourceLoader.requestedRange(
    requestedOffset: 100,
    currentOffset: 100,
    requestedLength: 1,
    requestsAllDataToEnd: false,
    byteCount: 100
  )

  #expect(range == nil)
  #expect(throws: AudioRangeError.rangeOutOfBounds) {
    try AudioAssetResourceLoader.requestedRange(
      requestedOffset: 101,
      currentOffset: 101,
      requestedLength: 1,
      requestsAllDataToEnd: false,
      byteCount: 100
    )
  }
}

@Test func zeroLengthRangeFinishesWithoutRequestingAByte() throws {
  let range = try AudioAssetResourceLoader.requestedRange(
    requestedOffset: 40,
    currentOffset: 40,
    requestedLength: 0,
    requestsAllDataToEnd: false,
    byteCount: 100
  )

  #expect(range == nil)
}

@Test @MainActor func avPlayerLoadsThroughTheValidatedRangeDelegate() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("MacEase-output-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = wavBytes()
  let store = try AudioRangeStore(directory: directory, limitBytes: 1024 * 1024)
  let fetcher = WAVRangeFetcher(bytes: bytes)
  let pipeline = AudioRangePipeline(store: store, fetcher: fetcher)
  let output = AVPlayerAudioOutput(rangePipeline: pipeline)
  let resource = PlaybackResource(
    location: .remote(URL(string: "https://m8.music.126.net/signed.wav")!),
    accountID: 42,
    songID: 7,
    requestedQuality: .standard,
    actualQuality: "standard",
    format: "wav",
    byteCount: Int64(bytes.count),
    expiresAt: Date().addingTimeInterval(1200)
  )

  let info = try await output.prepare(resource: resource, userAgent: "test")

  #expect(info.isPlayable)
  #expect(info.durationSeconds != nil)
  #expect(!(await fetcher.ranges.isEmpty))
  #expect(await pipeline.diskUsageBytes() > 0)
  output.teardown()
}

@Test func unboundOrIncompleteResourcesRemainDirectOnly() {
  let base = PlaybackResource(
    location: .remote(URL(string: "https://m8.music.126.net/signed.mp3")!),
    accountID: nil,
    songID: 7,
    requestedQuality: .standard,
    actualQuality: "standard",
    format: "mp3",
    byteCount: 100,
    expiresAt: nil
  )
  let unknownLength = PlaybackResource(
    location: base.location,
    accountID: 42,
    songID: base.songID,
    requestedQuality: base.requestedQuality,
    actualQuality: base.actualQuality,
    format: base.format,
    byteCount: nil,
    expiresAt: nil
  )

  #expect(base.cacheKey == nil)
  #expect(unknownLength.cacheKey == nil)
}

@Test @MainActor func rangeHTTP403BecomesATypedExpiredResourceFailure() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("MacEase-output-403-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try AudioRangeStore(directory: directory, limitBytes: 1024 * 1024)
  let pipeline = AudioRangePipeline(
    store: store,
    fetcher: HTTPFailureFetcher(statusCode: 403)
  )
  let output = AVPlayerAudioOutput(rangePipeline: pipeline)
  let resource = PlaybackResource(
    location: .remote(URL(string: "https://m8.music.126.net/expired.wav")!),
    accountID: 42,
    songID: 7,
    requestedQuality: .standard,
    actualQuality: "standard",
    format: "wav",
    byteCount: Int64(wavBytes().count),
    expiresAt: Date().addingTimeInterval(-1)
  )

  await #expect(throws: AudioOutputFailure.resourceUnavailable(statusCode: 403)) {
    try await output.prepare(resource: resource, userAgent: "test")
  }
}

@Test @MainActor func supersededDelegateCannotCommitOrReplaceTheNewAsset() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("MacEase-supersede-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = wavBytes()
  let store = try AudioRangeStore(directory: directory, limitBytes: 1024 * 1024)
  let fetcher = SupersedeWAVFetcher(bytes: bytes)
  await fetcher.oldGate.close()
  let pipeline = AudioRangePipeline(store: store, fetcher: fetcher)
  let output = AVPlayerAudioOutput(rangePipeline: pipeline)
  let old = PlaybackResource(
    location: .remote(URL(string: "https://m8.music.126.net/old.wav")!),
    accountID: 42,
    songID: 1,
    requestedQuality: .standard,
    actualQuality: "standard",
    format: "wav",
    byteCount: Int64(bytes.count),
    expiresAt: nil
  )
  let new = PlaybackResource(
    location: .remote(URL(string: "https://m8.music.126.net/new.wav")!),
    accountID: 42,
    songID: 2,
    requestedQuality: .standard,
    actualQuality: "standard",
    format: "wav",
    byteCount: Int64(bytes.count),
    expiresAt: nil
  )
  let oldKey = try #require(old.cacheKey)
  let newKey = try #require(new.cacheKey)

  let oldPrepare = Task { @MainActor in
    try await output.prepare(resource: old, userAgent: "test")
  }
  while !(await fetcher.oldArrived) { await Task.yield() }

  let newInfo = try await output.prepare(resource: new, userAgent: "test")
  await fetcher.oldGate.open()
  await #expect(throws: CancellationError.self) { try await oldPrepare.value }

  #expect(newInfo.isPlayable)
  #expect(!(await store.containsForTesting(oldKey)))
  #expect(await store.containsForTesting(newKey))
  output.teardown()
}

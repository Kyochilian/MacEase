@preconcurrency import AVFoundation
import Foundation
import NeteaseKit
import UniformTypeIdentifiers

/// Bridges AVFoundation's pull-style loading requests to the validated range
/// pipeline. The original signed URL never appears in the custom asset URL;
/// this object alone owns the already-validated mapping.
package final class AudioAssetResourceLoader: NSObject,
  AVAssetResourceLoaderDelegate, @unchecked Sendable
{
  package let assetURL: URL
  package let callbackQueue = DispatchQueue(
    label: "com.macease.audio-resource-loader"
  )

  private let resource: PlaybackResource
  private let key: AudioCacheKey
  private let pipeline: AudioRangePipeline
  private let userAgent: String
  private let lock = NSLock()
  private var activeRequests: Set<ObjectIdentifier> = []
  private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var invalidated = false
  private var failure: AudioOutputFailure?

  package var reportedFailure: AudioOutputFailure? {
    lock.withLock { failure }
  }

  package init(
    resource: PlaybackResource,
    key: AudioCacheKey,
    pipeline: AudioRangePipeline,
    userAgent: String
  ) {
    self.resource = resource
    self.key = key
    self.pipeline = pipeline
    self.userAgent = userAgent
    let suffix = Self.safeExtension(resource.format)
    assetURL = URL(
      string: "macease-audio://range/\(UUID().uuidString).\(suffix)"
    )!
    super.init()
  }

  package func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest:
      AVAssetResourceLoadingRequest
  ) -> Bool {
    fillContentInformation(loadingRequest.contentInformationRequest)
    guard let dataRequest = loadingRequest.dataRequest else {
      loadingRequest.finishLoading()
      return true
    }

    let id = ObjectIdentifier(loadingRequest)
    guard begin(id) else { return false }
    let box = LoadingRequestBox(loadingRequest)
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.respond(to: box.value, dataRequest: dataRequest)
        guard self.finish(id) else { return }
        box.value.finishLoading()
      } catch {
        self.recordFailure(error)
        guard self.finish(id) else { return }
        box.value.finishLoading(with: Self.loadingError(error))
      }
    }
    attach(task, to: id)
    return true
  }

  package func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    cancel(ObjectIdentifier(loadingRequest))
  }

  package func cancelAll() {
    lock.lock()
    invalidated = true
    activeRequests.removeAll()
    let pending = Array(tasks.values)
    tasks.removeAll()
    lock.unlock()
    for task in pending { task.cancel() }
  }

  private func respond(
    to loadingRequest: AVAssetResourceLoadingRequest,
    dataRequest: AVAssetResourceLoadingDataRequest
  ) async throws {
    guard
      let requestedRange = try Self.requestedRange(
        requestedOffset: dataRequest.requestedOffset,
        currentOffset: dataRequest.currentOffset,
        requestedLength: dataRequest.requestedLength,
        requestsAllDataToEnd: dataRequest.requestsAllDataToEndOfResource,
        byteCount: key.byteCount
      )
    else { return }

    var cursor = requestedRange.lowerBound
    while cursor < requestedRange.upperBound {
      try Task.checkCancellation()
      let length = min(
        AudioRangePipeline.transferChunkBytes,
        requestedRange.upperBound - cursor
      )
      let range = try AudioByteRange(offset: cursor, length: length)
      let bytes = try await pipeline.data(
        for: resource,
        range: range,
        userAgent: userAgent
      )
      try Task.checkCancellation()
      guard Int64(bytes.count) == length else {
        throw AudioRangeError.mismatchedLength
      }
      dataRequest.respond(with: bytes)
      cursor += length
    }
  }

  /// Computes the unread byte interval. EOF probes and zero-length reads are
  /// successful no-ops; only offsets beyond the resource are out of bounds.
  package static func requestedRange(
    requestedOffset: Int64,
    currentOffset: Int64,
    requestedLength: Int,
    requestsAllDataToEnd: Bool,
    byteCount: Int64
  ) throws -> Range<Int64>? {
    let currentOffset = max(currentOffset, requestedOffset)
    guard requestedOffset >= 0, currentOffset >= 0, requestedLength >= 0 else {
      throw AudioRangeError.invalidRange
    }
    guard requestedOffset <= byteCount, currentOffset <= byteCount else {
      throw AudioRangeError.rangeOutOfBounds
    }

    let requestedEnd: Int64
    if requestsAllDataToEnd {
      requestedEnd = byteCount
    } else {
      let requestedLength = Int64(requestedLength)
      guard requestedOffset <= Int64.max - requestedLength else {
        throw AudioRangeError.invalidRange
      }
      requestedEnd = min(requestedOffset + requestedLength, byteCount)
    }
    guard currentOffset < requestedEnd else { return nil }
    return currentOffset..<requestedEnd
  }

  private func fillContentInformation(
    _ request: AVAssetResourceLoadingContentInformationRequest?
  ) {
    guard let request else { return }
    request.contentLength = key.byteCount
    request.isByteRangeAccessSupported = true
    request.contentType = Self.contentType(format: resource.format)
  }

  private func begin(_ id: ObjectIdentifier) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !invalidated else { return false }
    activeRequests.insert(id)
    return true
  }

  private func attach(_ task: Task<Void, Never>, to id: ObjectIdentifier) {
    lock.lock()
    guard activeRequests.contains(id), !invalidated else {
      lock.unlock()
      task.cancel()
      return
    }
    tasks[id] = task
    lock.unlock()
  }

  private func finish(_ id: ObjectIdentifier) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    tasks.removeValue(forKey: id)
    return activeRequests.remove(id) != nil && !invalidated
  }

  private func cancel(_ id: ObjectIdentifier) {
    lock.lock()
    activeRequests.remove(id)
    let task = tasks.removeValue(forKey: id)
    lock.unlock()
    task?.cancel()
  }

  private func recordFailure(_ error: any Error) {
    guard case AudioRangeError.unsupportedStatus(let statusCode) = error,
      PlaybackExpiryPolicy.confirmsInvalidURL(statusCode: statusCode)
    else { return }
    lock.withLock {
      if failure == nil {
        failure = .resourceUnavailable(statusCode: statusCode)
      }
    }
  }

  private static func contentType(format: String?) -> String {
    guard
      let format = format?.trimmingCharacters(in: .whitespacesAndNewlines),
      !format.isEmpty,
      let type = UTType(filenameExtension: format)
    else { return UTType.audio.identifier }
    return type.identifier
  }

  private static func safeExtension(_ format: String?) -> String {
    let value = (format ?? "audio").lowercased().filter {
      $0.isASCII && ($0.isLetter || $0.isNumber)
    }.prefix(12)
    return value.isEmpty ? "audio" : String(value)
  }

  nonisolated private static func loadingError(_ error: any Error) -> NSError {
    let error = error as NSError
    if error.domain == NSURLErrorDomain {
      return error
    }
    return NSError(
      domain: "MacEase.AudioRange",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: String(describing: error)]
    )
  }

  /// AVFoundation request objects are thread-safe for delegate completion but
  /// do not declare Sendable. The delegate owns each object until completion.
  private struct LoadingRequestBox: @unchecked Sendable {
    let value: AVAssetResourceLoadingRequest

    init(_ value: AVAssetResourceLoadingRequest) { self.value = value }
  }
}

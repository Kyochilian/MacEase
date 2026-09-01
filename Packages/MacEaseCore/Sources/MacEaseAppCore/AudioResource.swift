import Foundation
import NeteaseKit

/// Everything the AVFoundation boundary needs to identify and load one
/// playable resource. A signed CDN URL is a location, never an identity.
package struct PlaybackResource: Equatable, Sendable {
  package enum Location: Equatable, Sendable {
    case remote(URL)
    case local(URL)
  }

  package let location: Location
  package let accountID: Int64?
  package let songID: Int64
  package let requestedQuality: PlaybackQuality
  package let actualQuality: String?
  package let format: String?
  package let byteCount: Int64?
  package let expiresAt: Date?

  package init(
    location: Location,
    accountID: Int64?,
    songID: Int64,
    requestedQuality: PlaybackQuality,
    actualQuality: String?,
    format: String?,
    byteCount: Int64?,
    expiresAt: Date?
  ) {
    self.location = location
    self.accountID = accountID
    self.songID = songID
    self.requestedQuality = requestedQuality
    self.actualQuality = actualQuality
    self.format = format
    self.byteCount = byteCount
    self.expiresAt = expiresAt
  }

  package var remoteURL: URL? {
    guard case .remote(let url) = location else { return nil }
    return url
  }

  /// Cacheability is deliberately stricter than playability. An unbound
  /// account, an unknown length, or a non-HTTPS legacy URL can still play
  /// directly, but none can create an account-scoped range cache entry.
  package var cacheKey: AudioCacheKey? {
    guard
      case .remote(let url) = location,
      url.scheme?.lowercased() == "https",
      let accountID,
      let byteCount, byteCount > 0,
      let format = format?.trimmingCharacters(in: .whitespacesAndNewlines),
      !format.isEmpty
    else { return nil }
    return AudioCacheKey(
      accountID: accountID,
      songID: songID,
      requestedQuality: requestedQuality,
      actualQuality: actualQuality,
      format: format,
      byteCount: byteCount
    )
  }
}

/// Stable identity for cache bytes. It contains no URL, credential or token.
package struct AudioCacheKey: Hashable, Codable, Sendable {
  package let accountID: Int64
  package let songID: Int64
  package let requestedQuality: PlaybackQuality
  package let actualQuality: String?
  package let format: String
  package let byteCount: Int64

  package init(
    accountID: Int64,
    songID: Int64,
    requestedQuality: PlaybackQuality,
    actualQuality: String?,
    format: String,
    byteCount: Int64
  ) {
    self.accountID = accountID
    self.songID = songID
    self.requestedQuality = requestedQuality
    self.actualQuality = actualQuality
    self.format = format
    self.byteCount = byteCount
  }
}

package struct AudioByteRange: Equatable, Hashable, Codable, Sendable {
  package let offset: Int64
  package let length: Int64

  package init(offset: Int64, length: Int64) throws {
    guard offset >= 0, length > 0, offset <= Int64.max - length else {
      throw AudioRangeError.invalidRange
    }
    self.offset = offset
    self.length = length
  }

  package var endOffset: Int64 { offset + length }
}

package enum AudioRangeError: Error, Equatable, Sendable {
  case invalidRange
  case rangeOutOfBounds
  case unsupportedResource
  case unsupportedStatus(Int)
  case missingContentRange
  case malformedContentRange
  case mismatchedContentRange
  case mismatchedLength
  case corruptCache
  case overlappingWrite
  case storageFailure
  case invalidHTTPResponse
}

package struct AudioHTTPRangeResponse: Equatable, Sendable {
  package let statusCode: Int
  package let contentRange: String?
  package let contentLength: Int64?
  package let mimeType: String?
  package let data: Data

  package init(
    statusCode: Int,
    contentRange: String?,
    contentLength: Int64?,
    mimeType: String?,
    data: Data
  ) {
    self.statusCode = statusCode
    self.contentRange = contentRange
    self.contentLength = contentLength
    self.mimeType = mimeType
    self.data = data
  }
}

package struct ValidatedAudioRangeResponse: Equatable, Sendable {
  package let range: AudioByteRange
  package let data: Data
  package let mimeType: String?
}

/// Shared by streaming and downloading so both accept exactly the same HTTP
/// byte semantics.
package enum AudioHTTPRangeValidator {
  package static func validate(
    _ response: AudioHTTPRangeResponse,
    requested: AudioByteRange,
    expectedByteCount: Int64
  ) throws -> ValidatedAudioRangeResponse {
    guard expectedByteCount > 0, requested.endOffset <= expectedByteCount else {
      throw AudioRangeError.rangeOutOfBounds
    }
    let received = Int64(response.data.count)
    if let contentLength = response.contentLength, contentLength != received {
      throw AudioRangeError.mismatchedLength
    }

    switch response.statusCode {
    case 206:
      guard let value = response.contentRange else {
        throw AudioRangeError.missingContentRange
      }
      let parsed = try parseContentRange(value)
      guard
        parsed.start == requested.offset,
        parsed.endInclusive == requested.endOffset - 1,
        parsed.total == expectedByteCount
      else { throw AudioRangeError.mismatchedContentRange }
      guard received == requested.length else {
        throw AudioRangeError.mismatchedLength
      }
      return ValidatedAudioRangeResponse(
        range: requested,
        data: response.data,
        mimeType: response.mimeType
      )

    case 200:
      // A server may ignore Range. The only safe 200 is a provably complete
      // representation; it can satisfy any subrange after being cached.
      guard response.contentRange == nil, received == expectedByteCount else {
        throw AudioRangeError.mismatchedLength
      }
      let full = try AudioByteRange(offset: 0, length: expectedByteCount)
      return ValidatedAudioRangeResponse(
        range: full,
        data: response.data,
        mimeType: response.mimeType
      )

    default:
      throw AudioRangeError.unsupportedStatus(response.statusCode)
    }
  }

  private static func parseContentRange(
    _ value: String
  ) throws -> (start: Int64, endInclusive: Int64, total: Int64) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix("bytes ") else {
      throw AudioRangeError.malformedContentRange
    }
    let body = trimmed.dropFirst(6)
    let halves = body.split(separator: "/", omittingEmptySubsequences: false)
    guard halves.count == 2, halves[1] != "*" else {
      throw AudioRangeError.malformedContentRange
    }
    let bounds = halves[0].split(separator: "-", omittingEmptySubsequences: false)
    guard
      bounds.count == 2,
      let start = Int64(bounds[0]),
      let end = Int64(bounds[1]),
      let total = Int64(halves[1]),
      start >= 0,
      end >= start,
      total > end
    else { throw AudioRangeError.malformedContentRange }
    return (start, end, total)
  }
}

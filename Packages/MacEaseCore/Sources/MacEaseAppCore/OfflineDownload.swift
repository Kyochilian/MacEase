import Foundation
import NeteaseKit

package struct OfflineDownloadID: Hashable, Codable, Sendable {
  package let accountID: Int64
  package let songID: Int64
  package let requestedQuality: PlaybackQuality

  package init(
    accountID: Int64,
    songID: Int64,
    requestedQuality: PlaybackQuality
  ) {
    self.accountID = accountID
    self.songID = songID
    self.requestedQuality = requestedQuality
  }
}

/// A completed, account-owned local audio file. The signed URL that produced
/// it is intentionally absent.
package struct OfflineDownload: Equatable, Sendable, Identifiable {
  package let id: OfflineDownloadID
  package let track: Track
  package let actualQuality: String
  package let format: String
  package let byteCount: Int64
  package let relativePath: String
  package let createdAt: Date

  package init(
    accountID: Int64,
    track: Track,
    requestedQuality: PlaybackQuality,
    actualQuality: String,
    format: String,
    byteCount: Int64,
    relativePath: String,
    createdAt: Date
  ) {
    id = OfflineDownloadID(
      accountID: accountID,
      songID: track.id,
      requestedQuality: requestedQuality
    )
    self.track = track
    self.actualQuality = actualQuality
    self.format = format
    self.byteCount = byteCount
    self.relativePath = relativePath
    self.createdAt = createdAt
  }

  package var requestedQuality: PlaybackQuality { id.requestedQuality }
  package var accountID: Int64 { id.accountID }
}

package struct StoredDownloads: Sendable {
  package let downloads: [OfflineDownload]
  package let discardedCorruptRows: Int
}

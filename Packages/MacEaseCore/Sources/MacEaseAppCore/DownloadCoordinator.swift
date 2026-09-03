@preconcurrency import AVFoundation
import Foundation
import NeteaseKit
import Observation

package typealias OfflineAudioValidating = @Sendable (URL) async -> Bool

package enum OfflineAudioValidation {
  package static func isPlayable(_ url: URL) async -> Bool {
    guard url.isFileURL else { return false }
    let asset = AVURLAsset(url: url)
    do {
      guard try await asset.load(.isPlayable) else { return false }
      return try await !asset.loadTracks(withMediaType: .audio).isEmpty
    } catch {
      return false
    }
  }
}

private enum DownloadFailure: Error {
  case unavailable
  case invalidResource
  case expiredURL
  case unplayableFile
}

package enum DownloadTerminalFailure: Equatable, Sendable {
  case unavailable
  case connection
  case invalidAudio
  case storage
  case other

  package var message: String {
    switch self {
    case .unavailable: "This track is not available for download."
    case .connection: "The download could not be completed because of a connection problem."
    case .invalidAudio: "The downloaded audio could not be verified."
    case .storage: "MacEase could not save the downloaded audio."
    case .other: "The download could not be completed."
    }
  }
}

package enum DownloadTerminalOutcome: Equatable, Sendable {
  case succeeded
  case failed(DownloadTerminalFailure)
}

package struct DownloadTerminalEvent: Equatable, Sendable {
  package let taskID: UUID
  package let accountID: Int64
  package let track: Track
  package let outcome: DownloadTerminalOutcome

  package init(
    taskID: UUID,
    accountID: Int64,
    track: Track,
    outcome: DownloadTerminalOutcome
  ) {
    self.taskID = taskID
    self.accountID = accountID
    self.track = track
    self.outcome = outcome
  }
}

/// Owns the one foreground download and the current account's completed
/// files. URL resolution uses the ordinary read arbitration; the much longer
/// CDN transfer begins only after that token has been released.
@MainActor
@Observable
package final class DownloadCoordinator: SessionGuardedCoordinator {
  package enum Activity: Equatable {
    case idle
    case resolving(songID: Int64)
    case transferring(songID: Int64)
  }

  @ObservationIgnored private let transport: any NeteaseTransporting
  @ObservationIgnored package let vault: any CredentialStoring
  @ObservationIgnored private let arbiter: OperationArbiter
  @ObservationIgnored private let ranges: AudioRangePipeline?
  @ObservationIgnored private let store: LibraryStore
  @ObservationIgnored private let files: OfflineAudioFiles
  @ObservationIgnored private let validator: OfflineAudioValidating
  @ObservationIgnored private let now: @Sendable () -> Date
  @ObservationIgnored private weak var playback: PlaybackController?
  @ObservationIgnored private var accountID: Int64?
  @ObservationIgnored package private(set) var generation = 0
  @ObservationIgnored private var operationToken: OperationToken?
  @ObservationIgnored private var downloadTask: Task<Void, Never>?
  @ObservationIgnored private var downloadTaskID: UUID?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
  @ObservationIgnored private var maintenanceTaskID: UUID?
  @ObservationIgnored private var localURLs: [OfflineDownloadID: URL] = [:]
  @ObservationIgnored package var onTerminalEvent:
    (@MainActor (DownloadTerminalEvent) -> Void)?

  package private(set) var downloads: [OfflineDownload] = []
  package private(set) var activity: Activity = .idle
  package private(set) var progress: Double?
  package private(set) var lastFailure: String?
  package var status = "Sign in to see downloads"

  package var noStoredSessionStatus: String {
    "No stored session to resolve the download"
  }

  package var isDownloading: Bool { downloadTask != nil }
  package var isMaintaining: Bool { maintenanceTask != nil }
  package var isLoading: Bool { loadTask != nil }
  package var canCreateDownloads: Bool { ranges != nil }
  package var downloadCreationUnavailableReason: String? {
    ranges == nil ? Self.unavailablePipelineMessage : nil
  }
  package var totalBytes: Int64 { downloads.reduce(0) { $0 + $1.byteCount } }

  private static let unavailablePipelineMessage =
    "Temporary audio pipeline is unavailable; new downloads cannot be created"

  package init(
    transport: any NeteaseTransporting,
    vault: any CredentialStoring,
    arbiter: OperationArbiter,
    ranges: AudioRangePipeline?,
    store: LibraryStore,
    files: OfflineAudioFiles,
    validator: @escaping OfflineAudioValidating = OfflineAudioValidation.isPlayable,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.transport = transport
    self.vault = vault
    self.arbiter = arbiter
    self.ranges = ranges
    self.store = store
    self.files = files
    self.validator = validator
    self.now = now
  }

  package func attach(playback: PlaybackController) {
    self.playback = playback
  }

  /// Called synchronously from the validated-account transition. Cancelling
  /// here means the old account cannot wait for SwiftUI task scheduling before
  /// it stops transferring or committing.
  package func bind(accountID: Int64?) {
    guard self.accountID != accountID else { return }
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
    maintenanceTask?.cancel()
    downloadTask?.cancel()
    if let operationToken {
      self.operationToken = nil
      arbiter.end(operationToken, outcome: .cancelled)
    }
    self.accountID = accountID
    downloads = []
    localURLs = [:]
    activity = .idle
    progress = nil
    lastFailure = nil

    guard let accountID else {
      status = "Sign in to see downloads"
      return
    }
    status = downloadTask == nil ? "Loading downloads" : "Canceling the previous download"
    let generation = generation
    loadTask = Task { [weak self] in
      await self?.load(accountID: accountID, generation: generation)
    }
  }

  package func clearSessionScopedData() {
    bind(accountID: nil)
  }

  package func startDownload(
    track: Track,
    quality: PlaybackQuality,
    session: any SessionProviding
  ) {
    guard downloadTask == nil, maintenanceTask == nil, loadTask == nil else {
      return
    }
    guard let account = session.account, account.userID == accountID else {
      status = "Validate the session before downloading"
      return
    }
    guard ranges != nil else {
      let message = Self.unavailablePipelineMessage
      lastFailure = message
      status = message
      return
    }
    let id = OfflineDownloadID(
      accountID: account.userID,
      songID: track.id,
      requestedQuality: quality
    )
    guard !downloads.contains(where: { $0.id == id }) else {
      status = "This quality is already downloaded"
      return
    }
    guard
      let token = arbiter.begin(name: "Download URL", effect: .playbackResolution)
    else {
      status = "Another account operation is in progress"
      return
    }

    operationToken = token
    let taskID = UUID()
    downloadTaskID = taskID
    let generation = generation
    activity = .resolving(songID: track.id)
    progress = nil
    lastFailure = nil
    status = "Resolving download URL (1 request)"
    downloadTask = Task { [weak self] in
      guard let self else { return }
      let outcome = await self.runDownload(
        track: track,
        quality: quality,
        account: account,
        session: session,
        generation: generation,
        taskID: taskID,
        operation: token
      )
      self.finishDownloadTask(
        taskID,
        accountID: account.userID,
        generation: generation,
        track: track,
        outcome: outcome
      )
    }
  }

  package func cancelDownload() {
    guard let downloadTask else { return }
    downloadTask.cancel()
    if let operationToken {
      self.operationToken = nil
      arbiter.end(operationToken, outcome: .cancelled)
    }
    activity = .idle
    progress = nil
    status = "Download canceled"
  }

  package func delete(_ download: OfflineDownload) {
    guard maintenanceTask == nil, downloadTask == nil,
      download.accountID == accountID,
      downloads.contains(where: { $0.id == download.id })
    else { return }
    stopIfPlaying(download.id)
    let generation = generation
    let taskID = UUID()
    maintenanceTaskID = taskID
    maintenanceTask = Task { [weak self] in
      guard let self else { return }
      await self.delete(download, generation: generation)
      self.finishMaintenanceTask(taskID)
    }
  }

  package func clearAll() {
    guard maintenanceTask == nil, downloadTask == nil,
      let accountID, !downloads.isEmpty
    else { return }
    if let active = playback?.activeOfflineDownloadID,
      active.accountID == accountID
    {
      playback?.stopForDeletedDownload()
    }
    let snapshot = downloads
    let generation = generation
    let taskID = UUID()
    maintenanceTaskID = taskID
    maintenanceTask = Task { [weak self] in
      guard let self else { return }
      await self.clear(
        snapshot,
        accountID: accountID,
        generation: generation
      )
      self.finishMaintenanceTask(taskID)
    }
  }

  /// Exact requested-quality matching is intentional. A downloaded lossless
  /// file must not silently satisfy a later request whose product semantics
  /// differ, and another account is never considered.
  package func playbackResource(
    songID: Int64,
    requestedQuality: PlaybackQuality,
    accountID: Int64
  ) -> PlaybackResource? {
    let id = OfflineDownloadID(
      accountID: accountID,
      songID: songID,
      requestedQuality: requestedQuality
    )
    guard let download = downloads.first(where: { $0.id == id }) else {
      return nil
    }
    return playbackResource(for: download)
  }

  /// Read-only counterpart used by command enablement. It validates the same
  /// exact account/song/requested-quality file without deleting a damaged
  /// record merely because a menu was opened.
  package func hasPlaybackResource(
    songID: Int64,
    requestedQuality: PlaybackQuality,
    accountID: Int64
  ) -> Bool {
    let id = OfflineDownloadID(
      accountID: accountID,
      songID: songID,
      requestedQuality: requestedQuality
    )
    guard let download = downloads.first(where: { $0.id == id }),
      let url = localURLs[id]
    else { return false }
    return Self.fileSize(url) == download.byteCount
  }

  package func playbackResource(for download: OfflineDownload) -> PlaybackResource? {
    guard download.accountID == accountID,
      downloads.contains(where: { $0.id == download.id }),
      let url = localURLs[download.id],
      Self.fileSize(url) == download.byteCount
    else {
      if download.accountID == accountID,
        downloads.contains(where: { $0.id == download.id })
      {
        discardInvalid(download)
      }
      return nil
    }
    return PlaybackResource(
      location: .local(url),
      accountID: download.accountID,
      songID: download.track.id,
      requestedQuality: download.requestedQuality,
      actualQuality: download.actualQuality,
      format: download.format,
      byteCount: download.byteCount,
      expiresAt: nil
    )
  }

  /// AVFoundation is the final authority after a file has passed the startup
  /// check. If it later rejects that exact local resource, remove it from the
  /// current account immediately so bounded online recovery does not reopen
  /// the same damaged file.
  package func invalidatePlaybackResource(_ id: OfflineDownloadID) {
    guard id.accountID == accountID,
      let download = downloads.first(where: { $0.id == id })
    else { return }
    discardInvalid(download)
  }

  package func settleLoadingForTesting() async {
    await loadTask?.value
  }

  package func settleDownloadForTesting() async {
    await downloadTask?.value
  }

  package func settleMaintenanceForTesting() async {
    await maintenanceTask?.value
  }

  // MARK: Download

  private func runDownload(
    track: Track,
    quality: PlaybackQuality,
    account: NeteaseAccount,
    session: any SessionProviding,
    generation: Int,
    taskID: UUID,
    operation: OperationToken
  ) async -> DownloadTerminalOutcome? {
    var resolutionIsHeld = true
    var credential: NeteaseCredential?
    defer {
      if resolutionIsHeld {
        releaseSessionOperation(
          operation,
          currentToken: &self.operationToken,
          arbiter: self.arbiter,
          outcome: .cancelled
        )
      }
    }

    do {
      credential = try await currentCredential(
        account: account,
        generation: generation,
        session: session
      )
      guard let credential else { return nil }
      try checkCurrent(
        accountID: account.userID,
        generation: generation,
        taskID: taskID
      )

      let resolution = try await transport.resolveSongURL(
        songID: track.id,
        quality: quality,
        credential: credential
      )
      guard
        try await sessionRemainsCurrent(
          account: account,
          credential: credential,
          generation: generation,
          session: session
        )
      else { return nil }
      try checkCurrent(
        accountID: account.userID,
        generation: generation,
        taskID: taskID
      )

      releaseSessionOperation(
        operation,
        currentToken: &self.operationToken,
        arbiter: self.arbiter,
        outcome: .applied
      )
      resolutionIsHeld = false
      guard case .resolved(let asset) = resolution else {
        throw DownloadFailure.unavailable
      }
      let resource = try downloadableResource(
        asset,
        expectedSongID: track.id,
        requestedQuality: quality,
        accountID: account.userID
      )
      try await transfer(
        resource: resource,
        track: track,
        generation: generation,
        taskID: taskID
      )
      return .succeeded
    } catch is CancellationError {
      // Explicit cancel and account replacement already published the reason.
      return nil
    } catch {
      if resolutionIsHeld,
        let service = error as? NeteaseServiceError,
        service.source == .service,
        service.statusCode == 301,
        let credential
      {
        if operationToken == operation { operationToken = nil }
        _ = await session.invalidateStoredSession(
          matching: credential,
          message: "Stored session expired; sign in again",
          readToken: operation
        )
      }
      guard isCurrent(
        accountID: account.userID,
        generation: generation,
        taskID: taskID
      ) else { return nil }
      var message = Self.diagnostic(for: error)
      if let cleanup = lastFailure, cleanup != message {
        message += "; " + cleanup
      }
      lastFailure = message
      status = message
      activity = .idle
      progress = nil
      return .failed(Self.terminalFailure(for: error))
    }
  }

  private func downloadableResource(
    _ asset: ResolvedAudioAsset,
    expectedSongID: Int64,
    requestedQuality: PlaybackQuality,
    accountID: Int64
  ) throws -> PlaybackResource {
    guard asset.songID == expectedSongID,
      asset.requestedQuality == requestedQuality,
      asset.url.scheme?.lowercased() == "https",
      let actual = asset.actualQuality?.trimmingCharacters(in: .whitespacesAndNewlines),
      !actual.isEmpty,
      let format = asset.format?.trimmingCharacters(in: .whitespacesAndNewlines),
      !format.isEmpty,
      let byteCount = asset.byteCount, byteCount > 0
    else { throw DownloadFailure.invalidResource }
    let expiresAt = asset.expiresIn.flatMap {
      $0 > 0 ? now().addingTimeInterval(TimeInterval($0)) : nil
    }
    return PlaybackResource(
      location: .remote(asset.url),
      accountID: accountID,
      songID: asset.songID,
      requestedQuality: asset.requestedQuality,
      actualQuality: actual,
      format: format,
      byteCount: byteCount,
      expiresAt: expiresAt
    )
  }

  private func transfer(
    resource: PlaybackResource,
    track: Track,
    generation: Int,
    taskID: UUID
  ) async throws {
    guard
      let ranges,
      let accountID = resource.accountID,
      let byteCount = resource.byteCount,
      let format = resource.format,
      let actualQuality = resource.actualQuality,
      let key = resource.cacheKey
    else { throw DownloadFailure.invalidResource }

    try checkCurrent(
      accountID: accountID,
      generation: generation,
      taskID: taskID
    )
    activity = .transferring(songID: track.id)
    progress = 0
    status = "Downloading \(track.name)"
    await ranges.pin(key)
    do {
      try checkCurrent(
        accountID: accountID,
        generation: generation,
        taskID: taskID
      )
      try await transferPinned(
        resource: resource,
        track: track,
        ranges: ranges,
        accountID: accountID,
        byteCount: byteCount,
        format: format,
        actualQuality: actualQuality,
        generation: generation,
        taskID: taskID
      )
      await ranges.unpin(key)
    } catch {
      await ranges.unpin(key)
      throw error
    }
  }

  private func transferPinned(
    resource: PlaybackResource,
    track: Track,
    ranges: AudioRangePipeline,
    accountID: Int64,
    byteCount: Int64,
    format: String,
    actualQuality: String,
    generation: Int,
    taskID: UUID
  ) async throws {
    let partial = try await files.makePartialFile(
      accountID: accountID,
      format: format
    )
    try checkCurrent(
      accountID: accountID,
      generation: generation,
      taskID: taskID
    )
    var committed: OfflineDownload?
    do {
      var offset: Int64 = 0
      while offset < byteCount {
        try checkCurrent(
          accountID: accountID,
          generation: generation,
          taskID: taskID
        )
        if let expiresAt = resource.expiresAt, now() >= expiresAt {
          throw DownloadFailure.expiredURL
        }
        let length = min(AudioRangePipeline.transferChunkBytes, byteCount - offset)
        let range = try AudioByteRange(offset: offset, length: length)
        let data = try await ranges.data(
          for: resource,
          range: range,
          userAgent: "MacEasePhase0/0.1 (macOS 15)"
        )
        try checkCurrent(
          accountID: accountID,
          generation: generation,
          taskID: taskID
        )
        guard Int64(data.count) == length else {
          throw AudioRangeError.mismatchedLength
        }
        try await files.append(data, to: partial, expectedOffset: offset)
        try checkCurrent(
          accountID: accountID,
          generation: generation,
          taskID: taskID
        )
        offset += length
        progress = Double(offset) / Double(byteCount)
      }

      let actualByteCount = await files.fileSize(partial)
      try checkCurrent(
        accountID: accountID,
        generation: generation,
        taskID: taskID
      )
      guard actualByteCount == byteCount else {
        throw AudioRangeError.storageFailure
      }
      let isPlayable = await validator(partial)
      try checkCurrent(
        accountID: accountID,
        generation: generation,
        taskID: taskID
      )
      guard isPlayable else {
        throw DownloadFailure.unplayableFile
      }
      let final = try await files.commit(
        partial: partial,
        accountID: accountID,
        format: format
      )
      let download = OfflineDownload(
        accountID: accountID,
        track: track,
        requestedQuality: resource.requestedQuality,
        actualQuality: actualQuality,
        format: format,
        byteCount: byteCount,
        relativePath: final.relativePath,
        createdAt: now()
      )
      committed = download
      do {
        try checkCurrent(
          accountID: accountID,
          generation: generation,
          taskID: taskID
        )
        try await store.saveDownload(download)
      } catch {
        do {
          try await files.remove(download)
        } catch let cleanupError {
          if isCurrent(
            accountID: accountID,
            generation: generation,
            taskID: taskID
          ) {
            lastFailure = "Download failed and its file cleanup also failed: "
              + Self.diagnostic(for: cleanupError)
          }
        }
        committed = nil
        throw error
      }

      guard isCurrent(
        accountID: accountID,
        generation: generation,
        taskID: taskID
      ) else {
        await compensateLateCommit(download, generation: generation)
        committed = nil
        throw CancellationError()
      }
      downloads.removeAll { $0.id == download.id }
      downloads.insert(download, at: 0)
      localURLs[download.id] = final.url
      lastFailure = nil
      progress = 1
      status = "Downloaded \(track.name)"
    } catch {
      if committed == nil {
        do {
          try await files.removePartial(partial)
        } catch let cleanupError {
          if self.accountID == accountID, self.generation == generation {
            lastFailure = "Download cleanup failed: "
              + Self.diagnostic(for: cleanupError)
          }
        }
      }
      throw error
    }
  }

  private func compensateLateCommit(
    _ download: OfflineDownload,
    generation: Int
  ) async {
    var failures: [String] = []
    do { try await store.deleteDownload(download.id) } catch {
      failures.append(LibraryStore.diagnostic(for: error))
    }
    do { try await files.remove(download) } catch {
      failures.append(Self.diagnostic(for: error))
    }
    if accountID == download.accountID, self.generation == generation,
      !failures.isEmpty
    {
      lastFailure = "Canceled download cleanup failed: "
        + failures.joined(separator: "; ")
    }
  }

  // MARK: Loading and maintenance

  private func load(accountID: Int64, generation: Int) async {
    defer {
      if self.generation == generation { loadTask = nil }
    }
    do {
      let stored = try await store.downloads(accountID: accountID)
      var valid: [OfflineDownload] = []
      var urls: [OfflineDownloadID: URL] = [:]
      var invalidCount = stored.discardedCorruptRows
      var cleanupFailures: [String] = []

      for download in stored.downloads {
        try Task.checkCancellation()
        guard self.accountID == accountID, self.generation == generation else {
          return
        }
        let url = await files.fileURL(for: download)
        let fileIsValid: Bool
        if let url, await files.hasExpectedSize(download) {
          fileIsValid = await validator(url)
        } else {
          fileIsValid = false
        }
        guard fileIsValid, let url else {
          invalidCount += 1
          do { try await store.deleteDownload(download.id) } catch {
            cleanupFailures.append(LibraryStore.diagnostic(for: error))
          }
          do { try await files.remove(download) } catch {
            cleanupFailures.append(Self.diagnostic(for: error))
          }
          continue
        }
        valid.append(download)
        urls[download.id] = url
      }

      do {
        _ = try await files.removeOrphans(
          accountID: accountID,
          keeping: Set(valid.map(\.relativePath))
        )
      } catch {
        cleanupFailures.append(Self.diagnostic(for: error))
      }
      guard self.accountID == accountID, self.generation == generation,
        !Task.isCancelled
      else { return }
      downloads = valid
      localURLs = urls
      if cleanupFailures.isEmpty {
        lastFailure = nil
        status = invalidCount == 0
          ? "Loaded downloads"
          : "Removed damaged download records"
      } else {
        lastFailure = "Some damaged download data could not be cleaned up: "
          + cleanupFailures.joined(separator: "; ")
        status = lastFailure ?? "Download cleanup failed"
      }
    } catch is CancellationError {
      return
    } catch {
      guard self.accountID == accountID, self.generation == generation else {
        return
      }
      let message = "Downloads could not be loaded: " + Self.diagnostic(for: error)
      lastFailure = message
      status = message
    }
  }

  private func delete(_ download: OfflineDownload, generation: Int) async {
    var staged: OfflineAudioFiles.StagedDeletion?
    var rowWasDeleted = false
    var rollbackFailure: String?
    do {
      staged = try await files.stageDeletion(download)
      try Task.checkCancellation()
      guard accountID == download.accountID, self.generation == generation else {
        throw CancellationError()
      }
      try await store.deleteDownload(download.id)
      rowWasDeleted = true

      var cleanupFailed = false
      if let staged {
        do {
          try await files.finish(staged)
        } catch {
          cleanupFailed = true
        }
      }
      // The account may have changed while SQLite was running. The scoped A
      // deletion may finish, but it must never clear or relabel B's view.
      guard accountID == download.accountID, self.generation == generation,
        !Task.isCancelled
      else {
        return
      }
      downloads.removeAll { $0.id == download.id }
      localURLs.removeValue(forKey: download.id)
      if cleanupFailed {
        lastFailure = "The download record was deleted, but file cleanup failed"
        status = lastFailure ?? "Download file cleanup failed"
      } else {
        lastFailure = nil
        status = "Deleted \(download.track.name)"
      }
    } catch {
      if !rowWasDeleted, let staged {
        do {
          try await files.rollback(staged)
        } catch let rollbackError {
          rollbackFailure = Self.diagnostic(for: rollbackError)
        }
      }
      if error is CancellationError {
        if accountID == download.accountID, self.generation == generation,
          let rollbackFailure
        {
          lastFailure = "Canceled deletion could not restore its file: "
            + rollbackFailure
        }
        return
      }
      guard accountID == download.accountID, self.generation == generation else {
        return
      }
      var message = "Download could not be deleted: " + Self.diagnostic(for: error)
      if let rollbackFailure { message += "; rollback failed: " + rollbackFailure }
      lastFailure = message
      status = message
    }
  }

  private func clear(
    _ snapshot: [OfflineDownload],
    accountID: Int64,
    generation: Int
  ) async {
    var staged: [OfflineAudioFiles.StagedDeletion] = []
    var rowsWereCleared = false
    do {
      for download in snapshot {
        if let deletion = try await files.stageDeletion(download) {
          staged.append(deletion)
        }
      }
      try Task.checkCancellation()
      guard self.accountID == accountID, self.generation == generation else {
        throw CancellationError()
      }
      try await store.clearDownloads(accountID: accountID)
      rowsWereCleared = true
      var cleanupFailed = false
      for deletion in staged {
        do { try await files.finish(deletion) } catch { cleanupFailed = true }
      }
      do {
        _ = try await files.removeOrphans(accountID: accountID, keeping: [])
      } catch {
        cleanupFailed = true
      }
      // As with a single delete, a completed A cleanup is allowed to finish
      // after a switch, but its UI completion belongs only to A.
      guard self.accountID == accountID, self.generation == generation,
        !Task.isCancelled
      else {
        return
      }
      downloads = []
      localURLs = [:]
      if cleanupFailed {
        lastFailure = "Download records were cleared, but some files need startup cleanup"
        status = lastFailure ?? "Download file cleanup failed"
      } else {
        lastFailure = nil
        status = "Cleared downloads for this account"
      }
    } catch {
      var rollbackFailed = false
      if !rowsWereCleared {
        rollbackFailed = await rollback(staged)
      }
      if error is CancellationError {
        if self.accountID == accountID, self.generation == generation,
          rollbackFailed
        {
          lastFailure = "Canceled download cleanup could not restore every file"
        }
        return
      }
      guard self.accountID == accountID, self.generation == generation else {
        return
      }
      let message = "Downloads could not be cleared: " + Self.diagnostic(for: error)
      lastFailure = rollbackFailed ? message + "; file rollback failed" : message
      status = lastFailure ?? message
    }
  }

  private func rollback(_ staged: [OfflineAudioFiles.StagedDeletion]) async -> Bool {
    var failed = false
    for deletion in staged.reversed() {
      do { try await files.rollback(deletion) } catch { failed = true }
    }
    return failed
  }

  private func discardInvalid(_ download: OfflineDownload) {
    downloads.removeAll { $0.id == download.id }
    localURLs.removeValue(forKey: download.id)
    status = "Downloaded file is missing or damaged; using online playback"
    guard maintenanceTask == nil else { return }
    let generation = generation
    let taskID = UUID()
    maintenanceTaskID = taskID
    maintenanceTask = Task { [weak self] in
      guard let self else { return }
      var failures: [String] = []
      do { try await self.store.deleteDownload(download.id) } catch {
        failures.append(LibraryStore.diagnostic(for: error))
      }
      do { try await self.files.remove(download) } catch {
        failures.append(Self.diagnostic(for: error))
      }
      if self.generation == generation, !failures.isEmpty {
        self.lastFailure = "Damaged download cleanup failed: "
          + failures.joined(separator: "; ")
      }
      self.finishMaintenanceTask(taskID)
    }
  }

  // MARK: State guards and diagnostics

  private func stopIfPlaying(_ id: OfflineDownloadID) {
    if playback?.activeOfflineDownloadID == id {
      playback?.stopForDeletedDownload()
    }
  }

  private func checkCurrent(
    accountID: Int64,
    generation: Int,
    taskID: UUID
  ) throws {
    try Task.checkCancellation()
    guard isCurrent(
      accountID: accountID,
      generation: generation,
      taskID: taskID
    ) else { throw CancellationError() }
  }

  private func isCurrent(
    accountID: Int64,
    generation: Int,
    taskID: UUID
  ) -> Bool {
    self.accountID == accountID && self.generation == generation
      && downloadTaskID == taskID && !Task.isCancelled
  }

  private func finishDownloadTask(
    _ taskID: UUID,
    accountID: Int64,
    generation: Int,
    track: Track,
    outcome: DownloadTerminalOutcome?
  ) {
    guard downloadTaskID == taskID else { return }
    downloadTask = nil
    downloadTaskID = nil
    guard self.accountID == accountID, self.generation == generation else {
      return
    }
    activity = .idle
    if progress != 1 { progress = nil }
    guard let outcome else { return }
    onTerminalEvent?(
      DownloadTerminalEvent(
        taskID: taskID,
        accountID: accountID,
        track: track,
        outcome: outcome
      )
    )
  }

  private func finishMaintenanceTask(_ taskID: UUID) {
    guard maintenanceTaskID == taskID else { return }
    maintenanceTask = nil
    maintenanceTaskID = nil
  }

  private static func fileSize(_ url: URL) -> Int64? {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let value = attributes[.size] as? NSNumber
    else { return nil }
    return value.int64Value
  }

  private static func diagnostic(for error: any Error) -> String {
    if error is CancellationError { return "Download canceled" }
    if let error = error as? LibraryStoreError {
      return LibraryStore.diagnostic(for: error)
    }
    if let error = error as? AudioRangeError {
      switch error {
      case .unsupportedStatus(let status):
        return "Audio server returned HTTP \(status)"
      case .storageFailure: return "Audio file storage failed"
      case .corruptCache: return "Temporary audio cache was damaged"
      default: return "Audio server returned inconsistent bytes"
      }
    }
    if let error = error as? URLError {
      return "Audio transfer failed (URL error \(error.code.rawValue))"
    }
    if let error = error as? NeteaseServiceError {
      return "Download URL \(error.source.rawValue) error \(error.statusCode)"
    }
    if let error = error as? DownloadFailure {
      switch error {
      case .unavailable: return "Track is unavailable for download"
      case .invalidResource: return "Resolved audio lacks safe download metadata"
      case .expiredURL: return "Download URL expired; click Download to try again"
      case .unplayableFile: return "Downloaded bytes are not playable audio"
      }
    }
    return "Download file operation failed"
  }

  /// Notification copy is intentionally coarser than diagnostics shown in the
  /// app: no endpoint, URL, status code, service code or disk path crosses the
  /// user-notification boundary.
  private static func terminalFailure(
    for error: any Error
  ) -> DownloadTerminalFailure {
    if error is URLError || error is NeteaseServiceError {
      return .connection
    }
    if error is LibraryStoreError {
      return .storage
    }
    if let error = error as? AudioRangeError {
      return error == .storageFailure ? .storage : .invalidAudio
    }
    if let error = error as? DownloadFailure {
      switch error {
      case .unavailable: return .unavailable
      case .expiredURL: return .connection
      case .invalidResource, .unplayableFile: return .invalidAudio
      }
    }
    return .other
  }
}

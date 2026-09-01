import Foundation
import Testing

@testable import MacEaseAppCore
@testable import NeteaseKit

private actor DownloadByteFetcher: AudioByteFetching {
  enum Mode: Sendable {
    case success
    case failure
  }

  private let bytes: Data
  private let mode: Mode
  let gate = RequestGate()
  private var calls: [AudioByteRange] = []

  init(bytes: Data, mode: Mode = .success) {
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
    if mode == .failure { throw URLError(.networkConnectionLost) }
    let lower = Int(range.offset)
    let upper = Int(range.endOffset)
    guard lower >= 0, upper <= bytes.count else {
      throw AudioRangeError.rangeOutOfBounds
    }
    return AudioHTTPRangeResponse(
      statusCode: 206,
      contentRange: "bytes \(range.offset)-\(range.endOffset - 1)/\(bytes.count)",
      contentLength: range.length,
      mimeType: "audio/mpeg",
      data: bytes.subdata(in: lower..<upper)
    )
  }

  func callCount() -> Int { calls.count }
}

@MainActor
private struct DownloadRig {
  let root: URL
  let bytes: Data
  let transport = FakeTransport()
  let credential = makeCredential()
  let vault: FakeVault
  let session: FakeSession
  let arbiter: OperationArbiter
  let store: LibraryStore
  let files: OfflineAudioFiles
  let rangeStore: AudioRangeStore
  let pipeline: AudioRangePipeline
  let fetcher: DownloadByteFetcher
  let coordinator: DownloadCoordinator
  let output: FakeAudioOutput
  let playback: PlaybackController

  init(
    bytes: Data = Data((0..<64).map { UInt8($0) }),
    fetchMode: DownloadByteFetcher.Mode = .success,
    validator: @escaping OfflineAudioValidating = { _ in true },
    arbiter: OperationArbiter = OperationArbiter(),
    rangePipelineAvailable: Bool = true
  ) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MacEase-download-\(UUID().uuidString)",
      isDirectory: true
    )
    self.bytes = bytes
    self.arbiter = arbiter
    vault = FakeVault(stored: credential)
    session = FakeSession(credential: credential)
    store = try LibraryStore(path: LibraryStore.inMemoryPath)
    files = try OfflineAudioFiles(
      directory: root.appendingPathComponent("Downloads", isDirectory: true)
    )
    rangeStore = try AudioRangeStore(
      directory: root.appendingPathComponent("Ranges", isDirectory: true),
      limitBytes: 10 * 1024 * 1024
    )
    fetcher = DownloadByteFetcher(bytes: bytes, mode: fetchMode)
    pipeline = AudioRangePipeline(store: rangeStore, fetcher: fetcher)
    coordinator = DownloadCoordinator(
      transport: transport,
      vault: vault,
      arbiter: arbiter,
      ranges: rangePipelineAvailable ? pipeline : nil,
      store: store,
      files: files,
      validator: validator,
      now: { Date(timeIntervalSince1970: 100) }
    )
    output = FakeAudioOutput()
    playback = PlaybackController(
      transport: transport,
      vault: vault,
      arbiter: arbiter,
      output: output
    )
    playback.attach(session: session)
    playback.attach(downloads: coordinator)
    coordinator.attach(playback: playback)
  }

  func activate(_ accountID: Int64 = testAccount.userID) async {
    coordinator.bind(accountID: accountID)
    await coordinator.settleLoadingForTesting()
  }

  func resolved(
    songID: Int64,
    quality: PlaybackQuality = .standard
  ) -> SongURLResolution {
    .resolved(
      ResolvedAudioAsset(
        songID: songID,
        url: URL(string: "https://m8.music.126.net/\(songID).mp3?token=secret")!,
        sourceScheme: "https",
        requestedQuality: quality,
        actualQuality: quality.rawValue,
        format: "mp3",
        bitRate: 128_000,
        byteCount: Int64(bytes.count),
        expiresIn: 1200,
        fee: 0,
        trial: false
      )
    )
  }

  func program(songID: Int64, quality: PlaybackQuality = .standard) async {
    await transport.setSongURL(.success(resolved(songID: songID, quality: quality)))
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}

@MainActor
private func seedDownload(
  store: LibraryStore,
  files: OfflineAudioFiles,
  accountID: Int64,
  track: Track,
  quality: PlaybackQuality = .standard,
  bytes: Data = Data([1, 2, 3, 4])
) async throws -> OfflineDownload {
  let partial = try await files.makePartialFile(accountID: accountID, format: "mp3")
  try await files.append(bytes, to: partial, expectedOffset: 0)
  let final = try await files.commit(
    partial: partial,
    accountID: accountID,
    format: "mp3"
  )
  let download = OfflineDownload(
    accountID: accountID,
    track: track,
    requestedQuality: quality,
    actualQuality: quality.rawValue,
    format: "mp3",
    byteCount: Int64(bytes.count),
    relativePath: final.relativePath,
    createdAt: Date(timeIntervalSince1970: 10)
  )
  try await store.saveDownload(download)
  return download
}

@Test @MainActor func downloadDoesNothingUntilTheUserTriggersIt() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  await rig.activate()

  #expect(await rig.transport.recordedCalls().isEmpty)
  #expect(await rig.fetcher.callCount() == 0)

  let track = makeTracks([1])[0]
  await rig.program(songID: track.id)
  rig.coordinator.startDownload(
    track: track,
    quality: .standard,
    session: rig.session
  )
  await rig.coordinator.settleDownloadForTesting()

  #expect(
    await rig.transport.recordedCalls() == [.resolveSongURL(track.id, .standard)]
  )
  #expect(await rig.fetcher.callCount() == 1)
}

@Test @MainActor func unavailableRangePipelineRefusesANewDownloadBeforeResolve() async throws {
  let rig = try DownloadRig(rangePipelineAvailable: false)
  defer { rig.cleanup() }
  await rig.activate()

  rig.coordinator.startDownload(
    track: makeTracks([90])[0],
    quality: .standard,
    session: rig.session
  )
  await rig.coordinator.settleDownloadForTesting()

  #expect(!rig.coordinator.canCreateDownloads)
  #expect(!rig.coordinator.isDownloading)
  #expect(rig.coordinator.status.contains("Temporary audio pipeline is unavailable"))
  #expect(await rig.transport.recordedCalls().isEmpty)
  #expect(await rig.fetcher.callCount() == 0)
  #expect(rig.arbiter.activeReadCount == 0)
}

@Test @MainActor func successfulDownloadCommitsFileAndRecord() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  await rig.activate()
  let track = makeTracks([2])[0]
  await rig.program(songID: track.id)

  rig.coordinator.startDownload(
    track: track,
    quality: .standard,
    session: rig.session
  )
  await rig.coordinator.settleDownloadForTesting()

  let stored = try await rig.store.downloads(accountID: testAccount.userID).downloads
  #expect(stored.count == 1)
  guard let first = stored.first else { return }
  #expect(first.track == track)
  #expect(first.byteCount == Int64(rig.bytes.count))
  #expect(first.relativePath.contains("token") == false)
  #expect(rig.coordinator.downloads == stored)
  #expect(rig.coordinator.progress == 1)
  #expect(await rig.files.hasExpectedSize(first))
}

/// The resolve read is deliberately gone while the CDN gate is closed. A
/// long transfer therefore cannot prevent a playlist write or sign-out from
/// claiming the arbiter.
@Test @MainActor func cdnTransferDoesNotHoldTheResolutionReadToken() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  await rig.activate()
  let track = makeTracks([3])[0]
  await rig.program(songID: track.id)
  await rig.fetcher.gate.close()

  rig.coordinator.startDownload(
    track: track,
    quality: .standard,
    session: rig.session
  )
  while await rig.fetcher.callCount() == 0 { await Task.yield() }

  #expect(rig.arbiter.activeReadCount == 0)
  #expect(rig.arbiter.canStart())
  rig.coordinator.cancelDownload()
  await rig.fetcher.gate.open()
  await rig.coordinator.settleDownloadForTesting()
}

@Test @MainActor func cancelLeavesNoCompletedFileOrRecord() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  await rig.activate()
  let track = makeTracks([4])[0]
  await rig.program(songID: track.id)
  await rig.fetcher.gate.close()
  rig.coordinator.startDownload(
    track: track,
    quality: .standard,
    session: rig.session
  )
  while await rig.fetcher.callCount() == 0 { await Task.yield() }

  rig.coordinator.cancelDownload()
  await rig.fetcher.gate.open()
  await rig.coordinator.settleDownloadForTesting()

  #expect(try await rig.store.downloads(accountID: testAccount.userID).downloads.isEmpty)
  #expect(rig.coordinator.downloads.isEmpty)
}

@Test @MainActor func failedTransferLeavesNoCompletedRecord() async throws {
  let rig = try DownloadRig(fetchMode: .failure)
  defer { rig.cleanup() }
  await rig.activate()
  let track = makeTracks([5])[0]
  await rig.program(songID: track.id)

  rig.coordinator.startDownload(
    track: track,
    quality: .standard,
    session: rig.session
  )
  await rig.coordinator.settleDownloadForTesting()

  #expect(try await rig.store.downloads(accountID: testAccount.userID).downloads.isEmpty)
  #expect(rig.coordinator.downloads.isEmpty)
  #expect(rig.coordinator.lastFailure != nil)
}

@Test @MainActor func aFailedDownloadRetriesOnlyAfterAnotherUserTrigger() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  await rig.activate()
  let track = makeTracks([9])[0]
  await rig.transport.setSongURL(
    .success(.unavailable(itemCode: 404, fee: nil))
  )

  rig.coordinator.startDownload(
    track: track,
    quality: .standard,
    session: rig.session
  )
  await rig.coordinator.settleDownloadForTesting()
  await Task.yield()

  #expect(
    await rig.transport.recordedCalls() == [.resolveSongURL(track.id, .standard)]
  )
  #expect(rig.coordinator.downloads.isEmpty)

  await rig.program(songID: track.id)
  rig.coordinator.startDownload(
    track: track,
    quality: .standard,
    session: rig.session
  )
  await rig.coordinator.settleDownloadForTesting()

  #expect(
    await rig.transport.recordedCalls()
      == [
        .resolveSongURL(track.id, .standard),
        .resolveSongURL(track.id, .standard),
      ]
  )
  #expect(rig.coordinator.downloads.count == 1)
}

@Test @MainActor func sqliteFailureDeletesTheFinalFile() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  await rig.activate()
  let track = makeTracks([6])[0]
  await rig.program(songID: track.id)
  await rig.store.failNextWriteForTesting()

  rig.coordinator.startDownload(
    track: track,
    quality: .standard,
    session: rig.session
  )
  await rig.coordinator.settleDownloadForTesting()

  #expect(try await rig.store.downloads(accountID: testAccount.userID).downloads.isEmpty)
  #expect(rig.coordinator.downloads.isEmpty)
  let accountDirectory = rig.root
    .appendingPathComponent("Downloads", isDirectory: true)
    .appendingPathComponent(String(testAccount.userID), isDirectory: true)
  let files = (try? FileManager.default.contentsOfDirectory(
    at: accountDirectory,
    includingPropertiesForKeys: nil
  )) ?? []
  #expect(files.isEmpty)
}

@Test @MainActor func startupRemovesInterruptedPartialFiles() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "MacEase-partial-\(UUID().uuidString)",
    isDirectory: true
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try OfflineAudioFiles(directory: root)
  let partial = try await files.makePartialFile(accountID: 42, format: "mp3")
  try await files.append(Data([1, 2]), to: partial, expectedOffset: 0)
  #expect(FileManager.default.fileExists(atPath: partial.path))

  _ = try OfflineAudioFiles(directory: root)

  #expect(!FileManager.default.fileExists(atPath: partial.path))
}

@Test @MainActor func accountSwitchCancelsAndPreventsALateCommit() async throws {
  let validationGate = RequestGate()
  await validationGate.close()
  let rig = try DownloadRig(validator: { _ in
    await validationGate.pass()
    return true
  })
  defer { rig.cleanup() }
  await rig.activate()
  let track = makeTracks([7])[0]
  await rig.program(songID: track.id)
  rig.coordinator.startDownload(
    track: track,
    quality: .standard,
    session: rig.session
  )
  while await validationGate.arrivalCount() == 0 { await Task.yield() }
  #expect(rig.coordinator.activity == .transferring(songID: track.id))
  #expect(rig.coordinator.progress == 1)

  rig.session.account = otherAccount
  rig.coordinator.bind(accountID: otherAccount.userID)
  await validationGate.open()
  await rig.coordinator.settleDownloadForTesting()
  await rig.coordinator.settleLoadingForTesting()

  #expect(try await rig.store.downloads(accountID: testAccount.userID).downloads.isEmpty)
  #expect(try await rig.store.downloads(accountID: otherAccount.userID).downloads.isEmpty)
  #expect(rig.coordinator.downloads.isEmpty)
  #expect(rig.coordinator.activity == .idle)
  #expect(rig.coordinator.progress == nil)
  #expect(rig.coordinator.lastFailure == nil)
  #expect(rig.coordinator.status == "Loaded downloads")
}

@Test @MainActor func aCompleteRangeCacheIsPromotedWithoutAnotherFetch() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  await rig.activate()
  let track = makeTracks([8])[0]
  await rig.program(songID: track.id)
  guard case .resolved(let asset) = rig.resolved(songID: track.id) else {
    Issue.record("Expected resolved fixture")
    return
  }
  let resource = PlaybackResource(
    location: .remote(asset.url),
    accountID: testAccount.userID,
    songID: track.id,
    requestedQuality: .standard,
    actualQuality: "standard",
    format: "mp3",
    byteCount: Int64(rig.bytes.count),
    expiresAt: Date(timeIntervalSince1970: 1_000)
  )
  _ = try await rig.pipeline.data(
    for: resource,
    range: AudioByteRange(offset: 0, length: Int64(rig.bytes.count)),
    userAgent: "test"
  )
  let callsBeforeDownload = await rig.fetcher.callCount()

  rig.coordinator.startDownload(
    track: track,
    quality: .standard,
    session: rig.session
  )
  await rig.coordinator.settleDownloadForTesting()

  #expect(await rig.fetcher.callCount() == callsBeforeDownload)
  #expect(try await rig.store.downloads(accountID: testAccount.userID).downloads.count == 1)
}

@Test @MainActor func deleteAndClearAreAccountScoped() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  let aliceTracks = makeTracks([11, 12])
  let bobTrack = makeTracks([21])[0]
  let first = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: aliceTracks[0]
  )
  _ = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: aliceTracks[1]
  )
  let bob = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: otherAccount.userID,
    track: bobTrack
  )
  await rig.activate()
  #expect(rig.coordinator.downloads.count == 2)

  rig.coordinator.delete(first)
  await rig.coordinator.settleMaintenanceForTesting()
  #expect(try await rig.store.downloads(accountID: testAccount.userID).downloads.count == 1)
  #expect(try await rig.store.downloads(accountID: otherAccount.userID).downloads == [bob])

  rig.coordinator.clearAll()
  await rig.coordinator.settleMaintenanceForTesting()
  #expect(try await rig.store.downloads(accountID: testAccount.userID).downloads.isEmpty)
  #expect(try await rig.store.downloads(accountID: otherAccount.userID).downloads == [bob])
}

@Test @MainActor func signOutHidesButKeepsDownloadsForRelogin() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  let track = makeTracks([30])[0]
  let stored = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: track
  )
  await rig.activate()
  #expect(rig.coordinator.downloads == [stored])

  rig.coordinator.bind(accountID: nil)
  #expect(rig.coordinator.downloads.isEmpty)
  #expect(try await rig.store.downloads(accountID: testAccount.userID).downloads == [stored])

  rig.coordinator.bind(accountID: testAccount.userID)
  await rig.coordinator.settleLoadingForTesting()
  #expect(rig.coordinator.downloads == [stored])
}

@Test @MainActor func unavailableRangePipelineStillDeletesAndClearsPerAccount() async throws {
  let rig = try DownloadRig(rangePipelineAvailable: false)
  defer { rig.cleanup() }
  let aliceTracks = makeTracks([31, 32])
  let first = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: aliceTracks[0]
  )
  _ = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: aliceTracks[1]
  )
  let bob = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: otherAccount.userID,
    track: makeTracks([33])[0]
  )
  await rig.activate()

  rig.coordinator.delete(first)
  await rig.coordinator.settleMaintenanceForTesting()
  rig.coordinator.clearAll()
  await rig.coordinator.settleMaintenanceForTesting()

  #expect(rig.coordinator.downloads.isEmpty)
  #expect(try await rig.store.downloads(accountID: testAccount.userID).downloads.isEmpty)
  #expect(try await rig.store.downloads(accountID: otherAccount.userID).downloads == [bob])
}

@Test @MainActor func unavailableRangePipelineKeepsDownloadsIsolatedAcrossBindings() async throws {
  let rig = try DownloadRig(rangePipelineAvailable: false)
  defer { rig.cleanup() }
  let alice = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: makeTracks([34])[0]
  )
  let bob = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: otherAccount.userID,
    track: makeTracks([35])[0]
  )

  await rig.activate(testAccount.userID)
  #expect(rig.coordinator.downloads == [alice])
  rig.session.account = otherAccount
  rig.coordinator.bind(accountID: otherAccount.userID)
  await rig.coordinator.settleLoadingForTesting()

  #expect(rig.coordinator.downloads == [bob])
  #expect(try await rig.store.downloads(accountID: testAccount.userID).downloads == [alice])
}

// MARK: Offline playback

@Test @MainActor func unavailableRangePipelineStillLoadsAndPlaysSavedAudio() async throws {
  let rig = try DownloadRig(rangePipelineAvailable: false)
  defer { rig.cleanup() }
  let track = makeTracks([39])[0]
  let download = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: track
  )
  await rig.activate()

  rig.playback.play(
    tracks: [track],
    startIndex: 0,
    context: .playlist(id: 1, name: "Offline"),
    session: rig.session
  )
  await rig.playback.settleForTesting()

  #expect(rig.coordinator.downloads == [download])
  #expect(await rig.transport.recordedCalls().isEmpty)
  #expect(rig.output.preparedResources.first?.location == .local(
    await rig.files.fileURL(for: download)!
  ))
}

@Test @MainActor func downloadedTrackBypassesAFullReadCeilingFromAnOrdinaryList() async throws {
  let arbiter = OperationArbiter(maximumConcurrentReads: 1)
  let rig = try DownloadRig(arbiter: arbiter)
  defer { rig.cleanup() }
  let track = makeTracks([36])[0]
  _ = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: track
  )
  await rig.activate()
  let blocker = try #require(arbiter.begin(name: "Playlist", effect: .read))

  rig.playback.play(
    tracks: [track],
    startIndex: 0,
    context: .playlist(id: 1, name: "Saved"),
    session: rig.session
  )
  await rig.playback.settleForTesting()

  #expect(rig.playback.phase == .playing)
  #expect(await rig.transport.recordedCalls().isEmpty)
  #expect(rig.output.preparedResources.count == 1)
  #expect(arbiter.end(blocker, outcome: .applied) == .applied)
}

@Test @MainActor func downloadedTrackBypassesAnUnrelatedWrite() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  let track = makeTracks([37])[0]
  _ = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: track
  )
  await rig.activate()
  let write = try #require(rig.arbiter.begin(name: "Rename", effect: .write))

  rig.playback.play(
    tracks: [track],
    startIndex: 0,
    context: .playlist(id: 1, name: "Saved"),
    session: rig.session
  )
  await rig.playback.settleForTesting()

  #expect(rig.playback.phase == .playing)
  #expect(await rig.transport.recordedCalls().isEmpty)
  #expect(rig.arbiter.end(write, outcome: .applied) == .applied)
}

@Test @MainActor func downloadedTrackFailsClosedForSessionMutationAndAccountMismatch() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  let track = makeTracks([38])[0]
  let download = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: track
  )
  await rig.activate()
  let mutation = try #require(
    rig.arbiter.begin(name: "Validate", effect: .sessionMutation)
  )

  rig.playback.play(
    tracks: [track],
    startIndex: 0,
    context: .downloads,
    session: rig.session
  )
  await rig.playback.settleForTesting()
  #expect(rig.playback.queue == nil)
  #expect(rig.output.preparedResources.isEmpty)
  #expect(await rig.transport.recordedCalls().isEmpty)
  #expect(rig.arbiter.end(mutation, outcome: .applied) == .applied)

  rig.session.account = otherAccount
  rig.playback.playDownloaded(download, session: rig.session)
  await rig.playback.settleForTesting()
  #expect(rig.output.preparedResources.isEmpty)
  #expect(await rig.transport.recordedCalls().isEmpty)
}

@Test @MainActor func nextPreviousAndRestoredContinuationUseLocalSourceSelection() async throws {
  let arbiter = OperationArbiter(maximumConcurrentReads: 1)
  let rig = try DownloadRig(arbiter: arbiter)
  defer { rig.cleanup() }
  let tracks = makeTracks([50, 51])
  for track in tracks {
    _ = try await seedDownload(
      store: rig.store,
      files: rig.files,
      accountID: testAccount.userID,
      track: track
    )
  }
  await rig.activate()
  let blocker = try #require(arbiter.begin(name: "Library", effect: .read))

  rig.playback.play(
    tracks: tracks,
    startIndex: 0,
    context: .playlist(id: 2, name: "Saved"),
    session: rig.session
  )
  await rig.playback.settleForTesting()
  #expect(rig.playback.playNext(session: rig.session))
  await rig.playback.settleForTesting()
  #expect(rig.playback.playPrevious(session: rig.session))
  await rig.playback.settleForTesting()
  #expect(rig.output.preparedResources.map(\.songID) == [50, 51, 50])
  #expect(await rig.transport.recordedCalls().isEmpty)

  rig.playback.stopForSessionChange()
  rig.playback.restore(
    PersistedQueue(
      tracks: [tracks[1]],
      currentIndex: 0,
      mode: .sequential,
      context: .playlist(id: 2, name: "Saved"),
      positionSeconds: 12,
      quality: .standard,
      wasPlaying: true
    )
  )
  rig.playback.playAgain(session: rig.session)
  await rig.playback.settleForTesting()

  #expect(rig.playback.currentTrack?.id == 51)
  #expect(rig.playback.phase == .playing)
  #expect(rig.output.preparedResources.map(\.songID).last == 51)
  #expect(await rig.transport.recordedCalls().isEmpty)
  #expect(arbiter.end(blocker, outcome: .applied) == .applied)
}

@Test @MainActor func automaticAdvanceUsesALocalTrackDuringAnUnrelatedWrite() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  let tracks = makeTracks([52, 53])
  for track in tracks {
    _ = try await seedDownload(
      store: rig.store,
      files: rig.files,
      accountID: testAccount.userID,
      track: track
    )
  }
  await rig.activate()
  rig.playback.playbackMode = .repeatAll
  rig.playback.play(
    tracks: tracks,
    startIndex: 0,
    context: .playlist(id: 3, name: "Saved"),
    session: rig.session
  )
  await rig.playback.settleForTesting()
  let write = try #require(rig.arbiter.begin(name: "Rename", effect: .write))

  rig.output.reportPlayedToEnd()
  await rig.playback.settleForTesting()

  #expect(rig.playback.currentTrack?.id == 53)
  #expect(rig.playback.phase == .playing)
  #expect(await rig.transport.recordedCalls().isEmpty)
  #expect(rig.arbiter.end(write, outcome: .applied) == .applied)
}

@Test @MainActor func validLocalFileSkipsSongURLResolution() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  let track = makeTracks([40])[0]
  let download = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: track
  )
  await rig.activate()

  rig.playback.play(
    tracks: [track],
    startIndex: 0,
    context: .downloads,
    session: rig.session
  )
  await rig.playback.settleForTesting()

  #expect(await rig.transport.recordedCalls().isEmpty)
  #expect(rig.output.preparedResources.count == 1)
  #expect(rig.output.preparedResources[0].location == .local(
    await rig.files.fileURL(for: download)!
  ))
  #expect(rig.playback.activeOfflineDownloadID == download.id)
}

@Test @MainActor func ordinaryOnlineTrackStillResolvesNormally() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  await rig.activate()
  let track = makeTracks([41])[0]
  await rig.program(songID: track.id)

  rig.playback.play(
    tracks: [track],
    startIndex: 0,
    context: .dailyRecommendations,
    session: rig.session
  )
  await rig.playback.settleForTesting()

  #expect(
    await rig.transport.recordedCalls() == [.resolveSongURL(track.id, .standard)]
  )
  guard let resource = rig.output.preparedResources.first else {
    Issue.record("Expected a prepared remote resource")
    return
  }
  guard case .remote = resource.location else {
    Issue.record("Expected remote playback")
    return
  }
}

@Test @MainActor func downloadsListUsesItsSavedQualityNotTheOnlinePicker() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  let track = makeTracks([42])[0]
  let download = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: track,
    quality: .lossless
  )
  await rig.activate()
  rig.playback.quality = .standard

  rig.playback.playDownloaded(download, session: rig.session)
  await rig.playback.settleForTesting()

  #expect(await rig.transport.recordedCalls().isEmpty)
  #expect(rig.output.preparedResources.first?.requestedQuality == .lossless)
  #expect(rig.playback.quality == .standard)
}

@Test @MainActor func missingDownloadIsNotUsedAndFallsBackToOnlineResolve() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  let track = makeTracks([43])[0]
  let download = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: track
  )
  await rig.activate()
  try await rig.files.remove(download)
  await rig.program(songID: track.id)

  rig.playback.play(
    tracks: [track],
    startIndex: 0,
    context: .dailyRecommendations,
    session: rig.session
  )
  await rig.playback.settleForTesting()
  await rig.coordinator.settleMaintenanceForTesting()

  #expect(
    await rig.transport.recordedCalls() == [.resolveSongURL(track.id, .standard)]
  )
  guard let resource = rig.output.preparedResources.first else {
    Issue.record("Expected online fallback resource")
    return
  }
  guard case .remote = resource.location else {
    Issue.record("A missing local file must not be opened")
    return
  }
  #expect(rig.coordinator.downloads.isEmpty)
  #expect(try await rig.store.downloads(accountID: testAccount.userID).downloads.isEmpty)
}

@Test @MainActor func anotherAccountsDownloadIsInvisibleToPlayback() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  let track = makeTracks([44])[0]
  _ = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: otherAccount.userID,
    track: track
  )
  await rig.activate(testAccount.userID)
  await rig.program(songID: track.id)

  rig.playback.play(
    tracks: [track],
    startIndex: 0,
    context: .dailyRecommendations,
    session: rig.session
  )
  await rig.playback.settleForTesting()

  #expect(
    await rig.transport.recordedCalls() == [.resolveSongURL(track.id, .standard)]
  )
  #expect(rig.coordinator.downloads.isEmpty)
  #expect(try await rig.store.downloads(accountID: otherAccount.userID).downloads.count == 1)
}

@Test @MainActor func aForgedRecordCannotReadOrDeleteAnotherAccountsFile() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  let track = makeTracks([49])[0]
  let otherDownload = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: otherAccount.userID,
    track: track
  )
  let forged = OfflineDownload(
    accountID: testAccount.userID,
    track: track,
    requestedQuality: .standard,
    actualQuality: PlaybackQuality.standard.rawValue,
    format: otherDownload.format,
    byteCount: otherDownload.byteCount,
    relativePath: otherDownload.relativePath,
    createdAt: Date(timeIntervalSince1970: 20)
  )
  try await rig.store.saveDownload(forged)

  await rig.activate(testAccount.userID)

  #expect(rig.coordinator.downloads.isEmpty)
  #expect(try await rig.store.downloads(accountID: testAccount.userID).downloads.isEmpty)
  #expect(
    try await rig.store.downloads(accountID: otherAccount.userID).downloads
      == [otherDownload]
  )
  #expect(await rig.files.fileURL(for: otherDownload).map {
    FileManager.default.fileExists(atPath: $0.path)
  } == true)
}

@Test @MainActor func deletingThePlayingDownloadStopsBeforeRemovingIt() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  let track = makeTracks([45])[0]
  let download = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: track
  )
  await rig.activate()
  rig.playback.playDownloaded(download, session: rig.session)
  await rig.playback.settleForTesting()
  #expect(rig.playback.phase == .playing)

  rig.coordinator.delete(download)
  await rig.coordinator.settleMaintenanceForTesting()

  #expect(rig.playback.phase == .idle)
  #expect(rig.playback.activeOfflineDownloadID == nil)
  #expect(try await rig.store.downloads(accountID: testAccount.userID).downloads.isEmpty)
  #expect(await rig.files.fileURL(for: download).map {
    FileManager.default.fileExists(atPath: $0.path)
  } == false)
}

@Test @MainActor func activationDropsAFileThatFailsPlaybackValidation() async throws {
  let rig = try DownloadRig(
    validator: { _ in false },
    rangePipelineAvailable: false
  )
  defer { rig.cleanup() }
  let track = makeTracks([46])[0]
  _ = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: track
  )

  await rig.activate()

  #expect(rig.coordinator.downloads.isEmpty)
  #expect(try await rig.store.downloads(accountID: testAccount.userID).downloads.isEmpty)
}

@Test @MainActor func localAssetFailureIsRemovedAndPlayAgainUsesOnlineResolution() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  let track = makeTracks([47])[0]
  _ = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: track
  )
  await rig.activate()
  rig.output.prepareResult = .success(
    AudioAssetInfo(isPlayable: false, durationSeconds: nil)
  )

  rig.playback.play(
    tracks: [track],
    startIndex: 0,
    context: .downloads,
    session: rig.session
  )
  await rig.playback.settleForTesting()
  await rig.coordinator.settleMaintenanceForTesting()

  #expect(rig.playback.phase == .failed)
  #expect(rig.playback.canPlayAgain)
  #expect(rig.coordinator.downloads.isEmpty)
  #expect(try await rig.store.downloads(accountID: testAccount.userID).downloads.isEmpty)

  await rig.program(songID: track.id)
  rig.output.prepareResult = .success(
    AudioAssetInfo(isPlayable: true, durationSeconds: 200)
  )
  rig.playback.playAgain(session: rig.session)
  await rig.playback.settleForTesting()

  #expect(
    await rig.transport.recordedCalls() == [.resolveSongURL(track.id, .standard)]
  )
  guard let resource = rig.output.preparedResources.last else {
    Issue.record("Expected an online retry resource")
    return
  }
  guard case .remote = resource.location else {
    Issue.record("Play Again must not reopen the rejected local resource")
    return
  }
}

@Test @MainActor func localItemFailureIsRemovedBeforePlayAgain() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  let track = makeTracks([48])[0]
  _ = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: track
  )
  await rig.activate()

  rig.playback.play(
    tracks: [track],
    startIndex: 0,
    context: .downloads,
    session: rig.session
  )
  await rig.playback.settleForTesting()
  rig.output.reportFailure("local read failed")
  await rig.coordinator.settleMaintenanceForTesting()

  #expect(rig.playback.phase == .failed)
  #expect(rig.coordinator.downloads.isEmpty)
  #expect(try await rig.store.downloads(accountID: testAccount.userID).downloads.isEmpty)

  await rig.program(songID: track.id)
  rig.playback.playAgain(session: rig.session)
  await rig.playback.settleForTesting()

  #expect(
    await rig.transport.recordedCalls() == [.resolveSongURL(track.id, .standard)]
  )
  guard case .remote = rig.output.preparedResources.last?.location else {
    Issue.record("Play Again must resolve online after a local item failure")
    return
  }
}

// MARK: - FM trash while local playback bypasses a write

@Test @MainActor func confirmedTrashRemovesTheOldSongAfterLocalNextAlreadyPlayed() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  let tracks = makeTracks([1, 2, 3, 4, 5])
  _ = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: tracks[1]
  )
  await rig.activate()

  let radio = RadioCoordinator(
    transport: rig.transport,
    vault: rig.vault,
    arbiter: rig.arbiter
  )
  radio.attach(playback: rig.playback)
  rig.playback.onPlaybackChanged = { [weak radio] revision in
    radio?.playbackChanged(revision: revision, session: rig.session)
  }
  await rig.transport.setFMBatches([tracks])
  await rig.program(songID: 1)
  radio.startPersonalFM(session: rig.session)
  await radio.settleForTesting()
  await rig.playback.settleForTesting()

  let beforeTrash = await rig.transport.gate.arrivalCount()
  await rig.transport.gate.close()
  radio.trashCurrentFMSong(session: rig.session)
  while await rig.transport.gate.arrivalCount() < beforeTrash + 1 {
    await Task.yield()
  }

  #expect(rig.playback.playNext(session: rig.session))
  await rig.playback.settleForTesting()
  rig.output.reportPosition(37)
  let teardownAfterNext = rig.output.teardownCount
  #expect(rig.playback.currentTrack?.id == 2)
  #expect(rig.playback.phase == .playing)

  await rig.transport.gate.open()
  await radio.settleForTesting()

  #expect(
    rig.playback.queuedTracks(context: .personalFM).map(\.id) == [2, 3, 4, 5]
  )
  #expect(rig.playback.currentTrack?.id == 2)
  #expect(rig.playback.queue?.currentIndex == 0)
  #expect(rig.playback.phase == .playing)
  #expect(rig.playback.positionSeconds == 37)
  #expect(rig.output.teardownCount == teardownAfterNext)
  #expect(rig.playback.playPrevious(session: rig.session) == false)
}

@Test @MainActor func lateTrashSuccessDoesNotEditADownloadQueueThatReplacedFM() async throws {
  let rig = try DownloadRig()
  defer { rig.cleanup() }
  let download = try await seedDownload(
    store: rig.store,
    files: rig.files,
    accountID: testAccount.userID,
    track: makeTracks([50])[0]
  )
  await rig.activate()

  let radio = RadioCoordinator(
    transport: rig.transport,
    vault: rig.vault,
    arbiter: rig.arbiter
  )
  radio.attach(playback: rig.playback)
  rig.playback.onPlaybackChanged = { [weak radio] revision in
    radio?.playbackChanged(revision: revision, session: rig.session)
  }
  await rig.transport.setFMBatches([makeTracks([1, 2, 3, 4, 5])])
  await rig.program(songID: 1)
  radio.startPersonalFM(session: rig.session)
  await radio.settleForTesting()
  await rig.playback.settleForTesting()

  let beforeTrash = await rig.transport.gate.arrivalCount()
  await rig.transport.gate.close()
  radio.trashCurrentFMSong(session: rig.session)
  while await rig.transport.gate.arrivalCount() < beforeTrash + 1 {
    await Task.yield()
  }

  rig.playback.playDownloaded(download, session: rig.session)
  await rig.playback.settleForTesting()
  let teardownBeforeSuccess = rig.output.teardownCount
  #expect(rig.playback.queueContext == .downloads)

  await rig.transport.gate.open()
  await radio.settleForTesting()

  #expect(rig.playback.queueContext == .downloads)
  #expect(rig.playback.currentTrack?.id == 50)
  #expect(rig.output.teardownCount == teardownBeforeSuccess)
  #expect(
    rig.arbiter.unresolvedOutcomes.map(\.kind) == [.appliedRemotelyOnly]
  )
}

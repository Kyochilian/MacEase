import Foundation
import Testing

@testable import MacEase
@testable import MacEaseAppCore

@Test @MainActor func audioCacheFailureDoesNotRemovePersistentDownloadServices() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "MacEase-composition-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(
    at: root,
    withIntermediateDirectories: true
  )
  defer { try? FileManager.default.removeItem(at: root) }

  let transport = FakeTransport()
  let vault = FakeVault(stored: makeCredential())
  let arbiter = OperationArbiter()
  let playback = PlaybackController(
    transport: transport,
    vault: vault,
    arbiter: arbiter,
    output: FakeAudioOutput()
  )

  let storage = MacEaseApp.openStorage(
    playback: playback,
    transport: transport,
    vault: vault,
    arbiter: arbiter,
    ranges: nil,
    storePath: root.appendingPathComponent("library.sqlite3").path,
    downloadsDirectory: root.appendingPathComponent("Downloads", isDirectory: true)
  )

  #expect(storage.persistence != nil)
  let downloads = try #require(storage.downloads)
  #expect(!downloads.canCreateDownloads)
  #expect(storage.diagnostic == nil)
}

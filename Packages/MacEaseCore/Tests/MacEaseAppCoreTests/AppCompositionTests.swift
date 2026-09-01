import Foundation
import Testing

@testable import MacEase
@testable import MacEaseAppCore
@testable import NeteaseKit

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

/// Every module the account owns data for is cleared by one identity change,
/// including the ones added for browsing, search and the radio.
@Test @MainActor func anIdentityChangeClearsEverySessionScopedModule() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let session = FakeSession(credential: credential)
  let arbiter = OperationArbiter()
  let output = FakeAudioOutput()
  let playback = PlaybackController(
    transport: transport,
    vault: vault,
    arbiter: arbiter,
    output: output
  )
  playback.attach(session: session)
  let library = PlaylistLibraryCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  let discovery = DiscoveryCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  let collections = CollectionsCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  let catalog = CatalogCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter,
    suggestionDelay: .zero
  )
  let radio = RadioCoordinator(transport: transport, vault: vault, arbiter: arbiter)
  radio.attach(playback: playback)

  await transport.setSearchPages([
    SearchPage(items: .songs(makeTracks([1])), totalCount: 1)
  ])
  await transport.setBrowsePages([
    CatalogPage(items: makeDiscovered([2]), more: false)
  ])
  await transport.setFMBatches([makeTracks([3, 4])])
  await transport.setSongURL(.success(makeResolvedAsset(songID: 3)))

  catalog.query = "canary"
  catalog.runSearch(session: session)
  await catalog.settleForTesting()
  discovery.loadCategoryPlaylists(reset: true, session: session)
  await discovery.settleForTesting()
  radio.startPersonalFM(session: session)
  await radio.settleForTesting()
  await playback.settleForTesting()

  #expect(!catalog.results.isEmpty)
  #expect(!discovery.categoryPlaylists.isEmpty)
  #expect(radio.isPlayingFM)

  MacEaseApp.clearSessionScopedState(
    playback: playback,
    downloads: nil,
    library: library,
    discovery: discovery,
    collections: collections,
    catalog: catalog,
    radio: radio,
    lyrics: nil,
    nowPlaying: nil
  )

  #expect(catalog.results.isEmpty)
  #expect(catalog.resultsKeywords == nil)
  #expect(discovery.categoryPlaylists.isEmpty)
  #expect(radio.isPlayingFM == false)
  #expect(playback.queue == nil)
  #expect(arbiter.activeReadCount == 0)
}

/// A playlist opened from discovery, browsing or search is read through the
/// library, but it is not one of the account's own: it must never enter the
/// collection that gets written to the per-account SQLite snapshot.
@Test @MainActor func openingADiscoveredPlaylistNeverEntersTheAccountSnapshot() async {
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let session = FakeSession(credential: credential)
  let library = PlaylistLibraryCoordinator(
    transport: transport,
    vault: vault,
    arbiter: OperationArbiter()
  )
  var persisted: [[UserPlaylist]] = []
  library.onPersistablePlaylistsChanged = { _, playlists in
    persisted.append(playlists)
  }

  await transport.setPlaylistPages([
    UserPlaylistPage(playlists: makePlaylists([10]), more: false)
  ])
  library.load(reset: true, session: session)
  await library.settleForTesting()
  #expect(persisted.count == 1)

  await transport.setPlaylistDetail(
    .success(PlaylistDetail(id: 777, name: "Discovered", trackIDs: [1]))
  )
  await transport.setSongDetailBatches([makeTracks([1])])
  // Exactly the row the composition root builds for a discovered playlist.
  library.loadTracks(
    for: UserPlaylist(
      id: 777,
      name: "Discovered",
      trackCount: 0,
      owned: false,
      isPrivate: nil
    ),
    session: session
  )
  await library.settleForTesting()

  #expect(library.tracks.map(\.id) == [1])
  #expect(library.playlists.map(\.id) == [10])
  // No second snapshot: nothing about the account's own playlists changed.
  #expect(persisted.count == 1)
  #expect(persisted[0].map(\.id) == [10])
}

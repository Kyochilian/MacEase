import AppKit
import Foundation
import Testing
import WebKit

@testable import MacEase
@testable import MacEaseAppCore
@testable import NeteaseKit

@MainActor
private final class CompositionNotificationCenter: NativeNotificationCenterIO {
  var status: NativeNotificationAuthorizationStatus = .authorized
  private(set) var requests: [NativeNotificationRequest] = []
  private(set) var removeAllCount = 0

  func authorizationStatus() async -> NativeNotificationAuthorizationStatus { status }
  func requestAuthorization() async throws {}
  func add(_ request: NativeNotificationRequest) async throws { requests.append(request) }
  func remove(identifier: UUID) {
    requests.removeAll { $0.identifier == identifier }
  }
  func removeAllPendingAndDelivered() {
    removeAllCount += 1
    requests.removeAll()
  }
}

@MainActor
private final class CompositionApplicationActivity: ApplicationActivityReading {
  var isApplicationActive = false
}

@MainActor
private struct AppDelegatePlaybackRig {
  let transport = FakeTransport()
  let vault: FakeVault
  let arbiter = OperationArbiter()
  let output = FakeAudioOutput()
  let session: FakeSession
  let playback: PlaybackController
  let library: PlaylistLibraryCoordinator
  let router: SystemMediaRouter

  init() {
    let credential = makeCredential()
    vault = FakeVault(stored: credential)
    session = FakeSession(credential: credential)
    playback = PlaybackController(
      transport: transport,
      vault: vault,
      arbiter: arbiter,
      output: output
    )
    playback.attach(session: session)
    library = PlaylistLibraryCoordinator(
      transport: transport,
      vault: vault,
      arbiter: arbiter
    )
    router = SystemMediaRouter(
      playback: playback,
      library: library,
      session: session
    )
  }

  func play(context: PlaybackContext = .dailyRecommendations) async {
    await transport.setSongURL(.success(makeResolvedAsset(songID: 1)))
    playback.play(
      tracks: makeTracks([1, 2, 3]),
      startIndex: 0,
      context: context,
      session: session
    )
    await playback.settleForTesting()
  }
}

@Test @MainActor func spacePlaybackShortcutLeavesTextInputAndModifiedKeysAlone() {
  typealias Shortcut = SafeSpacePlaybackShortcut.Coordinator
  #expect(
    Shortcut.shouldHandleSpace(
      characters: " ",
      modifiers: [],
      isRepeat: false,
      focusedElementConsumesSpace: false
    )
  )
  #expect(
    !Shortcut.shouldHandleSpace(
      characters: " ",
      modifiers: [],
      isRepeat: false,
      focusedElementConsumesSpace: true
    )
  )
  #expect(
    !Shortcut.shouldHandleSpace(
      characters: " ",
      modifiers: .command,
      isRepeat: false,
      focusedElementConsumesSpace: false
    )
  )

  let button = NSButton()
  #expect(Shortcut.focusedElementConsumesSpace(button))

  let webView = WKWebView()
  let webContent = NSView()
  webView.addSubview(webContent)
  #expect(Shortcut.focusedElementConsumesSpace(webContent))
}

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
  let scrobble = ScrobbleCoordinator(
    transport: transport,
    vault: vault,
    arbiter: arbiter
  )
  scrobble.status = "stale scrobble state"
  let notificationSuite = "macease.composition.notifications.\(UUID().uuidString)"
  let notificationDefaults = UserDefaults(suiteName: notificationSuite) ?? .standard
  let notificationSettings = AppSettings(defaults: notificationDefaults)
  notificationSettings.nativeNotificationsEnabled = true
  let notificationCenter = CompositionNotificationCenter()
  let notificationActivity = CompositionApplicationActivity()
  let nativeNotifications = NativeNotificationCoordinator(
    settings: notificationSettings,
    center: notificationCenter,
    activity: notificationActivity
  )
  await nativeNotifications.refreshAuthorizationStatus()
  nativeNotifications.bind(accountID: testAccount.userID)
  nativeNotifications.handle(
    .started(
      PlaybackLifecycleInstance(
        accountID: testAccount.userID,
        track: makeTracks([99])[0],
        context: .dailyRecommendations
      )
    )
  )
  await nativeNotifications.settleForTesting()
  #expect(notificationCenter.requests.count == 1)

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
    scrobble: scrobble,
    downloads: nil,
    library: library,
    discovery: discovery,
    collections: collections,
    catalog: catalog,
    radio: radio,
    lyrics: nil,
    nowPlaying: nil,
    nativeNotifications: nativeNotifications
  )

  #expect(catalog.results.isEmpty)
  #expect(catalog.resultsKeywords == nil)
  #expect(discovery.categoryPlaylists.isEmpty)
  #expect(radio.isPlayingFM == false)
  #expect(playback.queue == nil)
  #expect(arbiter.activeReadCount == 0)
  #expect(scrobble.status == "Listening feedback is waiting for validated playback")
  #expect(notificationCenter.requests.isEmpty)
  #expect(notificationCenter.removeAllCount >= 2)
  notificationDefaults.removePersistentDomain(forName: notificationSuite)
}

@Test @MainActor func dockMenuProjectsSharedModesWithoutAnyNetworkWork() async throws {
  let rig = AppDelegatePlaybackRig()
  await rig.play()
  let calls = await rig.transport.recordedCalls()
  let delegate = MacEaseAppDelegate()
  delegate.configure(
    router: rig.router,
    refreshNotificationAuthorization: {},
    prepareForTermination: {}
  )

  let menu = try #require(delegate.applicationDockMenu(NSApplication.shared))
  let shuffle = try #require(menu.items.first { $0.title == "Shuffle" })
  let repeatItem = try #require(menu.items.first { $0.title == "Repeat" })
  let repeatMenu = try #require(repeatItem.submenu)
  let repeatOne = try #require(
    repeatMenu.items.first { $0.title == "Repeat One" }
  )

  #expect(shuffle.isEnabled)
  #expect(shuffle.state == .off)
  #expect(repeatItem.isEnabled)
  #expect(repeatMenu.items.first { $0.title == "Off" }?.state == .on)
  #expect(await rig.transport.recordedCalls() == calls)

  #expect(NSApplication.shared.sendAction(shuffle.action!, to: shuffle.target, from: shuffle))
  #expect(rig.playback.playbackMode == .shuffle)
  #expect(
    NSApplication.shared.sendAction(
      repeatOne.action!,
      to: repeatOne.target,
      from: repeatOne
    )
  )
  #expect(rig.playback.playbackMode == .repeatOne)
  #expect(await rig.transport.recordedCalls() == calls)
}

@Test @MainActor func personalFMDockModesUseTheControllersDisabledState() async throws {
  let rig = AppDelegatePlaybackRig()
  await rig.play(context: .personalFM)
  let delegate = MacEaseAppDelegate()
  delegate.configure(
    router: rig.router,
    refreshNotificationAuthorization: {},
    prepareForTermination: {}
  )

  let menu = try #require(delegate.applicationDockMenu(NSApplication.shared))
  let shuffle = try #require(menu.items.first { $0.title == "Shuffle" })
  let repeatItem = try #require(menu.items.first { $0.title == "Repeat" })

  menu.update()
  #expect(!shuffle.isEnabled)
  #expect(!repeatItem.isEnabled)
}

@Test @MainActor func becomingActiveRefreshesNotificationPermission() async {
  let rig = AppDelegatePlaybackRig()
  let delegate = MacEaseAppDelegate()
  var refreshes = 0
  delegate.configure(
    router: rig.router,
    refreshNotificationAuthorization: { refreshes += 1 },
    prepareForTermination: {}
  )

  delegate.applicationDidBecomeActive(
    Notification(name: NSApplication.didBecomeActiveNotification)
  )
  for _ in 0..<5 { await Task.yield() }

  #expect(refreshes == 1)
}

@Test @MainActor func artworkLoadingRefusesInsecureURLsAtTheRequestBoundary() async {
  let loader = ArtworkLoader(diskCapacityBytes: 0, directory: nil)
  let url = URL(string: "http://p1.music.126.net/legacy-cover.jpg")!

  #expect(await loader.image(for: url) == nil)
  #expect(loader.cachedNotificationArtwork(for: url) == nil)
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

import MacEaseAppCore
import MacEaseSession
import NeteaseKit
import SwiftUI
import WebKit

@main
@MainActor
struct MacEaseApp: App {
  @Environment(\.scenePhase) private var scenePhase
  private enum MainTab: Hashable {
    case session
    case library
    case collections
    case discover
    case search
    case catalog
    case records
    case lyrics
    case downloads
    case settings
  }

  @NSApplicationDelegateAdaptor(MacEaseAppDelegate.self)
  private var appDelegate

  @State private var session: LoginCoordinator
  @State private var library: PlaylistLibraryCoordinator
  @State private var discovery: DiscoveryCoordinator
  @State private var collections: CollectionsCoordinator
  @State private var catalog: CatalogCoordinator
  @State private var radio: RadioCoordinator
  @State private var lyrics: LyricsCoordinator
  @State private var playback: PlaybackController
  @State private var scrobble: ScrobbleCoordinator
  @State private var arbiter: OperationArbiter
  @State private var settings: AppSettings
  @State private var nativeNotifications: NativeNotificationCoordinator
  @State private var updater: AppUpdater
  @State private var artwork: ArtworkLoader
  /// Temporary, evictable HTTP ranges. The player owns the active pin; the
  /// settings page only observes and maintains the same store.
  @State private var audioRanges: AudioRangePipeline?
  /// Persistent files and records for only the validated account.
  @State private var downloads: DownloadCoordinator?
  /// Held so the Now Playing bridge lives as long as the app does; the views
  /// never read it.
  @State private var nowPlaying: NowPlayingCoordinator
  @State private var mediaRouter: SystemMediaRouter
  /// Same: the machine-state observer must outlive the initialiser that
  /// started it, or sleep and device changes would stop being reported.
  @State private var systemEvents: MacSystemEventObserver
  /// nil when the store could not be opened. Persistence is a convenience:
  /// losing it costs the resume point, not the app.
  @State private var queuePersistence: QueuePersistence?
  /// Why the store could not be opened, when it could not. Kept so a store
  /// that never opened is visible rather than looking like one that is quietly
  /// keeping up.
  @State private var storageDiagnostic: String?
  @State private var selectedTab: MainTab = .session
  @State private var catalogPane: CatalogView.Pane = .newReleases
  @State private var discoverPane: DiscoverView.Pane = .recommended
  @State private var collectionPane: CollectionsView.Section = .albums
  @State private var showsOpenLink = false
  @State private var musicLinkText = ""
  @State private var musicLinkError: String?

  init() {
    // One transport and one credential store for the whole app: every
    // coordinator shares them instead of constructing its own.
    let transport = NeteaseSession()
    let vault = CredentialVault()
    // One arbiter protects writes and destructive session mutations.
    let arbiter = OperationArbiter()
    let settings = AppSettings()
    let updater = AppUpdater()
    let artwork = ArtworkLoader(
      diskCapacityBytes: Int(settings.imageCacheLimitBytes)
    )
    let nativeNotifications = NativeNotificationCoordinator(
      settings: settings,
      center: SystemNativeNotificationCenter(),
      activity: MacApplicationActivity(),
      cachedArtwork: { [weak artwork] url in
        artwork?.cachedNotificationArtwork(for: url)
      }
    )
    let audioCache = Self.openAudioRangeCache(
      limitBytes: settings.audioCacheLimitBytes
    )
    let login = LoginCoordinator(transport: transport, vault: vault, arbiter: arbiter)
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
      arbiter: arbiter
    )
    catalog.onAlbumCollectionStateConfirmed = { [weak collections] albumID, collected in
      collections?.confirmAlbumCollected(collected, albumID: albumID)
    }
    let radio = RadioCoordinator(
      transport: transport,
      vault: vault,
      arbiter: arbiter
    )
    let lyrics = LyricsCoordinator(
      transport: transport,
      vault: vault,
      arbiter: arbiter
    )
    let playback = PlaybackController(
      transport: transport,
      vault: vault,
      arbiter: arbiter,
      output: AVPlayerAudioOutput(rangePipeline: audioCache.pipeline)
    )
    playback.attach(session: login)
    let scrobble = ScrobbleCoordinator(
      transport: transport,
      vault: vault,
      arbiter: arbiter
    )
    playback.onLifecycleEvent = {
      [weak scrobble, weak login, weak nativeNotifications, weak discovery] event in
      nativeNotifications?.handle(event)
      discovery?.recordPlayback(event)
      guard let login else { return }
      scrobble?.handle(event, session: login)
    }
    login.onPrepareIdentityMutation = { [weak playback, weak scrobble] in
      playback?.prepareForSessionMutation()
      await scrobble?.settle()
    }
    login.onFinishIdentityMutationPreparation = { [weak playback] in
      playback?.finishSessionMutationPreparation()
    }
    radio.attach(playback: playback)
    // One playback callback both invalidates old radio responses and reports
    // ordinary queue movement that may need a continuation. It is neither a
    // timer nor a poll.
    playback.onPlaybackChanged = { [weak radio, weak login] revision in
      guard let login else { return }
      radio?.playbackChanged(revision: revision, session: login)
    }
    // Sleep, wake, the output device going away and the network coming and
    // going. The decisions live in PlaybackController, which is tested; this
    // only delivers the events.
    let systemEvents = MacSystemEventObserver()
    playback.observe(system: systemEvents)
    // Now Playing and the media keys read a projection of playback and route
    // commands back as intents. The router lives in MacEaseAppCore so this
    // exact wiring is covered by tests; it never calls the transport itself.
    let router = SystemMediaRouter(playback: playback, library: library, session: login)
    let nowPlaying = NowPlayingCoordinator(
      surface: MPSystemMediaController(),
      snapshotProvider: { router.snapshot() },
      performIntent: { router.perform($0) },
      artworkProvider: { [weak artwork] url in
        await artwork?.image(for: url, variant: .display)
      }
    )
    nowPlaying.startObserving()
    // A store that will not open is not a reason to refuse to run: queue
    // restore and persistent downloads are unavailable, but online use remains.
    // Why it would not open is kept, so it cannot be mistaken for a store that
    // is quietly keeping up.
    let storage = Self.openStorage(
      playback: playback,
      transport: transport,
      vault: vault,
      arbiter: arbiter,
      ranges: audioCache.pipeline
    )
    let queuePersistence = storage.persistence
    let downloads = storage.downloads
    lyrics.attach(store: queuePersistence?.store)
    catalog.attach(store: queuePersistence?.store)
    discovery.attach(store: queuePersistence?.store)
    if let downloads {
      downloads.saveLyrics = { [weak lyrics] track, session in
        await lyrics?.saveForOffline(track: track, session: session)
      }
      playback.attach(downloads: downloads)
      downloads.attach(playback: playback)
      downloads.onTerminalEvent = { [weak nativeNotifications] event in
        nativeNotifications?.handle(event)
      }
    }
    playback.onExplicitStop = {
      queuePersistence?.clearQueueAfterExplicitStop()
    }
    playback.onQueueEdited = {
      Task { await queuePersistence?.save() }
    }
    library.onPersistablePlaylistsChanged = { accountID, playlists in
      await queuePersistence?.savePlaylists(playlists, accountID: accountID)
    }
    // A divergence found by any coordinator invalidates the identity for all
    // of them, so the session owner clears everything, not just the reporter.
    login.onIdentityChanged = {
      [
        weak playback, weak library, weak discovery, weak collections, weak lyrics,
        weak catalog, weak radio, weak downloads, weak scrobble, weak nowPlaying,
        weak nativeNotifications
      ] in
      Self.clearSessionScopedState(
        playback: playback,
        scrobble: scrobble,
        downloads: downloads,
        library: library,
        discovery: discovery,
        collections: collections,
        catalog: catalog,
        radio: radio,
        lyrics: lyrics,
        nowPlaying: nowPlaying,
        nativeNotifications: nativeNotifications
      )
    }
    // Every path that establishes or drops an account arrives here, so QR,
    // SMS, Import and Validate all bind the same per-account data and spend
    // the same account-scoped Discover prefetch. None of them carries a
    // copy of this decision, so none of them can be left out of it.
    login.onValidatedAccountChanged = {
      [
        weak login, weak library, weak discovery, weak downloads,
        weak nativeNotifications
      ] account in
      // Binding and cancellation are synchronous with the identity commit;
      // an old CDN task cannot wait for a later SwiftUI scheduling turn.
      downloads?.bind(accountID: account?.userID)
      discovery?.bindHistory(accountID: account?.userID)
      nativeNotifications?.bind(accountID: account?.userID)
      Task { @MainActor in
        guard let account else {
          await queuePersistence?.deactivate()
          return
        }
        // Another transition may have superseded this one; binding the account
        // it replaced would put the wrong queue back.
        guard let login, login.account?.userID == account.userID else { return }
        if login.isOnline { discovery?.prefetch(session: login) }
        // Binding the new account is what restores its queue; the previous
        // account's stored queue is left on disk untouched.
        await queuePersistence?.activate(accountID: account.userID)
        guard login.account?.userID == account.userID else { return }
        library?.restore(
          playlists: await queuePersistence?.storedPlaylists(
            accountID: account.userID
          ) ?? []
        )
        if login.isOnline { library?.load(reset: true, session: login) }
      }
    }
    _session = State(initialValue: login)
    _library = State(initialValue: library)
    _discovery = State(initialValue: discovery)
    _collections = State(initialValue: collections)
    _catalog = State(initialValue: catalog)
    _radio = State(initialValue: radio)
    _lyrics = State(initialValue: lyrics)
    _playback = State(initialValue: playback)
    _scrobble = State(initialValue: scrobble)
    _arbiter = State(initialValue: arbiter)
    _settings = State(initialValue: settings)
    _nativeNotifications = State(initialValue: nativeNotifications)
    _updater = State(initialValue: updater)
    _artwork = State(initialValue: artwork)
    _audioRanges = State(initialValue: audioCache.pipeline)
    _downloads = State(initialValue: downloads)
    _nowPlaying = State(initialValue: nowPlaying)
    _mediaRouter = State(initialValue: router)
    _systemEvents = State(initialValue: systemEvents)
    _queuePersistence = State(initialValue: queuePersistence)
    let combinedDiagnostic = [storage.diagnostic, audioCache.diagnostic]
      .compactMap { $0 }
      .joined(separator: " ")
    _storageDiagnostic = State(
      initialValue: combinedDiagnostic.isEmpty ? nil : combinedDiagnostic
    )
    appDelegate.configure(
      router: router,
      refreshNotificationAuthorization: { [weak nativeNotifications] in
        await nativeNotifications?.refreshAuthorizationStatus()
      },
      prepareForTermination: {
        nativeNotifications.reset()
        playback.prepareForSessionMutation()
        await scrobble.settle()
        nowPlaying.clear()
      }
    )
    Task { await nativeNotifications.refreshAuthorizationStatus() }
  }

  /// Everything an identity change has to discard, in one place.
  ///
  /// It used to be a list of calls inside the closure the session owner holds,
  /// which meant a coordinator added later was cleared only if whoever added
  /// it remembered this closure existed. Naming every module here makes
  /// leaving one out a compile error rather than a session's data surviving
  /// into the next account.
  @MainActor
  static func clearSessionScopedState(
    playback: PlaybackController?,
    scrobble: ScrobbleCoordinator?,
    downloads: DownloadCoordinator?,
    library: PlaylistLibraryCoordinator?,
    discovery: DiscoveryCoordinator?,
    collections: CollectionsCoordinator?,
    catalog: CatalogCoordinator?,
    radio: RadioCoordinator?,
    lyrics: LyricsCoordinator?,
    nowPlaying: NowPlayingCoordinator?,
    nativeNotifications: NativeNotificationCoordinator?
  ) {
    playback?.stopForSessionChange()
    scrobble?.reset()
    downloads?.bind(accountID: nil)
    library?.reset()
    discovery?.reset()
    collections?.reset()
    catalog?.reset()
    radio?.reset()
    lyrics?.reset()
    // The system surface must not keep advertising a track that belonged to a
    // session that no longer exists.
    nowPlaying?.clear()
    nativeNotifications?.reset()
  }

  static func openStorage(
    playback: PlaybackController,
    transport: any NeteaseTransporting,
    vault: any CredentialStoring,
    arbiter: OperationArbiter,
    ranges: AudioRangePipeline?,
    storePath: String? = nil,
    downloadsDirectory: URL? = nil
  ) -> (
    persistence: QueuePersistence?,
    downloads: DownloadCoordinator?,
    diagnostic: String?
  ) {
    do {
      let store = try LibraryStore(
        path: try storePath ?? LibraryStore.defaultPath()
      )
      let persistence = QueuePersistence(store: store, playback: playback)
      do {
        let files = try OfflineAudioFiles(
          directory: try downloadsDirectory ?? OfflineAudioFiles.defaultDirectory()
        )
        return (
          persistence,
          DownloadCoordinator(
            transport: transport,
            vault: vault,
            arbiter: arbiter,
            ranges: ranges,
            store: store,
            files: files
          ),
          nil
        )
      } catch {
        return (
          persistence,
          nil,
          "Offline download storage is unavailable: "
            + LibraryStore.diagnostic(for: error)
        )
      }
    } catch {
      return (
        nil,
        nil,
        "Local storage is unavailable, so the queue and downloads will not "
          + "survive a relaunch: " + LibraryStore.diagnostic(for: error)
      )
    }
  }

  private static func openAudioRangeCache(
    limitBytes: Int64
  ) -> (pipeline: AudioRangePipeline?, diagnostic: String?) {
    do {
      let store = try AudioRangeStore(
        directory: AudioRangeStore.defaultDirectory(),
        limitBytes: limitBytes
      )
      return (
        AudioRangePipeline(store: store, fetcher: URLSessionAudioByteFetcher()),
        nil
      )
    } catch {
      return (
        nil,
        "Temporary audio caching is unavailable: "
          + (error as NSError).localizedDescription
      )
    }
  }

  var body: some Scene {
    Window("MacEase", id: "main") {
      VStack(spacing: 0) {
        TabView(selection: $selectedTab) {
          SessionView(
            session: session,
            arbiter: arbiter,
            storageStatus: storageDiagnostic ?? queuePersistence?.lastFailure
              ?? downloads?.lastFailure,
            artwork: artwork
          )
          .tabItem { Label("Session", systemImage: "person.crop.circle") }
          .tag(MainTab.session)
          PlaylistLibraryView(
            session: session,
            library: library,
            discovery: discovery,
            playback: playback,
            arbiter: arbiter,
            artwork: artwork,
            downloads: downloads
          )
          .tabItem { Label("Library", systemImage: "music.note.list") }
          .tag(MainTab.library)
          CollectionsView(
            session: session,
            collections: collections,
            playback: playback,
            arbiter: arbiter,
            artwork: artwork,
            openAlbum: { id in
              catalog.openAlbum(id: id, session: session)
              catalogPane = .album
              selectedTab = .catalog
            },
            openArtist: { id in
              catalog.openArtist(id: id, session: session)
              catalogPane = .artist
              selectedTab = .catalog
            },
            downloads: downloads,
            section: $collectionPane
          )
          .tabItem { Label("Collections", systemImage: "square.stack") }
          .tag(MainTab.collections)
          DiscoverView(
            session: session,
            library: library,
            discovery: discovery,
            radio: radio,
            playback: playback,
            arbiter: arbiter,
            artwork: artwork,
            openPlaylist: openDiscoveredPlaylist,
            openArtist: { artist in
              catalog.openArtist(id: artist.id, session: session)
              catalogPane = .artist
              selectedTab = .catalog
            },
            downloads: downloads,
            pane: $discoverPane
          )
          .tabItem { Label("Discover", systemImage: "sparkles") }
          .tag(MainTab.discover)
          SearchView(
            session: session,
            library: library,
            catalog: catalog,
            playback: playback,
            arbiter: arbiter,
            artwork: artwork,
            openPlaylist: openDiscoveredPlaylist,
            openAlbum: { albumID in
              catalog.openAlbum(id: albumID, session: session)
              catalogPane = .album
              selectedTab = .catalog
            },
            openArtist: { artistID in
              catalog.openArtist(id: artistID, session: session)
              catalogPane = .artist
              selectedTab = .catalog
            },
            downloads: downloads
          )
          .tabItem { Label("Search", systemImage: "magnifyingglass") }
          .tag(MainTab.search)
          CatalogView(
            session: session,
            library: library,
            catalog: catalog,
            collections: collections,
            playback: playback,
            arbiter: arbiter,
            artwork: artwork,
            downloads: downloads,
            showSimilarArtists: { artist in
              discovery.loadSimilarArtists(seed: artist, session: session)
              discoverPane = .recommended
              selectedTab = .discover
            },
            pane: $catalogPane
          )
          .tabItem { Label("Catalog", systemImage: "square.grid.2x2") }
          .tag(MainTab.catalog)
          PlayRecordsView(
            session: session,
            library: library,
            discovery: discovery,
            playback: playback,
            scrobble: scrobble,
            arbiter: arbiter,
            artwork: artwork
          )
          .tabItem { Label("Records", systemImage: "chart.bar") }
          .tag(MainTab.records)
          LyricsView(
            session: session,
            playback: playback,
            lyrics: lyrics,
            artwork: artwork,
            settings: settings
          )
          .tabItem { Label("Lyrics", systemImage: "text.quote") }
          .tag(MainTab.lyrics)
          if let downloads {
            DownloadsView(
              session: session,
              downloads: downloads,
              playback: playback,
              artwork: artwork
            )
            .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            .tag(MainTab.downloads)
          }
          SettingsView(
            settings: settings,
            nativeNotifications: nativeNotifications,
            updater: updater,
            artwork: artwork,
            audioRanges: audioRanges,
            downloads: downloads
          )
          .tabItem { Label("Settings", systemImage: "gearshape") }
          .tag(MainTab.settings)
        }
        Divider()
        UnresolvedOutcomeBanner(arbiter: arbiter)
        PlaybackBarView(
          session: session,
          playback: playback,
          arbiter: arbiter,
          downloads: downloads,
          mediaRouter: mediaRouter,
          artwork: artwork
        )
      }
      .frame(minWidth: 760, minHeight: 600)
      .preferredColorScheme(settings.theme.colorScheme)
      .background {
        SafeSpacePlaybackShortcut {
          mediaRouter.perform(.togglePlayback)
        }
        .frame(width: 0, height: 0)
      }
      // A queue is worth remembering when it changes in a way the user would
      // notice: a new track or a seek bumps the epoch, and pausing or stopping
      // changes the phase. The slow tick inside `QueuePersistence` covers the
      // position moving on its own. None of this is a request.
      .onChange(of: playback.positionEpoch) {
        Task { await queuePersistence?.save() }
      }
      .onChange(of: playback.phase) {
        Task { await queuePersistence?.save() }
      }
      .task {
        appDelegate.configureRecentSources(
          account: { session.account?.userID }, sources: { discovery.recentSources },
          open: openRecentSource
        )
        await session.start()
        if session.account != nil {
          selectedTab = session.isOnline ? .discover : .downloads
        }
      }
      .onChange(of: scenePhase) {
        if scenePhase == .active { session.applicationDidBecomeActive() }
      }
      .environment(
        \.openURL,
        OpenURLAction { url in
          guard let link = NeteaseMusicLink(url: url) else { return .systemAction }
          openMusicLink(link)
          return .handled
        }
      )
      .onOpenURL { url in
        if let link = NeteaseMusicLink(url: url) { openMusicLink(link) }
      }
      .sheet(isPresented: $showsOpenLink) {
        Form {
          Text("Open NetEase Music Link").font(.headline)
          TextField("Song, album, artist or playlist link", text: $musicLinkText)
          if let musicLinkError { Text(musicLinkError).foregroundStyle(.red) }
          HStack {
            Button("Open") {
              guard
                let url = URL(
                  string: musicLinkText.trimmingCharacters(in: .whitespacesAndNewlines)),
                let link = NeteaseMusicLink(url: url)
              else {
                musicLinkError = "Enter a valid music.163.com music link"
                return
              }
              showsOpenLink = false
              openMusicLink(link)
            }.keyboardShortcut(.defaultAction)
            Button("Cancel") { showsOpenLink = false }
          }
        }.padding().frame(width: 500)
      }
    }
    .defaultSize(width: 980, height: 760)
    .commands {
      CommandGroup(after: .newItem) {
        Button("Open Music Link…") {
          musicLinkError = nil
          showsOpenLink = true
        }
        .keyboardShortcut("o", modifiers: .command)
      }
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
      }

      CommandMenu("Playback") {
        Button("Play/Pause") {
          _ = mediaRouter.perform(.togglePlayback)
        }
        .disabled(!mediaRouter.canPerform(.togglePlayback))

        Divider()

        Button("Previous") {
          _ = mediaRouter.perform(AppPlaybackCommand.previous)
        }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        .disabled(!mediaRouter.canPerform(.previous))
        Button("Next") {
          _ = mediaRouter.perform(AppPlaybackCommand.next)
        }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        .disabled(!mediaRouter.canPerform(.next))

        Divider()

        modeCommand("Sequential", mode: .sequential)
        modeCommand("Shuffle", mode: .shuffle)
        modeCommand("Repeat One", mode: .repeatOne)
        modeCommand("Repeat All", mode: .repeatAll)

        Divider()

        Button(likeCommandTitle(mediaRouter.snapshot().liked)) {
          _ = mediaRouter.perform(.toggleLiked)
        }
        .keyboardShortcut("l", modifiers: [.command])
        .disabled(!mediaRouter.canPerform(.toggleLiked))

        Button("Show Lyrics") { selectedTab = .lyrics }
          .keyboardShortcut("l", modifiers: [.command, .option])
      }
    }
  }

  @ViewBuilder
  private func modeCommand(_ title: String, mode: PlaybackMode) -> some View {
    Button {
      _ = mediaRouter.perform(.setMode(mode))
    } label: {
      if playback.playbackMode == mode {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
    .disabled(!mediaRouter.canPerform(.setMode(mode)))
  }

  private func likeCommandTitle(_ state: LikedState) -> String {
    switch state {
    case .liked: "Unlike"
    case .notLiked: "Like"
    case .unknown: "Like/Unlike"
    }
  }

  /// Opens a playlist that came from discovery, browsing or search through the
  /// same read path the library uses.
  ///
  /// It is passed as a row the account does not own and whose length is not
  /// known, because that is the truth: nothing here has been told either. The
  /// library only ever replaces a row it already holds, so a playlist read
  /// this way never enters the account's own collection and is never written
  /// to its stored snapshot.
  private func openMusicLink(_ link: NeteaseMusicLink) {
    switch link {
    case .song(let id):
      catalog.openSong(id: id, session: session)
      catalogPane = .song
      selectedTab = .catalog
    case .album(let id):
      catalog.openAlbum(id: id, session: session)
      catalogPane = .album
      selectedTab = .catalog
    case .artist(let id):
      catalog.openArtist(id: id, session: session)
      catalogPane = .artist
      selectedTab = .catalog
    case .playlist(let id): openDiscoveredPlaylist(DiscoveredPlaylist(id: id, name: "Playlist"))
    }
  }

  private func openRecentSource(_ context: PlaybackContext) {
    switch context {
    case .song(let id, _): openMusicLink(.song(id))
    case .playlist(let id, let name): openDiscoveredPlaylist(DiscoveredPlaylist(id: id, name: name))
    case .album(let id, _): openMusicLink(.album(id))
    case .artist(let id, _): openMusicLink(.artist(id))
    case .downloads: selectedTab = .downloads
    case .cloudDrive:
      collectionPane = .cloud
      selectedTab = .collections
    case .searchResults(let keywords):
      catalog.query = keywords
      catalog.runSearch(session: session)
      selectedTab = .search
    case .dailyRecommendations:
      discoverPane = .recommended
      selectedTab = .discover
      discovery.loadDailySongs(session: session)
    case .recommendationHistory(let date):
      discoverPane = .history
      selectedTab = .discover
      discovery.loadRecommendationHistory(date: date, session: session)
    case .recommendedNewSongs:
      discoverPane = .recommended
      selectedTab = .discover
      discovery.loadNewSongs(session: session)
    case .personalFM:
      discoverPane = .radio
      selectedTab = .discover
      radio.startPersonalFM(session: session)
    case .heartbeatMode(let name, let playlistID, let songID):
      discoverPane = .radio
      selectedTab = .discover
      if let playlistID, let songID {
        radio.startHeartbeatMode(
          seed: Track(id: songID, name: name), playlistID: playlistID, session: session)
      }
    case .unknown, .listeningRankings, .recentListening: selectedTab = .records
    case .similarSongs:
      discoverPane = .recommended
      selectedTab = .discover
    }
  }

  private func openDiscoveredPlaylist(_ playlist: DiscoveredPlaylist) {
    library.loadTracks(
      for: UserPlaylist(
        id: playlist.id,
        name: playlist.name,
        trackCount: 0,
        owned: false,
        isPrivate: nil
      ),
      session: session
    )
    selectedTab = .library
  }
}

extension PlaybackMode {
  var label: String {
    switch self {
    case .sequential: "Sequential"
    case .repeatAll: "Repeat All"
    case .repeatOne: "Repeat One"
    case .shuffle: "Shuffle"
    }
  }
}

/// A write whose server result the client could not determine is never shown
/// as success or failure. The user is told to go and check, and no automatic
/// follow-up request is issued.
private struct UnresolvedOutcomeBanner: View {
  let arbiter: OperationArbiter

  var body: some View {
    if !arbiter.unresolvedOutcomes.isEmpty {
      Divider()
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        Text(
          arbiter.unresolvedOutcomes
            .map { "\($0.name): \($0.advice)" }
            .joined(separator: "; ")
        )
        .font(.caption)
        Spacer()
        Button("Dismiss") { arbiter.acknowledgeUnresolvedOutcomes() }
          .buttonStyle(.borderless)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
  }
}

struct LoginWebView: NSViewRepresentable {
  let webView: WKWebView

  func makeNSView(context: Context) -> WKWebView {
    webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}
}

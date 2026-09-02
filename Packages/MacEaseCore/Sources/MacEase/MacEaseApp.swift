import MacEaseAppCore
import MacEaseSession
import NeteaseKit
import SwiftUI
import WebKit

@main
@MainActor
struct MacEaseApp: App {
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

  init() {
    // One transport and one credential store for the whole app: every
    // coordinator shares them instead of constructing its own.
    let transport = NeteaseSession()
    let vault = CredentialVault()
    // One arbiter protects writes and destructive session mutations.
    let arbiter = OperationArbiter()
    let settings = AppSettings()
    let artwork = ArtworkLoader(
      diskCapacityBytes: Int(settings.imageCacheLimitBytes)
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
    playback.onLifecycleEvent = { [weak scrobble, weak login] event in
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
        await artwork?.image(for: url)
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
    if let downloads {
      playback.attach(downloads: downloads)
      downloads.attach(playback: playback)
    }
    playback.onExplicitStop = {
      queuePersistence?.clearQueueAfterExplicitStop()
    }
    library.onPersistablePlaylistsChanged = { accountID, playlists in
      await queuePersistence?.savePlaylists(playlists, accountID: accountID)
    }
    // A divergence found by any coordinator invalidates the identity for all
    // of them, so the session owner clears everything, not just the reporter.
    login.onIdentityChanged = {
      [weak playback, weak library, weak discovery, weak collections, weak lyrics,
        weak catalog, weak radio, weak downloads, weak scrobble, weak nowPlaying] in
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
        nowPlaying: nowPlaying
      )
    }
    // Every path that establishes or drops an account arrives here, so QR,
    // SMS, Import and Validate all bind the same per-account data and spend
    // the same single launch-scoped Discover prefetch. None of them carries a
    // copy of this decision, so none of them can be left out of it.
    login.onValidatedAccountChanged = {
      [weak login, weak library, weak discovery, weak downloads] account in
      // Binding and cancellation are synchronous with the identity commit;
      // an old CDN task cannot wait for a later SwiftUI scheduling turn.
      downloads?.bind(accountID: account?.userID)
      Task { @MainActor in
        guard let account else {
          await queuePersistence?.deactivate()
          return
        }
        // Another transition may have superseded this one; binding the account
        // it replaced would put the wrong queue back.
        guard let login, login.account == account else { return }
        discovery?.prefetch(session: login)
        // Binding the new account is what restores its queue; the previous
        // account's stored queue is left on disk untouched.
        await queuePersistence?.activate(accountID: account.userID)
        guard login.account == account else { return }
        library?.restore(
          playlists: await queuePersistence?.storedPlaylists(
            accountID: account.userID
          ) ?? []
        )
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
      prepareForTermination: {
        playback.prepareForSessionMutation()
        await scrobble.settle()
        nowPlaying.clear()
      }
    )
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
    scrobble: ScrobbleCoordinator? = nil,
    downloads: DownloadCoordinator?,
    library: PlaylistLibraryCoordinator?,
    discovery: DiscoveryCoordinator?,
    collections: CollectionsCoordinator?,
    catalog: CatalogCoordinator?,
    radio: RadioCoordinator?,
    lyrics: LyricsCoordinator?,
    nowPlaying: NowPlayingCoordinator?
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
              ?? downloads?.lastFailure
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
            artwork: artwork
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
            }
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
            }
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
            showSimilarArtists: { artist in
              discovery.loadSimilarArtists(seed: artist, session: session)
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
          library: library,
          discovery: discovery,
          playback: playback,
          arbiter: arbiter,
          downloads: downloads
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
        await session.start()
      }
    }
    .defaultSize(width: 980, height: 760)
    .commands {
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

private struct SessionView: View {
  @Bindable var session: LoginCoordinator
  let arbiter: OperationArbiter
  /// Non-nil when local storage is not doing its job, so a queue that is not
  /// being saved never looks like one that is.
  let storageStatus: String?
  @State private var showsWebLogin = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("MacEase")
          .font(.headline)

        Label(sessionPresenceTitle, systemImage: sessionPresenceIcon)
          .foregroundStyle(
            session.storedSessionPresence == .stored ? .green : .secondary
          )

        Spacer()

        Button("Validate Session", systemImage: "checkmark.shield") {
          mutateSession(session.validateSession)
        }
        Button("Refresh Token · 1 request", systemImage: "arrow.triangle.2.circlepath") {
          mutateSession(session.refreshSession)
        }
        .help("Exchanges the stored session for a fresh one")
        Button("Sign Out · up to 2 requests", systemImage: "rectangle.portrait.and.arrow.right") {
          mutateSession(session.signOutEverywhere)
        }
        .help("Revokes the session on NetEase, then clears it here")
      }
      .padding(12)
      .disabled(arbiter.isBusy)

      Divider()

      NativeSignInView(
        session: session,
        arbiter: arbiter,
        mutate: mutateSession
      )

      Divider()

      DisclosureGroup("Other ways to sign in", isExpanded: $showsWebLogin) {
        VStack(spacing: 0) {
          HStack(spacing: 8) {
            Button("Open Login Page", systemImage: "safari") {
              session.loadLoginPage()
            }
            Button("Save Session From Page", systemImage: "key.fill") {
              mutateSession(session.saveSession)
            }
            Button("Clear Session", systemImage: "trash") {
              mutateSession(session.clearSession)
            }
            .help("Clears locally only; Sign Out also revokes on NetEase")
            Spacer()
          }
          .padding(.vertical, 8)
          .disabled(arbiter.isBusy)

          LoginWebView(webView: session.webView)
            .frame(minHeight: 320)

          HStack(spacing: 8) {
            SecureField("Cookie header", text: $session.manualCookieHeader)
            Button("Import Session", systemImage: "square.and.arrow.down") {
              mutateSession(session.importSession)
            }
            .disabled(arbiter.isBusy)
          }
          .padding(.vertical, 8)
        }
      }
      .padding(.horizontal, 12)

      Divider()

      Text(session.status)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)

      if let storageStatus {
        Label(storageStatus, systemImage: "externaldrive.badge.exclamationmark")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.bottom, 12)
      }
    }
  }

  private var sessionPresenceTitle: String {
    switch session.storedSessionPresence {
    case .unknown: "Session status unknown"
    case .absent: "Not signed in"
    case .stored: "Session stored"
    }
  }

  private var sessionPresenceIcon: String {
    switch session.storedSessionPresence {
    case .unknown: "questionmark.circle"
    case .absent: "person.crop.circle"
    case .stored: "checkmark.circle.fill"
    }
  }

  /// A session mutation only starts when the arbiter is free, so it can no
  /// longer cancel a write that has already reached the server. What happens
  /// to per-account local data follows from the account the operation left in
  /// effect, which `LoginCoordinator` reports once for every path — including
  /// a QR authorisation, which arrives long after this call has returned.
  private func mutateSession(
    _ operation: @escaping @MainActor () async -> SessionMutationResult
  ) {
    Task { _ = await operation() }
  }
}

private struct PlaylistLibraryView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  let discovery: DiscoveryCoordinator
  let playback: PlaybackController
  let arbiter: OperationArbiter
  let artwork: ArtworkLoader
  let downloads: DownloadCoordinator?
  @State private var newPlaylistName = ""
  @State private var newPlaylistIsPrivate = false
  @State private var submittedPlaylistName: String?
  @State private var renameText = ""
  @State private var playlistPendingDeletion: UserPlaylist?
  @State private var playlistPendingPublication: UserPlaylist?

  private var requestInFlight: Bool { library.isLoading || arbiter.isBusy }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      createRow

      Divider()

      if library.playlists.isEmpty && !library.isLoading {
        Text(library.status)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HSplitView {
          playlistList
          detailPane
        }
      }

      Divider()

      HStack {
        if library.isLoading {
          ProgressView()
            .controlSize(.small)
        }
        Text(library.status)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(12)
    }
    .onChange(of: library.selectedPlaylist?.id) {
      renameText = library.selectedPlaylist?.name ?? ""
    }
    .onChange(of: library.lastCreateReceipt?.id) {
      guard let receipt = library.lastCreateReceipt, receipt.succeeded,
        let submitted = submittedPlaylistName
      else { return }
      // Only clear what this action submitted: a late completion must not
      // wipe a name the user has since typed.
      if newPlaylistName == submitted {
        newPlaylistName = ""
      }
      submittedPlaylistName = nil
    }
    .confirmationDialog(
      playlistPendingDeletion.map { "Delete \($0.name)?" } ?? "Delete playlist?",
      isPresented: Binding(
        get: { playlistPendingDeletion != nil },
        set: { if !$0 { playlistPendingDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete · 1 request", role: .destructive) {
        if let playlist = playlistPendingDeletion {
          library.deletePlaylist(playlist, session: session)
        }
        playlistPendingDeletion = nil
      }
      Button("Cancel", role: .cancel) { playlistPendingDeletion = nil }
    } message: {
      Text("This permanently deletes the playlist from your NetEase account.")
    }
    .confirmationDialog(
      playlistPendingPublication.map { "Make \($0.name) public?" }
        ?? "Make playlist public?",
      isPresented: Binding(
        get: { playlistPendingPublication != nil },
        set: { if !$0 { playlistPendingPublication = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Make Public · 1 request", role: .destructive) {
        if let playlist = playlistPendingPublication {
          library.publishPlaylist(playlist, session: session)
        }
        playlistPendingPublication = nil
      }
      Button("Cancel", role: .cancel) { playlistPendingPublication = nil }
    } message: {
      Text(
        "This permanently makes the playlist public. MacEase cannot make it private again."
      )
    }
  }

  @ViewBuilder private var toolbar: some View {
    HStack {
      Text("Your Playlists")
        .font(.headline)
      Spacer()
      Button("Load Playlists · 1 request", systemImage: "arrow.clockwise") {
        library.load(reset: true, session: session)
      }
      .disabled(session.account == nil || requestInFlight)
      Button("Load Liked IDs · 1 request", systemImage: "heart") {
        library.loadLikedIDs(session: session)
      }
      .disabled(session.account == nil || requestInFlight)
      .help("Marks loaded track rows that are in your liked songs")
      if library.canLoadMore {
        Button("Load More · 1 request", systemImage: "plus") {
          library.load(reset: false, session: session)
        }
        .disabled(requestInFlight)
      } else if library.playlistsNeedReload {
        // The page cursor no longer names the same server position, so
        // continuing from it could skip or repeat rows.
        Label("Reload to page further", systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("A write changed your playlists; Load Playlists starts over")
      }
    }
    .padding(12)
  }

  @ViewBuilder private var createRow: some View {
    HStack {
      TextField("New playlist name", text: $newPlaylistName)
        .frame(maxWidth: 240)
      // Privacy is set when the playlist is created. That is the only
      // direction NetEase is known to accept, so it is the only one offered.
      Toggle("Private", isOn: $newPlaylistIsPrivate)
        .toggleStyle(.checkbox)
        .help("Creates the playlist private; only you can see it")
      Button("Create · 1 request", systemImage: "plus.rectangle.on.folder") {
        submittedPlaylistName = newPlaylistName
        library.createPlaylist(
          named: newPlaylistName,
          isPrivate: newPlaylistIsPrivate,
          session: session
        )
      }
      .disabled(
        session.account == nil || requestInFlight
          || newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      )
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 12)
  }

  @ViewBuilder private var playlistList: some View {
    List(
      library.playlists,
      id: \.id,
      selection: Binding(
        get: { library.selectedPlaylist?.id },
        set: { id in
          guard let playlist = library.playlists.first(where: { $0.id == id })
          else { return }
          library.loadTracks(for: playlist, session: session)
        }
      )
    ) { playlist in
      // Selection opens the playlist, so the row is not itself a button and
      // the trailing control is not nested inside one.
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(playlist.name)
          Text(
            "\(playlist.trackCount) tracks · "
              + (playlist.owned ? "Created" : "Saved")
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer()
        if playlist.owned {
          Button {
            playlistPendingDeletion = playlist
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .disabled(requestInFlight)
          .help("Delete playlist · 1 request")
          .accessibilityLabel("Delete \(playlist.name)")
        } else {
          Button {
            library.setSubscribed(
              false,
              playlistID: playlist.id,
              playlistName: playlist.name,
              session: session
            )
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .disabled(requestInFlight)
          .help("Unsubscribe from this saved playlist · 1 request")
          .accessibilityLabel("Unsubscribe from \(playlist.name)")
        }
      }
      .padding(.vertical, 3)
      .tag(playlist.id)
    }
    .frame(minWidth: 340)
  }

  @ViewBuilder private var detailPane: some View {
    VStack(spacing: 0) {
      if let playlist = library.selectedPlaylist {
        detailHeader(playlist)

        Divider()

        if library.tracks.isEmpty {
          Text(library.status)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          List(library.tracks, id: \.id) { track in
            trackRow(track)
          }
        }
      } else {
        Text(
          "Choose a playlist. The first batch uses one playlist-detail request "
            + "and, for a nonempty playlist, one song-detail request."
        )
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(minWidth: 340)
  }

  @ViewBuilder private func detailHeader(_ playlist: UserPlaylist) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(playlist.name)
          .font(.headline)
        Text("\(playlist.trackCount) tracks")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if playlist.owned {
        TextField("Rename", text: $renameText)
          .frame(maxWidth: 160)
        Button("Rename · 1 request") {
          library.renameSelectedPlaylist(to: renameText, session: session)
        }
        .disabled(
          requestInFlight
            || renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .help("Changes only the name; description and tags are untouched")
        if playlist.isPrivate == true {
          Button("Make Public · 1 request") {
            playlistPendingPublication = playlist
          }
          .disabled(requestInFlight)
          .help("Permanently publishes this private playlist")
        }
      }
      if library.canLoadMoreTracks {
        Button("Load More Tracks · 1 request", systemImage: "plus") {
          library.loadMoreTracks(session: session)
        }
        .disabled(requestInFlight)
      } else if library.tracksNeedReload {
        Label("Reload to page further", systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("A track was added; open the playlist again to page further")
      }
    }
    .padding(12)
  }

  @ViewBuilder private func trackRow(_ track: Track) -> some View {
    HStack {
      TrackRowLabel(track: track, loader: artwork)
      Spacer()
      LikeButton(
        track: track,
        library: library,
        session: session,
        disabled: requestInFlight
      )
      AddToPlaylistMenu(
        track: track,
        library: library,
        session: session,
        disabled: requestInFlight
      )
      DownloadTrackButton(
        track: track,
        quality: playback.quality,
        downloads: downloads,
        session: session,
        disabled: requestInFlight
      )
      if library.selectedPlaylist?.owned == true {
        Button {
          // Named by id: a list that changed cannot make this land on a
          // different row.
          library.removeSelectedPlaylistTrack(id: track.id, session: session)
        } label: {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .disabled(requestInFlight)
        .help("Remove from this playlist · 1 request")
        .accessibilityLabel("Remove \(track.name)")
      }
      PlayTrackButton(
        track: track,
        tracks: library.tracks,
        context: playbackContext,
        playback: playback,
        session: session
      )
      .help("Starts the queue from this track over the loaded list")
    }
    .padding(.vertical, 3)
  }

  /// The open playlist is what a restored queue names, so a relaunch can say
  /// what the user was listening to rather than just how many tracks it held.
  private var playbackContext: PlaybackContext {
    guard let playlist = library.selectedPlaylist else {
      return .dailyRecommendations
    }
    return .playlist(id: playlist.id, name: playlist.name)
  }
}

private struct PlayRecordsView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  @Bindable var discovery: DiscoveryCoordinator
  let playback: PlaybackController
  let scrobble: ScrobbleCoordinator
  let arbiter: OperationArbiter
  let artwork: ArtworkLoader

  private var requestInFlight: Bool { discovery.isLoading || arbiter.isBusy }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Listening Rankings")
          .font(.headline)
        Text(scrobble.status)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Picker("Scope", selection: $discovery.recordScope) {
          Text("All Time").tag(PlayRecordScope.allTime)
          Text("Last Week").tag(PlayRecordScope.lastWeek)
        }
        .fixedSize()
        .disabled(requestInFlight)
        Button("Load · 1 request", systemImage: "arrow.clockwise") {
          discovery.loadRecords(session: session)
        }
        .disabled(session.account == nil || requestInFlight)
      }
      .padding(12)

      Divider()

      if discovery.records.isEmpty {
        Text(discovery.status)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(Array(discovery.records.enumerated()), id: \.element.track.id) {
          rank, entry in
          HStack {
            Text("\(rank + 1)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .frame(width: 28, alignment: .trailing)
            TrackRowLabel(track: entry.track, loader: artwork)
            Spacer()
            Text("\(entry.playCount) plays")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            PlayTrackButton(
              track: entry.track,
              tracks: discovery.records.map(\.track),
              context: .listeningRankings,
              playback: playback,
              session: session
            )
          }
          .padding(.vertical, 3)
        }
      }
    }
  }
}

private struct PlaybackBarView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  let discovery: DiscoveryCoordinator
  @Bindable var playback: PlaybackController
  let arbiter: OperationArbiter
  let downloads: DownloadCoordinator?
  @State private var scrubPosition: Double?

  private var requestInFlight: Bool { arbiter.isBusy }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "music.note")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(playback.trackName ?? "Nothing playing")
            if let position = playback.queuePosition {
              Text(position)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Text(playback.status)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        if playback.phase == .playing || playback.phase == .paused {
          Text(timeString(scrubPosition ?? playback.positionSeconds))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
          if let duration = playback.durationSeconds {
            Slider(
              value: Binding(
                get: { min(scrubPosition ?? playback.positionSeconds, duration) },
                set: { scrubPosition = $0 }
              ),
              in: 0...duration
            ) { editing in
              if !editing {
                if let scrubPosition {
                  playback.seek(to: scrubPosition)
                }
                scrubPosition = nil
              }
            }
            .frame(width: 180)
            .help("Seek (local, no request)")
            Text(timeString(duration))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
        if let track = playback.currentTrack {
          DownloadTrackButton(
            track: track,
            quality: playback.quality,
            downloads: downloads,
            session: session,
            disabled: requestInFlight
          )
        }
        SystemRoutePicker()
          .frame(width: 28, height: 28)
          .help("Choose an AirPlay or system audio route")
        Picker("Quality", selection: $playback.quality) {
          ForEach(PlaybackQuality.allCases, id: \.self) { quality in
            Text(quality.rawValue).tag(quality)
          }
        }
        .fixedSize()
        .help("Applies to the next explicit Play")
        .disabled(arbiter.isBusy)
        if playback.canPlayAgain {
          Button(
            playback.retryResumesPlayback
              ? "Play Again" : "Restore Paused",
            systemImage: "arrow.counterclockwise"
          ) {
            playback.playAgain(session: session)
          }
          .disabled(session.account == nil)
          .help("Uses a matching download or resolves a fresh song URL")
        }
        if playback.isActive {
          Button("Stop", systemImage: "stop.fill") {
            playback.stop()
          }
        }
      }
      .padding(12)

      Divider()

      HStack(spacing: 10) {
        Button("Previous", systemImage: "backward.end.fill") {
          playback.playPrevious(session: session)
        }
        .disabled(!playback.canPlayPrevious(session: session))
        if playback.phase == .paused {
          Button("Resume", systemImage: "play.fill") {
            playback.resume()
          }
        } else {
          Button("Pause", systemImage: "pause.fill") {
            playback.pause()
          }
          .disabled(playback.phase != .playing)
        }
        Button("Next", systemImage: "forward.end.fill") {
          playback.playNext(session: session)
        }
        .disabled(!playback.canPlayNext(session: session))

        Picker("Mode", selection: $playback.playbackMode) {
          ForEach(PlaybackMode.allCases, id: \.self) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .fixedSize()
        .help(
          "Order after a track ends naturally; matching downloads play locally, "
            + "otherwise confirmed unavailability uses bounded downward quality recovery"
        )

        Spacer()

        Button {
          playback.isMuted.toggle()
        } label: {
          Image(
            systemName: playback.isMuted
              ? "speaker.slash.fill" : "speaker.wave.2.fill"
          )
        }
        .buttonStyle(.borderless)
        .help("Mute (local, no request)")
        Slider(value: $playback.volume, in: 0...1)
          .frame(width: 100)
          .help("Volume (local, no request)")

        Menu {
          ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
            Button("\(minutes) min") {
              playback.setSleepTimer(minutes: minutes)
            }
          }
          Button("Off") {
            playback.setSleepTimer(minutes: 0)
          }
          Divider()
          Toggle("Stop immediately at deadline", isOn: $playback.sleepStopsImmediately)
        } label: {
          Label(sleepLabel, systemImage: "moon.zzz")
        }
        .fixedSize()
        .help("Local timer; by default it lets the current track finish")
      }
      .padding(12)
    }
    // A drag session can outlive the slider when the track ends mid-drag;
    // stale scrub state would freeze the next track's displayed position.
    .onChange(of: playback.phase) {
      if playback.phase != .playing && playback.phase != .paused {
        scrubPosition = nil
      }
    }
  }

  private var sleepLabel: String {
    switch playback.sleepTimer {
    case .off:
      "Sleep Timer"
    case .armed(let deadline):
      "Sleep at " + deadline.formatted(date: .omitted, time: .shortened)
    case .finishingTrack:
      "Sleep after this track"
    }
  }

  private func timeString(_ seconds: Double) -> String {
    let total = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}

extension PlaybackMode {
  fileprivate var label: String {
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

private struct LoginWebView: NSViewRepresentable {
  let webView: WKWebView

  func makeNSView(context: Context) -> WKWebView {
    webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}
}

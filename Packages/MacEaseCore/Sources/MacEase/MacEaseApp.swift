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
    case discover
    case search
    case records
  }

  @State private var session: LoginCoordinator
  @State private var library: PlaylistLibraryCoordinator
  @State private var discovery: DiscoveryCoordinator
  @State private var playback: PlaybackController
  @State private var arbiter: OperationArbiter
  @State private var selectedTab: MainTab = .session

  init() {
    // One transport and one credential store for the whole app: every
    // coordinator shares them instead of constructing its own.
    let transport = NeteaseSession()
    let vault = CredentialVault()
    // One arbiter owns "a NetEase request is in flight" for the whole app.
    let arbiter = OperationArbiter()
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
    let playback = PlaybackController(
      transport: transport,
      vault: vault,
      arbiter: arbiter
    )
    playback.attach(session: login)
    _session = State(initialValue: login)
    _library = State(initialValue: library)
    _discovery = State(initialValue: discovery)
    _playback = State(initialValue: playback)
    _arbiter = State(initialValue: arbiter)
  }

  var body: some Scene {
    Window("MacEase", id: "main") {
      VStack(spacing: 0) {
        TabView(selection: $selectedTab) {
          SessionView(
            session: session,
            library: library,
            discovery: discovery,
            playback: playback,
            arbiter: arbiter
          )
          .tabItem { Label("Session", systemImage: "person.crop.circle") }
          .tag(MainTab.session)
          PlaylistLibraryView(
            session: session,
            library: library,
            discovery: discovery,
            playback: playback,
            arbiter: arbiter
          )
          .tabItem { Label("Library", systemImage: "music.note.list") }
          .tag(MainTab.library)
          DiscoverView(
            session: session,
            library: library,
            discovery: discovery,
            playback: playback,
            arbiter: arbiter,
            openPlaylist: { playlist in
              library.loadTracks(
                for: UserPlaylist(
                  id: playlist.id,
                  name: playlist.name,
                  trackCount: 0,
                  owned: false
                ),
                session: session
              )
              selectedTab = .library
            }
          )
          .tabItem { Label("Discover", systemImage: "sparkles") }
          .tag(MainTab.discover)
          SearchView(
            session: session,
            library: library,
            discovery: discovery,
            playback: playback,
            arbiter: arbiter
          )
          .tabItem { Label("Search", systemImage: "magnifyingglass") }
          .tag(MainTab.search)
          PlayRecordsView(
            session: session,
            library: library,
            discovery: discovery,
            playback: playback,
            arbiter: arbiter
          )
          .tabItem { Label("Records", systemImage: "chart.bar") }
          .tag(MainTab.records)
        }
        Divider()
        UnresolvedOutcomeBanner(arbiter: arbiter)
        PlaybackBarView(
          session: session,
          library: library,
          discovery: discovery,
          playback: playback,
          arbiter: arbiter
        )
      }
      .frame(minWidth: 760, minHeight: 600)
      .task {
        await session.start()
      }
    }
    .defaultSize(width: 980, height: 760)
  }
}

private struct SessionView: View {
  @Bindable var session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  let discovery: DiscoveryCoordinator
  let playback: PlaybackController
  let arbiter: OperationArbiter

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("MacEase")
          .font(.headline)

        Label(
          session.hasStoredSession ? "Session stored" : "Not signed in",
          systemImage: session.hasStoredSession ? "checkmark.circle.fill" : "person.crop.circle"
        )
        .foregroundStyle(session.hasStoredSession ? .green : .secondary)

        Spacer()

        Button("Open Login", systemImage: "arrow.clockwise") {
          session.loadLoginPage()
        }
        Button("Save Session", systemImage: "key.fill") {
          mutateSession(session.saveSession)
        }
        Button("Validate Session", systemImage: "checkmark.shield") {
          mutateSession(session.validateSession)
        }
        Button("Clear Session", systemImage: "trash") {
          mutateSession(session.clearSession)
        }
      }
      .padding(12)
      .disabled(arbiter.isBusy)

      Divider()

      LoginWebView(webView: session.webView)

      Divider()

      HStack(spacing: 8) {
        SecureField("Cookie header", text: $session.manualCookieHeader)
        Button("Import Session", systemImage: "square.and.arrow.down") {
          mutateSession(session.importSession)
        }
        .disabled(arbiter.isBusy)
      }
      .padding(12)

      Divider()

      Text(session.status)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
  }

  /// A session mutation only starts when the arbiter is free, so it can no
  /// longer cancel a write that has already reached the server. What happens
  /// to session-scoped data is decided from the typed result, never from the
  /// status text, and only after the operation has finished.
  private func mutateSession(
    _ operation: @escaping @MainActor () async -> SessionMutationResult
  ) {
    guard arbiter.canStart() else { return }
    Task {
      switch await operation() {
      case .unchangedValidated:
        // Same account: playback and everything loaded still belong to it.
        // Roadmap decision: one launch-scoped Discover prefetch after the
        // first successful validation; refreshes stay user-triggered.
        discovery.prefetch(session: session)
      case .credentialReplaced(let account):
        clearSessionScopedState()
        if account != nil {
          discovery.prefetch(session: session)
        }
      case .signedOut, .storedUnvalidated:
        clearSessionScopedState()
      case .rejected:
        // Nothing was established, so nothing confirmed is thrown away.
        break
      }
    }
  }

  private func clearSessionScopedState() {
    playback.stop()
    library.reset()
    discovery.reset()
  }
}

private struct PlaylistLibraryView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  let discovery: DiscoveryCoordinator
  let playback: PlaybackController
  let arbiter: OperationArbiter
  @State private var newPlaylistName = ""
  @State private var renameText = ""
  @State private var playlistPendingDeletion: UserPlaylist?

  private var requestInFlight: Bool { arbiter.isBusy }

  var body: some View {
    VStack(spacing: 0) {
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
        if library.hasMore {
          Button("Load More · 1 request", systemImage: "plus") {
            library.load(reset: false, session: session)
          }
          .disabled(requestInFlight)
        }
      }
      .padding(12)

      HStack {
        TextField("New playlist name", text: $newPlaylistName)
          .frame(maxWidth: 240)
        Button("Create · 1 request", systemImage: "plus.rectangle.on.folder") {
          library.createPlaylist(named: newPlaylistName, session: session)
          newPlaylistName = ""
        }
        .disabled(
          session.account == nil || requestInFlight
            || newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 12)

      Divider()

      if library.playlists.isEmpty && !library.isLoading {
        Text(library.status)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HSplitView {
          List(library.playlists, id: \.id) { playlist in
            Button {
              library.loadTracks(for: playlist, session: session)
            } label: {
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
                Text("Load Tracks · up to 2 requests")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                if playlist.owned {
                  Button {
                    playlistPendingDeletion = playlist
                  } label: {
                    Image(systemName: "trash")
                  }
                  .buttonStyle(.borderless)
                  .disabled(requestInFlight)
                  .help("Delete playlist · 1 request")
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
                }
              }
              .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .disabled(requestInFlight)
          }
          .frame(minWidth: 340)

          VStack(spacing: 0) {
            if let playlist = library.selectedPlaylist {
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
                    library.renameSelectedPlaylist(
                      to: renameText,
                      session: session
                    )
                  }
                  .disabled(
                    requestInFlight
                      || renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                  )
                  .help("Changes only the name; description and tags are untouched")
                }
                if library.hasMoreTracks {
                  Button("Load More Tracks · 1 request", systemImage: "plus") {
                    library.loadMoreTracks(session: session)
                  }
                  .disabled(requestInFlight)
                }
              }
              .padding(12)

              Divider()

              if library.tracks.isEmpty {
                Text(library.status)
                  .foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
              } else {
                List(library.tracks.indices, id: \.self) { index in
                  let track = library.tracks[index]
                  HStack {
                    VStack(alignment: .leading, spacing: 3) {
                      Text(track.name)
                      if !track.artists.isEmpty {
                        Text(track.artists.joined(separator: ", "))
                          .font(.caption)
                          .foregroundStyle(.secondary)
                      }
                    }
                    Spacer()
                    let isLiked = library.likedIDs?.contains(track.id) == true
                    Button {
                      library.setLiked(!isLiked, for: track, session: session)
                    } label: {
                      Image(systemName: isLiked ? "heart.fill" : "heart")
                        .foregroundStyle(isLiked ? .red : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.account == nil || requestInFlight)
                    .help(
                      isLiked
                        ? "Unlike · 1 request" : "Like · 1 request"
                    )
                    Menu {
                      ForEach(library.playlists.filter(\.owned), id: \.id) { target in
                        Button(target.name) {
                          library.addTrack(
                            track,
                            to: target,
                            session: session
                          )
                        }
                      }
                    } label: {
                      Image(systemName: "text.badge.plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(
                      requestInFlight || !library.playlists.contains(where: \.owned)
                    )
                    .help("Add to one of your playlists · 1 request")
                    if library.selectedPlaylist?.owned == true {
                      Button {
                        library.removeSelectedPlaylistTrack(
                          at: index,
                          session: session
                        )
                      } label: {
                        Image(systemName: "minus.circle")
                      }
                      .buttonStyle(.borderless)
                      .disabled(requestInFlight)
                      .help("Remove from this playlist · 1 request")
                    }
                    Button("Play · 1 request", systemImage: "play.fill") {
                      playback.play(
                        tracks: library.tracks,
                        startIndex: index,
                        session: session
                      )
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.account == nil || requestInFlight)
                    .help("Starts the queue from this track over the loaded list")
                  }
                  .padding(.vertical, 3)
                }
              }
            } else {
              Text(
                "Choose Load Tracks. The first batch uses one playlist-detail request "
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
  }
}

private struct DiscoverView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  let discovery: DiscoveryCoordinator
  let playback: PlaybackController
  let arbiter: OperationArbiter
  let openPlaylist: (DiscoveredPlaylist) -> Void

  private var requestInFlight: Bool { arbiter.isBusy }

  private var loadDisabled: Bool {
    session.account == nil || requestInFlight
  }

  var body: some View {
    VStack(spacing: 0) {
      List {
        Section {
          ForEach(discovery.dailySongs.indices, id: \.self) { index in
            let track = discovery.dailySongs[index]
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                if !track.artists.isEmpty {
                  Text(track.artists.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
              Button("Play · 1 request", systemImage: "play.fill") {
                playback.play(
                  tracks: discovery.dailySongs,
                  startIndex: index,
                  session: session
                )
              }
              .buttonStyle(.borderless)
              .disabled(loadDisabled)
            }
          }
        } header: {
          sectionHeader("Daily Songs") {
            discovery.loadDailySongs(session: session)
          }
        }

        Section {
          playlistRows(discovery.dailyPlaylists)
        } header: {
          sectionHeader("Daily Playlists") {
            discovery.loadDailyPlaylists(session: session)
          }
        }

        Section {
          playlistRows(discovery.personalized)
        } header: {
          sectionHeader("Recommended Playlists") {
            discovery.loadPersonalized(session: session)
          }
        }

        Section {
          playlistRows(discovery.toplists)
        } header: {
          sectionHeader("Toplists") {
            discovery.loadToplists(session: session)
          }
        }

        Section {
          ForEach(discovery.similarSongs.indices, id: \.self) { index in
            let track = discovery.similarSongs[index]
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                if !track.artists.isEmpty {
                  Text(track.artists.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
              Button("Play · 1 request", systemImage: "play.fill") {
                playback.play(
                  tracks: discovery.similarSongs,
                  startIndex: index,
                  session: session
                )
              }
              .buttonStyle(.borderless)
              .disabled(loadDisabled)
            }
          }
        } header: {
          HStack {
            Text(
              discovery.similarSeedName
                .map { "Similar to \($0)" } ?? "Similar Songs"
            )
            Spacer()
            Button("Load · 1 request", systemImage: "arrow.clockwise") {
              if let seed = playback.currentTrack {
                discovery.loadSimilarSongs(seed: seed, session: session)
              }
            }
            .buttonStyle(.borderless)
            .disabled(loadDisabled || playback.currentTrack == nil)
            .help("Uses the current queue track as the seed")
          }
        }
      }

      Divider()

      HStack {
        if discovery.isLoading {
          ProgressView()
            .controlSize(.small)
        }
        Text(discovery.status)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(12)
    }
  }

  private func sectionHeader(
    _ title: String,
    load: @escaping () -> Void
  ) -> some View {
    HStack {
      Text(title)
      Spacer()
      Button("Load · 1 request", systemImage: "arrow.clockwise", action: load)
        .buttonStyle(.borderless)
        .disabled(loadDisabled)
    }
  }

  private func playlistRows(_ playlists: [DiscoveredPlaylist]) -> some View {
    ForEach(playlists.indices, id: \.self) { index in
      let playlist = playlists[index]
      HStack {
        Text(playlist.name)
        Spacer()
        Button("Open · up to 2 requests", systemImage: "music.note.list") {
          openPlaylist(playlist)
        }
        .buttonStyle(.borderless)
        .disabled(loadDisabled)
        Button {
          library.setSubscribed(
            true,
            playlistID: playlist.id,
            playlistName: playlist.name,
            session: session
          )
        } label: {
          Image(systemName: "plus.circle")
        }
        .buttonStyle(.borderless)
        .disabled(loadDisabled)
        .help("Subscribe to this playlist · 1 request")
      }
    }
  }
}

private struct SearchView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  @Bindable var discovery: DiscoveryCoordinator
  let playback: PlaybackController
  let arbiter: OperationArbiter

  private var requestInFlight: Bool { arbiter.isBusy }

  private var searchDisabled: Bool {
    session.account == nil || requestInFlight
      || discovery.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("Search songs", text: $discovery.searchQuery)
          .onSubmit {
            if !searchDisabled { discovery.search(session: session) }
          }
        Button("Search · 1 request", systemImage: "magnifyingglass") {
          discovery.search(session: session)
        }
        .disabled(searchDisabled)
      }
      .padding(12)

      Divider()

      if discovery.searchResults.isEmpty {
        Text(discovery.status)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(discovery.searchResults.indices, id: \.self) { index in
          let track = discovery.searchResults[index]
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(track.name)
              if !track.artists.isEmpty {
                Text(track.artists.joined(separator: ", "))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Spacer()
            let isLiked = library.likedIDs?.contains(track.id) == true
            Button {
              library.setLiked(!isLiked, for: track, session: session)
            } label: {
              Image(systemName: isLiked ? "heart.fill" : "heart")
                .foregroundStyle(isLiked ? .red : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(session.account == nil || requestInFlight)
            .help(isLiked ? "Unlike · 1 request" : "Like · 1 request")
            Menu {
              ForEach(library.playlists.filter(\.owned), id: \.id) { target in
                Button(target.name) {
                  library.addTrack(track, to: target, session: session)
                }
              }
            } label: {
              Image(systemName: "text.badge.plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(
              requestInFlight || !library.playlists.contains(where: \.owned)
            )
            .help("Add to one of your playlists · 1 request")
            Button("Play · 1 request", systemImage: "play.fill") {
              playback.play(
                tracks: discovery.searchResults,
                startIndex: index,
                session: session
              )
            }
            .buttonStyle(.borderless)
            .disabled(session.account == nil || requestInFlight)
          }
          .padding(.vertical, 3)
        }
      }
    }
  }
}

private struct PlayRecordsView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  @Bindable var discovery: DiscoveryCoordinator
  let playback: PlaybackController
  let arbiter: OperationArbiter

  private var requestInFlight: Bool { arbiter.isBusy }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Listening Rankings")
          .font(.headline)
        Text("Server-side data only; MacEase playback is never scrobbled")
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
        List(discovery.records.indices, id: \.self) { index in
          let entry = discovery.records[index]
          HStack {
            Text("\(index + 1)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
              Text(entry.track.name)
              if !entry.track.artists.isEmpty {
                Text(entry.track.artists.joined(separator: ", "))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Spacer()
            Text("\(entry.playCount) plays")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            Button("Play · 1 request", systemImage: "play.fill") {
              playback.play(
                tracks: discovery.records.map(\.track),
                startIndex: index,
                session: session
              )
            }
            .buttonStyle(.borderless)
            .disabled(session.account == nil || requestInFlight)
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
  @State private var scrubPosition: Double?

  private var requestInFlight: Bool { arbiter.isBusy }

  private var stepDisabled: Bool {
    session.account == nil || requestInFlight
  }

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
        Picker("Quality", selection: $playback.quality) {
          ForEach(PlaybackQuality.allCases, id: \.self) { quality in
            Text(quality.rawValue).tag(quality)
          }
        }
        .fixedSize()
        .help("Applies to the next explicit Play")
        .disabled(arbiter.isBusy)
        if playback.canPlayAgain {
          Button("Play Again · 1 request", systemImage: "arrow.counterclockwise") {
            playback.playAgain(session: session)
          }
          .disabled(session.account == nil || requestInFlight)
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
        Button("Previous · 1 request", systemImage: "backward.end.fill") {
          playback.playPrevious(session: session)
        }
        .disabled(!playback.canStepPrevious || stepDisabled)
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
        Button("Next · 1 request", systemImage: "forward.end.fill") {
          playback.playNext(session: session)
        }
        .disabled(!playback.canStepNext || stepDisabled)

        Picker("Mode", selection: $playback.playbackMode) {
          ForEach(PlaybackMode.allCases, id: \.self) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .fixedSize()
        .help(
          "Order after a track ends naturally; each new track is 1 request, "
            + "repeat one is 0"
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
          "Outcome unknown for "
            + arbiter.unresolvedOutcomes.map(\.name).joined(separator: ", ")
            + ". The request reached the server but its result was lost; "
            + "reload the affected list to check before retrying."
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

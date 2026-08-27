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
    // One arbiter protects writes and destructive session mutations.
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
    // A divergence found by any coordinator invalidates the identity for all
    // of them, so the session owner clears everything, not just the reporter.
    login.onIdentityChanged = { [weak playback, weak library, weak discovery] in
      playback?.stop()
      library?.reset()
      discovery?.reset()
    }
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

        Label(sessionPresenceTitle, systemImage: sessionPresenceIcon)
          .foregroundStyle(
            session.storedSessionPresence == .stored ? .green : .secondary
          )

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
  /// to session-scoped data is decided from the typed result, never from the
  /// status text, and only after the operation has finished.
  private func mutateSession(
    _ operation: @escaping @MainActor () async -> SessionMutationResult
  ) {
    Task {
      switch await operation() {
      case .unchangedValidated:
        // Same account: playback and everything loaded still belong to it.
        // Roadmap decision: one launch-scoped Discover prefetch after the
        // first successful validation; refreshes stay user-triggered.
        discovery.prefetch(session: session)
      case .credentialReplaced(let account):
        if account != nil {
          discovery.prefetch(session: session)
        }
      case .signedOut, .storedUnvalidated, .storedPresenceUnknown:
        // LoginCoordinator committed the identity change and cleared all
        // session-scoped modules before releasing its operation lease.
        break
      case .rejected:
        // Nothing was established, so nothing confirmed is thrown away.
        break
      }
    }
  }
}

private struct PlaylistLibraryView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  let discovery: DiscoveryCoordinator
  let playback: PlaybackController
  let arbiter: OperationArbiter
  @State private var newPlaylistName = ""
  @State private var submittedPlaylistName: String?
  @State private var renameText = ""
  @State private var playlistPendingDeletion: UserPlaylist?

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
      Button("Create · 1 request", systemImage: "plus.rectangle.on.folder") {
        submittedPlaylistName = newPlaylistName
        library.createPlaylist(named: newPlaylistName, session: session)
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

  @ViewBuilder private func trackRow(_ track: PlaylistTrack) -> some View {
    HStack {
      TrackLabel(track: track)
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
        playback: playback,
        session: session,
        disabled: session.account == nil || requestInFlight
      )
      .help("Starts the queue from this track over the loaded list")
    }
    .padding(.vertical, 3)
  }
}

/// The heart is tri-state. "Not loaded yet" is shown as a distinct neutral
/// state and offers an explicit Like, rather than an empty heart whose toggle
/// would be guessing the starting value.
private struct LikeButton: View {
  let track: PlaylistTrack
  let library: PlaylistLibraryCoordinator
  let session: LoginCoordinator
  let disabled: Bool

  var body: some View {
    let state = library.liked.state(of: track.id)
    Button {
      library.setLiked(state != .liked, for: track, session: session)
    } label: {
      Image(systemName: state == .liked ? "heart.fill" : "heart")
        .foregroundStyle(state == .liked ? AnyShapeStyle(.red) : AnyShapeStyle(colour(for: state)))
    }
    .buttonStyle(.borderless)
    .disabled(session.account == nil || disabled)
    .help(help(for: state))
    .accessibilityLabel(accessibilityLabel(for: state))
  }

  private func colour(for state: LikedState) -> HierarchicalShapeStyle {
    state == .notLiked ? .secondary : .tertiary
  }

  private func help(for state: LikedState) -> String {
    switch state {
    case .liked: "Unlike · 1 request"
    case .notLiked: "Like · 1 request"
    case .unknown: "Liked state unknown; this likes the track · 1 request"
    }
  }

  private func accessibilityLabel(for state: LikedState) -> String {
    switch state {
    case .liked: "Liked, unlike \(track.name)"
    case .notLiked: "Not liked, like \(track.name)"
    case .unknown: "Liked state not loaded, like \(track.name)"
    }
  }
}

private struct TrackLabel: View {
  let track: PlaylistTrack

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(track.name)
      if !track.artists.isEmpty {
        Text(track.artists.joined(separator: ", "))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// Resolves the row's position at action time from the track id, so a list
/// that changed between render and click cannot start the wrong track.
private struct PlayTrackButton: View {
  let track: PlaylistTrack
  let tracks: [PlaylistTrack]
  let playback: PlaybackController
  let session: LoginCoordinator
  let disabled: Bool

  var body: some View {
    Button("Play · 1 request", systemImage: "play.fill") {
      guard let index = tracks.firstIndex(where: { $0.id == track.id }) else {
        return
      }
      playback.play(tracks: tracks, startIndex: index, session: session)
    }
    .buttonStyle(.borderless)
    .disabled(disabled)
    .accessibilityLabel("Play \(track.name)")
  }
}

/// Shared by the library and search rows so both add through the same path.
private struct AddToPlaylistMenu: View {
  let track: PlaylistTrack
  let library: PlaylistLibraryCoordinator
  let session: LoginCoordinator
  let disabled: Bool

  var body: some View {
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
    .disabled(disabled || !library.playlists.contains(where: \.owned))
    .help("Add to one of your playlists · 1 request")
    .accessibilityLabel("Add \(track.name) to a playlist")
  }
}

private struct DiscoverView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  let discovery: DiscoveryCoordinator
  let playback: PlaybackController
  let arbiter: OperationArbiter
  let openPlaylist: (DiscoveredPlaylist) -> Void

  private var requestInFlight: Bool { discovery.isLoading || arbiter.isBusy }

  private var loadDisabled: Bool {
    session.account == nil || requestInFlight
  }

  var body: some View {
    VStack(spacing: 0) {
      List {
        Section {
          ForEach(discovery.dailySongs, id: \.id) { track in
            HStack {
              TrackLabel(track: track)
              Spacer()
              PlayTrackButton(
                track: track,
                tracks: discovery.dailySongs,
                playback: playback,
                session: session,
                disabled: loadDisabled
              )
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
          ForEach(discovery.similarSongs, id: \.id) { track in
            HStack {
              TrackLabel(track: track)
              Spacer()
              PlayTrackButton(
                track: track,
                tracks: discovery.similarSongs,
                playback: playback,
                session: session,
                disabled: loadDisabled
              )
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
    ForEach(playlists, id: \.id) { playlist in
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

  private var requestInFlight: Bool { discovery.isLoading || arbiter.isBusy }

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
        List(discovery.searchResults, id: \.id) { track in
          HStack {
            TrackLabel(track: track)
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
            PlayTrackButton(
              track: track,
              tracks: discovery.searchResults,
              playback: playback,
              session: session,
              disabled: session.account == nil || requestInFlight
            )
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

  private var requestInFlight: Bool { discovery.isLoading || arbiter.isBusy }

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
        List(Array(discovery.records.enumerated()), id: \.element.track.id) {
          rank, entry in
          HStack {
            Text("\(rank + 1)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .frame(width: 28, alignment: .trailing)
            TrackLabel(track: entry.track)
            Spacer()
            Text("\(entry.playCount) plays")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            PlayTrackButton(
              track: entry.track,
              tracks: discovery.records.map(\.track),
              playback: playback,
              session: session,
              disabled: session.account == nil || requestInFlight
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
          Button(
            playback.retryResumesPlayback
              ? "Play Again · 1 request" : "Restore Paused · 1 request",
            systemImage: "arrow.counterclockwise"
          ) {
            playback.playAgain(session: session)
          }
          .disabled(session.account == nil || requestInFlight)
          .help("Re-resolves the song URL; the expired one is never reused")
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

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
    case records
  }

  @State private var session: LoginCoordinator
  @State private var library: PlaylistLibraryCoordinator
  @State private var discovery: DiscoveryCoordinator
  @State private var playback: PlaybackController
  @State private var selectedTab: MainTab = .session

  init() {
    let netease = NeteaseSession()
    let login = LoginCoordinator(session: netease)
    let library = PlaylistLibraryCoordinator(session: netease)
    let discovery = DiscoveryCoordinator(session: netease)
    let playback = PlaybackController(session: netease)
    playback.attach(loginCoordinator: login) {
      library.isLoading || discovery.isLoading
    }
    _session = State(initialValue: login)
    _library = State(initialValue: library)
    _discovery = State(initialValue: discovery)
    _playback = State(initialValue: playback)
  }

  var body: some Scene {
    Window("MacEase", id: "main") {
      VStack(spacing: 0) {
        TabView(selection: $selectedTab) {
          SessionView(
            session: session,
            library: library,
            discovery: discovery,
            playback: playback
          )
          .tabItem { Label("Session", systemImage: "person.crop.circle") }
          .tag(MainTab.session)
          PlaylistLibraryView(
            session: session,
            library: library,
            discovery: discovery,
            playback: playback
          )
          .tabItem { Label("Library", systemImage: "music.note.list") }
          .tag(MainTab.library)
          DiscoverView(
            session: session,
            library: library,
            discovery: discovery,
            playback: playback,
            openPlaylist: { playlist in
              library.loadTracks(
                for: UserPlaylist(
                  id: playlist.id,
                  name: playlist.name,
                  trackCount: 0,
                  owned: false
                ),
                loginCoordinator: session
              )
              selectedTab = .library
            }
          )
          .tabItem { Label("Discover", systemImage: "sparkles") }
          .tag(MainTab.discover)
          PlayRecordsView(
            session: session,
            library: library,
            discovery: discovery,
            playback: playback
          )
          .tabItem { Label("Records", systemImage: "chart.bar") }
          .tag(MainTab.records)
        }
        Divider()
        PlaybackBarView(
          session: session,
          library: library,
          discovery: discovery,
          playback: playback
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
      .disabled(session.isBusy)

      Divider()

      LoginWebView(webView: session.webView)

      Divider()

      HStack(spacing: 8) {
        SecureField("Cookie header", text: $session.manualCookieHeader)
        Button("Import Session", systemImage: "square.and.arrow.down") {
          mutateSession(session.importSession)
        }
        .disabled(session.isBusy)
      }
      .padding(12)

      Divider()

      Text(session.status)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
  }

  private func mutateSession(_ operation: @escaping @MainActor () async -> Void) {
    playback.stop()
    library.reset()
    discovery.reset()
    Task {
      await operation()
      // Roadmap decision: one launch-scoped Discover prefetch after the
      // first successful validation; refreshes stay user-triggered.
      discovery.prefetch(loginCoordinator: session)
    }
  }
}

private struct PlaylistLibraryView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  let discovery: DiscoveryCoordinator
  let playback: PlaybackController

  private var requestInFlight: Bool {
    session.isBusy || library.isLoading || discovery.isLoading
      || playback.isResolving
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Your Playlists")
          .font(.headline)
        Spacer()
        Button("Load Playlists · 1 request", systemImage: "arrow.clockwise") {
          library.load(reset: true, loginCoordinator: session)
        }
        .disabled(session.account == nil || requestInFlight)
        Button("Load Liked IDs · 1 request", systemImage: "heart") {
          library.loadLikedIDs(loginCoordinator: session)
        }
        .disabled(session.account == nil || requestInFlight)
        .help("Marks loaded track rows that are in your liked songs")
        if library.hasMore {
          Button("Load More · 1 request", systemImage: "plus") {
            library.load(reset: false, loginCoordinator: session)
          }
          .disabled(requestInFlight)
        }
      }
      .padding(12)

      Divider()

      if library.playlists.isEmpty && !library.isLoading {
        Text(library.status)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HSplitView {
          List(library.playlists, id: \.id) { playlist in
            Button {
              library.loadTracks(for: playlist, loginCoordinator: session)
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
                if library.hasMoreTracks {
                  Button("Load More Tracks · 1 request", systemImage: "plus") {
                    library.loadMoreTracks(loginCoordinator: session)
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
                      HStack(spacing: 5) {
                        Text(track.name)
                        if library.likedIDs?.contains(track.id) == true {
                          Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .help("In your liked songs")
                        }
                      }
                      if !track.artists.isEmpty {
                        Text(track.artists.joined(separator: ", "))
                          .font(.caption)
                          .foregroundStyle(.secondary)
                      }
                    }
                    Spacer()
                    Button("Play · 1 request", systemImage: "play.fill") {
                      playback.play(
                        tracks: library.tracks,
                        startIndex: index,
                        loginCoordinator: session
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
  }
}

private struct DiscoverView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  let discovery: DiscoveryCoordinator
  let playback: PlaybackController
  let openPlaylist: (DiscoveredPlaylist) -> Void

  private var requestInFlight: Bool {
    session.isBusy || library.isLoading || discovery.isLoading
      || playback.isResolving
  }

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
                  loginCoordinator: session
                )
              }
              .buttonStyle(.borderless)
              .disabled(loadDisabled)
            }
          }
        } header: {
          sectionHeader("Daily Songs") {
            discovery.loadDailySongs(loginCoordinator: session)
          }
        }

        Section {
          playlistRows(discovery.dailyPlaylists)
        } header: {
          sectionHeader("Daily Playlists") {
            discovery.loadDailyPlaylists(loginCoordinator: session)
          }
        }

        Section {
          playlistRows(discovery.personalized)
        } header: {
          sectionHeader("Recommended Playlists") {
            discovery.loadPersonalized(loginCoordinator: session)
          }
        }

        Section {
          playlistRows(discovery.toplists)
        } header: {
          sectionHeader("Toplists") {
            discovery.loadToplists(loginCoordinator: session)
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
      }
    }
  }
}

private struct PlayRecordsView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  @Bindable var discovery: DiscoveryCoordinator
  let playback: PlaybackController

  private var requestInFlight: Bool {
    session.isBusy || library.isLoading || discovery.isLoading
      || playback.isResolving
  }

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
          discovery.loadRecords(loginCoordinator: session)
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
                loginCoordinator: session
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
  @State private var scrubPosition: Double?

  private var requestInFlight: Bool {
    session.isBusy || library.isLoading || discovery.isLoading
      || playback.isResolving
  }

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
        .disabled(playback.isResolving)
        if playback.canPlayAgain {
          Button("Play Again · 1 request", systemImage: "arrow.counterclockwise") {
            playback.playAgain(loginCoordinator: session)
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
          playback.playPrevious(loginCoordinator: session)
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
          playback.playNext(loginCoordinator: session)
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

private struct LoginWebView: NSViewRepresentable {
  let webView: WKWebView

  func makeNSView(context: Context) -> WKWebView {
    webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}
}

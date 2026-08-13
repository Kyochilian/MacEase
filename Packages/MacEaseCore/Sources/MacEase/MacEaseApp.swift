import MacEaseSession
import NeteaseKit
import SwiftUI
import WebKit

@main
@MainActor
struct MacEaseApp: App {
  @State private var session: LoginCoordinator
  @State private var library: PlaylistLibraryCoordinator
  @State private var playback: PlaybackController

  init() {
    let netease = NeteaseSession()
    _session = State(initialValue: LoginCoordinator(session: netease))
    _library = State(initialValue: PlaylistLibraryCoordinator(session: netease))
    _playback = State(initialValue: PlaybackController(session: netease))
  }

  var body: some Scene {
    Window("MacEase", id: "main") {
      VStack(spacing: 0) {
        TabView {
          SessionView(session: session, library: library, playback: playback)
            .tabItem { Label("Session", systemImage: "person.crop.circle") }
          PlaylistLibraryView(session: session, library: library, playback: playback)
            .tabItem { Label("Library", systemImage: "music.note.list") }
        }
        Divider()
        PlaybackBarView(session: session, library: library, playback: playback)
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
    Task { await operation() }
  }
}

private struct PlaylistLibraryView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  let playback: PlaybackController

  private var requestInFlight: Bool {
    session.isBusy || library.isLoading || playback.isResolving
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
                        trackID: track.id,
                        name: track.name,
                        loginCoordinator: session
                      )
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.account == nil || requestInFlight)
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

private struct PlaybackBarView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator
  @Bindable var playback: PlaybackController

  private var requestInFlight: Bool {
    session.isBusy || library.isLoading || playback.isResolving
  }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "music.note")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(playback.trackName ?? "Nothing playing")
        Text(playback.status)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if playback.phase == .playing {
        Text(timeString(playback.positionSeconds))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
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
  }

  private func timeString(_ seconds: Double) -> String {
    let total = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}

private struct LoginWebView: NSViewRepresentable {
  let webView: WKWebView

  func makeNSView(context: Context) -> WKWebView {
    webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}
}

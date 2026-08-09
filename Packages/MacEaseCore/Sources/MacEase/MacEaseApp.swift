import MacEaseSession
import SwiftUI
import WebKit

@main
@MainActor
struct MacEaseApp: App {
  @State private var session = LoginCoordinator()
  @State private var library = PlaylistLibraryCoordinator()

  var body: some Scene {
    Window("MacEase", id: "main") {
      TabView {
        SessionView(session: session, library: library)
          .tabItem { Label("Session", systemImage: "person.crop.circle") }
        PlaylistLibraryView(session: session, library: library)
          .tabItem { Label("Library", systemImage: "music.note.list") }
      }
      .frame(minWidth: 760, minHeight: 560)
      .task {
        await session.start()
      }
    }
    .defaultSize(width: 980, height: 720)
  }
}

private struct SessionView: View {
  @Bindable var session: LoginCoordinator
  let library: PlaylistLibraryCoordinator

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
          library.reset()
          Task { await session.saveSession() }
        }
        Button("Validate Session", systemImage: "checkmark.shield") {
          library.reset()
          Task { await session.validateSession() }
        }
        Button("Clear Session", systemImage: "trash") {
          library.reset()
          Task { await session.clearSession() }
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
          library.reset()
          Task { await session.importSession() }
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
}

private struct PlaylistLibraryView: View {
  let session: LoginCoordinator
  let library: PlaylistLibraryCoordinator

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Your Playlists")
          .font(.headline)
        Spacer()
        Button("Load Playlists", systemImage: "arrow.clockwise") {
          library.load(reset: true, loginCoordinator: session)
        }
        .disabled(session.account == nil || session.isBusy || library.isLoading)
        if library.hasMore {
          Button("Load More", systemImage: "plus") {
            library.load(reset: false, loginCoordinator: session)
          }
          .disabled(session.isBusy || library.isLoading)
        }
      }
      .padding(12)

      Divider()

      if library.playlists.isEmpty && !library.isLoading {
        Text(library.status)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(library.playlists, id: \.id) { playlist in
          VStack(alignment: .leading, spacing: 3) {
            Text(playlist.name)
            Text(
              "\(playlist.trackCount) tracks · "
                + (playlist.owned ? "Created" : "Saved")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .padding(.vertical, 3)
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

private struct LoginWebView: NSViewRepresentable {
  let webView: WKWebView

  func makeNSView(context: Context) -> WKWebView {
    webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}
}

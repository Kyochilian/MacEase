import SwiftUI
import WebKit

@main
@MainActor
struct GateBLoginHarnessApp: App {
  @State private var coordinator = LoginCoordinator()
  @State private var probes = SandboxProbeCoordinator()

  var body: some Scene {
    Window("MacEase Phase 0 / Gate B", id: "login") {
      LoginHarnessView(coordinator: coordinator, probes: probes)
        .task {
          await coordinator.start()
        }
    }
    .defaultSize(width: 960, height: 720)
  }
}

private struct LoginHarnessView: View {
  let coordinator: LoginCoordinator
  let probes: SandboxProbeCoordinator

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button("Open Login") {
          coordinator.loadLoginPage()
        }
        Button("Save Session") {
          Task { await coordinator.saveSession() }
        }
        Button("Validate Session") {
          Task { await coordinator.validateSession() }
        }
        Button("Clear Session") {
          Task { await coordinator.clearSession() }
        }

        Spacer()

        Text(coordinator.hasStoredSession ? "Stored" : "Not stored")
          .foregroundStyle(coordinator.hasStoredSession ? .green : .secondary)
      }
      .padding(12)
      .disabled(coordinator.isBusy)

      Divider()

      LoginWebView(webView: coordinator.webView)

      Divider()

      Text(coordinator.status)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(probes.sandboxStatus)
          Spacer()
          Button("Probe AVPlayer") {
            Task { await probes.probeAVPlayer() }
          }
          Button("Stop AVPlayer") {
            probes.stopAVPlayer()
          }
          Button("Probe CoreAudio") {
            probes.probeCoreAudio()
          }
          Button("Stop CoreAudio") {
            probes.stopCoreAudio()
          }
          Button("Probe Bookmark") {
            probes.probeBookmark()
          }
        }
        Text(probes.audioStatus)
        Text(probes.coreAudioStatus)
        Text(probes.bookmarkStatus)
      }
      .padding(12)
    }
    .frame(minWidth: 760, minHeight: 560)
    .onDisappear {
      probes.stopAVPlayer()
      probes.stopCoreAudio()
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

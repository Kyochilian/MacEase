import AppKit
import NeteaseKit
import SwiftUI
import WebKit

@main
@MainActor
struct GateBLoginHarnessApp: App {
  @State private var coordinator = LoginCoordinator()
  @State private var playback = PlaybackProbeCoordinator()
  @State private var probes = SandboxProbeCoordinator()

  var body: some Scene {
    Window("MacEase Gate B / Gate C Harness", id: "login") {
      LoginHarnessView(
        coordinator: coordinator,
        playback: playback,
        probes: probes
      )
        .task {
          await coordinator.start()
        }
    }
    .defaultSize(width: 960, height: 780)
  }
}

private struct LoginHarnessView: View {
  @Bindable var coordinator: LoginCoordinator
  @Bindable var playback: PlaybackProbeCoordinator
  let probes: SandboxProbeCoordinator

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 8) {
        HStack {
          Button("Open Login") {
            coordinator.loadLoginPage()
          }
          Button("Save Session") {
            Task { await coordinator.saveSession() }
          }
          Button("Validate Session") {
            Task {
              await coordinator.validateSession()
              if !coordinator.hasStoredSession {
                playback.stop()
              }
            }
          }
          Button("Clear Session") {
            playback.stop()
            Task { await coordinator.clearSession() }
          }

          Spacer()

          Text(coordinator.hasStoredSession ? "Stored" : "Not stored")
            .foregroundStyle(coordinator.hasStoredSession ? .green : .secondary)
        }

        HStack {
          SecureField(
            "MUSIC_U=…; __csrf=…",
            text: $coordinator.manualCookieHeader
          )
          Button("Import Session") {
            Task { await coordinator.importSession() }
          }
        }
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
          TextField("Song ID", text: $playback.songID)
            .frame(width: 140)
          Picker("Quality", selection: $playback.quality) {
            ForEach(PlaybackQuality.allCases, id: \.self) { quality in
              Text(quality.rawValue).tag(quality)
            }
          }
          .frame(width: 120)
          Button("Play eapi Song") {
            playback.play(loginCoordinator: coordinator)
          }
          Button("Probe eapi CDN") {
            playback.probeCDN(loginCoordinator: coordinator)
          }
          Button("Stop eapi Song") {
            playback.stop()
          }
        }
        HStack {
          TextField("Seek seconds", text: $playback.seekPosition)
            .frame(width: 140)
          Button("Seek") {
            playback.seek()
          }
          Button("Refresh Current URL") {
            playback.refreshCurrentAsset(loginCoordinator: coordinator)
          }
        }
        Text(playback.status)
      }
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
      playback.stop()
      probes.stopAVPlayer()
      probes.stopCoreAudio()
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.willSleepNotification
      )
    ) { _ in
      playback.handleSleep()
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.didWakeNotification
      )
    ) { _ in
      playback.handleWake()
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

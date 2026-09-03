import MacEaseAppCore
import SwiftUI

/// Settings and maintenance.
///
/// No control here issues a NetEase request. The update section delegates its
/// one explicit network action to the app's single Sparkle controller.
struct SettingsView: View {
  @Bindable var settings: AppSettings
  @Bindable var nativeNotifications: NativeNotificationCoordinator
  @Bindable var updater: AppUpdater
  let artwork: ArtworkLoader
  let audioRanges: AudioRangePipeline?
  let downloads: DownloadCoordinator?
  @State private var imageCacheBytes: Int?
  @State private var audioCacheBytes: Int64?
  @State private var audioCacheStatus: String?
  @State private var confirmsClearDownloads = false

  var body: some View {
    Form {
      Section("Appearance") {
        Picker("Theme", selection: $settings.theme) {
          ForEach(ThemePreference.allCases, id: \.self) { theme in
            Text(theme.label).tag(theme)
          }
        }
        .pickerStyle(.segmented)
      }

      Section("Lyrics") {
        Toggle("Show translations under each line", isOn: $settings.showsLyricTranslation)
          .help("Applies to the lyrics panel; it never changes what is requested")
        Toggle("Highlight timed words", isOn: $settings.usesVerbatimLyrics)
          .help("Uses YRC timing when available and otherwise keeps line highlighting")
        Toggle("Show romanisation above each line", isOn: $settings.showsLyricRomanisation)
      }

      Section("Updates") {
        Toggle(
          "Automatically check for updates",
          isOn: $updater.automaticallyChecksForUpdates
        )
        .disabled(!updater.isConfigured)
        Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") {
          updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
        Text(updater.status)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Notifications") {
        Toggle(
          "Native notifications",
          isOn: Binding(
            get: { nativeNotifications.isEnabled },
            set: { enabled in
              Task { await nativeNotifications.setEnabled(enabled) }
            }
          )
        )
        Toggle(
          "Now Playing",
          isOn: Binding(
            get: { nativeNotifications.playbackIsEnabled },
            set: { nativeNotifications.setPlaybackEnabled($0) }
          )
        )
        .disabled(!nativeNotifications.isEnabled)
        Toggle(
          "Download results",
          isOn: Binding(
            get: { nativeNotifications.downloadsAreEnabled },
            set: { nativeNotifications.setDownloadsEnabled($0) }
          )
        )
        .disabled(!nativeNotifications.isEnabled)
        LabeledContent(
          "System permission",
          value: nativeNotifications.authorizationStatus.description
        )
        if nativeNotifications.authorizationStatus == .denied {
          Text(
            "Notifications are denied. Open System Settings, choose "
              + "Notifications, then select MacEase to change access."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          Text(nativeNotifications.status)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section("About") {
        LabeledContent("Version", value: Self.versionDescription)
      }

      Section("Artwork cache") {
        LabeledContent("On disk") {
          Text(imageCacheBytes.map { ByteFormat.short(Int64($0)) } ?? "—")
            .monospacedDigit()
        }
        Picker("Limit", selection: $settings.imageCacheLimitBytes) {
          ForEach(Self.cacheLimits, id: \.self) { limit in
            Text(ByteFormat.short(limit)).tag(limit)
          }
        }
        HStack {
          Button("Clear artwork cache", systemImage: "trash") {
            Task {
              artwork.clear()
              await refresh()
            }
          }
          Spacer()
          Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await refresh() }
          }
            .buttonStyle(.borderless)
        }
      }

      Section("Temporary audio cache") {
        LabeledContent("On disk") {
          Text(
            audioRanges == nil
              ? "Unavailable"
              : audioCacheBytes.map(ByteFormat.short) ?? "—"
          )
            .monospacedDigit()
        }
        Picker("Limit", selection: $settings.audioCacheLimitBytes) {
          ForEach(Self.audioCacheLimits, id: \.self) { limit in
            Text(ByteFormat.short(limit)).tag(limit)
          }
        }
        .disabled(audioRanges == nil)
        HStack {
          Button("Clear temporary audio cache", systemImage: "trash") {
            Task {
              do {
                audioCacheBytes = try await audioRanges?.clear()
                audioCacheStatus = nil
              } catch {
                audioCacheStatus = "Temporary cache could not be cleared"
              }
            }
          }
          .disabled(audioRanges == nil)
          .help("Keeps bytes pinned by the track currently playing")
          Spacer()
          Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await refresh() }
          }
          .buttonStyle(.borderless)
          .disabled(audioRanges == nil)
        }
        if let message = audioCacheStatus
          ?? (audioRanges == nil ? "Temporary audio cache unavailable" : nil)
        {
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section("Offline downloads") {
        LabeledContent("Current account") {
          Text(downloads.map { ByteFormat.short($0.totalBytes) } ?? "Unavailable")
            .monospacedDigit()
        }
        HStack {
          Button(
            "Delete all offline downloads",
            systemImage: "trash",
            role: .destructive
          ) {
            confirmsClearDownloads = true
          }
          .disabled(
            downloads == nil || downloads?.downloads.isEmpty != false
              || downloads?.isDownloading == true
              || downloads?.isMaintaining == true
          )
          .help("Deletes persistent files only for the signed-in account")
          Spacer()
        }
        if let downloads {
          Text(downloads.lastFailure ?? downloads.status)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section {
        Text(
          "Cache maintenance stays on this Mac. Update checks use only the "
            + "configured Sparkle appcast; clearing caches does not delete downloads."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task {
      await refresh()
      await nativeNotifications.refreshAuthorizationStatus()
    }
    .onChange(of: settings.imageCacheLimitBytes) {
      artwork.setDiskCapacity(Int(settings.imageCacheLimitBytes))
      Task { await refresh() }
    }
    .onChange(of: settings.audioCacheLimitBytes) {
      Task {
        guard let audioRanges else {
          audioCacheStatus = "Temporary audio cache unavailable"
          return
        }
        do {
          try await audioRanges.setLimitBytes(settings.audioCacheLimitBytes)
          audioCacheStatus = nil
        } catch {
          audioCacheStatus = "Temporary cache limit could not be applied"
        }
        await refresh()
      }
    }
    .confirmationDialog(
      "Delete all offline downloads for this account?",
      isPresented: $confirmsClearDownloads,
      titleVisibility: .visible
    ) {
      Button("Delete All Downloads", role: .destructive) {
        downloads?.clearAll()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Temporary audio cache data is not affected.")
    }
  }

  private static let cacheLimits: [Int64] = [
    64 * 1024 * 1024,
    256 * 1024 * 1024,
    512 * 1024 * 1024,
    1024 * 1024 * 1024,
  ]

  private static let audioCacheLimits: [Int64] = [
    512 * 1024 * 1024,
    1024 * 1024 * 1024,
    2 * 1024 * 1024 * 1024,
    4 * 1024 * 1024 * 1024,
  ]

  private static var versionDescription: String {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "Development"
    guard let build = info["CFBundleVersion"] as? String else { return version }
    return "\(version) (\(build))"
  }

  private func refresh() async {
    imageCacheBytes = artwork.diskUsageBytes
    audioCacheBytes = await audioRanges?.diskUsageBytes()
  }
}

extension ThemePreference {
  /// nil means "whatever the system is set to", which is what SwiftUI's
  /// `preferredColorScheme` takes for the same meaning.
  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

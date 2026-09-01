import MacEaseAppCore
import SwiftUI

/// Settings and maintenance.
///
/// Everything here is local: nothing on this page issues a NetEase request, so
/// the cache figures are what is on this disk and the theme is what this app
/// asks the system for.
struct SettingsView: View {
  @Bindable var settings: AppSettings
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
          "Nothing on this page sends a request. Temporary audio ranges are "
            + "recreated as needed; clearing them does not delete offline downloads."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task { await refresh() }
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

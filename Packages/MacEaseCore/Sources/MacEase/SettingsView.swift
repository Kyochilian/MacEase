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
  @State private var imageCacheBytes: Int?

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
              refresh()
            }
          }
          Spacer()
          Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
            .buttonStyle(.borderless)
        }
      }

      Section {
        Text(
          "Nothing on this page sends a request. Clearing the cache only "
            + "deletes files MacEase downloaded to this machine."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task { refresh() }
    .onChange(of: settings.imageCacheLimitBytes) {
      artwork.setDiskCapacity(Int(settings.imageCacheLimitBytes))
      refresh()
    }
  }

  private static let cacheLimits: [Int64] = [
    64 * 1024 * 1024,
    256 * 1024 * 1024,
    512 * 1024 * 1024,
    1024 * 1024 * 1024,
  ]

  private func refresh() {
    imageCacheBytes = artwork.diskUsageBytes
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

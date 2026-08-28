import Foundation
import Observation

/// Which appearance the app asks the system for.
package enum ThemePreference: String, CaseIterable, Sendable {
  case system
  case light
  case dark

  package var label: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

/// App-wide preferences.
///
/// These are preferences about the app rather than data about an account, so
/// they live in `UserDefaults` next to the playback volume that was already
/// stored there, not in the per-account database. Signing out changes what
/// MacEase may show; it does not mean the user wanted a different theme.
///
/// Every value is validated on read: `UserDefaults` is shared, writable
/// storage, so a stored string that is no longer a case of the enum falls back
/// to the default rather than trapping.
@MainActor
@Observable
package final class AppSettings {
  private enum Key {
    static let theme = "settings.theme"
    static let lyricTranslation = "settings.lyrics.showsTranslation"
    static let imageCacheLimitBytes = "settings.images.diskLimitBytes"
    static let audioCacheLimitBytes = "settings.audio.diskLimitBytes"
  }

  /// Defaults chosen to be useful without being surprising: artwork is small
  /// and re-fetched constantly, so it gets a modest cache; audio is large, so
  /// its cache is bounded well below what a music library would occupy.
  package static let defaultImageCacheLimitBytes: Int64 = 256 * 1024 * 1024
  package static let defaultAudioCacheLimitBytes: Int64 = 2 * 1024 * 1024 * 1024

  @ObservationIgnored private let defaults: UserDefaults

  package init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    theme =
      ThemePreference(rawValue: defaults.string(forKey: Key.theme) ?? "")
      ?? .system
    // `object(forKey:)` distinguishes "never set" from "set to false", which
    // `bool(forKey:)` cannot; the translation default is on.
    showsLyricTranslation =
      defaults.object(forKey: Key.lyricTranslation) as? Bool ?? true
    imageCacheLimitBytes = Self.storedLimit(
      defaults,
      key: Key.imageCacheLimitBytes,
      fallback: Self.defaultImageCacheLimitBytes
    )
    audioCacheLimitBytes = Self.storedLimit(
      defaults,
      key: Key.audioCacheLimitBytes,
      fallback: Self.defaultAudioCacheLimitBytes
    )
  }

  package var theme: ThemePreference {
    didSet { defaults.set(theme.rawValue, forKey: Key.theme) }
  }

  package var showsLyricTranslation: Bool {
    didSet { defaults.set(showsLyricTranslation, forKey: Key.lyricTranslation) }
  }

  package var imageCacheLimitBytes: Int64 {
    didSet {
      imageCacheLimitBytes = max(0, imageCacheLimitBytes)
      defaults.set(imageCacheLimitBytes, forKey: Key.imageCacheLimitBytes)
    }
  }

  package var audioCacheLimitBytes: Int64 {
    didSet {
      audioCacheLimitBytes = max(0, audioCacheLimitBytes)
      defaults.set(audioCacheLimitBytes, forKey: Key.audioCacheLimitBytes)
    }
  }

  /// A negative or absent stored limit is not a limit. Clamping here keeps
  /// every caller from having to defend against it.
  private static func storedLimit(
    _ defaults: UserDefaults,
    key: String,
    fallback: Int64
  ) -> Int64 {
    guard let stored = defaults.object(forKey: key) as? Int64, stored >= 0 else {
      return fallback
    }
    return stored
  }
}

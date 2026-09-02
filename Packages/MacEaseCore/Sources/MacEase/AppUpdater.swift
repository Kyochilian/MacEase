import Foundation
import Observation
import Sparkle

/// The two release-time values without which an updater must not start.
struct SparkleConfiguration: Equatable {
  let feedURL: URL
  let publicEDKey: String

  enum Failure: Error, Equatable {
    case missingFeedURL
    case invalidFeedURL
    case missingPublicKey
    case invalidPublicKey
    case installerServiceDisabled

    var diagnostic: String {
      switch self {
      case .missingFeedURL: "Updates are disabled: this build has no appcast URL"
      case .invalidFeedURL: "Updates are disabled: this build has an invalid appcast URL"
      case .missingPublicKey: "Updates are disabled: this build has no Sparkle public key"
      case .invalidPublicKey: "Updates are disabled: this build has an invalid Sparkle public key"
      case .installerServiceDisabled:
        "Updates are disabled: the sandboxed installer service is not enabled"
      }
    }
  }

  static func parse(_ info: [String: Any]) -> Result<Self, Failure> {
    guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty else {
      return .failure(.missingFeedURL)
    }
    guard
      let feedURL = URL(string: feed),
      feedURL.scheme?.lowercased() == "https",
      feedURL.host != nil,
      feedURL.user == nil,
      feedURL.password == nil,
      feedURL.query == nil,
      feedURL.fragment == nil
    else { return .failure(.invalidFeedURL) }

    guard let publicKey = info["SUPublicEDKey"] as? String, !publicKey.isEmpty else {
      return .failure(.missingPublicKey)
    }
    guard Data(base64Encoded: publicKey)?.count == 32 else {
      return .failure(.invalidPublicKey)
    }
    guard info["SUEnableInstallerLauncherService"] as? Bool == true else {
      return .failure(.installerServiceDisabled)
    }
    return .success(Self(feedURL: feedURL, publicEDKey: publicKey))
  }
}

/// The app's single Sparkle state source.
///
/// `SPUUpdater` persists its automatic-check preference itself. Keeping that
/// value here as a projection avoids a second UserDefaults key disagreeing
/// with Sparkle on the next launch.
@MainActor
@Observable
final class AppUpdater {
  private(set) var isConfigured = false
  private(set) var canCheckForUpdates = false
  private(set) var status: String

  var automaticallyChecksForUpdates = false {
    didSet {
      guard let updater = controller?.updater else { return }
      guard updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else {
        return
      }
      updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
      status = automaticallyChecksForUpdates
        ? "Automatic update checks are enabled"
        : "Automatic update checks are disabled"
    }
  }

  @ObservationIgnored private var controller: SPUStandardUpdaterController?
  @ObservationIgnored private var capabilityObservation: NSKeyValueObservation?
  @ObservationIgnored private var automaticCheckObservation: NSKeyValueObservation?

  init(
    infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
    startsUpdater: Bool = true
  ) {
    switch SparkleConfiguration.parse(infoDictionary) {
    case .failure(let failure):
      status = failure.diagnostic
    case .success:
      #if DEBUG
        // Unit tests can construct an unstarted controller to exercise
        // Sparkle's preference, but the development app never starts one or
        // exposes a manual network action even if a local plist is populated.
        guard !startsUpdater else {
          status = "Updates are disabled in development builds"
          return
        }
      #endif
      let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
      )
      self.controller = controller
      isConfigured = true
      automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
      status = "Updates are configured"
      if startsUpdater { controller.startUpdater() }
      canCheckForUpdates = controller.updater.canCheckForUpdates
      capabilityObservation = controller.updater.observe(
        \.canCheckForUpdates,
        options: [.new]
      ) { [weak self] _, change in
        guard let value = change.newValue else { return }
        Task { @MainActor [weak self] in self?.canCheckForUpdates = value }
      }
      automaticCheckObservation = controller.updater.observe(
        \.automaticallyChecksForUpdates,
        options: [.new]
      ) { [weak self] _, change in
        guard let value = change.newValue else { return }
        Task { @MainActor [weak self] in self?.automaticallyChecksForUpdates = value }
      }
    }
  }

  @discardableResult
  func checkForUpdates() -> Bool {
    guard let controller else { return false }
    guard controller.updater.canCheckForUpdates else {
      status = "An update check is already in progress"
      return false
    }
    status = "Checking for updates"
    controller.checkForUpdates(nil)
    return true
  }
}

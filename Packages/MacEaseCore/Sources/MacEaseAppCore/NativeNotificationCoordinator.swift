import Foundation
import NeteaseKit
import Observation

package enum NativeNotificationAuthorizationStatus: Equatable, Sendable {
  case notDetermined
  case denied
  case authorized
  case provisional
  case ephemeral
  case unknown

  package var permitsDelivery: Bool {
    switch self {
    case .authorized, .provisional, .ephemeral: true
    case .notDetermined, .denied, .unknown: false
    }
  }

  package var description: String {
    switch self {
    case .notDetermined: "Not requested"
    case .denied: "Denied in System Settings"
    case .authorized: "Authorized"
    case .provisional: "Provisional"
    case .ephemeral: "Temporary authorization"
    case .unknown: "Unavailable"
    }
  }
}

package struct NativeNotificationArtwork: Equatable, Sendable {
  package let data: Data
  package let filenameExtension: String

  package init(data: Data, filenameExtension: String) {
    self.data = data
    self.filenameExtension = filenameExtension
  }
}

package struct NativeNotificationRequest: Equatable, Sendable {
  package let identifier: UUID
  package let title: String
  package let body: String
  package let artwork: NativeNotificationArtwork?

  package init(
    identifier: UUID,
    title: String,
    body: String,
    artwork: NativeNotificationArtwork? = nil
  ) {
    self.identifier = identifier
    self.title = title
    self.body = body
    self.artwork = artwork
  }
}

/// The only seams around UserNotifications. The concrete implementation lives
/// in the app target; tests never reach the process notification center.
@MainActor
package protocol NativeNotificationCenterIO: AnyObject {
  func authorizationStatus() async -> NativeNotificationAuthorizationStatus
  func requestAuthorization() async throws
  func add(_ request: NativeNotificationRequest) async throws
  /// Removes only a request whose add may have crossed an account-generation
  /// boundary; unrelated notifications must survive that cleanup.
  func remove(identifier: UUID)
  func removeAllPendingAndDelivered()
}

@MainActor
package protocol ApplicationActivityReading: AnyObject {
  var isApplicationActive: Bool { get }
}

package typealias CachedNotificationArtworkProvider =
  @MainActor @Sendable (URL) async -> NativeNotificationArtwork?

/// Owns native-notification permission state, product preferences and event
/// deduplication. It consumes the playback lifecycle and foreground-download
/// terminal boundaries directly; it never infers work from a SwiftUI phase.
@MainActor
@Observable
package final class NativeNotificationCoordinator {
  private enum DeliveryKind {
    case playback
    case download
  }

  @ObservationIgnored private let settings: AppSettings
  @ObservationIgnored private let center: any NativeNotificationCenterIO
  @ObservationIgnored private let activity: any ApplicationActivityReading
  @ObservationIgnored private let cachedArtwork: CachedNotificationArtworkProvider
  @ObservationIgnored private var accountID: Int64?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var deliveredPlaybackLifecycles: Set<UUID> = []
  @ObservationIgnored private var deliveredDownloadTasks: Set<UUID> = []
  @ObservationIgnored private var deliveryTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var authorizationRequestIsInFlight = false

  package private(set) var authorizationStatus:
    NativeNotificationAuthorizationStatus = .unknown
  package private(set) var status = "Notification permission has not been checked"

  package init(
    settings: AppSettings,
    center: any NativeNotificationCenterIO,
    activity: any ApplicationActivityReading,
    cachedArtwork: @escaping CachedNotificationArtworkProvider = { _ in nil }
  ) {
    self.settings = settings
    self.center = center
    self.activity = activity
    self.cachedArtwork = cachedArtwork
  }

  package var isEnabled: Bool { settings.nativeNotificationsEnabled }
  package var playbackIsEnabled: Bool { settings.playbackNotificationsEnabled }
  package var downloadsAreEnabled: Bool { settings.downloadNotificationsEnabled }
  package var effectivePlaybackIsEnabled: Bool {
    isEnabled && playbackIsEnabled && authorizationStatus.permitsDelivery
  }
  package var effectiveDownloadsAreEnabled: Bool {
    isEnabled && downloadsAreEnabled && authorizationStatus.permitsDelivery
  }

  /// Safe to call at launch and whenever the app becomes active: this only
  /// reads settings and never asks the system to show a prompt.
  package func refreshAuthorizationStatus() async {
    let current = await center.authorizationStatus()
    authorizationStatus = current
    status = "System permission: \(current.description)"
  }

  /// The one permission-request path. Repeated rendering and activation only
  /// refresh; a prompt is possible solely on an explicit off-to-on user action.
  package func setEnabled(_ enabled: Bool) async {
    settings.nativeNotificationsEnabled = enabled
    guard enabled else {
      cancelDeliveriesAndRemoveNotifications()
      status = "Native notifications are off"
      return
    }

    await refreshAuthorizationStatus()
    guard isEnabled,
      authorizationStatus == .notDetermined,
      !authorizationRequestIsInFlight
    else { return }
    authorizationRequestIsInFlight = true
    defer { authorizationRequestIsInFlight = false }
    do {
      try await center.requestAuthorization()
      await refreshAuthorizationStatus()
    } catch {
      status = "Notification permission could not be requested"
    }
  }

  package func setPlaybackEnabled(_ enabled: Bool) {
    settings.playbackNotificationsEnabled = enabled
  }

  package func setDownloadsEnabled(_ enabled: Bool) {
    settings.downloadNotificationsEnabled = enabled
  }

  /// Binding is synchronous with an account commit. It invalidates old cover
  /// work before a callback from the replacement account can be accepted.
  package func bind(accountID: Int64?) {
    guard self.accountID != accountID else { return }
    cancelAccountEvents()
    self.accountID = accountID
  }

  package func reset() {
    cancelAccountEvents()
    accountID = nil
  }

  package func settleForTesting() async {
    let tasks = Array(deliveryTasks.values)
    for task in tasks { await task.value }
  }

  package func handle(_ event: PlaybackLifecycleEvent) {
    guard case .started(let instance) = event else { return }
    guard deliveredPlaybackLifecycles.insert(instance.id).inserted else { return }
    guard accountID == instance.accountID,
      effectivePlaybackIsEnabled,
      !activity.isApplicationActive
    else { return }

    let artist = instance.track.artistDisplayName ?? "Unknown Artist"
    deliver(
      identifier: instance.id,
      kind: .playback,
      title: "Now Playing",
      body: "\(instance.track.name) — \(artist)",
      artworkURL: instance.track.artworkURL,
      accountID: instance.accountID,
      requiresInactiveApplication: true
    )
  }

  package func handle(_ event: DownloadTerminalEvent) {
    guard deliveredDownloadTasks.insert(event.taskID).inserted else { return }
    guard accountID == event.accountID, effectiveDownloadsAreEnabled else { return }

    let title: String
    let body: String
    switch event.outcome {
    case .succeeded:
      title = "Download Complete"
      let artist = event.track.artistDisplayName ?? "Unknown Artist"
      body = "\(event.track.name) — \(artist)"
    case .failed(let failure):
      title = "Download Failed"
      body = "\(event.track.name): \(failure.message)"
    }
    deliver(
      identifier: event.taskID,
      kind: .download,
      title: title,
      body: body,
      artworkURL: nil,
      accountID: event.accountID,
      requiresInactiveApplication: false
    )
  }

  private func deliver(
    identifier deliveryID: UUID,
    kind: DeliveryKind,
    title: String,
    body: String,
    artworkURL: URL?,
    accountID: Int64,
    requiresInactiveApplication: Bool
  ) {
    let generation = generation
    deliveryTasks[deliveryID] = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.generation == generation {
          self.deliveryTasks[deliveryID] = nil
        }
      }
      let artwork: NativeNotificationArtwork? = if let artworkURL {
        await self.cachedArtwork(artworkURL)
      } else {
        nil
      }
      guard !Task.isCancelled,
        self.generation == generation,
        self.accountID == accountID,
        self.isEnabled(kind),
        !requiresInactiveApplication || !self.activity.isApplicationActive
      else { return }
      do {
        try await self.center.add(
          NativeNotificationRequest(
            identifier: deliveryID,
            title: title,
            body: body,
            artwork: artwork
          )
        )
        guard !Task.isCancelled,
          self.generation == generation,
          self.accountID == accountID,
          self.isEnabled(kind),
          !requiresInactiveApplication || !self.activity.isApplicationActive
        else {
          // `UNUserNotificationCenter.add` may already have crossed into the
          // system when cancellation arrives. A second cleanup closes that
          // narrow race after the await as well as before it.
          self.center.remove(identifier: deliveryID)
          return
        }
      } catch {
        guard self.generation == generation else { return }
        self.status = "A native notification could not be delivered"
      }
    }
  }

  private func isEnabled(_ kind: DeliveryKind) -> Bool {
    switch kind {
    case .playback: effectivePlaybackIsEnabled
    case .download: effectiveDownloadsAreEnabled
    }
  }

  private func cancelAccountEvents() {
    cancelDeliveriesAndRemoveNotifications()
    deliveredPlaybackLifecycles = []
    deliveredDownloadTasks = []
  }

  private func cancelDeliveriesAndRemoveNotifications() {
    generation &+= 1
    for task in deliveryTasks.values { task.cancel() }
    deliveryTasks = [:]
    center.removeAllPendingAndDelivered()
  }
}

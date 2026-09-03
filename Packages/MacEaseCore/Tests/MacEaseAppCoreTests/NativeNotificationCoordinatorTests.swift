import Foundation
import Testing

@testable import MacEaseAppCore
@testable import NeteaseKit

@MainActor
private final class FakeNativeNotificationCenter: NativeNotificationCenterIO {
  enum Failure: Error { case expected }

  var currentStatus: NativeNotificationAuthorizationStatus
  var authorizationResult = true
  var requestFails = false
  var addFails = false
  var addGate: RequestGate?
  private(set) var statusReads = 0
  private(set) var authorizationRequests = 0
  private(set) var requests: [NativeNotificationRequest] = []
  private(set) var removals = 0

  init(status: NativeNotificationAuthorizationStatus = .notDetermined) {
    currentStatus = status
  }

  func authorizationStatus() async -> NativeNotificationAuthorizationStatus {
    statusReads += 1
    return currentStatus
  }

  func requestAuthorization() async throws {
    authorizationRequests += 1
    if requestFails { throw Failure.expected }
    currentStatus = authorizationResult ? .authorized : .denied
  }

  func add(_ request: NativeNotificationRequest) async throws {
    // Consume the gate before the first suspension. This lets a test hold an
    // old-generation add while a replacement account queues its own request.
    if let addGate {
      self.addGate = nil
      await addGate.pass()
    }
    if addFails { throw Failure.expected }
    requests.append(request)
  }

  func remove(identifier: UUID) {
    removals += 1
    requests.removeAll { $0.identifier == identifier }
  }

  func removeAllPendingAndDelivered() {
    removals += 1
    requests = []
  }
}

@MainActor
private final class FakeApplicationActivity: ApplicationActivityReading {
  var isApplicationActive: Bool
  init(active: Bool = false) { isApplicationActive = active }
}

@MainActor
private struct NotificationRig {
  let suiteName = "macease.notifications.tests.\(UUID().uuidString)"
  let defaults: UserDefaults
  let settings: AppSettings
  let center: FakeNativeNotificationCenter
  let activity: FakeApplicationActivity
  let coordinator: NativeNotificationCoordinator

  init(
    status: NativeNotificationAuthorizationStatus = .authorized,
    active: Bool = false,
    artwork: @escaping CachedNotificationArtworkProvider = { _ in nil }
  ) {
    defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    settings = AppSettings(defaults: defaults)
    center = FakeNativeNotificationCenter(status: status)
    activity = FakeApplicationActivity(active: active)
    coordinator = NativeNotificationCoordinator(
      settings: settings,
      center: center,
      activity: activity,
      cachedArtwork: artwork
    )
  }

  func enable(accountID: Int64 = testAccount.userID) async {
    settings.nativeNotificationsEnabled = true
    await coordinator.refreshAuthorizationStatus()
    coordinator.bind(accountID: accountID)
  }

  func cleanup() {
    coordinator.reset()
    defaults.removePersistentDomain(forName: suiteName)
  }
}

private func lifecycle(
  id: UUID = UUID(),
  accountID: Int64 = testAccount.userID,
  trackID: Int64 = 1
) -> PlaybackLifecycleInstance {
  PlaybackLifecycleInstance(
    id: id,
    accountID: accountID,
    track: makeTracks([trackID])[0],
    context: .dailyRecommendations
  )
}

@Test @MainActor func firstLaunchDoesNotReadOrRequestNotificationPermission() {
  let rig = NotificationRig(status: .notDetermined)
  defer { rig.cleanup() }

  #expect(!rig.settings.nativeNotificationsEnabled)
  #expect(rig.settings.playbackNotificationsEnabled)
  #expect(rig.settings.downloadNotificationsEnabled)
  #expect(rig.center.statusReads == 0)
  #expect(rig.center.authorizationRequests == 0)
  #expect(rig.center.requests.isEmpty)
}

@Test @MainActor func launchRefreshReadsPermissionWithoutRequestingIt() async {
  let rig = NotificationRig(status: .notDetermined)
  defer { rig.cleanup() }

  await rig.coordinator.refreshAuthorizationStatus()

  #expect(rig.center.statusReads == 1)
  #expect(rig.center.authorizationRequests == 0)
  #expect(rig.coordinator.authorizationStatus == .notDetermined)
}

@Test @MainActor func explicitEnableRequestsUndeterminedPermissionOnlyOnce() async {
  let rig = NotificationRig(status: .notDetermined)
  defer { rig.cleanup() }

  await rig.coordinator.setEnabled(true)
  await rig.coordinator.setEnabled(true)

  #expect(rig.center.authorizationRequests == 1)
  #expect(rig.coordinator.authorizationStatus == .authorized)
  #expect(rig.coordinator.effectivePlaybackIsEnabled)
  #expect(rig.coordinator.effectiveDownloadsAreEnabled)
}

@Test @MainActor func deniedPermissionIsNeverRequestedAgainByRefreshOrEnable() async {
  let rig = NotificationRig(status: .denied)
  defer { rig.cleanup() }

  await rig.coordinator.setEnabled(true)
  await rig.coordinator.refreshAuthorizationStatus()
  await rig.coordinator.setEnabled(true)

  #expect(rig.center.authorizationRequests == 0)
  #expect(!rig.coordinator.effectivePlaybackIsEnabled)
  #expect(rig.coordinator.authorizationStatus == .denied)
}

@Test @MainActor func aRejectedPermissionRequestIsNotRepeated() async {
  let rig = NotificationRig(status: .notDetermined)
  defer { rig.cleanup() }
  rig.center.authorizationResult = false

  await rig.coordinator.setEnabled(true)
  await rig.coordinator.setEnabled(true)

  #expect(rig.center.authorizationRequests == 1)
  #expect(rig.coordinator.authorizationStatus == .denied)
  #expect(!rig.coordinator.effectivePlaybackIsEnabled)
  #expect(!rig.coordinator.effectiveDownloadsAreEnabled)
}

@Test(arguments: [
  NativeNotificationAuthorizationStatus.authorized,
  .provisional,
  .ephemeral,
])
@MainActor
func systemGrantedStatusesPermitDelivery(
  status: NativeNotificationAuthorizationStatus
) async {
  let rig = NotificationRig(status: status)
  defer { rig.cleanup() }

  await rig.enable()

  #expect(rig.coordinator.effectivePlaybackIsEnabled)
  #expect(rig.coordinator.effectiveDownloadsAreEnabled)
}

@Test @MainActor func anUnknownFuturePermissionStatusFailsClosed() async {
  let rig = NotificationRig(status: .unknown)
  defer { rig.cleanup() }

  await rig.enable()
  rig.coordinator.handle(.started(lifecycle()))
  await rig.coordinator.settleForTesting()

  #expect(!rig.coordinator.effectivePlaybackIsEnabled)
  #expect(!rig.coordinator.effectiveDownloadsAreEnabled)
  #expect(rig.center.requests.isEmpty)
  #expect(rig.center.authorizationRequests == 0)
}

@Test @MainActor func activationRefreshesAChangedSystemPermission() async {
  let rig = NotificationRig(status: .denied)
  defer { rig.cleanup() }
  await rig.coordinator.refreshAuthorizationStatus()
  rig.center.currentStatus = .authorized

  await rig.coordinator.refreshAuthorizationStatus()

  #expect(rig.center.statusReads == 2)
  #expect(rig.coordinator.authorizationStatus == .authorized)
  #expect(rig.center.authorizationRequests == 0)
}

@Test @MainActor func aPlaybackLifecycleNotifiesOnceOnlyWhileBackgrounded() async {
  let rig = NotificationRig()
  defer { rig.cleanup() }
  await rig.enable()
  let instance = lifecycle()

  rig.coordinator.handle(.started(instance))
  rig.coordinator.handle(.started(instance))
  rig.coordinator.handle(.finished(instance, playedSeconds: 12))
  await rig.coordinator.settleForTesting()

  let request = rig.center.requests.first
  #expect(rig.center.requests.count == 1)
  #expect(request?.title == "Now Playing")
  #expect(request?.body.contains(instance.track.name) == true)
  #expect(request?.body.contains("artist") == true)

  rig.activity.isApplicationActive = true
  rig.coordinator.handle(.started(lifecycle(trackID: 2)))
  await rig.coordinator.settleForTesting()
  #expect(rig.center.requests.count == 1)
}

@Test @MainActor func preparePauseResumeAndSeekDoNotDuplicatePlaybackNotification() async {
  let rig = NotificationRig()
  defer { rig.cleanup() }
  await rig.enable()
  let credential = makeCredential()
  let transport = FakeTransport()
  let vault = FakeVault(stored: credential)
  let session = FakeSession(credential: credential)
  let output = FakeAudioOutput()
  output.automaticallyReportsPlaying = false
  let playback = PlaybackController(
    transport: transport,
    vault: vault,
    arbiter: OperationArbiter(),
    output: output
  )
  playback.attach(session: session)
  playback.onLifecycleEvent = { rig.coordinator.handle($0) }
  await transport.setSongURL(.success(makeResolvedAsset(songID: 1)))

  playback.play(
    tracks: makeTracks([1]),
    startIndex: 0,
    context: .dailyRecommendations,
    session: session
  )
  await playback.settleForTesting()
  await rig.coordinator.settleForTesting()
  #expect(rig.center.requests.isEmpty)

  output.reportPlaybackState(.playing)
  await rig.coordinator.settleForTesting()
  #expect(rig.center.requests.count == 1)

  #expect(playback.seek(to: 40))
  output.reportPlaybackState(.notPlaying)
  output.reportPlaybackState(.playing)
  #expect(playback.pause())
  #expect(playback.resume())
  await rig.coordinator.settleForTesting()

  #expect(rig.center.requests.count == 1)
}

@Test @MainActor func repeatOneMayNotifyForDistinctLifecyclesOfTheSameSong() async {
  let rig = NotificationRig()
  defer { rig.cleanup() }
  await rig.enable()

  rig.coordinator.handle(.started(lifecycle(trackID: 7)))
  rig.coordinator.handle(.started(lifecycle(trackID: 7)))
  await rig.coordinator.settleForTesting()

  #expect(rig.center.requests.count == 2)
  #expect(Set(rig.center.requests.map(\.identifier)).count == 2)
}

@Test @MainActor func downloadTerminalsNotifyOnceAndCancellationHasNoEvent() async {
  let rig = NotificationRig(active: true)
  defer { rig.cleanup() }
  await rig.enable()
  let track = makeTracks([8])[0]
  let successID = UUID()
  let failureID = UUID()

  let success = DownloadTerminalEvent(
    taskID: successID,
    accountID: testAccount.userID,
    track: track,
    outcome: .succeeded
  )
  let failure = DownloadTerminalEvent(
    taskID: failureID,
    accountID: testAccount.userID,
    track: track,
    outcome: .failed(.connection)
  )
  rig.coordinator.handle(success)
  rig.coordinator.handle(success)
  rig.coordinator.handle(failure)
  rig.coordinator.handle(failure)
  await rig.coordinator.settleForTesting()

  #expect(rig.center.requests.count == 2)
  #expect(rig.center.requests.map(\.title).contains("Download Complete"))
  #expect(rig.center.requests.map(\.title).contains("Download Failed"))
  let failureBody = rig.center.requests.first { $0.title == "Download Failed" }?.body
  #expect(failureBody?.contains("HTTP") == false)
  #expect(failureBody?.contains("URL") == false)
  #expect(failureBody?.contains(String(testAccount.userID)) == false)
}

@Test @MainActor func accountResetDropsLateArtworkAndClearsSystemNotifications() async {
  let gate = RequestGate()
  await gate.close()
  let rig = NotificationRig { _ in
    await gate.pass()
    return NativeNotificationArtwork(data: Data([1, 2, 3]), filenameExtension: "jpg")
  }
  defer { rig.cleanup() }
  await rig.enable()

  rig.coordinator.handle(.started(lifecycle()))
  while await gate.arrivalCount() == 0 { await Task.yield() }
  rig.coordinator.reset()
  rig.coordinator.bind(accountID: otherAccount.userID)
  await gate.open()
  for _ in 0..<10 { await Task.yield() }

  #expect(rig.center.requests.isEmpty)
  #expect(rig.center.removals >= 2)
}

@Test @MainActor func accountResetAlsoCleansAnAddAlreadyCrossingTheSystemSeam() async {
  let rig = NotificationRig()
  defer { rig.cleanup() }
  await rig.enable()
  let gate = RequestGate()
  await gate.close()
  rig.center.addGate = gate
  let initialRemovals = rig.center.removals

  rig.coordinator.handle(.started(lifecycle()))
  while await gate.arrivalCount() == 0 { await Task.yield() }
  rig.coordinator.reset()
  rig.coordinator.bind(accountID: otherAccount.userID)
  await gate.open()
  while rig.center.removals < initialRemovals + 3 { await Task.yield() }

  #expect(rig.center.requests.isEmpty)
}

@Test @MainActor func staleCleanupCannotRemoveAReplacementAccountsNotification() async {
  let rig = NotificationRig()
  defer { rig.cleanup() }
  await rig.enable()

  let oldGate = RequestGate()
  await oldGate.close()
  rig.center.addGate = oldGate
  let oldID = UUID()
  rig.coordinator.handle(.started(lifecycle(id: oldID)))
  while await oldGate.arrivalCount() == 0 { await Task.yield() }

  rig.coordinator.reset()
  rig.coordinator.bind(accountID: otherAccount.userID)
  let replacementID = UUID()
  rig.coordinator.handle(
    .started(lifecycle(id: replacementID, accountID: otherAccount.userID))
  )
  while rig.center.requests.first?.identifier != replacementID {
    await Task.yield()
  }

  await oldGate.open()
  await rig.coordinator.settleForTesting()

  #expect(rig.center.requests.map(\.identifier) == [replacementID])
}

@Test @MainActor func staleAccountEventsAndDisabledKindsAreIgnored() async {
  let rig = NotificationRig()
  defer { rig.cleanup() }
  await rig.enable(accountID: otherAccount.userID)

  rig.coordinator.handle(.started(lifecycle(accountID: testAccount.userID)))
  rig.coordinator.setPlaybackEnabled(false)
  rig.coordinator.handle(.started(lifecycle(accountID: otherAccount.userID)))
  rig.coordinator.setDownloadsEnabled(false)
  rig.coordinator.handle(
    DownloadTerminalEvent(
      taskID: UUID(),
      accountID: otherAccount.userID,
      track: makeTracks([3])[0],
      outcome: .succeeded
    )
  )
  await rig.coordinator.settleForTesting()

  #expect(rig.center.requests.isEmpty)
}

@Test @MainActor func notificationCenterFailureDoesNotEscapeTheCoordinator() async {
  let rig = NotificationRig()
  defer { rig.cleanup() }
  await rig.enable()
  rig.center.addFails = true

  rig.coordinator.handle(.started(lifecycle()))
  await rig.coordinator.settleForTesting()

  #expect(rig.center.requests.isEmpty)
  #expect(rig.coordinator.status == "A native notification could not be delivered")
}

@Test @MainActor func notificationPreferencesPersistSeparatelyFromPermission() {
  let suiteName = "macease.notifications.preferences.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName) ?? .standard
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.removePersistentDomain(forName: suiteName)
  let first = AppSettings(defaults: defaults)
  first.nativeNotificationsEnabled = true
  first.playbackNotificationsEnabled = false
  first.downloadNotificationsEnabled = false

  let restored = AppSettings(defaults: defaults)

  #expect(restored.nativeNotificationsEnabled)
  #expect(!restored.playbackNotificationsEnabled)
  #expect(!restored.downloadNotificationsEnabled)
}

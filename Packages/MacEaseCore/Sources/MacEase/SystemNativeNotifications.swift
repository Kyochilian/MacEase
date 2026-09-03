import AppKit
import Foundation
import MacEaseAppCore
@preconcurrency import UserNotifications

@MainActor
final class SystemNativeNotificationCenter: NSObject, NativeNotificationCenterIO,
  UNUserNotificationCenterDelegate
{
  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
    super.init()
    center.delegate = self
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list]
  }

  func authorizationStatus() async -> NativeNotificationAuthorizationStatus {
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .notDetermined: return .notDetermined
    case .denied: return .denied
    case .authorized: return .authorized
    case .provisional: return .provisional
    case .ephemeral: return .ephemeral
    @unknown default: return .unknown
    }
  }

  func requestAuthorization() async throws {
    _ = try await center.requestAuthorization(options: [.alert])
  }

  func add(_ request: NativeNotificationRequest) async throws {
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.body

    var temporaryArtworkURL: URL?
    if let artwork = request.artwork,
      let fileExtension = Self.safeExtension(artwork.filenameExtension)
    {
      let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(fileExtension)
      do {
        try artwork.data.write(to: fileURL, options: .atomic)
        let attachment = try UNNotificationAttachment(
          identifier: UUID().uuidString,
          url: fileURL
        )
        content.attachments = [attachment]
        temporaryArtworkURL = fileURL
      } catch {
        // The text notification remains useful when attachment validation or
        // temporary-file creation fails.
        try? FileManager.default.removeItem(at: fileURL)
      }
    }
    defer {
      if let temporaryArtworkURL {
        try? FileManager.default.removeItem(at: temporaryArtworkURL)
      }
    }

    try Task.checkCancellation()
    try await center.add(
      UNNotificationRequest(
        identifier: request.identifier.uuidString,
        content: content,
        trigger: nil
      )
    )
  }

  func remove(identifier: UUID) {
    let value = identifier.uuidString
    center.removePendingNotificationRequests(withIdentifiers: [value])
    center.removeDeliveredNotifications(withIdentifiers: [value])
  }

  func removeAllPendingAndDelivered() {
    center.removeAllPendingNotificationRequests()
    center.removeAllDeliveredNotifications()
  }

  private static func safeExtension(_ value: String) -> String? {
    let value = value.lowercased()
    guard (1...5).contains(value.count),
      value.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    else { return nil }
    return value
  }
}

@MainActor
final class MacApplicationActivity: ApplicationActivityReading {
  var isApplicationActive: Bool { NSApplication.shared.isActive }
}

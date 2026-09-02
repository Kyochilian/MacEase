import Foundation
import Testing

@testable import MacEase

private func validUpdateInfo() -> [String: Any] {
  [
    "SUFeedURL": "https://updates.example.test/appcast.xml",
    "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
    "SUEnableInstallerLauncherService": true,
  ]
}

@Test func sparkleConfigurationFailsClosedForEveryMissingOrUnsafeInput() {
  #expect(SparkleConfiguration.parse([:]) == .failure(.missingFeedURL))
  #expect(
    SparkleConfiguration.parse([
      "SUFeedURL": "http://updates.example.test/appcast.xml"
    ]) == .failure(.invalidFeedURL)
  )
  #expect(
    SparkleConfiguration.parse([
      "SUFeedURL": "https://token@updates.example.test/appcast.xml"
    ]) == .failure(.invalidFeedURL)
  )
  #expect(
    SparkleConfiguration.parse([
      "SUFeedURL": "https://updates.example.test/appcast.xml?channel=preview"
    ]) == .failure(.invalidFeedURL)
  )
  #expect(
    SparkleConfiguration.parse([
      "SUFeedURL": "https://updates.example.test/appcast.xml"
    ]) == .failure(.missingPublicKey)
  )
  #expect(
    SparkleConfiguration.parse([
      "SUFeedURL": "https://updates.example.test/appcast.xml",
      "SUPublicEDKey": "not-a-key",
    ]) == .failure(.invalidPublicKey)
  )
  var noInstaller = validUpdateInfo()
  noInstaller["SUEnableInstallerLauncherService"] = false
  #expect(
    SparkleConfiguration.parse(noInstaller) == .failure(.installerServiceDisabled)
  )
}

@Test func sparkleConfigurationAcceptsOnlyTheReleaseInputsItUses() throws {
  let configuration = try SparkleConfiguration.parse(validUpdateInfo()).get()
  #expect(configuration.feedURL.absoluteString == "https://updates.example.test/appcast.xml")
  #expect(Data(base64Encoded: configuration.publicEDKey)?.count == 32)
}

@Test @MainActor func developmentBuildWithoutReleaseConfigurationNeverStartsAnUpdater() {
  let updater = AppUpdater(infoDictionary: [:])

  #expect(!updater.isConfigured)
  #expect(!updater.canCheckForUpdates)
  #expect(!updater.checkForUpdates())
  #expect(updater.status == "Updates are disabled: this build has no appcast URL")
}

#if DEBUG
  @Test @MainActor func developmentAppCannotStartEvenWithInjectedReleaseConfiguration() {
    let updater = AppUpdater(infoDictionary: validUpdateInfo())

    #expect(!updater.isConfigured)
    #expect(!updater.canCheckForUpdates)
    #expect(!updater.checkForUpdates())
    #expect(updater.status == "Updates are disabled in development builds")
  }
#endif

@Suite(.serialized)
@MainActor
struct SparklePreferenceTests {
  @Test func sparklesOwnPreferenceSurvivesAControllerRecreation() {
    let first = AppUpdater(infoDictionary: validUpdateInfo(), startsUpdater: false)
    let original = first.automaticallyChecksForUpdates
    defer { first.automaticallyChecksForUpdates = original }

    first.automaticallyChecksForUpdates = !original
    let restored = AppUpdater(infoDictionary: validUpdateInfo(), startsUpdater: false)

    #expect(restored.automaticallyChecksForUpdates == !original)
    #expect(restored.isConfigured)
    #expect(!restored.canCheckForUpdates)
  }
}

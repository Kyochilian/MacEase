import Foundation
import Testing

private let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .appending(path: "../../../..")
  .standardizedFileURL

private func supportDictionary(_ name: String) throws -> [String: Any] {
  let data = try Data(contentsOf: repositoryRoot.appending(path: "Support/\(name)"))
  return try #require(
    PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
  )
}

private func runScript(
  named scriptName: String,
  _ arguments: [String],
  environment additions: [String: String] = [:]
) throws -> (status: Int32, output: String) {
  try runScript(
    at: repositoryRoot.appending(path: "scripts/\(scriptName)"),
    arguments,
    environment: additions
  )
}

private func runScript(
  at script: URL,
  _ arguments: [String],
  environment additions: [String: String] = [:]
) throws -> (status: Int32, output: String) {
  let process = Process()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: "/bin/zsh")
  process.arguments = [script.path] + arguments
  var environment = [
    "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
  ]
  environment.merge(additions) { _, addition in addition }
  process.environment = environment
  process.standardOutput = output
  process.standardError = output
  try process.run()
  process.waitUntilExit()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func runReleaseScript(
  _ arguments: [String],
  environment additions: [String: String] = [:]
) throws -> (status: Int32, output: String) {
  try runScript(
    named: "release_macease_app.sh",
    arguments,
    environment: additions
  )
}

private func writeExecutable(_ source: String, named name: String, in directory: URL) throws {
  let url = directory.appending(path: name)
  try Data(source.utf8).write(to: url)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  try process.run()
  process.waitUntilExit()
  return process.terminationStatus
}

@Test func checkedInReleaseConfigurationIsSafeAndSparkleSandboxCompatible() throws {
  let info = try supportDictionary("MacEase-Info.plist")
  #expect(info["CFBundleIdentifier"] as? String == "com.macease.app")
  #expect(info["LSMinimumSystemVersion"] as? String == "15.0")
  #expect(info["SUEnableInstallerLauncherService"] as? Bool == true)
  #expect(info["SUFeedURL"] == nil)
  #expect(info["SUPublicEDKey"] == nil)

  let entitlements = try supportDictionary("MacEase.entitlements")
  #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
  #expect(entitlements["com.apple.security.network.client"] as? Bool == true)
  #expect(entitlements["com.apple.security.temporary-exception.mach-lookup.global-name"]
    as? [String] == ["com.macease.app-spks", "com.macease.app-spki"])
}

@Test func packageConfigurationRequiresCompleteLicenseSources() throws {
  let files = FileManager.default
  let license = try Data(contentsOf: repositoryRoot.appending(path: "LICENSE"))
  let notices = try Data(
    contentsOf: repositoryRoot.appending(path: "THIRD_PARTY_NOTICES.txt")
  )
  #expect(!license.isEmpty)
  #expect(!notices.isEmpty)
  let noticeText = String(decoding: notices, as: UTF8.self)
  #expect(noticeText.contains("EXTERNAL LICENSES"))
  #expect(noticeText.contains("bspatch.c and bsdiff.c"))
  #expect(noticeText.contains("sais.c and sais.h"))
  #expect(noticeText.contains("Portable C implementation of Ed25519"))
  #expect(noticeText.contains("SUSignatureVerifier.m"))

  let root = files.temporaryDirectory.appending(
    path: "macease-missing-notices-\(UUID().uuidString)"
  )
  defer { try? files.removeItem(at: root) }
  let script = root.appending(path: "scripts/package_macease_app.sh")
  try files.createDirectory(
    at: script.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try files.createDirectory(
    at: root.appending(path: "Support"),
    withIntermediateDirectories: true
  )
  try files.createDirectory(
    at: root.appending(path: "Packages/MacEaseCore"),
    withIntermediateDirectories: true
  )
  for path in [
    "scripts/package_macease_app.sh",
    "Support/MacEase-Info.plist",
    "Support/MacEase.entitlements",
    "Packages/MacEaseCore/Package.resolved",
    "LICENSE",
  ] {
    try files.copyItem(
      at: repositoryRoot.appending(path: path),
      to: root.appending(path: path)
    )
  }

  let missing = try runScript(at: script, ["--check"])
  #expect(missing.status != 0)
  #expect(missing.output.contains("third-party notices are missing or empty"))
}

@Test func releaseDryRunPerformsOnlyStructuralChecks() throws {
  let result = try runReleaseScript(["verify-config"])
  #expect(result.status == 0)
  #expect(result.output.contains("no signing, notarization, or upload ran"))
}

@Test func releasePreflightFailsClosedWithoutHumanMaterials() throws {
  let result = try runReleaseScript(["preflight"])
  #expect(result.status != 0)
  #expect(result.output.contains("MACEASE_SIGNING_IDENTITY"))
  #expect(result.output.contains("MACEASE_TEAM_ID"))
  #expect(result.output.contains("MACEASE_SPARKLE_FEED_URL"))
  #expect(result.output.contains("MACEASE_SPARKLE_PUBLIC_KEY"))
  #expect(result.output.contains("MACEASE_NOTARY_PROFILE"))
  #expect(result.output.contains("MACEASE_SPARKLE_KEYCHAIN_ACCOUNT"))
  #expect(result.output.contains("MACEASE_RELEASE_DOWNLOAD_PREFIX"))
  #expect(result.output.contains("MACEASE_RELEASE_URL"))
  #expect(result.output.contains("MACEASE_HOMEPAGE_URL"))
  #expect(!result.output.contains("success"))
}

@Test func packageDryRunRejectsBroadOutputAndLiveUpdatesForAdHocBuild() throws {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  let broadOutput = try runScript(
    named: "package_macease_app.sh",
    ["--check", "--output-directory", home],
    environment: ["HOME": home]
  )
  #expect(broadOutput.status != 0)
  #expect(broadOutput.output.contains("broad output directory"))

  let publicKey = Data(repeating: 7, count: 32).base64EncodedString()
  let adHocUpdates = try runScript(
    named: "package_macease_app.sh",
    [
      "--check",
      "--feed-url", "https://updates.example.test/appcast.xml",
      "--public-key", publicKey,
    ]
  )
  #expect(adHocUpdates.status != 0)
  #expect(adHocUpdates.output.contains("ad-hoc development package"))
}

@Test func releaseMetadataContainsTheArchiveDigestAndHomebrewRequirements() throws {
  let files = FileManager.default
  let root = files.temporaryDirectory.appending(path: "macease-release-tests-\(UUID().uuidString)")
  defer { try? files.removeItem(at: root) }
  let app = root.appending(path: "MacEase.app")
  let executable = app.appending(path: "Contents/MacOS/MacEase")
  let framework = app.appending(path: "Contents/Frameworks/Sparkle.framework")
  let resources = app.appending(path: "Contents/Resources")
  let tools = root.appending(path: "tools")
  try files.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
  try files.createDirectory(at: framework, withIntermediateDirectories: true)
  try files.createDirectory(at: resources, withIntermediateDirectories: true)
  try files.createDirectory(at: tools, withIntermediateDirectories: true)
  try Data([0]).write(to: executable)
  try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
  try files.copyItem(
    at: repositoryRoot.appending(path: "LICENSE"),
    to: resources.appending(path: "LICENSE.txt")
  )
  try files.copyItem(
    at: repositoryRoot.appending(path: "THIRD_PARTY_NOTICES.txt"),
    to: resources.appending(path: "THIRD_PARTY_NOTICES.txt")
  )

  var info = try supportDictionary("MacEase-Info.plist")
  info["CFBundleShortVersionString"] = "1.2.3"
  info["CFBundleVersion"] = "42"
  let feedURL = "https://updates.example.test/appcast.xml"
  let publicKey = Data(repeating: 7, count: 32).base64EncodedString()
  info["SUFeedURL"] = feedURL
  info["SUPublicEDKey"] = publicKey
  let infoData = try PropertyListSerialization.data(
    fromPropertyList: info,
    format: .xml,
    options: 0
  )
  try infoData.write(to: app.appending(path: "Contents/Info.plist"))

  try writeExecutable(
    """
    #!/bin/zsh
    if [[ "$1" == "--verify" ]]; then exit 0; fi
    if [[ "$1" == "-d" && "$2" == "--verbose=4" ]]; then
      print -u2 -r -- "Authority=Developer ID Application: Test (ABCDE12345)"
      print -u2 -r -- "flags=0x10000(runtime)"
      print -u2 -r -- "TeamIdentifier=ABCDE12345"
      print -u2 -r -- "CDHash=0123456789abcdef"
      exit 0
    fi
    if [[ "$1" == "-d" && "$2" == "--entitlements" ]]; then
      cp "$MACEASE_TEST_ENTITLEMENTS" "$3"
      exit 0
    fi
    exit 2
    """,
    named: "codesign",
    in: tools
  )
  try writeExecutable(
    """
    #!/bin/zsh
    [[ "$1" == "-archs" ]] || exit 2
    print -r -- arm64
    """,
    named: "lipo",
    in: tools
  )
  try writeExecutable(
    """
    #!/bin/zsh
    [[ "$1" == "-L" ]] || exit 2
    print -r -- '@rpath/Sparkle.framework/Versions/B/Sparkle'
    """,
    named: "otool",
    in: tools
  )
  try writeExecutable(
    """
    #!/bin/zsh
    [[ "$1" == "stapler" && "$2" == "validate" ]] || exit 2
    """,
    named: "xcrun",
    in: tools
  )

  let archive = root.appending(path: "MacEase-1.2.3.zip")
  #expect(
    try run(
      "/usr/bin/ditto",
      ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, archive.path]
    ) == 0
  )
  let output = root.appending(path: "metadata")
  let releaseEnvironment = [
    "PATH": "\(tools.path):/usr/bin:/bin:/usr/sbin:/sbin",
    "MACEASE_SIGNING_IDENTITY": "Developer ID Application: Test (ABCDE12345)",
    "MACEASE_TEAM_ID": "ABCDE12345",
    "MACEASE_SPARKLE_FEED_URL": feedURL,
    "MACEASE_SPARKLE_PUBLIC_KEY": publicKey,
    "MACEASE_NOTARY_PROFILE": "macease-test-notary",
    "MACEASE_SPARKLE_KEYCHAIN_ACCOUNT": "macease-test-key",
    "MACEASE_RELEASE_DOWNLOAD_PREFIX": "https://downloads.example.test",
    "MACEASE_RELEASE_URL": "https://downloads.example.test/MacEase-1.2.3.zip",
    "MACEASE_HOMEPAGE_URL": "https://macease.example.test",
    "MACEASE_TEST_ENTITLEMENTS": repositoryRoot
      .appending(path: "Support/MacEase.entitlements").path,
  ]
  let result = try runReleaseScript(
    ["metadata", app.path, archive.path, output.path],
    environment: releaseEnvironment
  )

  #expect(result.status == 0)
  let metadataData = try Data(contentsOf: output.appending(path: "release-metadata.json"))
  let metadata = try #require(
    JSONSerialization.jsonObject(with: metadataData) as? [String: String]
  )
  let digest = try #require(metadata["sha256"])
  #expect(metadata["version"] == "1.2.3")
  #expect(metadata["build"] == "42")
  #expect(metadata["architecture"] == "arm64")
  #expect(metadata["minimumMacOS"] == "15.0")
  #expect(digest.count == 64)

  let cask = try String(contentsOf: output.appending(path: "macease.rb"), encoding: .utf8)
  #expect(cask.contains("version \"1.2.3\""))
  #expect(cask.contains("sha256 \"\(digest)\""))
  #expect(cask.contains("depends_on arch: :arm64"))
  #expect(cask.contains("depends_on macos: :sequoia"))
  #expect(cask.contains("app \"MacEase.app\""))

  var mismatchedKeyEnvironment = releaseEnvironment
  mismatchedKeyEnvironment["MACEASE_SPARKLE_PUBLIC_KEY"] = Data(
    repeating: 8,
    count: 32
  ).base64EncodedString()
  let mismatch = try runReleaseScript(
    ["appcast", root.path],
    environment: mismatchedKeyEnvironment
  )
  #expect(mismatch.status != 0)
  #expect(mismatch.output.contains("does not match the release key"))
}

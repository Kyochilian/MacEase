// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MacEaseCore",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "NeteaseKit", targets: ["NeteaseKit"]),
    .executable(name: "MacEase", targets: ["MacEase"]),
    .executable(name: "GateALyricsProbe", targets: ["GateALyricsProbe"]),
    .executable(name: "GateBLoginHarness", targets: ["GateBLoginHarness"]),
    .executable(name: "GateCPlaybackProbe", targets: ["GateCPlaybackProbe"]),
    .executable(name: "GatePhase2PlaylistProbe", targets: ["GatePhase2PlaylistProbe"]),
  ],
  targets: [
    .target(name: "NeteaseKit"),
    // App state, coordinators and the operation arbiter. Deliberately free
    // of AppKit and WebKit so its tests run without a GUI stack.
    .target(
      name: "MacEaseAppCore",
      dependencies: ["NeteaseKit"]
    ),
    .target(
      name: "MacEaseSession",
      dependencies: ["NeteaseKit", "MacEaseAppCore"]
    ),
    .executableTarget(
      name: "MacEase",
      dependencies: ["MacEaseSession", "MacEaseAppCore", "NeteaseKit"]
    ),
    .executableTarget(
      name: "GateALyricsProbe",
      dependencies: ["NeteaseKit"]
    ),
    .executableTarget(
      name: "GateBLoginHarness",
      dependencies: ["NeteaseKit", "MacEaseSession", "MacEaseAppCore"]
    ),
    .executableTarget(
      name: "GateCPlaybackProbe",
      dependencies: ["NeteaseKit"]
    ),
    .executableTarget(
      name: "GatePhase2PlaylistProbe",
      dependencies: ["NeteaseKit"]
    ),
    .testTarget(
      name: "NeteaseKitTests",
      dependencies: ["NeteaseKit"]
    ),
    .testTarget(
      name: "MacEaseAppCoreTests",
      dependencies: ["MacEaseSession", "MacEaseAppCore", "NeteaseKit"]
    ),
  ],
  swiftLanguageModes: [.v6]
)

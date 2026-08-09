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
    .target(
      name: "MacEaseSession",
      dependencies: ["NeteaseKit"]
    ),
    .executableTarget(
      name: "MacEase",
      dependencies: ["MacEaseSession", "NeteaseKit"]
    ),
    .executableTarget(
      name: "GateALyricsProbe",
      dependencies: ["NeteaseKit"]
    ),
    .executableTarget(
      name: "GateBLoginHarness",
      dependencies: ["NeteaseKit", "MacEaseSession"]
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
  ],
  swiftLanguageModes: [.v6]
)

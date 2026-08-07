// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MacEaseCore",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "NeteaseKit", targets: ["NeteaseKit"]),
    .executable(name: "GateALyricsProbe", targets: ["GateALyricsProbe"]),
    .executable(name: "GateBLoginHarness", targets: ["GateBLoginHarness"]),
    .executable(name: "GateCPlaybackProbe", targets: ["GateCPlaybackProbe"]),
  ],
  targets: [
    .target(name: "NeteaseKit"),
    .executableTarget(
      name: "GateALyricsProbe",
      dependencies: ["NeteaseKit"]
    ),
    .executableTarget(
      name: "GateBLoginHarness",
      dependencies: ["NeteaseKit"]
    ),
    .executableTarget(
      name: "GateCPlaybackProbe",
      dependencies: ["NeteaseKit"]
    ),
    .testTarget(
      name: "NeteaseKitTests",
      dependencies: ["NeteaseKit"]
    ),
  ],
  swiftLanguageModes: [.v6]
)

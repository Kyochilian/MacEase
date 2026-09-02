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
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
  ],
  targets: [
    .target(name: "NeteaseKit"),
    // App state, coordinators and the operation arbiter. It reaches system
    // frameworks only through the protocols in this target — AudioOutput,
    // SystemMediaControlling, SystemEventObserving — so every decision they
    // guard is testable without a running media server, audio device or
    // window server.
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
      dependencies: [
        "MacEaseSession",
        "MacEaseAppCore",
        "NeteaseKit",
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        ])
      ]
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
      dependencies: ["MacEase", "MacEaseSession", "MacEaseAppCore", "NeteaseKit"]
    ),
  ],
  swiftLanguageModes: [.v6]
)

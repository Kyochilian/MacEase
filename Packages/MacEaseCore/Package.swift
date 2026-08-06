// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MacEaseCore",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "NeteaseKit", targets: ["NeteaseKit"]),
    .executable(name: "GateBLoginHarness", targets: ["GateBLoginHarness"]),
  ],
  targets: [
    .target(name: "NeteaseKit"),
    .executableTarget(
      name: "GateBLoginHarness",
      dependencies: ["NeteaseKit"]
    ),
    .testTarget(
      name: "NeteaseKitTests",
      dependencies: ["NeteaseKit"]
    ),
  ],
  swiftLanguageModes: [.v6]
)

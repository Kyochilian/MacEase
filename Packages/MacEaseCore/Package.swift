// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MacEaseCore",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "NeteaseKit", targets: ["NeteaseKit"])
  ],
  targets: [
    .target(name: "NeteaseKit"),
    .testTarget(
      name: "NeteaseKitTests",
      dependencies: ["NeteaseKit"]
    ),
  ],
  swiftLanguageModes: [.v6]
)

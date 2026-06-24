// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MideaKit",
  platforms: [.macOS(.v13), .iOS(.v16)],
  products: [
    .library(name: "MideaKit", targets: ["MideaKit"])
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0")
  ],
  targets: [
    .target(name: "MideaKit"),
    .testTarget(
      name: "MideaKitTests",
      dependencies: ["MideaKit"],
      resources: [.copy("vectors.json")]
    ),
  ]
)

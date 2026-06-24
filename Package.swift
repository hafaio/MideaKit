// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MideaKit",
  platforms: [.macOS(.v13), .iOS(.v16)],
  products: [
    .library(name: "MideaKit", targets: ["MideaKit"])
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

// The DocC plugin is only needed to build documentation (in CI), so it's added
// conditionally to keep it out of library consumers' dependency graphs.
if Context.environment["MIDEAKIT_DOCS"] != nil {
  package.dependencies.append(
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"))
}

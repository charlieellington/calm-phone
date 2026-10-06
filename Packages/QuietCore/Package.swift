// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "QuietCore",
  platforms: [.macOS(.v13), .iOS("18.5")],
  products: [
    .library(name: "QuietCore", targets: ["QuietCore"]),
    .executable(name: "QuietProbe", targets: ["QuietProbe"]),
  ],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "QuietCore", dependencies: ["CSQLite"]),
    .executableTarget(name: "QuietProbe", dependencies: ["QuietCore"]),
    .testTarget(name: "QuietCoreTests", dependencies: ["QuietCore"]),
  ], swiftLanguageModes: [.v5]
)

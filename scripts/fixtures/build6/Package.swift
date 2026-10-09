// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Build6Fixture",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "Build6Fixture", targets: ["Quiet"])],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "QuietCore", dependencies: ["CSQLite"]),
    .executableTarget(name: "Quiet", dependencies: ["QuietCore"]),
  ], swiftLanguageModes: [.v5]
)

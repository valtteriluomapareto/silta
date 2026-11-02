// swift-tools-version: 6.2
import PackageDescription

// Every target gets the same settings: Swift 6 mode plus the Swift 7 upcoming
// features (D29, enforced by scripts/guards/check_package_features.py).
let swiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
  name: "silta",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "silta", targets: ["silta"]),
    .library(name: "SiltaCore", targets: ["SiltaCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
  ],
  targets: [
    .target(
      name: "SiltaCore",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Yams", package: "Yams"),
      ],
      swiftSettings: swiftSettings
    ),
    .executableTarget(
      name: "silta",
      dependencies: [
        "SiltaCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      swiftSettings: swiftSettings
    ),
    .target(
      name: "SiltaTestSupport",
      dependencies: ["SiltaCore"],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "SiltaCoreTests",
      dependencies: [
        "SiltaCore", "SiltaTestSupport",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      exclude: ["Golden"],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "siltaTests",
      dependencies: ["SiltaCore", "SiltaTestSupport"],
      exclude: ["Golden"],
      swiftSettings: swiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)

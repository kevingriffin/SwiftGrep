// swift-tools-version: 6.4
import CompilerPluginSupport
import PackageDescription

let settings: [SwiftSetting] = [
  // Every use of an unsafe construct must be marked with `unsafe`, so the
  // places that need review are visible in the source.
  .strictMemorySafety(),
]

let package = Package(
  name: "SwiftGrep",
  platforms: [.macOS(.v27)],
  products: [
    .executable(name: "sg", targets: ["sg"]),
    .library(name: "GrepRegex", targets: ["GrepRegex"]),
    .library(name: "SwiftGrepKit", targets: ["SwiftGrepKit"]),
  ],
  dependencies: [
    // Pre-1.0: pinned to a minor version.
    .package(url: "https://github.com/apple/swift-binary-parsing", .upToNextMinor(from: "0.0.4")),
    // For the macros; SwiftPM uses a prebuilt copy matching the toolchain.
    .package(url: "https://github.com/swiftlang/swift-syntax", "603.0.0"..<"605.0.0"),
  ],
  targets: [
    .target(name: "GrepRegex", swiftSettings: settings),
    .macro(
      name: "SwiftGrepMacros",
      dependencies: [
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
      ],
    ),
    .target(
      name: "SwiftGrepKit",
      dependencies: ["GrepRegex", "SwiftGrepMacros", .product(name: "BinaryParsing", package: "swift-binary-parsing")],
      swiftSettings: settings,
    ),
    .executableTarget(name: "sg", dependencies: ["SwiftGrepKit"], swiftSettings: settings),
    .testTarget(name: "GrepRegexTests", dependencies: ["GrepRegex"]),
    .testTarget(name: "SwiftGrepKitTests", dependencies: ["SwiftGrepKit"]),
  ],
)

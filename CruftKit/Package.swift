// swift-tools-version: 6.0
// FROZEN (contracts v1): this manifest is single-owner. Do not edit in parallel work;
// amendments go through the integrator. SwiftPM globs sources, so adding .swift files
// never requires touching this file.
import PackageDescription

let package = Package(
    name: "CruftKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CruftKit", targets: ["CruftKit"]),
        .executable(name: "cruft-cli", targets: ["CruftCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(name: "CruftKit"),
        .target(name: "CruftKitTestSupport", dependencies: ["CruftKit"]),
        .executableTarget(
            name: "CruftCLI",
            dependencies: [
                "CruftKit",
                "CruftKitTestSupport",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "CruftKitTests",
            dependencies: ["CruftKit", "CruftKitTestSupport"]
        ),
    ]
)

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Standup",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "standup", targets: ["CLI"]),
        .library(name: "StandupCore", targets: ["StandupCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "StandupCore",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/StandupCore"
        ),
        .target(
            name: "LivePlugins",
            dependencies: ["StandupCore"],
            path: "Sources/LivePlugins"
        ),
        .target(
            name: "StagePlugins",
            dependencies: ["StandupCore"],
            path: "Sources/StagePlugins"
        ),
        .executableTarget(
            name: "CLI",
            dependencies: [
                "StandupCore",
                "LivePlugins",
                "StagePlugins",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "StandupTests",
            dependencies: ["StandupCore", "LivePlugins", "StagePlugins"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Codo",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "CodoCore",
            path: "Sources/CodoCore"
        ),
        .executableTarget(
            name: "Codo",
            dependencies: ["CodoCore"],
            path: "Sources/Codo"
        ),
        .testTarget(
            name: "CodoCoreTests",
            dependencies: ["CodoCore"],
            path: "Tests/CodoCoreTests"
        )
    ]
)

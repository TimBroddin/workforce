// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WorkforceKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WorkforceKit", targets: ["WorkforceKit"]),
        .executable(name: "workforce", targets: ["WorkforceCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "WorkforceKit"
        ),
        .executableTarget(
            name: "WorkforceCLI",
            dependencies: [
                "WorkforceKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "WorkforceKitTests",
            dependencies: ["WorkforceKit"]
        ),
    ]
)

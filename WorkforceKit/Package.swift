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
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.76.0"),
    ],
    targets: [
        .target(
            name: "WorkforceKit",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "WorkforceCLI",
            dependencies: [
                "WorkforceKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "WorkforceKitTests",
            dependencies: ["WorkforceKit"]
        ),
    ]
)

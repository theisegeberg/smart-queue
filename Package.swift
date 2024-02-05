// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "smart-queue",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(
            name: "SmartQueue",
            targets: ["SmartQueue"]
        ),
    ],
    targets: [
        .target(
            name: "SmartQueue"),
        .testTarget(
            name: "SmartQueueTests",
            dependencies: ["SmartQueue"]
        ),
    ]
)

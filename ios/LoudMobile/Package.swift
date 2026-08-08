// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LoudMobile",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LoudSecureSync", targets: ["LoudSecureSync"])
    ],
    targets: [
        .target(name: "LoudSecureSync"),
        .testTarget(name: "LoudSecureSyncTests", dependencies: ["LoudSecureSync"])
    ]
)


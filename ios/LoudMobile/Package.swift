// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LoudMobile",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LoudKit", targets: ["LoudKit"])
    ],
    targets: [
        .target(name: "LoudKit"),
        .testTarget(name: "LoudKitTests", dependencies: ["LoudKit"])
    ]
)

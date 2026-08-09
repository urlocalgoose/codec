// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Codec",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "CodecKit", targets: ["CodecKit"])
    ],
    targets: [
        .target(name: "CodecKit"),
        .testTarget(name: "CodecKitTests", dependencies: ["CodecKit"])
    ]
)

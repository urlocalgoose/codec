// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShippedClientCompatibility",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "client-compatibility", targets: ["CompatibilityRunner"])],
    targets: [
        .target(name: "CodecKit"),
        .executableTarget(name: "CompatibilityRunner", dependencies: ["CodecKit"]),
    ]
)

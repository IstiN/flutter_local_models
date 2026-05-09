// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MLXBridge",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "MLXBridge", type: .dynamic, targets: ["MLXBridge"]),
    ],
    targets: [
        .target(
            name: "MLXBridge"
        ),
        .testTarget(
            name: "MLXBridgeTests",
            dependencies: ["MLXBridge"]
        ),
    ]
)

// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "shelf-bridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "shelf-bridge", targets: ["shelf-bridge"]),
        .library(name: "ShelfBridgeCore", targets: ["ShelfBridgeCore"]),
    ],
    targets: [
        .target(name: "ShelfBridgeCore"),
        .executableTarget(name: "shelf-bridge", dependencies: ["ShelfBridgeCore"]),
        // Depends on the executable so integration tests can start the real `wrap`.
        .testTarget(name: "ShelfBridgeCoreTests", dependencies: ["ShelfBridgeCore", "shelf-bridge"]),
    ]
)

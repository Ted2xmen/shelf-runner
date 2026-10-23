// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "shelf-runner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "shelf-runner", targets: ["shelf-runner"]),
        .library(name: "ShelfRunnerCore", targets: ["ShelfRunnerCore"]),
    ],
    targets: [
        .target(name: "ShelfRunnerCore"),
        .executableTarget(name: "shelf-runner", dependencies: ["ShelfRunnerCore"]),
        // Depends on the executable so integration tests can start the real `wrap`.
        .testTarget(name: "ShelfRunnerCoreTests", dependencies: ["ShelfRunnerCore", "shelf-runner"]),
    ]
)

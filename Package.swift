// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Compagnion",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CompagnionCore",
            path: "Sources/CompagnionCore"
        ),
        .executableTarget(
            name: "Compagnion",
            dependencies: ["CompagnionCore"],
            path: "Sources/Compagnion"
        ),
        .testTarget(
            name: "CompagnionCoreTests",
            dependencies: ["CompagnionCore"],
            path: "Tests/CompagnionCoreTests"
        ),
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Compagnion",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Compagnion",
            path: "Sources/Compagnion"
        )
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WangErChat",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "WangErChat",
            path: "Sources/WangErChat"
        )
    ]
)

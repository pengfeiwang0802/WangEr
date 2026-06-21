// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WangErChat",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SWS",
            path: "Sources/SWS"
        ),
        .executableTarget(
            name: "WangErChat",
            dependencies: ["SWS"],
            path: "Sources/WangErChat"
        ),
        .testTarget(
            name: "WangErChatTests",
            dependencies: ["SWS"],
            path: "Tests/WangErChatTests"
        ),
        .executableTarget(
            name: "sws-tool",
            dependencies: ["SWS"],
            path: "Tools/sws-tool"
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetScribe",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "MeetScribe", path: "Sources/MeetScribe"),
        .testTarget(name: "MeetScribeTests", dependencies: ["MeetScribe"], path: "Tests/MeetScribeTests"),
    ]
)

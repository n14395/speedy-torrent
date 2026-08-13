// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftTorrent",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "TorrentEngine"),
        .executableTarget(
            name: "SwiftTorrentApp",
            dependencies: ["TorrentEngine"]
        ),
        .executableTarget(
            name: "storrent",
            dependencies: ["TorrentEngine"]
        ),
        .testTarget(
            name: "TorrentEngineTests",
            dependencies: ["TorrentEngine"]
        ),
    ]
)

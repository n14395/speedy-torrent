// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpeedyTorrent",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "TorrentEngine"),
        .executableTarget(
            name: "SpeedyTorrentApp",
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

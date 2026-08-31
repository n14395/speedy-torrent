import Foundation
import Testing
@testable import TorrentEngine

/// Builds a seeder serving `payload` on a random port, plus the torrent data
/// its leechers need.
private func makeSeeder(
    root: URL, payloadBytes: Int, pieceLength: Int = 32 * 1024
) throws -> (torrentData: Data, seedDirectory: URL) {
    let seedDir = root.appendingPathComponent("seed")
    let contentDir = seedDir.appendingPathComponent("payload")
    try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
    var generator = SystemRandomNumberGenerator()
    let payload = Data((0..<payloadBytes).map { _ in UInt8.random(in: 0...255, using: &generator) })
    try payload.write(to: contentDir.appendingPathComponent("file.bin"))
    return (
        try TorrentBuilder.makeTorrentData(contentsOf: contentDir, pieceLength: pieceLength),
        seedDir
    )
}

/// Polls until the torrent finishes, up to `attempts` × 100 ms.
private func waitForSeeding(_ session: TorrentSession, attempts: Int = 600) async throws -> Bool {
    for _ in 0..<attempts {
        try await Task.sleep(for: .milliseconds(100))
        if let snap = await session.snapshots().first, snap.state == .seeding {
            return true
        }
    }
    return false
}

@Suite struct PerTorrentRateLimitTests {
    /// The torrent's own cap has to bite with no session-wide limit in play —
    /// that is the whole point of the second bucket.
    @Test(.timeLimit(.minutes(2)))
    func perTorrentLimitThrottlesWithoutASessionLimit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("torrent-limit-\(UUID().uuidString)")
        let leechDir = root.appendingPathComponent("leech")
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (torrentData, seedDir) = try makeSeeder(root: root, payloadBytes: 600_000)

        let port = UInt16.random(in: 20000...60000)
        let seeder = TorrentSession(configuration: .init(
            downloadDirectory: seedDir, listenPort: port, enableDHT: false
        ))
        _ = try await seeder.startListening()
        _ = try await seeder.addTorrent(fileData: torrentData)

        // No session limit at all: 600 KB at 200 KiB/s → ≥ ~2s even after the
        // one-second burst allowance.
        let leecher = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0, enableDHT: false
        ))
        let hash = try await leecher.addTorrent(fileData: torrentData)
        try await leecher.setRateLimits(download: 200 * 1024, upload: nil, for: hash)

        let start = ContinuousClock.now
        try await leecher.addPeers([PeerAddress(host: "127.0.0.1", port: port)], to: hash)
        let done = try await waitForSeeding(leecher)
        let elapsed = start.duration(to: .now)

        #expect(done)
        #expect(elapsed >= .seconds(1.5), "finished too fast for the cap: \(elapsed)")
        await leecher.shutdown()
        await seeder.shutdown()
    }

    /// A cap applied to a running transfer must reach the connections that are
    /// already open, and must not wedge them.
    @Test(.timeLimit(.minutes(2)))
    func aLimitSetMidTransferReachesOpenConnections() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("torrent-limit-live-\(UUID().uuidString)")
        let leechDir = root.appendingPathComponent("leech")
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (torrentData, seedDir) = try makeSeeder(root: root, payloadBytes: 600_000)

        let port = UInt16.random(in: 20000...60000)
        let seeder = TorrentSession(configuration: .init(
            downloadDirectory: seedDir, listenPort: port, enableDHT: false
        ))
        _ = try await seeder.startListening()
        _ = try await seeder.addTorrent(fileData: torrentData)

        let leecher = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0,
            downloadRateLimit: 300 * 1024, enableDHT: false
        ))
        let hash = try await leecher.addTorrent(fileData: torrentData)
        try await leecher.addPeers([PeerAddress(host: "127.0.0.1", port: port)], to: hash)

        // Wait for the transfer to be genuinely under way, then clamp it.
        var started = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if let snap = await leecher.snapshots().first, snap.completedLength > 0 {
                started = true
                break
            }
        }
        #expect(started, "transfer never started")
        try await leecher.setRateLimits(download: 150 * 1024, upload: nil, for: hash)
        #expect(await leecher.snapshots().first?.downloadRateLimit == 150 * 1024)

        #expect(try await waitForSeeding(leecher), "throttled transfer never finished")
        await leecher.shutdown()
        await seeder.shutdown()
    }

    @Test func limitsAreReportedClearedAndRestoredAcrossRestarts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("limit-state-\(UUID().uuidString)")
        let state = root.appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at: root) }
        let (torrentData, _) = try makeSeeder(root: root, payloadBytes: 40_000)

        let configuration = TorrentSession.Configuration(
            downloadDirectory: root, listenPort: 0, stateDirectory: state, enableDHT: false
        )
        let session = TorrentSession(configuration: configuration)
        let hash = try await session.addTorrent(fileData: torrentData)
        #expect(await session.snapshots().first?.downloadRateLimit == nil)

        try await session.setRateLimits(download: 128 * 1024, upload: 64 * 1024, for: hash)
        var snapshot = await session.snapshots().first
        #expect(snapshot?.downloadRateLimit == 128 * 1024)
        #expect(snapshot?.uploadRateLimit == 64 * 1024)

        // 0 and nil both mean "no cap of its own".
        try await session.setRateLimits(download: 0, upload: 64 * 1024, for: hash)
        snapshot = await session.snapshots().first
        #expect(snapshot?.downloadRateLimit == nil)
        #expect(snapshot?.uploadRateLimit == 64 * 1024)
        await session.shutdown()

        let restored = TorrentSession(configuration: configuration)
        await restored.restore()
        let afterRestart = await restored.snapshots().first
        #expect(afterRestart?.downloadRateLimit == nil)
        #expect(afterRestart?.uploadRateLimit == 64 * 1024)
        await restored.shutdown()
    }

    @Test func settingLimitsOnAnUnknownTorrentThrows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("limit-unknown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = TorrentSession(configuration: .init(
            downloadDirectory: root, listenPort: 0, enableDHT: false
        ))
        let stranger = InfoHash(data: Data(repeating: 9, count: 20))!
        await #expect(throws: SessionError.self) {
            try await session.setRateLimits(download: 1024, upload: nil, for: stranger)
        }
        await session.shutdown()
    }
}

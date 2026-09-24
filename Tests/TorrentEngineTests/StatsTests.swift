// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TorrentEngine

@Suite struct StatsTests {
    /// Session counters accumulate a real loopback transfer, persist across a
    /// restart into the all-time counters, and restored per-torrent totals are
    /// not double-counted.
    @Test(.timeLimit(.minutes(1)))
    func statisticsAccumulateAndPersist() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stats-\(UUID().uuidString)")
        let seedDir = root.appendingPathComponent("seed")
        let leechDir = root.appendingPathComponent("leech")
        let stateDir = root.appendingPathComponent("state")
        let content = seedDir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var gen = SystemRandomNumberGenerator()
        let payload = Data((0..<200_000).map { _ in UInt8.random(in: 0...255, using: &gen) })
        try payload.write(to: content.appendingPathComponent("file.bin"))
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: content, pieceLength: 32 * 1024)
        let hash = try TorrentMetaInfo(torrentFileData: torrentData).info.infoHash

        let port = UInt16.random(in: 20000...60000)
        let seeder = TorrentSession(configuration: .init(
            downloadDirectory: seedDir, listenPort: port, enableDHT: false
        ))
        _ = try await seeder.startListening()
        _ = try await seeder.addTorrent(fileData: torrentData)

        func makeLeecher() -> TorrentSession {
            TorrentSession(configuration: .init(
                downloadDirectory: leechDir, listenPort: 0, stateDirectory: stateDir,
                enableDHT: false
            ))
        }

        let leecher = makeLeecher()
        _ = try await leecher.addTorrent(fileData: torrentData)
        try await leecher.addPeers([PeerAddress(host: "127.0.0.1", port: port)], to: hash)

        var complete = false
        for _ in 0..<400 {
            try await Task.sleep(for: .milliseconds(100))
            if let snap = await leecher.snapshots().first, snap.state == .seeding {
                complete = true
                break
            }
        }
        #expect(complete)

        let downloaded = Int64(payload.count)
        let leechStats = await leecher.statistics()
        #expect(leechStats.sessionDownloaded >= downloaded)
        #expect(leechStats.allTimeDownloaded == leechStats.sessionDownloaded)
        #expect(leechStats.launchCount == 1)

        let seedStats = await seeder.statistics()
        #expect(seedStats.sessionUploaded >= downloaded)

        await leecher.shutdown() // persists stats.json

        // A restarted session: all-time survives, the new session starts at
        // zero, and the restored torrent's totals do not inflate all-time.
        let restarted = makeLeecher()
        await restarted.restore()
        _ = await restarted.snapshots()
        _ = await restarted.snapshots()
        let restartedStats = await restarted.statistics()
        #expect(restartedStats.sessionDownloaded == 0)
        #expect(restartedStats.allTimeDownloaded == leechStats.allTimeDownloaded)
        #expect(restartedStats.launchCount == 2)
        await restarted.shutdown()

        await seeder.shutdown()
    }
}

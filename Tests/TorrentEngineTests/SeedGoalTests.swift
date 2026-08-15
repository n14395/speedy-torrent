import Foundation
import Testing
@testable import TorrentEngine

@Suite struct SeedGoalTests {
    /// A seeder with a low ratio limit must stop seeding (pause itself) once it
    /// has uploaded enough to a downloading peer.
    @Test(.timeLimit(.minutes(1)))
    func ratioLimitStopsSeeding() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seedgoal-\(UUID().uuidString)")
        let seedDir = root.appendingPathComponent("seed")
        let leechDir = root.appendingPathComponent("leech")
        let content = seedDir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var gen = SystemRandomNumberGenerator()
        let payload = Data((0..<300_000).map { _ in UInt8.random(in: 0...255, using: &gen) })
        try payload.write(to: content.appendingPathComponent("file.bin"))
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: content, pieceLength: 32 * 1024)
        let hash = try TorrentMetaInfo(torrentFileData: torrentData).info.infoHash

        let port = UInt16.random(in: 20000...60000)
        let seeder = TorrentSession(configuration: .init(
            downloadDirectory: seedDir, listenPort: port, enableDHT: false, seedRatioLimit: 0.1
        ))
        _ = try await seeder.startListening()
        _ = try await seeder.addTorrent(fileData: torrentData)

        let leecher = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0, enableDHT: false
        ))
        _ = try await leecher.addTorrent(fileData: torrentData)
        try await leecher.addPeers([PeerAddress(host: "127.0.0.1", port: port)], to: hash)

        var paused = false
        for _ in 0..<400 {
            try await Task.sleep(for: .milliseconds(100))
            if let snap = await seeder.snapshots().first, snap.state == .paused {
                paused = true
                #expect(snap.uploadedTotal > 0)
                break
            }
        }
        #expect(paused)

        await leecher.shutdown()
        await seeder.shutdown()
    }
}

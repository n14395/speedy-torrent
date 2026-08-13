import Foundation
import Testing
@testable import TorrentEngine

/// Full-stack test: one session seeds generated content over 127.0.0.1, a
/// second session downloads it through the real peer-wire path (handshake,
/// bitfield, request pipeline, verification, disk).
@Suite struct LoopbackTests {
    @Test(.timeLimit(.minutes(2)))
    func seederToLeecherTransfer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopback-\(UUID().uuidString)")
        let seedDir = root.appendingPathComponent("seed")
        let leechDir = root.appendingPathComponent("leech")
        let contentDir = seedDir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(
            at: contentDir.appendingPathComponent("nested"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // ~800 KB across two files → 25 pieces of 32 KiB.
        var generator = SystemRandomNumberGenerator()
        let fileA = Data((0..<700_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let fileB = Data((0..<100_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try fileA.write(to: contentDir.appendingPathComponent("a.bin"))
        try fileB.write(to: contentDir.appendingPathComponent("nested/b.bin"))

        let torrentData = try TorrentBuilder.makeTorrentData(
            contentsOf: contentDir, pieceLength: 32 * 1024
        )

        let port = UInt16.random(in: 20000...60000)
        let seeder = TorrentSession(configuration: .init(
            downloadDirectory: seedDir, listenPort: port
        ))
        let leecher = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0
        ))

        _ = try await seeder.startListening()
        let seedHash = try await seeder.addTorrent(fileData: torrentData)

        // The seeder must recognize its existing data and start seeding.
        let seedSnapshot = try #require(await seeder.snapshots().first)
        #expect(seedSnapshot.state == .seeding, "seeder state: \(seedSnapshot.state)")
        #expect(seedSnapshot.completedLength == 800_000)

        let leechHash = try await leecher.addTorrent(fileData: torrentData)
        #expect(leechHash == seedHash)
        try await leecher.addPeers([PeerAddress(host: "127.0.0.1", port: port)], to: leechHash)

        // Wait for completion.
        var completed = false
        for _ in 0..<600 {
            try await Task.sleep(for: .milliseconds(100))
            if let snap = await leecher.snapshots().first, snap.state == .seeding {
                completed = true
                break
            }
        }
        let finalSnap = try #require(await leecher.snapshots().first)
        #expect(completed, "download did not complete; final: \(finalSnap)")
        #expect(finalSnap.completedLength == 800_000)
        #expect(finalSnap.downloadedTotal >= 800_000)

        // Byte-for-byte comparison of delivered content.
        let gotA = try Data(contentsOf: leechDir.appendingPathComponent("payload/a.bin"))
        let gotB = try Data(contentsOf: leechDir.appendingPathComponent("payload/nested/b.bin"))
        #expect(gotA == fileA)
        #expect(gotB == fileB)

        // The seeder should have recorded roughly the payload as uploaded.
        let seedFinal = try #require(await seeder.snapshots().first)
        #expect(seedFinal.uploadedTotal >= 800_000)

        await leecher.shutdown()
        await seeder.shutdown()
    }

    /// Sequential mode must deliver pieces (nearly) in order.
    @Test(.timeLimit(.minutes(2)))
    func sequentialDownloadCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopback-seq-\(UUID().uuidString)")
        let seedDir = root.appendingPathComponent("seed")
        let leechDir = root.appendingPathComponent("leech")
        let contentDir = seedDir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<400_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try payload.write(to: contentDir.appendingPathComponent("file.bin"))

        let torrentData = try TorrentBuilder.makeTorrentData(
            contentsOf: contentDir, pieceLength: 32 * 1024
        )

        let port = UInt16.random(in: 20000...60000)
        let seeder = TorrentSession(configuration: .init(downloadDirectory: seedDir, listenPort: port))
        let leecher = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0, sequentialDownload: true
        ))

        _ = try await seeder.startListening()
        _ = try await seeder.addTorrent(fileData: torrentData)
        let hash = try await leecher.addTorrent(fileData: torrentData)
        try await leecher.addPeers([PeerAddress(host: "127.0.0.1", port: port)], to: hash)

        var completed = false
        for _ in 0..<600 {
            try await Task.sleep(for: .milliseconds(100))
            if let snap = await leecher.snapshots().first, snap.state == .seeding {
                completed = true
                break
            }
        }
        #expect(completed)
        let got = try Data(contentsOf: leechDir.appendingPathComponent("payload/file.bin"))
        #expect(got == payload)

        await leecher.shutdown()
        await seeder.shutdown()
    }
}

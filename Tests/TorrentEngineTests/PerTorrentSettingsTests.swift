import Foundation
import Testing
@testable import TorrentEngine

@Suite struct PerTorrentSettingsTests {
    /// A move reports how far it has got, and hands the ring back to the
    /// download once it lands. Within one volume a move is a rename, so this
    /// covers the bookkeeping either side of it rather than the copy itself —
    /// that needs a second volume, and was verified against a real one.
    @Test(.timeLimit(.minutes(2)))
    func moveProgressIsReportedAndCleared() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("moveprogress-\(UUID().uuidString)")
        let content = root.appendingPathComponent("payload")
        let destination = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 7, count: 300_000).write(to: content.appendingPathComponent("file.bin"))
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: content, pieceLength: 32 * 1024)

        let session = TorrentSession(configuration: .init(
            downloadDirectory: root, listenPort: 0, enableDHT: false
        ))
        let hash = try await session.addTorrent(fileData: torrentData)
        #expect(await session.snapshots().first?.moveProgress == 0)

        try await session.setDownloadDirectory(destination, for: hash)
        let after = await session.snapshots().first
        // Cleared, not left pinned at whatever the last sample happened to be.
        #expect(after?.moveProgress == 0)
        #expect(after?.state != .moving)
        #expect(after?.downloadDirectory == destination.path)
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("payload/file.bin").path
        ))
        await session.shutdown()
    }

    /// Change the download directory in the middle of an active transfer: the
    /// engine must move the partial content, remap storage, and finish the
    /// download in the new location with intact data.
    @Test(.timeLimit(.minutes(2)))
    func movesContentMidDownloadAndCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("move-\(UUID().uuidString)")
        let seedDir = root.appendingPathComponent("seed")
        let leechDirA = root.appendingPathComponent("leech-a")
        let leechDirB = root.appendingPathComponent("leech-b")
        let contentDir = seedDir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDirB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<600_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try payload.write(to: contentDir.appendingPathComponent("file.bin"))
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: contentDir, pieceLength: 32 * 1024)

        let port = UInt16.random(in: 20000...60000)
        let seeder = TorrentSession(configuration: .init(downloadDirectory: seedDir, listenPort: port, enableDHT: false))
        _ = try await seeder.startListening()
        _ = try await seeder.addTorrent(fileData: torrentData)

        // Throttle so the transfer is still in flight when we move.
        let leecher = TorrentSession(configuration: .init(
            downloadDirectory: leechDirA, listenPort: 0,
            downloadRateLimit: 150 * 1024, enableDHT: false
        ))
        let hash = try await leecher.addTorrent(fileData: torrentData)
        try await leecher.addPeers([PeerAddress(host: "127.0.0.1", port: port)], to: hash)

        // Wait until some data has arrived, then move.
        var sawProgress = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if let snap = await leecher.snapshots().first, snap.completedLength > 0 {
                sawProgress = true
                break
            }
        }
        #expect(sawProgress)
        try await leecher.setDownloadDirectory(leechDirB, for: hash)

        let moved = try #require(await leecher.snapshots().first)
        #expect(moved.downloadDirectory == leechDirB.standardizedFileURL.path)

        var completed = false
        for _ in 0..<600 {
            try await Task.sleep(for: .milliseconds(100))
            if let snap = await leecher.snapshots().first, snap.state == .seeding {
                completed = true
                break
            }
        }
        #expect(completed)

        let movedFile = leechDirB.appendingPathComponent("payload/file.bin")
        #expect(try Data(contentsOf: movedFile) == payload)
        #expect(!FileManager.default.fileExists(atPath: leechDirA.appendingPathComponent("payload").path))

        await leecher.shutdown()
        await seeder.shutdown()
    }

    /// Per-torrent sequential overrides survive restarts, and the global
    /// setting only affects new torrents.
    @Test(.timeLimit(.minutes(1)))
    func sequentialOverridePersistsAcrossRestore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seq-\(UUID().uuidString)")
        let downloadDir = root.appendingPathComponent("dl")
        let stateDir = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let contentDir = root.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        try Data((0..<50_000).map { UInt8($0 % 251) }).write(to: contentDir.appendingPathComponent("f.bin"))
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: contentDir, pieceLength: 16 * 1024)

        // Global default is non-sequential; override this torrent to sequential.
        let session1 = TorrentSession(configuration: .init(
            downloadDirectory: downloadDir, listenPort: 0,
            sequentialDownload: false, stateDirectory: stateDir, enableDHT: false
        ))
        let hash = try await session1.addTorrent(fileData: torrentData)
        #expect(try #require(await session1.snapshots().first).sequential == false)
        try await session1.setSequential(true, for: hash)
        #expect(try #require(await session1.snapshots().first).sequential == true)
        await session1.shutdown()

        // The override must survive a restart.
        let session2 = TorrentSession(configuration: .init(
            downloadDirectory: downloadDir, listenPort: 0,
            sequentialDownload: false, stateDirectory: stateDir, enableDHT: false
        ))
        await session2.restore()
        let restored = try #require(await session2.snapshots().first)
        #expect(restored.infoHash == hash)
        #expect(restored.sequential == true)

        // Changing the global default must not touch the existing torrent.
        await session2.setSequentialDownload(false)
        #expect(try #require(await session2.snapshots().first).sequential == true)
        await session2.shutdown()
    }

    /// Changing an unresolved magnet's directory/order applies once metadata
    /// arrives (no files exist yet, so nothing moves).
    @Test(.timeLimit(.minutes(2)))
    func magnetSettingsCarryOverAfterResolution() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("magset-\(UUID().uuidString)")
        let seedDir = root.appendingPathComponent("seed")
        let leechDirA = root.appendingPathComponent("leech-a")
        let leechDirB = root.appendingPathComponent("leech-b")
        let contentDir = seedDir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDirB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<200_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try payload.write(to: contentDir.appendingPathComponent("file.bin"))
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: contentDir, pieceLength: 32 * 1024)
        let infoHash = try TorrentMetaInfo(torrentFileData: torrentData).info.infoHash

        let port = UInt16.random(in: 20000...60000)
        let seeder = TorrentSession(configuration: .init(downloadDirectory: seedDir, listenPort: port, enableDHT: false))
        _ = try await seeder.startListening()
        _ = try await seeder.addTorrent(fileData: torrentData)

        let leecher = TorrentSession(configuration: .init(
            downloadDirectory: leechDirA, listenPort: 0, enableDHT: false
        ))
        let hash = try await leecher.addMagnet("magnet:?xt=urn:btih:\(infoHash.hexString)")
        // Adjust settings while metadata is still unresolved.
        try await leecher.setDownloadDirectory(leechDirB, for: hash)
        try await leecher.setSequential(true, for: hash)
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
        let final = try #require(await leecher.snapshots().first)
        #expect(final.sequential == true)
        #expect(final.downloadDirectory == leechDirB.path)
        #expect(try Data(contentsOf: leechDirB.appendingPathComponent("payload/file.bin")) == payload)

        await leecher.shutdown()
        await seeder.shutdown()
    }
}

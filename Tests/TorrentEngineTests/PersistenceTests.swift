import Foundation
import Testing
@testable import TorrentEngine

@Suite struct PersistenceStoreTests {
    @Test func assembledTorrentDataPreservesInfoHash() throws {
        let original = try TorrentMetaInfo(torrentFileData: Bencode.encode(.dictionary([
            ("announce", .string("udp://t.example:6969/announce")),
            ("info", .dictionary([
                ("length", .integer(5)),
                ("name", .string("hello")),
                ("piece length", .integer(16384)),
                ("pieces", .string(Data(repeating: 0x61, count: 20))),
            ])),
        ])))
        let tiers = [["udp://t.example:6969/announce"], ["http://b.example/announce"]]
        let assembled = TorrentMetaInfo.assembleTorrentData(
            infoDictData: original.info.rawData, announceTiers: tiers
        )
        let parsed = try TorrentMetaInfo(torrentFileData: assembled)
        #expect(parsed.info.infoHash == original.info.infoHash)
        #expect(parsed.announceTiers == tiers)
    }

    @Test func savesAndRestoresResumeData() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("persist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = PersistenceStore(baseURL: base)
        let hash = InfoHash(data: Data(repeating: 7, count: 20))!

        store.saveTorrentData(Data("dummy".utf8), for: hash)
        let resume = ResumeData(
            infoHashHex: hash.hexString,
            bitfieldBase64: Data([0xF0]).base64EncodedString(),
            downloadDirectory: "/tmp/x",
            uploaded: 10, downloaded: 20, paused: true,
            addedAt: 123, fileStamps: ["a.bin": 456]
        )
        store.saveResume(resume, for: hash)

        let loaded = store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.torrentData == Data("dummy".utf8))
        #expect(loaded.first?.resume?.uploaded == 10)
        #expect(loaded.first?.resume?.paused == true)
        #expect(loaded.first?.resume?.fileStamps == ["a.bin": 456])

        store.remove(for: hash)
        #expect(store.loadAll().isEmpty)
    }
}

@Suite struct ResumeE2ETests {
    /// Complete a download with persistence on, then restore into a fresh
    /// session: it must come back seeding instantly (trusted bitfield). Then
    /// tamper with a file and restore again: it must detect and re-check.
    @Test(.timeLimit(.minutes(3)))
    func restoreAfterCompletionAndAfterTampering() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-\(UUID().uuidString)")
        let seedDir = root.appendingPathComponent("seed")
        let leechDir = root.appendingPathComponent("leech")
        let stateDir = root.appendingPathComponent("state")
        let contentDir = seedDir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<300_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try payload.write(to: contentDir.appendingPathComponent("file.bin"))
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: contentDir, pieceLength: 32 * 1024)

        let port = UInt16.random(in: 20000...60000)
        let seeder = TorrentSession(configuration: .init(downloadDirectory: seedDir, listenPort: port))
        _ = try await seeder.startListening()
        _ = try await seeder.addTorrent(fileData: torrentData)

        // Session 1: download with persistence.
        let leecher1 = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0, stateDirectory: stateDir
        ))
        let hash = try await leecher1.addTorrent(fileData: torrentData)
        try await leecher1.addPeers([PeerAddress(host: "127.0.0.1", port: port)], to: hash)
        var done = false
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(100))
            if let snap = await leecher1.snapshots().first, snap.state == .seeding {
                done = true
                break
            }
        }
        #expect(done)
        await leecher1.shutdown()

        // Session 2: restore — must trust resume data and be complete at once.
        let leecher2 = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0, stateDirectory: stateDir
        ))
        await leecher2.restore()
        let restored = try #require(await leecher2.snapshots().first)
        #expect(restored.state == .seeding)
        #expect(restored.completedLength == 300_000)
        #expect(restored.infoHash == hash)
        await leecher2.shutdown()

        // Tamper: flip bytes mid-file. Restore must fall back to re-checking
        // and find the damaged piece missing.
        let filePath = leechDir.appendingPathComponent("payload/file.bin")
        let handle = try FileHandle(forWritingTo: filePath)
        try handle.seek(toOffset: 100_000)
        try handle.write(contentsOf: Data(repeating: 0xEE, count: 100))
        try handle.close()

        let leecher3 = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0, stateDirectory: stateDir
        ))
        await leecher3.restore()
        let damaged = try #require(await leecher3.snapshots().first)
        #expect(damaged.state == .downloading)
        #expect(damaged.completedLength < 300_000)
        await leecher3.shutdown()
        await seeder.shutdown()
    }

    @Test(.timeLimit(.minutes(2)))
    func pauseStopsTransferAndResumeCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-\(UUID().uuidString)")
        let seedDir = root.appendingPathComponent("seed")
        let leechDir = root.appendingPathComponent("leech")
        let contentDir = seedDir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<300_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try payload.write(to: contentDir.appendingPathComponent("file.bin"))
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: contentDir, pieceLength: 32 * 1024)

        let port = UInt16.random(in: 20000...60000)
        let seeder = TorrentSession(configuration: .init(downloadDirectory: seedDir, listenPort: port))
        _ = try await seeder.startListening()
        _ = try await seeder.addTorrent(fileData: torrentData)

        let leecher = TorrentSession(configuration: .init(downloadDirectory: leechDir, listenPort: 0))
        let hash = try await leecher.addTorrent(fileData: torrentData)

        // Pause before introducing the peer: nothing should transfer.
        try await leecher.pauseTorrent(hash)
        try await leecher.addPeers([PeerAddress(host: "127.0.0.1", port: port)], to: hash)
        try await Task.sleep(for: .seconds(1))
        let pausedSnap = try #require(await leecher.snapshots().first)
        #expect(pausedSnap.state == .paused)
        #expect(pausedSnap.completedLength == 0)

        // Resume: it should finish.
        try await leecher.resumeTorrent(hash)
        var done = false
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(100))
            if let snap = await leecher.snapshots().first, snap.state == .seeding {
                done = true
                break
            }
        }
        #expect(done)
        await leecher.shutdown()
        await seeder.shutdown()
    }

    @Test(.timeLimit(.minutes(2)))
    func downloadRateLimitIsRespected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ratelimit-\(UUID().uuidString)")
        let seedDir = root.appendingPathComponent("seed")
        let leechDir = root.appendingPathComponent("leech")
        let contentDir = seedDir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<600_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try payload.write(to: contentDir.appendingPathComponent("file.bin"))
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: contentDir, pieceLength: 32 * 1024)

        let port = UInt16.random(in: 20000...60000)
        let seeder = TorrentSession(configuration: .init(downloadDirectory: seedDir, listenPort: port))
        _ = try await seeder.startListening()
        _ = try await seeder.addTorrent(fileData: torrentData)

        // 600 KB at 200 KiB/s → ≥ ~2s even after the 1s burst allowance.
        let leecher = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0, downloadRateLimit: 200 * 1024
        ))
        let hash = try await leecher.addTorrent(fileData: torrentData)
        let start = ContinuousClock.now
        try await leecher.addPeers([PeerAddress(host: "127.0.0.1", port: port)], to: hash)
        var done = false
        for _ in 0..<600 {
            try await Task.sleep(for: .milliseconds(100))
            if let snap = await leecher.snapshots().first, snap.state == .seeding {
                done = true
                break
            }
        }
        let elapsed = start.duration(to: .now)
        #expect(done)
        #expect(elapsed >= .seconds(1.5), "finished too fast for the cap: \(elapsed)")
        await leecher.shutdown()
        await seeder.shutdown()
    }
}

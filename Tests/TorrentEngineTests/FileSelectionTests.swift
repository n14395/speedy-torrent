import Foundation
import Testing
@testable import TorrentEngine

/// Multi-file synthetic info for piece-mask tests (dummy hashes).
private func makeMultiFileInfo(lengths: [Int], pieceLength: Int = 16384) throws -> TorrentInfo {
    let total = lengths.reduce(0, +)
    let pieceCount = (total + pieceLength - 1) / pieceLength
    let files = BValue.list(lengths.enumerated().map { index, length in
        .dictionary([
            ("length", .integer(length)),
            ("path", .list([.string("f\(index).bin")])),
        ])
    })
    let encoded = Bencode.encode(.dictionary([
        ("files", files),
        ("name", .string("multi")),
        ("piece length", .integer(pieceLength)),
        ("pieces", .string(Data(repeating: 0xCD, count: 20 * pieceCount))),
    ]))
    return try TorrentInfo(bencodedData: encoded)
}

@Suite struct WantedPieceMaskTests {
    @Test func masksPiecesToWantedFilesIncludingBoundaries() throws {
        // A: [0, 40000) B: [40000, 90000) C: [90000, 130000), 16 KiB pieces.
        let info = try makeMultiFileInfo(lengths: [40_000, 50_000, 40_000])
        let manager = PieceManager(info: info, sequential: true, wantedFiles: [1])
        let peer = fullBitfield(info.pieceCount)

        // File B overlaps pieces 2...5 (boundary pieces included).
        for piece in 0..<info.pieceCount {
            #expect(manager.isWanted(piece) == (2...5).contains(piece), "piece \(piece)")
        }
        #expect(manager.wantedBytes == 4 * 16384)

        // Sequential picking must start at the first wanted piece, and only
        // ever serve wanted pieces.
        var excluding = Set<BlockRef>()
        var pickedPieces = Set<Int>()
        while let ref = manager.nextRequest(peerHas: peer, excluding: excluding) {
            if excluding.contains(ref) { break }
            manager.markRequested(ref)
            excluding.insert(ref)
            pickedPieces.insert(ref.index)
        }
        #expect(pickedPieces == Set(2...5))

        // Completing just those pieces completes the wanted selection.
        for piece in 2...5 {
            manager.pieceVerified(piece)
        }
        #expect(manager.isWantedComplete)
        #expect(!manager.isComplete)
        #expect(manager.completedWantedBytes == manager.wantedBytes)
    }

    @Test func selectionChangesReviveDownloading() throws {
        let info = try makeMultiFileInfo(lengths: [40_000, 50_000, 40_000])
        let manager = PieceManager(info: info, sequential: true, wantedFiles: [1])
        for piece in 2...5 {
            manager.pieceVerified(piece)
        }
        #expect(manager.isWantedComplete)

        manager.setWantedFiles([0, 1, 2])
        #expect(!manager.isWantedComplete)
        let next = manager.nextRequest(peerHas: fullBitfield(info.pieceCount), excluding: [])
        #expect(next?.index == 0)

        // Empty selections are rejected.
        manager.setWantedFiles([])
        #expect(manager.wantedFiles == [0, 1, 2])
    }

    @Test func interestTracksWantedPieces() throws {
        let info = try makeMultiFileInfo(lengths: [40_000, 50_000, 40_000])
        let manager = PieceManager(info: info, wantedFiles: [0])
        // Peer only has the last piece (file C territory): not useful.
        var peer = Bitfield(count: info.pieceCount)
        peer[info.pieceCount - 1] = true
        #expect(!manager.peerHasUsefulPiece(peer))
        peer[0] = true
        #expect(manager.peerHasUsefulPiece(peer))
    }
}

@Suite struct FileSelectionE2ETests {
    /// Download only the middle file of three, verify it byte-for-byte, then
    /// expand the selection to everything and verify the rest arrives.
    @Test(.timeLimit(.minutes(2)))
    func selectiveDownloadThenExpandSelection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("filesel-\(UUID().uuidString)")
        let seedDir = root.appendingPathComponent("seed")
        let leechDir = root.appendingPathComponent("leech")
        let contentDir = seedDir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var generator = SystemRandomNumberGenerator()
        let fileContents = (0..<3).map { _ in
            Data((0..<150_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        }
        // Names chosen so the builder's sorted order matches indices 0,1,2.
        for (index, data) in fileContents.enumerated() {
            try data.write(to: contentDir.appendingPathComponent("f\(index).bin"))
        }
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: contentDir, pieceLength: 32 * 1024)
        let meta = try TorrentMetaInfo(torrentFileData: torrentData)
        #expect(meta.info.files.map(\.path) == [["f0.bin"], ["f1.bin"], ["f2.bin"]])

        let port = UInt16.random(in: 20000...60000)
        let seeder = TorrentSession(configuration: .init(downloadDirectory: seedDir, listenPort: port, enableDHT: false))
        _ = try await seeder.startListening()
        _ = try await seeder.addTorrent(fileData: torrentData)

        let leecher = TorrentSession(configuration: .init(downloadDirectory: leechDir, listenPort: 0, enableDHT: false))
        let hash = try await leecher.addTorrent(fileData: torrentData, wantedFiles: [1])
        try await leecher.addPeers([PeerAddress(host: "127.0.0.1", port: port)], to: hash)

        // Phase 1: only f1 wanted.
        var partialDone = false
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(100))
            if let snap = await leecher.snapshots().first, snap.state == .seeding {
                partialDone = true
                break
            }
        }
        #expect(partialDone)
        let partial = try #require(await leecher.snapshots().first)
        #expect(partial.wantedLength < partial.totalLength)
        #expect(partial.completedLength == partial.wantedLength)
        // Far less than the full payload crossed the wire.
        #expect(partial.downloadedTotal < 300_000)
        #expect(try Data(contentsOf: leechDir.appendingPathComponent("payload/f1.bin")) == fileContents[1])

        // The wanted file is finalized; the unwanted ones stay as .part.
        let fileManager = FileManager.default
        #expect(!fileManager.fileExists(atPath: leechDir.appendingPathComponent("payload/f1.bin.part").path))
        #expect(fileManager.fileExists(atPath: leechDir.appendingPathComponent("payload/f0.bin.part").path))
        #expect(!fileManager.fileExists(atPath: leechDir.appendingPathComponent("payload/f0.bin").path))

        let statuses = try await leecher.fileStatuses(for: hash)
        #expect(statuses.map(\.wanted) == [false, true, false])
        // Per-file progress: the finished wanted file reads as 100%.
        #expect(statuses[1].completedLength == statuses[1].length)
        #expect(statuses[1].progress == 1)

        // Phase 2: want everything.
        try await leecher.setWantedFiles([0, 1, 2], for: hash)
        var fullDone = false
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(100))
            if let snap = await leecher.snapshots().first,
               snap.state == .seeding, snap.completedLength == snap.totalLength {
                fullDone = true
                break
            }
        }
        #expect(fullDone)
        for (index, data) in fileContents.enumerated() {
            #expect(try Data(contentsOf: leechDir.appendingPathComponent("payload/f\(index).bin")) == data, "f\(index)")
        }
        // Every file now reports fully complete.
        let finalStatuses = try await leecher.fileStatuses(for: hash)
        #expect(finalStatuses.allSatisfy { $0.completedLength == $0.length })

        await leecher.shutdown()
        await seeder.shutdown()
    }

    /// Files that no wanted piece overlaps are never written to disk (not even
    /// an empty `.part`), and appear only if the file is later selected.
    @Test(.timeLimit(.minutes(1)))
    func unwantedNonBorderingFilesAreNotCreated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skip-\(UUID().uuidString)")
        let leechDir = root.appendingPathComponent("leech")
        let contentDir = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Four piece-aligned files (32 KiB each, 16 KiB pieces) → no file
        // shares a piece with its neighbour, so unwanted files are fully skipped.
        for index in 0..<4 {
            try Data(repeating: UInt8(index + 1), count: 32 * 1024)
                .write(to: contentDir.appendingPathComponent("f\(index).bin"))
        }
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: contentDir, pieceLength: 16 * 1024)

        let session = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0, enableDHT: false
        ))
        let hash = try await session.addTorrent(fileData: torrentData, wantedFiles: [0])

        let fileManager = FileManager.default
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: leechDir.appendingPathComponent("payload/\(name)").path)
        }

        // Only the wanted file is allocated; the rest leave no trace.
        #expect(exists("f0.bin.part"))
        for index in 1...3 {
            #expect(!exists("f\(index).bin.part"), "f\(index).bin.part should not exist")
            #expect(!exists("f\(index).bin"), "f\(index).bin should not exist")
        }

        // Selecting more files allocates them on demand.
        try await session.setWantedFiles([0, 2], for: hash)
        #expect(exists("f2.bin.part"))
        #expect(!exists("f1.bin.part"))
        #expect(!exists("f3.bin.part"))

        await session.shutdown()
    }

    /// The wanted-file selection survives a session restart.
    @Test(.timeLimit(.minutes(1)))
    func selectionPersistsAcrossRestore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("filesel-persist-\(UUID().uuidString)")
        let downloadDir = root.appendingPathComponent("dl")
        let stateDir = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let contentDir = root.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        for index in 0..<3 {
            try Data(repeating: UInt8(index), count: 50_000)
                .write(to: contentDir.appendingPathComponent("f\(index).bin"))
        }
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: contentDir, pieceLength: 16 * 1024)

        let session1 = TorrentSession(configuration: .init(
            downloadDirectory: downloadDir, listenPort: 0, stateDirectory: stateDir, enableDHT: false
        ))
        let hash = try await session1.addTorrent(fileData: torrentData, wantedFiles: [0, 2])
        #expect(try await session1.fileStatuses(for: hash).map(\.wanted) == [true, false, true])
        await session1.shutdown()

        let session2 = TorrentSession(configuration: .init(
            downloadDirectory: downloadDir, listenPort: 0, stateDirectory: stateDir, enableDHT: false
        ))
        await session2.restore()
        #expect(try await session2.fileStatuses(for: hash).map(\.wanted) == [true, false, true])
        await session2.shutdown()
    }
}

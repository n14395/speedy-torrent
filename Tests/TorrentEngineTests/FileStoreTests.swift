// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit
import Testing
@testable import TorrentEngine

@Suite struct FileStoreTests {
    /// Builds real content on disk, a real torrent for it, then exercises the
    /// store's piece/file mapping against a parallel in-memory payload.
    @Test func writesAndReadsAcrossFileBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("filestore-\(UUID().uuidString)")
        let contentDir = root.appendingPathComponent("content")
        try FileManager.default.createDirectory(
            at: contentDir.appendingPathComponent("sub"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        var generator = SystemRandomNumberGenerator()
        let fileA = Data((0..<50_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let fileB = Data((0..<30_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try fileA.write(to: contentDir.appendingPathComponent("a.bin"))
        try fileB.write(to: contentDir.appendingPathComponent("sub/b.bin"))
        let payload = fileA + fileB

        let pieceLength = 32 * 1024
        let torrent = try TorrentBuilder.makeTorrentData(contentsOf: contentDir, pieceLength: pieceLength)
        let info = try TorrentMetaInfo(torrentFileData: torrent).info

        // Reconstruct into a fresh directory from the in-memory payload.
        let outDir = root.appendingPathComponent("out")
        let store = FileStore(info: info, downloadDirectory: outDir)
        let existing = try await store.preallocate()
        #expect(!existing)

        for index in 0..<info.pieceCount {
            let start = index * pieceLength
            let end = min(start + pieceLength, payload.count)
            try await store.writePiece(payload[start..<end], at: index)
        }

        // Before finalizing, in-progress data lives in .part files.
        let fileManager = FileManager.default
        #expect(fileManager.fileExists(atPath: outDir.appendingPathComponent("content/a.bin.part").path))
        #expect(!fileManager.fileExists(atPath: outDir.appendingPathComponent("content/a.bin").path))

        // readBlock spanning the a.bin/b.bin boundary (at offset 50 000).
        let boundary = try await store.readBlock(index: 1, begin: 16_000, length: 4_000)
        #expect(boundary == payload[48_768..<52_768])

        // Finalize everything; .part files are renamed to their final names.
        await store.reconcile(have: fullBitfield(info.pieceCount))
        #expect(try Data(contentsOf: outDir.appendingPathComponent("content/a.bin")) == fileA)
        #expect(try Data(contentsOf: outDir.appendingPathComponent("content/sub/b.bin")) == fileB)
        #expect(!fileManager.fileExists(atPath: outDir.appendingPathComponent("content/a.bin.part").path))

        // Verification over the reconstructed data must pass in full.
        let verified = await store.verifyAllPieces()
        #expect(verified.isFull)
        await store.close()

        // A store pointed at the *original* (finished) content verifies fully
        // and treats the files as already complete.
        let seedStore = FileStore(info: info, downloadDirectory: root)
        let hadData = try await seedStore.preallocate()
        #expect(hadData)
        let seedVerified = await seedStore.verifyAllPieces()
        #expect(seedVerified.isFull)
        await seedStore.close()
    }

    @Test func preallocateCreatesPartFileOfCorrectSize() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prealloc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let info = try makeTestInfo(pieceCount: 3, pieceLength: 16384, lastPieceSize: 1000)
        let store = FileStore(info: info, downloadDirectory: root)
        _ = try await store.preallocate()
        await store.close()

        // Incomplete single-file torrent → data lives at "<name>.part".
        let partPath = root.appendingPathComponent("test.part").path
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("test").path))
        let attributes = try FileManager.default.attributesOfItem(atPath: partPath)
        #expect(attributes[.size] as? Int64 == Int64(info.totalLength))
    }

    /// Each file is renamed to its final name only once *all* of its pieces
    /// are present, even when pieces straddle file boundaries.
    @Test func finalizesFilesIndividuallyAsTheyComplete() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("finalize-\(UUID().uuidString)")
        let contentDir = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var generator = SystemRandomNumberGenerator()
        // Three 40 KB files, 32 KiB pieces → pieces cross every boundary.
        let files = (0..<3).map { _ in
            Data((0..<40_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        }
        for (index, data) in files.enumerated() {
            try data.write(to: contentDir.appendingPathComponent("f\(index).bin"))
        }
        let payload = files.reduce(Data(), +)
        let pieceLength = 32 * 1024
        let torrent = try TorrentBuilder.makeTorrentData(contentsOf: contentDir, pieceLength: pieceLength)
        let info = try TorrentMetaInfo(torrentFileData: torrent).info

        let outDir = root.appendingPathComponent("out")
        let store = FileStore(info: info, downloadDirectory: outDir)
        _ = try await store.preallocate()

        let fileManager = FileManager.default
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: outDir.appendingPathComponent("payload/\(name)").path)
        }

        var have = Bitfield(count: info.pieceCount)
        func writeAndFinalize(_ piece: Int) async throws {
            let start = piece * pieceLength
            let end = min(start + pieceLength, payload.count)
            try await store.writePiece(payload[start..<end], at: piece)
            have[piece] = true
            await store.finalizeCompletedFiles(after: piece, have: have)
        }

        // f0 spans pieces 0-1; completing them finalizes only f0.
        try await writeAndFinalize(0)
        try await writeAndFinalize(1)
        #expect(exists("f0.bin"))
        #expect(!exists("f0.bin.part"))
        #expect(exists("f1.bin.part") && !exists("f1.bin"))
        #expect(exists("f2.bin.part") && !exists("f2.bin"))

        // Piece 2 completes f1 (shares piece 1 with f0, piece 2 with f2).
        try await writeAndFinalize(2)
        #expect(exists("f1.bin") && !exists("f1.bin.part"))
        #expect(exists("f2.bin.part") && !exists("f2.bin"))

        // Final piece completes f2.
        try await writeAndFinalize(3)
        #expect(exists("f2.bin") && !exists("f2.bin.part"))

        await store.close()
        for (index, data) in files.enumerated() {
            #expect(try Data(contentsOf: outDir.appendingPathComponent("payload/f\(index).bin")) == data, "f\(index)")
        }
    }
}

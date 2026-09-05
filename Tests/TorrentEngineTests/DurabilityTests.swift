import Foundation
import CryptoKit
import Testing
@testable import TorrentEngine

/// Fast resume trusts its saved bitfield whenever the file stamps still match.
/// That contract only holds if the data behind the bitfield actually reached
/// the device — a write that has only reached the page cache already updated
/// the stamp, so a resume record written before a flush claimed pieces an
/// unclean quit would discard.
@Suite struct DurabilityTests {
    private func makeTorrent(pieceLength: Int, pieces: Int) throws -> (TorrentInfo, [Data]) {
        var blocks: [Data] = []
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<pieces {
            blocks.append(Data((0..<pieceLength).map { _ in
                UInt8.random(in: 0...255, using: &generator)
            }))
        }
        let payload = blocks.reduce(Data(), +)
        var hashes = Data()
        for block in blocks { hashes.append(sha1(block)) }
        let info = BValue.dictionary([
            ("length", .integer(payload.count)),
            ("name", .string("payload.bin")),
            ("piece length", .integer(pieceLength)),
            ("pieces", .string(hashes)),
        ])
        return (try TorrentInfo(bencodedData: Bencode.encode(info)), blocks)
    }

    private func sha1(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }

    @Test func synchronizeReportsSuccessAndClearsAfterWrites() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("durability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let (info, blocks) = try makeTorrent(pieceLength: 16_384, pieces: 4)
        let store = FileStore(info: info, downloadDirectory: root)
        _ = try await store.preallocate()

        // Nothing written yet: flushing is a no-op that still succeeds.
        #expect(await store.synchronize())

        for (index, block) in blocks.enumerated() {
            try await store.writePiece(block, at: index)
        }
        #expect(await store.synchronize())
        // Second call has nothing left to flush.
        #expect(await store.synchronize())

        // Everything written must read back and verify.
        let have = await store.verifyAllPieces()
        #expect(have.isFull)
    }

    /// Closing must flush too — `finalize` closes a handle to rename the
    /// `.part` file, and a rename must not outrun the data behind it.
    @Test func dataSurvivesCloseAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("durability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let (info, blocks) = try makeTorrent(pieceLength: 16_384, pieces: 3)
        let writer = FileStore(info: info, downloadDirectory: root)
        _ = try await writer.preallocate()
        for (index, block) in blocks.enumerated() {
            try await writer.writePiece(block, at: index)
        }
        var have = Bitfield(count: info.pieceCount)
        for index in 0..<info.pieceCount { have[index] = true }
        await writer.reconcile(have: have)
        await writer.close()

        let reader = FileStore(info: info, downloadDirectory: root)
        _ = try await reader.preallocate()
        #expect(await reader.verifyAllPieces().isFull)
        await reader.close()
    }
}

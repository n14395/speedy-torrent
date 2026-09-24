// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TorrentEngine

@Suite struct RecheckTests {
    /// A completed torrent whose data is corrupted on disk must, after a
    /// re-check, report less-than-complete and go back to downloading.
    @Test(.timeLimit(.minutes(1)))
    func verifyDataDetectsCorruption() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recheck-\(UUID().uuidString)")
        let content = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var gen = SystemRandomNumberGenerator()
        let payload = Data((0..<200_000).map { _ in UInt8.random(in: 0...255, using: &gen) })
        let fileURL = content.appendingPathComponent("file.bin")
        try payload.write(to: fileURL)
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: content, pieceLength: 32 * 1024)
        let hash = try TorrentMetaInfo(torrentFileData: torrentData).info.infoHash

        // Adding with the data already present verifies it as complete.
        let session = TorrentSession(configuration: .init(
            downloadDirectory: root, listenPort: 0, enableDHT: false
        ))
        _ = try await session.addTorrent(fileData: torrentData, downloadDirectory: root)

        var seeding = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if await session.snapshots().first?.state == .seeding { seeding = true; break }
        }
        #expect(seeding)
        #expect(await session.snapshots().first?.completedLength == Int64(payload.count))

        // Corrupt the first pieces in place (same inode, so the store sees it).
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0xFF, count: 64 * 1024))
        try handle.close()

        try await session.recheckTorrent(hash)

        // recheck runs to completion before returning: state is settled.
        let snapshot = await session.snapshots().first
        #expect(snapshot?.state == .downloading)
        let completed = snapshot?.completedLength ?? .max
        #expect(completed < Int64(payload.count))

        await session.shutdown()
    }
}

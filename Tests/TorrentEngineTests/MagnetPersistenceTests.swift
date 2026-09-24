// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TorrentEngine

@Suite struct MagnetPersistenceTests {
    /// A magnet still fetching metadata must survive a restart — with its
    /// trackers, name, download directory and queue position intact —
    /// instead of silently disappearing from the list.
    @Test(.timeLimit(.minutes(1)))
    func pendingMagnetSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("magnet-persist-\(UUID().uuidString)")
        let downloadDir = root.appendingPathComponent("downloads")
        let stateDir = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hex = "0123456789abcdef0123456789abcdef01234567"
        let hash = try #require(InfoHash(hex: hex))
        let magnet = "magnet:?xt=urn:btih:\(hex)&dn=Pending+Payload"
            + "&tr=udp%3A%2F%2Ftracker.example%3A6969"

        func makeSession() -> TorrentSession {
            TorrentSession(configuration: .init(
                downloadDirectory: downloadDir, listenPort: 0,
                stateDirectory: stateDir, enableDHT: false
            ))
        }

        let session = makeSession()
        _ = try await session.addMagnet(magnet)
        let before = await session.snapshots()
        #expect(before.count == 1)
        #expect(before.first?.state == .fetchingMetadata)
        #expect(before.first?.name == "Pending Payload")
        await session.shutdown()

        // A fresh session restores it, still fetching.
        let restored = makeSession()
        await restored.restore()
        let after = await restored.snapshots()
        #expect(after.count == 1)
        #expect(after.first?.infoHash == hash)
        #expect(after.first?.state == .fetchingMetadata)
        #expect(after.first?.name == "Pending Payload")
        #expect(after.first?.downloadDirectory == downloadDir.path)
        // The added date is preserved, not reset to "now".
        #expect(after.first?.addedAt == before.first?.addedAt)

        // Removing it clears the saved record for good.
        try await restored.removeTorrent(hash)
        await restored.shutdown()

        let final = makeSession()
        await final.restore()
        #expect(await final.snapshots().isEmpty)
        await final.shutdown()
    }

    /// Magnets and torrents share one queue order across a restart.
    @Test(.timeLimit(.minutes(1)))
    func magnetsKeepQueuePositionAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("magnet-order-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src")
        let downloadDir = root.appendingPathComponent("downloads")
        let stateDir = root.appendingPathComponent("state")
        let content = src.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 7, count: 64 * 1024)
            .write(to: content.appendingPathComponent("file.bin"))
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: content, pieceLength: 32 * 1024)
        let torrentHash = try TorrentMetaInfo(torrentFileData: torrentData).info.infoHash
        let magnetHex = "89abcdef0123456789abcdef0123456789abcdef"
        let magnetHash = try #require(InfoHash(hex: magnetHex))

        func makeSession() -> TorrentSession {
            TorrentSession(configuration: .init(
                downloadDirectory: downloadDir, listenPort: 0,
                stateDirectory: stateDir, enableDHT: false
            ))
        }

        let session = makeSession()
        _ = try await session.addMagnet("magnet:?xt=urn:btih:\(magnetHex)&dn=First")
        _ = try await session.addTorrent(fileData: torrentData, downloadDirectory: downloadDir)
        #expect(await session.snapshots().map(\.infoHash) == [magnetHash, torrentHash])
        await session.shutdown()

        let restored = makeSession()
        await restored.restore()
        #expect(await restored.snapshots().map(\.infoHash) == [magnetHash, torrentHash])
        await restored.shutdown()
    }
}

// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TorrentEngine

@Suite struct QueueTests {
    /// Builds a torrent whose data lives in `dir` but is added to a *different*
    /// session, so it is incomplete and wants to download.
    private func makeTorrent(_ dir: URL, seed: UInt8) throws -> Data {
        let content = dir.appendingPathComponent("payload-\(seed)")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data(repeating: seed, count: 128 * 1024)
            .write(to: content.appendingPathComponent("file.bin"))
        return try TorrentBuilder.makeTorrentData(contentsOf: content, pieceLength: 32 * 1024)
    }

    @Test(.timeLimit(.minutes(1)))
    func maxActiveDownloadsQueuesExtras() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src")
        let leechDir = root.appendingPathComponent("leech")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let torrentA = try makeTorrent(src, seed: 1)
        let torrentB = try makeTorrent(src, seed: 2)
        let hashA = try TorrentMetaInfo(torrentFileData: torrentA).info.infoHash

        // No data present here, no peers — both torrents want to download.
        let session = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0, enableDHT: false, maxActiveDownloads: 1
        ))
        _ = try await session.addTorrent(fileData: torrentA, downloadDirectory: leechDir)
        _ = try await session.addTorrent(fileData: torrentB, downloadDirectory: leechDir)

        func states() async -> [TorrentState] { await session.snapshots().map(\.state) }

        // First stays active; second waits.
        #expect(await states() == [.downloading, .queued])

        // Pausing the active one promotes the queued one.
        try await session.pauseTorrent(hashA)
        #expect(await states() == [.paused, .downloading])

        // Lifting the cap runs both (resumed A regains its front-of-order slot).
        await session.setMaxActiveDownloads(nil)
        try await session.resumeTorrent(hashA)
        #expect(await states() == [.downloading, .downloading])

        await session.shutdown()
    }

    /// Moving a queued torrent to the top gives it the active slot, demoting
    /// the previous front; the order survives a session restart.
    @Test(.timeLimit(.minutes(1)))
    func reorderChangesPriorityAndPersists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reorder-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src")
        let leechDir = root.appendingPathComponent("leech")
        let stateDir = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let torrentA = try makeTorrent(src, seed: 3)
        let torrentB = try makeTorrent(src, seed: 4)
        let hashB = try TorrentMetaInfo(torrentFileData: torrentB).info.infoHash

        func makeSession() -> TorrentSession {
            TorrentSession(configuration: .init(
                downloadDirectory: leechDir, listenPort: 0, stateDirectory: stateDir,
                enableDHT: false, maxActiveDownloads: 1
            ))
        }

        let session = makeSession()
        _ = try await session.addTorrent(fileData: torrentA, downloadDirectory: leechDir)
        _ = try await session.addTorrent(fileData: torrentB, downloadDirectory: leechDir)
        #expect(await session.snapshots().map(\.state) == [.downloading, .queued])

        // B jumps the queue.
        try await session.moveTorrent(hashB, .top)
        let snaps = await session.snapshots()
        #expect(snaps.map(\.infoHash).first == hashB)
        #expect(snaps.map(\.state) == [.downloading, .queued])

        await session.shutdown()

        // A fresh session restores B first (order persisted, not added-date).
        let restored = makeSession()
        await restored.restore()
        #expect(await restored.snapshots().map(\.infoHash).first == hashB)
        await restored.shutdown()
    }
}

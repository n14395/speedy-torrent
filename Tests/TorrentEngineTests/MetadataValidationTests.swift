// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TorrentEngine

@Suite struct MetadataValidationTests {
    private func multiFileInfo(paths: [[String]]) -> BValue {
        .dictionary([
            ("files", .list(paths.map { path in
                BValue.dictionary([
                    ("length", .integer(16384)),
                    ("path", .list(path.map { BValue.string($0) })),
                ])
            })),
            ("name", .string("bundle")),
            ("piece length", .integer(16384)),
            ("pieces", .string(Data(repeating: 0x61, count: 20 * paths.count))),
        ])
    }

    /// Two entries with the same path share one file on disk and overwrite each
    /// other at different global offsets.
    @Test func rejectsDuplicateFilePaths() {
        let info = multiFileInfo(paths: [["a", "dup.bin"], ["a", "dup.bin"]])
        #expect(throws: MetaInfoError.invalidField("duplicate file path")) {
            try TorrentInfo(bencodedData: Bencode.encode(info))
        }
    }

    /// Same leaf name in different directories is legitimate and must survive.
    @Test func acceptsSameNameInDifferentDirectories() throws {
        let info = multiFileInfo(paths: [["a", "same.bin"], ["b", "same.bin"]])
        let parsed = try TorrentInfo(bencodedData: Bencode.encode(info))
        #expect(parsed.files.count == 2)
    }
}

@Suite struct UnreadableRestoreTests {
    /// A persisted torrent whose metadata no longer parses must surface as a
    /// failed row the user can see and remove — not disappear from the list.
    @Test(.timeLimit(.minutes(1)))
    func unparseableTorrentSurfacesAsFailed() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("unreadable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = PersistenceStore(baseURL: base)
        let hash = InfoHash(data: Data(repeating: 9, count: 20))!
        store.saveTorrentData(Data("not a torrent at all".utf8), for: hash)

        let session = TorrentSession(configuration: .init(
            downloadDirectory: base, listenPort: 0, stateDirectory: base, enableDHT: false
        ))
        await session.restore()

        let snapshot = try #require(await session.snapshots().first)
        #expect(snapshot.infoHash == hash)
        #expect(snapshot.state == .failed)
        #expect(snapshot.errorMessage != nil)

        try await session.removeTorrent(hash)
        #expect(await session.snapshots().isEmpty)
        await session.shutdown()
    }
}

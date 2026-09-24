// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TorrentEngine

/// Multi-file synthetic info for priority ordering tests (dummy hashes).
private func makePriorityInfo(lengths: [Int], pieceLength: Int = 16384) throws -> TorrentInfo {
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
        ("name", .string("priority")),
        ("piece length", .integer(pieceLength)),
        ("pieces", .string(Data(repeating: 0xCD, count: 20 * pieceCount))),
    ]))
    return try TorrentInfo(bencodedData: encoded)
}

/// Drains the manager's piece picks, one 16 KiB piece per request, in the order
/// it hands them out. Stops once every piece is in flight (before endgame
/// duplication starts repeating them).
private func pickOrder(_ manager: PieceManager, peer: Bitfield, count: Int) -> [Int] {
    var picked: [Int] = []
    var excluding = Set<BlockRef>()
    while picked.count < count, let ref = manager.nextRequest(peerHas: peer, excluding: excluding) {
        guard !excluding.contains(ref) else { break }
        manager.markRequested(ref)
        excluding.insert(ref)
        if !picked.contains(ref.index) { picked.append(ref.index) }
    }
    return picked
}

@Suite struct FilePriorityTests {
    /// Three 32 KiB files over 16 KiB pieces: file 0 → pieces 0-1,
    /// file 1 → 2-3, file 2 → 4-5. No file shares a piece with another.
    private func threeFileInfo() throws -> TorrentInfo {
        try makePriorityInfo(lengths: [32768, 32768, 32768])
    }

    @Test func highPriorityFilesAreRequestedFirst() throws {
        let info = try threeFileInfo()
        let manager = PieceManager(info: info, filePriorities: [2: .high])
        let peer = fullBitfield(info.pieceCount)
        manager.peerJoined(with: peer) // uniform availability: priority decides

        let order = pickOrder(manager, peer: peer, count: 6)
        #expect(Set(order.prefix(2)) == [4, 5], "high-priority file first, got \(order)")
        #expect(Set(order.dropFirst(2)) == [0, 1, 2, 3])
    }

    @Test func lowPriorityFilesAreRequestedLast() throws {
        let info = try threeFileInfo()
        let manager = PieceManager(info: info, filePriorities: [0: .low])
        let peer = fullBitfield(info.pieceCount)
        manager.peerJoined(with: peer)

        let order = pickOrder(manager, peer: peer, count: 6)
        #expect(Set(order.suffix(2)) == [0, 1], "low-priority file last, got \(order)")
    }

    @Test func sequentialOrderAppliesWithinAPriorityBand() throws {
        let info = try threeFileInfo()
        let manager = PieceManager(info: info, sequential: true, filePriorities: [2: .high])
        let peer = fullBitfield(info.pieceCount)

        // The high file's pieces come first, then everything else in file order.
        #expect(pickOrder(manager, peer: peer, count: 6) == [4, 5, 0, 1, 2, 3])
    }

    @Test func rarestFirstStillDecidesWithinTheBand() throws {
        let info = try threeFileInfo()
        let manager = PieceManager(info: info, filePriorities: [2: .high])
        let peer = fullBitfield(info.pieceCount)
        // Everyone has everything except one peer missing piece 5, making it
        // the rarest piece inside the high-priority file.
        manager.peerJoined(with: peer)
        var partial = peer
        partial[5] = false
        manager.peerJoined(with: partial)

        #expect(pickOrder(manager, peer: peer, count: 1) == [5])
    }

    @Test func priorityOfAnUnwantedFileIsIgnored() throws {
        let info = try threeFileInfo()
        // The high-priority file is not wanted at all: it must neither be
        // fetched nor reorder anything else.
        let manager = PieceManager(
            info: info, sequential: true, wantedFiles: [0, 2], filePriorities: [1: .high]
        )
        let peer = fullBitfield(info.pieceCount)

        #expect(pickOrder(manager, peer: peer, count: 6) == [0, 1, 4, 5])
    }

    @Test func boundaryPieceFollowsItsMostUrgentFile() throws {
        // Two 24 KiB files over 16 KiB pieces: file 0 → pieces 0-1,
        // file 1 → pieces 1-2. Piece 1 belongs to both.
        let info = try makePriorityInfo(lengths: [24576, 24576])
        let manager = PieceManager(info: info, sequential: true, filePriorities: [1: .high])
        let peer = fullBitfield(info.pieceCount)

        // The shared piece is pulled up with the high file, not left behind
        // with the normal one.
        #expect(pickOrder(manager, peer: peer, count: 3) == [1, 2, 0])
    }

    @Test func settingPriorityReordersAnInFlightTorrent() throws {
        let info = try threeFileInfo()
        let manager = PieceManager(info: info, sequential: true)
        let peer = fullBitfield(info.pieceCount)

        #expect(pickOrder(manager, peer: peer, count: 1) == [0])
        manager.setPriority(.high, for: [2])
        // Piece 0 stays in flight — already-requested blocks are never dropped
        // to honour a promotion — while every new piece now comes from the file
        // just promoted, and only then does file order resume.
        #expect(pickOrder(manager, peer: peer, count: 2) == [4, 5])
        #expect(pickOrder(manager, peer: peer, count: 1) == [1])
        #expect(manager.priority(for: 2) == .high)
        #expect(manager.priority(for: 0) == .normal)
    }

    @Test func resettingToNormalClearsTheStoredPriority() throws {
        let info = try threeFileInfo()
        let manager = PieceManager(info: info, filePriorities: [0: .low, 2: .high])
        #expect(manager.fileIndices(at: .high) == [2])
        #expect(manager.fileIndices(at: .low) == [0])

        manager.setPriority(.normal, for: [0, 2])
        #expect(manager.fileIndices(at: .high) == nil)
        #expect(manager.fileIndices(at: .low) == nil)
        #expect(manager.filePriorities.isEmpty)
    }

    @Test func prioritiesSurviveAResumeRoundTrip() throws {
        let resume = ResumeData(
            infoHashHex: String(repeating: "a", count: 40),
            bitfieldBase64: Data([0xF0]).base64EncodedString(),
            downloadDirectory: "/tmp/x",
            uploaded: 0, downloaded: 0, paused: false,
            highPriorityFiles: [2], lowPriorityFiles: [0, 1],
            addedAt: 1, fileStamps: [:]
        )
        let decoded = try JSONDecoder().decode(
            ResumeData.self, from: JSONEncoder().encode(resume)
        )
        #expect(decoded.savedFilePriorities == [0: .low, 1: .low, 2: .high])
    }

    @Test func resumeRecordsWrittenBeforePrioritiesExistedStillLoad() throws {
        let json = """
        {"version":1,"infoHashHex":"\(String(repeating: "b", count: 40))",
         "bitfieldBase64":"8A==","downloadDirectory":"/tmp/x","uploaded":0,
         "downloaded":0,"paused":false,"addedAt":1,"fileStamps":{}}
        """
        let decoded = try JSONDecoder().decode(ResumeData.self, from: Data(json.utf8))
        #expect(decoded.savedFilePriorities.isEmpty)
    }

    /// End to end: priorities chosen at add time are reported back, can be
    /// changed on a live torrent, and come back after a restart.
    @Test func sessionAppliesReportsAndRestoresPriorities() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("priority-\(UUID().uuidString)")
        let content = root.appendingPathComponent("payload")
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 40_000).write(to: content.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 40_000).write(to: content.appendingPathComponent("b.bin"))
        let torrentData = try TorrentBuilder.makeTorrentData(
            contentsOf: content, pieceLength: 16384
        )
        let meta = try TorrentMetaInfo(torrentFileData: torrentData)
        let indexOfA = meta.info.files.firstIndex { $0.path.last == "a.bin" }!
        let indexOfB = meta.info.files.firstIndex { $0.path.last == "b.bin" }!

        let configuration = TorrentSession.Configuration(
            downloadDirectory: root, listenPort: 0, stateDirectory: state, enableDHT: false
        )
        let session = TorrentSession(configuration: configuration)
        let hash = try await session.addTorrent(
            fileData: torrentData, filePriorities: [indexOfB: .high]
        )

        var statuses = try await session.fileStatuses(for: hash)
        #expect(statuses[indexOfB].priority == .high)
        #expect(statuses[indexOfA].priority == .normal)

        try await session.setFilePriority(.low, forFiles: [indexOfA], in: hash)
        statuses = try await session.fileStatuses(for: hash)
        #expect(statuses[indexOfA].priority == .low)
        await session.shutdown()

        // A fresh session over the same state directory restores both.
        let restored = TorrentSession(configuration: configuration)
        await restored.restore()
        let afterRestart = try await restored.fileStatuses(for: hash)
        #expect(afterRestart[indexOfA].priority == .low)
        #expect(afterRestart[indexOfB].priority == .high)
        await restored.shutdown()
    }
}

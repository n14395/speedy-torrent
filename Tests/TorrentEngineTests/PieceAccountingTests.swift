// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TorrentEngine

/// `wantedBytes` / `completedWantedBytes` are maintained incrementally instead
/// of being summed on demand. These pin the invariant that makes that safe:
/// after any sequence of operations they must equal a from-scratch count.
@Suite struct PieceAccountingTests {
    private func makeInfo(files: Int, sizeEach: Int64, pieceLength: Int) throws -> TorrentInfo {
        let total = Int64(files) * sizeEach
        let pieceCount = Int((total + Int64(pieceLength) - 1) / Int64(pieceLength))
        let info = BValue.dictionary([
            ("files", .list((0..<files).map { index in
                BValue.dictionary([
                    ("length", .integer(Int(sizeEach))),
                    ("path", .list([.string("file\(index).bin")])),
                ])
            })),
            ("name", .string("bundle")),
            ("piece length", .integer(pieceLength)),
            ("pieces", .string(Data(repeating: 0x61, count: 20 * pieceCount))),
        ])
        return try TorrentInfo(bencodedData: Bencode.encode(info))
    }

    private func check(_ manager: PieceManager, _ label: String) {
        let expected = manager.recomputedByteTotals()
        #expect(manager.wantedBytes == expected.wanted, "wantedBytes after \(label)")
        #expect(
            manager.completedWantedBytes == expected.completed,
            "completedWantedBytes after \(label)"
        )
    }

    @Test func countersTrackSelectionAndVerification() throws {
        let info = try makeInfo(files: 4, sizeEach: 65_536, pieceLength: 16_384)
        let manager = PieceManager(info: info)
        check(manager, "init")

        for index in stride(from: 0, to: info.pieceCount, by: 2) {
            manager.markHave(index)
        }
        check(manager, "markHave")

        manager.setWantedFiles([0, 2])
        check(manager, "setWantedFiles([0, 2])")

        manager.setPriority(.high, for: [0])
        check(manager, "setPriority")

        manager.setWantedFiles([0, 1, 2, 3])
        check(manager, "setWantedFiles(all)")

        manager.resetHave()
        check(manager, "resetHave")
        #expect(manager.completedWantedBytes == 0)

        for index in 0..<info.pieceCount {
            manager.markHave(index)
        }
        check(manager, "markHave(all)")
        #expect(manager.isWantedComplete)
    }

    /// The free-block cursor is a hint over the request arrays, so a
    /// request/cancel sequence must never lose a block or hand one out twice.
    @Test func requestAndCancelNeverLoseABlock() throws {
        let info = try makeInfo(files: 1, sizeEach: 400_000, pieceLength: 262_144)
        let manager = PieceManager(info: info)
        var everything = Bitfield(count: info.pieceCount)
        for index in 0..<info.pieceCount { everything[index] = true }

        var handedOut: [BlockRef] = []
        while let ref = manager.nextRequest(peerHas: everything, excluding: Set(handedOut)) {
            guard !handedOut.contains(ref) else { break } // endgame duplication
            manager.markRequested(ref)
            handedOut.append(ref)
        }
        #expect(!handedOut.isEmpty)

        // Cancel everything, then re-request: exactly the same blocks must come
        // back. Not the same *order* — `nextRequest` walks `inProgress` in
        // dictionary order, which is deliberately unspecified.
        for ref in handedOut { manager.cancelRequest(ref) }
        var second: [BlockRef] = []
        while let ref = manager.nextRequest(peerHas: everything, excluding: Set(second)) {
            guard !second.contains(ref) else { break }
            manager.markRequested(ref)
            second.append(ref)
        }
        #expect(Set(second) == Set(handedOut))
        #expect(second.count == handedOut.count, "a cancelled block was lost or duplicated")
    }

    /// Verifying a piece that only unwanted files cover must not move the
    /// completed counter — that is the difference between the wanted totals and
    /// the unconditional `completedLength`.
    @Test func unwantedPiecesDoNotCountAsCompleted() throws {
        let info = try makeInfo(files: 2, sizeEach: 65_536, pieceLength: 16_384)
        let manager = PieceManager(info: info)
        manager.setWantedFiles([0])
        let before = manager.completedWantedBytes

        // File 1 starts at byte 65_536, i.e. piece 4 of 8.
        manager.markHave(info.pieceCount - 1)
        #expect(manager.completedWantedBytes == before)
        check(manager, "markHave(unwanted)")
        #expect(manager.completedLength > 0)
    }
}

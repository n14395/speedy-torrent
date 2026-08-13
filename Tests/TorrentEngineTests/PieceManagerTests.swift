import Foundation
import Testing
@testable import TorrentEngine

/// Builds a synthetic TorrentInfo: `pieceCount` pieces of `pieceLength`, with
/// the last piece `lastPieceSize` bytes (hashes are dummies — PieceManager
/// never verifies).
func makeTestInfo(pieceCount: Int, pieceLength: Int = 32 * 1024, lastPieceSize: Int? = nil) throws -> TorrentInfo {
    let last = lastPieceSize ?? pieceLength
    let total = (pieceCount - 1) * pieceLength + last
    let encoded = Bencode.encode(.dictionary([
        ("length", .integer(total)),
        ("name", .string("test")),
        ("piece length", .integer(pieceLength)),
        ("pieces", .string(Data(repeating: 0xAB, count: 20 * pieceCount))),
    ]))
    return try TorrentInfo(bencodedData: encoded)
}

func fullBitfield(_ count: Int) -> Bitfield {
    var bits = Bitfield(count: count)
    for index in 0..<count { bits[index] = true }
    return bits
}

@Suite struct PieceManagerTests {
    @Test func sequentialModePicksInOrder() throws {
        let info = try makeTestInfo(pieceCount: 4)
        let manager = PieceManager(info: info, sequential: true)
        let peer = fullBitfield(4)

        let first = manager.nextRequest(peerHas: peer, excluding: [])
        #expect(first == BlockRef(index: 0, begin: 0, length: 16384))
        manager.markRequested(first!)
        let second = manager.nextRequest(peerHas: peer, excluding: [first!])
        #expect(second == BlockRef(index: 0, begin: 16384, length: 16384))
    }

    @Test func rarestFirstPrefersRarePieces() throws {
        let info = try makeTestInfo(pieceCount: 4)
        let manager = PieceManager(info: info)
        // Two peers have everything; one extra peer lacks piece 2, making
        // pieces 0,1,3 availability 3 and piece 2 availability 2.
        manager.peerJoined(with: fullBitfield(4))
        manager.peerJoined(with: fullBitfield(4))
        var partial = fullBitfield(4)
        partial[2] = false
        manager.peerJoined(with: partial)

        let pick = manager.nextRequest(peerHas: fullBitfield(4), excluding: [])
        #expect(pick?.index == 2)
    }

    @Test func blockAssemblyAndVerificationFlow() throws {
        let info = try makeTestInfo(pieceCount: 2, pieceLength: 32 * 1024, lastPieceSize: 100)
        let manager = PieceManager(info: info, sequential: true)
        let peer = fullBitfield(2)

        // Piece 0 has two 16 KiB blocks.
        var refs: [BlockRef] = []
        var excluding = Set<BlockRef>()
        for _ in 0..<2 {
            let ref = manager.nextRequest(peerHas: peer, excluding: excluding)!
            manager.markRequested(ref)
            excluding.insert(ref)
            refs.append(ref)
        }
        #expect(refs.map(\.begin) == [0, 16384])

        let blockA = Data(repeating: 1, count: 16384)
        let blockB = Data(repeating: 2, count: 16384)
        #expect({ if case .progress = manager.receivedBlock(index: 0, begin: 0, block: blockA) { true } else { false } }())
        guard case .pieceComplete(let assembled) = manager.receivedBlock(index: 0, begin: 16384, block: blockB) else {
            Issue.record("expected pieceComplete")
            return
        }
        #expect(assembled == blockA + blockB)

        manager.pieceVerified(0)
        #expect(manager.have[0])
        #expect(manager.completedLength == 32 * 1024)

        // Last piece is a single short block.
        let ref = manager.nextRequest(peerHas: peer, excluding: [])!
        #expect(ref == BlockRef(index: 1, begin: 0, length: 100))
    }

    @Test func failedPieceIsRedownloadable() throws {
        let info = try makeTestInfo(pieceCount: 1, pieceLength: 16384)
        let manager = PieceManager(info: info)
        let peer = fullBitfield(1)

        let ref = manager.nextRequest(peerHas: peer, excluding: [])!
        manager.markRequested(ref)
        guard case .pieceComplete = manager.receivedBlock(index: 0, begin: 0, block: Data(count: 16384)) else {
            Issue.record("expected pieceComplete")
            return
        }
        manager.pieceFailed(0)
        #expect(!manager.have[0])
        // The piece must be requestable again from scratch.
        #expect(manager.nextRequest(peerHas: peer, excluding: []) == ref)
    }

    @Test func endgameDuplicatesOutstandingBlocks() throws {
        let info = try makeTestInfo(pieceCount: 1, pieceLength: 32 * 1024)
        let manager = PieceManager(info: info)
        let peer = fullBitfield(1)

        // Request both blocks (as peer A).
        var outstandingA = Set<BlockRef>()
        while let ref = manager.nextRequest(peerHas: peer, excluding: outstandingA) {
            if outstandingA.contains(ref) { break }
            manager.markRequested(ref)
            outstandingA.insert(ref)
            if outstandingA.count == 2 { break }
        }
        #expect(outstandingA.count == 2)

        // A second peer (no outstanding) should get an endgame duplicate.
        let duplicate = manager.nextRequest(peerHas: peer, excluding: [])
        #expect(duplicate != nil)
        #expect(outstandingA.contains(duplicate!))

        // But not a block it is itself already fetching.
        #expect(manager.nextRequest(peerHas: peer, excluding: outstandingA) == nil)
    }

    @Test func ignoresBogusBlocks() throws {
        let info = try makeTestInfo(pieceCount: 2, pieceLength: 32 * 1024)
        let manager = PieceManager(info: info)
        // Not in progress at all.
        #expect({ if case .ignored = manager.receivedBlock(index: 0, begin: 0, block: Data(count: 16384)) { true } else { false } }())
        // Misaligned begin.
        let peer = fullBitfield(2)
        let ref = manager.nextRequest(peerHas: peer, excluding: [])!
        manager.markRequested(ref)
        #expect({ if case .ignored = manager.receivedBlock(index: ref.index, begin: 3, block: Data(count: 16384)) { true } else { false } }())
        // Wrong length.
        #expect({ if case .ignored = manager.receivedBlock(index: ref.index, begin: 0, block: Data(count: 5)) { true } else { false } }())
    }
}

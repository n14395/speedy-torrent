// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TorrentEngine

@Suite struct HandshakeTests {
    @Test func roundTrips() throws {
        let original = Handshake(
            infoHash: InfoHash(data: Data(repeating: 0xCD, count: 20))!,
            peerID: Data("-ST0100-abcdefghijkl".utf8)
        )
        let encoded = original.encoded()
        #expect(encoded.count == Handshake.length)
        let decoded = try Handshake.decode(encoded)
        #expect(decoded == original)
        #expect(decoded.supportsExtensions)
        #expect(decoded.supportsDHT)
    }

    @Test func decodesReservedBits() throws {
        var encoded = Handshake(
            infoHash: InfoHash(data: Data(repeating: 1, count: 20))!,
            peerID: Data(repeating: 2, count: 20),
            supportsExtensions: false,
            supportsDHT: false
        ).encoded()
        var decoded = try Handshake.decode(encoded)
        #expect(!decoded.supportsExtensions)
        #expect(!decoded.supportsDHT)

        encoded[25] = 0x10 // extension bit, byte 5 of reserved (offset 20+5)
        decoded = try Handshake.decode(encoded)
        #expect(decoded.supportsExtensions)
    }

    @Test func rejectsWrongProtocolString() {
        var encoded = Handshake(
            infoHash: InfoHash(data: Data(repeating: 1, count: 20))!,
            peerID: Data(repeating: 2, count: 20)
        ).encoded()
        encoded[1] = UInt8(ascii: "X")
        #expect(throws: PeerWireError.self) {
            try Handshake.decode(encoded)
        }
    }
}

@Suite struct PeerMessageTests {
    private func roundTrip(_ message: PeerMessage) throws -> PeerMessage {
        let framed = message.encoded()
        let length = Int(framed.readUInt32(at: 0)!)
        #expect(framed.count == length + 4)
        return try PeerMessage.decode(payload: framed.readData(at: 4, count: length)!)
    }

    @Test func roundTripsAllMessageTypes() throws {
        let messages: [PeerMessage] = [
            .keepAlive, .choke, .unchoke, .interested, .notInterested,
            .have(1234),
            .bitfield(Data([0xF0, 0x01])),
            .request(index: 1, begin: 16384, length: 16384),
            .piece(index: 2, begin: 32768, block: Data(repeating: 7, count: 100)),
            .cancel(index: 3, begin: 0, length: 16384),
            .port(6881),
            .extended(id: 1, payload: Data("d1:md11:ut_metadatai1eee".utf8)),
        ]
        for message in messages {
            #expect(try roundTrip(message) == message, "\(message)")
        }
    }

    @Test func rejectsMalformedPayloads() {
        // Unknown ID, truncated have, truncated request.
        for payload in [Data([99]), Data([4, 0, 0]), Data([6, 0, 0, 0, 1])] {
            #expect(throws: PeerWireError.malformedMessage) {
                try PeerMessage.decode(payload: payload)
            }
        }
    }
}

@Suite struct BitfieldTests {
    @Test func setAndGet() {
        var bits = Bitfield(count: 10)
        #expect(bits.isEmpty)
        bits[0] = true
        bits[9] = true
        #expect(bits[0] && bits[9] && !bits[5])
        #expect(bits.setCount == 2)
        #expect(bits.bytes == [0x80, 0x40]) // bit 9 = second byte, second-highest bit
        bits[0] = false
        #expect(bits.setCount == 1)
    }

    @Test func fullDetection() {
        var bits = Bitfield(count: 9)
        for index in 0..<9 { bits[index] = true }
        #expect(bits.isFull)
    }

    @Test func parseValidatesLengthAndSpareBits() {
        // 10 pieces → 2 bytes; spare low 6 bits of byte 1 must be zero.
        #expect(Bitfield(data: Data([0xFF, 0xC0]), count: 10) != nil)
        #expect(Bitfield(data: Data([0xFF, 0xC1]), count: 10) == nil)
        #expect(Bitfield(data: Data([0xFF]), count: 10) == nil)
        #expect(Bitfield(data: Data([0xFF, 0xC0]), count: 10)?.setCount == 10)
    }

    @Test func missingPieceDetection() {
        var ours = Bitfield(count: 8)
        var theirs = Bitfield(count: 8)
        theirs[3] = true
        #expect(theirs.hasAnyPieceMissing(from: ours))
        ours[3] = true
        #expect(!theirs.hasAnyPieceMissing(from: ours))
    }
}

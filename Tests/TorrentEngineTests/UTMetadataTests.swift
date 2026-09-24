// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TorrentEngine

/// Bounds checking for BEP 9 ut_metadata. (`ExtensionProtocolTests` already
/// exists in DHTTests.swift and covers the handshake/PEX codecs.)
@Suite struct UTMetadataTests {
    private func metadataHeader(piece: Int) -> Data {
        Bencode.encode(.dictionary([
            ("msg_type", .integer(UTMetadata.MessageType.request.rawValue)),
            ("piece", .integer(piece)),
        ]))
    }

    /// `piece` is peer-supplied and was multiplied by the 16 KiB piece size
    /// without a bound. Bencode accepts 19 digits, which reaches `Int.max`
    /// exactly, so one extended message could trap the process on overflow.
    @Test func rejectsOutOfRangeMetadataPiece() {
        #expect(UTMetadata.parse(metadataHeader(piece: .max)) == nil)
        #expect(UTMetadata.parse(metadataHeader(piece: UTMetadata.maxPieces)) == nil)
        #expect(UTMetadata.parse(metadataHeader(piece: -1)) == nil)
    }

    @Test func acceptsInRangeMetadataPiece() {
        #expect(UTMetadata.parse(metadataHeader(piece: 0))?.piece == 0)
        let last = UTMetadata.maxPieces - 1
        #expect(UTMetadata.parse(metadataHeader(piece: last))?.piece == last)
    }

    /// The bound has to cover a legitimately large info dictionary, not just
    /// small ones — `maxPieces` must span `maxMetadataSize`.
    @Test func boundCoversTheLargestAllowedMetadata() {
        #expect(UTMetadata.maxPieces * UTMetadata.pieceSize >= UTMetadata.maxMetadataSize)
    }
}

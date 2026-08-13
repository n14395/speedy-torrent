import Foundation
import Testing
@testable import TorrentEngine

@Suite struct CompactPeerTests {
    @Test func parsesIPv4CompactList() {
        let blob = Data([192, 168, 1, 2, 0x1A, 0xE1, 10, 0, 0, 1, 0x00, 0x50])
        let peers = CompactPeers.parseIPv4(blob)
        #expect(peers == [
            PeerAddress(host: "192.168.1.2", port: 6881),
            PeerAddress(host: "10.0.0.1", port: 80),
        ])
    }

    @Test func skipsZeroPortsAndRejectsBadLengths() {
        let zeroPort = Data([1, 2, 3, 4, 0, 0])
        #expect(CompactPeers.parseIPv4(zeroPort).isEmpty)
        #expect(CompactPeers.parseIPv4(Data([1, 2, 3])).isEmpty)
    }

    @Test func parsesIPv6CompactList() {
        var blob = Data(count: 16)
        blob[15] = 1 // ::1
        blob.appendUInt16(6881)
        let peers = CompactPeers.parseIPv6(blob)
        #expect(peers == [PeerAddress(host: "0:0:0:0:0:0:0:1", port: 6881)])
    }
}

@Suite struct HTTPTrackerTests {
    private var request: AnnounceRequest {
        AnnounceRequest(
            infoHash: InfoHash(data: Data(0..<20))!,
            peerID: Data("-ST0100-abcdefghijkl".utf8),
            port: 6881,
            uploaded: 10,
            downloaded: 20,
            left: 30,
            event: .started,
            numWant: 50,
            key: 0xDEAD_BEEF
        )
    }

    @Test func buildsAnnounceURLWithRawByteEncoding() throws {
        let url = try #require(HTTPTrackerClient.buildURL(
            base: "http://tracker.test/announce", request: request
        ))
        let string = url.absoluteString
        #expect(string.hasPrefix("http://tracker.test/announce?"))
        // Raw bytes 0x00-0x13 must be percent-encoded byte-for-byte.
        #expect(string.contains("info_hash=%00%01%02%03%04%05%06%07%08%09%0A%0B%0C%0D%0E%0F%10%11%12%13"))
        #expect(string.contains("peer_id=-ST0100-abcdefghijkl"))
        #expect(string.contains("port=6881"))
        #expect(string.contains("uploaded=10"))
        #expect(string.contains("downloaded=20"))
        #expect(string.contains("left=30"))
        #expect(string.contains("compact=1"))
        #expect(string.contains("event=started"))
        #expect(string.contains("key=deadbeef"))
    }

    @Test func appendsToExistingQueryString() throws {
        let url = try #require(HTTPTrackerClient.buildURL(
            base: "http://tracker.test/announce?passkey=abc", request: request
        ))
        #expect(url.absoluteString.contains("announce?passkey=abc&info_hash="))
    }

    @Test func parsesCompactResponse() throws {
        var peerBlob = Data([127, 0, 0, 1])
        peerBlob.appendUInt16(6881)
        let body = Bencode.encode(.dictionary([
            ("interval", .integer(900)),
            ("complete", .integer(5)),
            ("incomplete", .integer(2)),
            ("peers", .string(peerBlob)),
        ]))
        let response = try HTTPTrackerClient.parseResponse(body)
        #expect(response.interval == 900)
        #expect(response.seeders == 5)
        #expect(response.leechers == 2)
        #expect(response.peers == [PeerAddress(host: "127.0.0.1", port: 6881)])
    }

    @Test func parsesDictionaryPeerList() throws {
        let body = Bencode.encode(.dictionary([
            ("interval", .integer(1800)),
            ("peers", .list([
                .dictionary([("ip", .string("10.1.2.3")), ("port", .integer(51413))]),
            ])),
        ]))
        let response = try HTTPTrackerClient.parseResponse(body)
        #expect(response.peers == [PeerAddress(host: "10.1.2.3", port: 51413)])
    }

    @Test func throwsOnFailureReason() {
        let body = Bencode.encode(.dictionary([
            ("failure reason", .string("torrent not registered")),
        ]))
        #expect(throws: TrackerError.failure("torrent not registered")) {
            try HTTPTrackerClient.parseResponse(body)
        }
    }
}

@Suite struct UDPTrackerPacketTests {
    @Test func buildsConnectRequest() {
        let packet = UDPTrackerPacket.connectRequest(transactionID: 0x12345678)
        #expect(packet.count == 16)
        #expect(packet.readUInt64(at: 0) == 0x0000_0417_2710_1980)
        #expect(packet.readUInt32(at: 8) == 0)
        #expect(packet.readUInt32(at: 12) == 0x12345678)
    }

    @Test func parsesConnectResponse() {
        var response = Data()
        response.appendUInt32(0)
        response.appendUInt32(0x12345678)
        response.appendUInt64(0xAABB_CCDD_EEFF_0011)
        #expect(UDPTrackerPacket.parseConnectResponse(response, transactionID: 0x12345678) == 0xAABB_CCDD_EEFF_0011)
        // Wrong transaction ID must be rejected.
        #expect(UDPTrackerPacket.parseConnectResponse(response, transactionID: 1) == nil)
    }

    @Test func buildsAnnounceRequestLayout() {
        let request = AnnounceRequest(
            infoHash: InfoHash(data: Data(repeating: 0xAA, count: 20))!,
            peerID: Data(repeating: 0xBB, count: 20),
            port: 6881,
            uploaded: 1,
            downloaded: 2,
            left: 3,
            event: .started,
            numWant: 50,
            key: 7
        )
        let packet = UDPTrackerPacket.announceRequest(
            connectionID: 99, transactionID: 42, request: request
        )
        #expect(packet.count == 98)
        #expect(packet.readUInt64(at: 0) == 99)
        #expect(packet.readUInt32(at: 8) == 1)
        #expect(packet.readUInt32(at: 12) == 42)
        #expect(packet.readData(at: 16, count: 20) == request.infoHash.data)
        #expect(packet.readData(at: 36, count: 20) == request.peerID)
        #expect(packet.readUInt64(at: 56) == 2) // downloaded
        #expect(packet.readUInt64(at: 64) == 3) // left
        #expect(packet.readUInt64(at: 72) == 1) // uploaded
        #expect(packet.readUInt32(at: 80) == 2) // event: started
        #expect(packet.readUInt32(at: 88) == 7) // key
        #expect(packet.readUInt32(at: 92) == 50) // num_want
        #expect(packet.readUInt16(at: 96) == 6881)
    }

    @Test func parsesAnnounceResponseWithPeers() throws {
        var response = Data()
        response.appendUInt32(1)
        response.appendUInt32(42)
        response.appendUInt32(1800)
        response.appendUInt32(3) // leechers
        response.appendUInt32(9) // seeders
        response.append(contentsOf: [127, 0, 0, 1])
        response.appendUInt16(6881)
        let parsed = try UDPTrackerPacket.parseAnnounceResponse(response, transactionID: 42)
        #expect(parsed.interval == 1800)
        #expect(parsed.leechers == 3)
        #expect(parsed.seeders == 9)
        #expect(parsed.peers == [PeerAddress(host: "127.0.0.1", port: 6881)])
    }

    @Test func parsesErrorResponse() {
        var response = Data()
        response.appendUInt32(3)
        response.appendUInt32(42)
        response.append(contentsOf: Array("access denied".utf8))
        #expect(throws: TrackerError.failure("access denied")) {
            try UDPTrackerPacket.parseAnnounceResponse(response, transactionID: 42)
        }
    }
}

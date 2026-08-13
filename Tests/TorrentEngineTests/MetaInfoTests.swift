import Foundation
import CryptoKit
import Testing
@testable import TorrentEngine

/// A hand-crafted single-file torrent whose info-hash was computed externally
/// with `shasum -a 1` over the raw info dictionary bytes.
private let fixtureTorrent = Data(
    "d8:announce18:http://example.com4:infod6:lengthi5e4:name5:hello12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaaee".utf8
)
private let fixtureInfoHash = "961d86b2d565bb5cfd7d6481f22e4d3ff541c806"

@Suite struct MetaInfoTests {
    @Test func parsesFixtureWithKnownInfoHash() throws {
        let meta = try TorrentMetaInfo(torrentFileData: fixtureTorrent)
        #expect(meta.info.infoHash.hexString == fixtureInfoHash)
        #expect(meta.info.name == "hello")
        #expect(meta.info.pieceLength == 16384)
        #expect(meta.info.totalLength == 5)
        #expect(meta.info.pieceCount == 1)
        #expect(meta.info.pieceSize(at: 0) == 5)
        #expect(meta.info.files == [FileEntry(path: ["hello"], length: 5)])
        #expect(meta.info.isDirectory == false)
        #expect(meta.info.isPrivate == false)
        #expect(meta.announceTiers == [["http://example.com"]])
    }

    @Test func parsesAnnounceListTiers() throws {
        let data = Data(
            "d8:announce8:http://a13:announce-listll8:http://a8:http://bel8:http://cee4:infod6:lengthi5e4:name5:hello12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaaee".utf8
        )
        let meta = try TorrentMetaInfo(torrentFileData: data)
        #expect(meta.announceTiers == [["http://a", "http://b"], ["http://c"]])
        #expect(meta.allTrackers == ["http://a", "http://b", "http://c"])
    }

    @Test func parsesPrivateFlag() throws {
        let data = Data(
            "d4:infod6:lengthi5e4:name5:hello12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaa7:privatei1eee".utf8
        )
        let meta = try TorrentMetaInfo(torrentFileData: data)
        #expect(meta.info.isPrivate)
        #expect(meta.announceTiers.isEmpty)
    }

    @Test func rejectsTraversalPaths() {
        let data = Data(
            "d4:infod5:filesld6:lengthi5e4:pathl2:..6:secreteee4:name5:hello12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaaee".utf8
        )
        #expect(throws: MetaInfoError.self) {
            try TorrentMetaInfo(torrentFileData: data)
        }
    }

    @Test func rejectsPieceCountMismatch() {
        // 5-byte file with 16 KiB pieces requires exactly 1 piece hash; give 2.
        let data = Data(
            "d4:infod6:lengthi5e4:name5:hello12:piece lengthi16384e6:pieces40:aaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbee".utf8
        )
        #expect(throws: MetaInfoError.invalidField("piece count mismatch")) {
            try TorrentMetaInfo(torrentFileData: data)
        }
    }
}

@Suite struct TorrentBuilderTests {
    @Test func buildsMultiFileTorrentThatRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("builder-test-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var generator = SystemRandomNumberGenerator()
        let fileA = Data((0..<70_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let fileB = Data((0..<10_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try fileA.write(to: root.appendingPathComponent("a.bin"))
        try fileB.write(to: sub.appendingPathComponent("b.bin"))

        let pieceLength = 32 * 1024
        let torrentData = try TorrentBuilder.makeTorrentData(
            contentsOf: root,
            pieceLength: pieceLength,
            announceTiers: [["http://tracker.test/announce"]]
        )
        let meta = try TorrentMetaInfo(torrentFileData: torrentData)

        #expect(meta.info.name == root.lastPathComponent)
        #expect(meta.info.totalLength == 80_000)
        #expect(meta.info.isDirectory)
        #expect(meta.info.files == [
            FileEntry(path: ["a.bin"], length: 70_000),
            FileEntry(path: ["sub", "b.bin"], length: 10_000),
        ])
        #expect(meta.info.pieceCount == 3) // ceil(80000 / 32768)

        // Verify every piece hash against the concatenated payload.
        let payload = fileA + fileB
        for index in 0..<meta.info.pieceCount {
            let start = index * pieceLength
            let end = min(start + pieceLength, payload.count)
            let expected = Data(Insecure.SHA1.hash(data: payload[start..<end]))
            #expect(meta.info.pieceHashes[index] == expected, "piece \(index)")
        }

        // Building the same content twice must produce the same info-hash.
        let again = try TorrentBuilder.makeTorrentData(
            contentsOf: root, pieceLength: pieceLength
        )
        let metaAgain = try TorrentMetaInfo(torrentFileData: again)
        #expect(metaAgain.info.infoHash == meta.info.infoHash)
    }
}

@Suite struct MagnetLinkTests {
    private let hexHash = "961d86b2d565bb5cfd7d6481f22e4d3ff541c806"

    @Test func parsesHexMagnet() throws {
        let link = try #require(MagnetLink(string:
            "magnet:?xt=urn:btih:\(hexHash.uppercased())&dn=My+File%20Name&tr=udp%3A%2F%2Ftracker.test%3A6969%2Fannounce&tr=http%3A%2F%2Fbackup.test%2Fannounce"
        ))
        #expect(link.infoHash.hexString == hexHash)
        #expect(link.displayName == "My File Name")
        #expect(link.trackers == ["udp://tracker.test:6969/announce", "http://backup.test/announce"])
    }

    @Test func parsesBase32Magnet() throws {
        // Base32 of the fixture hash, computed from its raw bytes.
        let base32 = "SYOYNMWVMW5VZ7L5MSA7ELSNH72UDSAG"
        let link = try #require(MagnetLink(string: "magnet:?xt=urn:btih:\(base32)"))
        #expect(link.infoHash.hexString == hexHash)
    }

    @Test func rejectsInvalidMagnets() {
        #expect(MagnetLink(string: "magnet:?dn=NoHash") == nil)
        #expect(MagnetLink(string: "magnet:?xt=urn:btih:tooshort") == nil)
        #expect(MagnetLink(string: "http://example.com") == nil)
    }
}

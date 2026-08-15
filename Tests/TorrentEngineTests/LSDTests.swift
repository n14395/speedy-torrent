import Foundation
import Testing
@testable import TorrentEngine

@Suite struct LSDTests {
    @Test func announcementRoundTrips() throws {
        let a = try #require(InfoHash(hex: String(repeating: "ab", count: 20)))
        let b = try #require(InfoHash(hex: String(repeating: "cd", count: 20)))
        let encoded = LSDMessage.encode(port: 51413, infoHashes: [a, b], cookie: "deadbeef")

        // It's a valid BT-SEARCH request terminated by a blank line.
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.hasPrefix("BT-SEARCH * HTTP/1.1\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))

        let parsed = try #require(LSDMessage.parse(encoded))
        #expect(parsed.port == 51413)
        #expect(parsed.infoHashes == [a, b])
        #expect(parsed.cookie == "deadbeef")
    }

    @Test func rejectsNonSearchAndEmpty() {
        #expect(LSDMessage.parse(Data("GET / HTTP/1.1\r\n\r\n".utf8)) == nil)
        // Missing Port / Infohash headers.
        #expect(LSDMessage.parse(Data("BT-SEARCH * HTTP/1.1\r\nHost: x\r\n\r\n".utf8)) == nil)
    }
}

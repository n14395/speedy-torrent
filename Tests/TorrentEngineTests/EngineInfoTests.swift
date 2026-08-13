import Testing
@testable import TorrentEngine

@Test func peerIDPrefixIsEightBytes() {
    // BEP 20 Azureus-style prefixes are exactly 8 bytes, leaving 12 random bytes.
    #expect(TorrentEngineInfo.peerIDPrefix.utf8.count == 8)
}

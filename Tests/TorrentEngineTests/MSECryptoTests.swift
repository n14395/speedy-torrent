import Foundation
import Testing
@testable import TorrentEngine

@Suite struct RC4Tests {
    @Test func matchesKnownVector() {
        // Classic RC4 test vector: RC4("Key", "Plaintext") = BBF316E8D940AF0AD3.
        var cipher = RC4(key: Array("Key".utf8))
        let out = cipher.process(Array("Plaintext".utf8))
        #expect(out == [0xBB, 0xF3, 0x16, 0xE8, 0xD9, 0x40, 0xAF, 0x0A, 0xD3])
    }

    @Test func decryptsWhatItEncrypts() {
        let key: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let message = Array("the quick brown fox".utf8)
        var enc = RC4(key: key)
        let cipher = enc.process(message)
        var dec = RC4(key: key)
        #expect(dec.process(cipher) == message)
    }
}

@Suite struct BigUIntTests {
    @Test func smallModExp() {
        // 2^10 mod 1000 = 1024 mod 1000 = 24.
        let base = BigUInt(bigEndianBytes: [2])
        let exp = BigUInt(bigEndianBytes: [10])
        let mod = BigUInt(bigEndianBytes: [0x03, 0xE8]) // 1000
        #expect(base.modExp(exp, modulus: mod).bigEndianBytes(count: 2) == [0x00, 0x18])
    }

    @Test func bytesRoundTrip() {
        let bytes: [UInt8] = [0x00, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]
        let value = BigUInt(bigEndianBytes: bytes)
        // Leading zero is dropped in value but restored by padding.
        #expect(value.bigEndianBytes(count: 9) == bytes)
    }

    /// A full Diffie–Hellman exchange over the real 768-bit MSE prime: both
    /// sides must derive the same shared secret.
    @Test(.timeLimit(.minutes(1)))
    func diffieHellmanAgrees() {
        let prime = BigUInt(bigEndianBytes: MSEHandshake.primeBytes)
        let g = BigUInt(bigEndianBytes: [2])

        let xa = BigUInt(bigEndianBytes: Array(repeating: 0x3B, count: 16))
        let xb = BigUInt(bigEndianBytes: Array(repeating: 0xA7, count: 16))

        let ya = g.modExp(xa, modulus: prime)
        let yb = g.modExp(xb, modulus: prime)

        let secretA = yb.modExp(xa, modulus: prime)
        let secretB = ya.modExp(xb, modulus: prime)

        #expect(secretA == secretB)
        #expect(!secretA.isZero)
    }
}

@Suite struct MSELoopbackTests {
    /// A leecher and seeder that both *require* encryption must complete the
    /// transfer — which is only possible if the MSE handshake (initiator on the
    /// leecher, responder on the seeder) succeeded and the RC4 stream works.
    @Test(.timeLimit(.minutes(2)))
    func requiredEncryptionTransferCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mse-\(UUID().uuidString)")
        let seedDir = root.appendingPathComponent("seed")
        let leechDir = root.appendingPathComponent("leech")
        let content = seedDir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var gen = SystemRandomNumberGenerator()
        let payload = Data((0..<200_000).map { _ in UInt8.random(in: 0...255, using: &gen) })
        try payload.write(to: content.appendingPathComponent("file.bin"))
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: content, pieceLength: 32 * 1024)
        let hash = try TorrentMetaInfo(torrentFileData: torrentData).info.infoHash

        let port = UInt16.random(in: 20000...60000)
        let seeder = TorrentSession(configuration: .init(
            downloadDirectory: seedDir, listenPort: port, enableDHT: false, encryptionPolicy: .required
        ))
        _ = try await seeder.startListening()
        _ = try await seeder.addTorrent(fileData: torrentData)

        let leecher = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0, enableDHT: false, encryptionPolicy: .required
        ))
        _ = try await leecher.addTorrent(fileData: torrentData)
        try await leecher.addPeers([PeerAddress(host: "127.0.0.1", port: port)], to: hash)

        var completed = false
        for _ in 0..<1200 {
            try await Task.sleep(for: .milliseconds(100))
            if await leecher.snapshots().first?.state == .seeding {
                completed = true
                break
            }
        }
        #expect(completed)
        let got = try Data(contentsOf: leechDir.appendingPathComponent("payload/file.bin"))
        #expect(got == payload)

        let peers = await leecher.peerDetails(for: hash)
        let allEncrypted = peers.allSatisfy(\.encrypted)
        #expect(!peers.isEmpty)
        #expect(allEncrypted)

        await leecher.shutdown()
        await seeder.shutdown()
    }
}

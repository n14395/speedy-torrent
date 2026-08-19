import Foundation
import Testing
@testable import TorrentEngine

@Suite struct MagnetEncryptionTests {
    /// Builds a one-file torrent under `dir` and returns its .torrent bytes.
    private func makePayload(_ dir: URL, bytes: Int) throws -> Data {
        let content = dir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try data.write(to: content.appendingPathComponent("file.bin"))
        return try TorrentBuilder.makeTorrentData(contentsOf: content, pieceLength: 32 * 1024)
    }

    /// A magnet leecher that *prefers* encryption must still fetch metadata
    /// from peers that only speak plaintext — the same fallback the download
    /// path already does. Without it, magnets stall at "Fetching metadata"
    /// against every non-MSE peer in the swarm.
    @Test(.timeLimit(.minutes(1)))
    func preferredEncryptionFallsBackToPlaintextPeer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("magnet-enc-\(UUID().uuidString)")
        let seedDir = root.appendingPathComponent("seed")
        let leechDir = root.appendingPathComponent("leech")
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let torrentData = try makePayload(seedDir, bytes: 120_000)
        let hash = try TorrentMetaInfo(torrentFileData: torrentData).info.infoHash

        // Seeder speaks plaintext only.
        let port = UInt16.random(in: 20000...60000)
        let seeder = TorrentSession(configuration: .init(
            downloadDirectory: seedDir, listenPort: port, enableDHT: false,
            encryptionPolicy: .disabled
        ))
        _ = try await seeder.startListening()
        _ = try await seeder.addTorrent(fileData: torrentData)

        // Leecher prefers encryption, as the app does by default.
        let leecher = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0, enableDHT: false,
            encryptionPolicy: .preferred
        ))
        let magnet = "magnet:?xt=urn:btih:\(hash.hexString)&dn=payload"
        _ = try await leecher.beginMetadataPrefetch(magnet)
        try await leecher.addPeers([PeerAddress(host: "127.0.0.1", port: port)], to: hash)

        var resolved: TorrentSession.PrefetchedMetadata?
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(100))
            if let meta = await leecher.prefetchedMetadata(for: hash) {
                resolved = meta
                break
            }
        }
        let metadata = try #require(resolved, "magnet never resolved against a plaintext peer")
        #expect(metadata.totalLength == 120_000)

        await leecher.shutdown()
        await seeder.shutdown()
    }

    /// The mirror case: an encrypted-only peer must still serve metadata to a
    /// leecher that prefers encryption.
    @Test(.timeLimit(.minutes(1)))
    func preferredEncryptionResolvesFromEncryptedPeer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("magnet-enc2-\(UUID().uuidString)")
        let seedDir = root.appendingPathComponent("seed")
        let leechDir = root.appendingPathComponent("leech")
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let torrentData = try makePayload(seedDir, bytes: 120_000)
        let hash = try TorrentMetaInfo(torrentFileData: torrentData).info.infoHash

        let port = UInt16.random(in: 20000...60000)
        let seeder = TorrentSession(configuration: .init(
            downloadDirectory: seedDir, listenPort: port, enableDHT: false,
            encryptionPolicy: .required
        ))
        _ = try await seeder.startListening()
        _ = try await seeder.addTorrent(fileData: torrentData)

        let leecher = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0, enableDHT: false,
            encryptionPolicy: .preferred
        ))
        let magnet = "magnet:?xt=urn:btih:\(hash.hexString)&dn=payload"
        _ = try await leecher.beginMetadataPrefetch(magnet)
        try await leecher.addPeers([PeerAddress(host: "127.0.0.1", port: port)], to: hash)

        var resolved: TorrentSession.PrefetchedMetadata?
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(100))
            if let meta = await leecher.prefetchedMetadata(for: hash) {
                resolved = meta
                break
            }
        }
        _ = try #require(resolved, "magnet never resolved against an encrypted peer")

        await leecher.shutdown()
        await seeder.shutdown()
    }
}

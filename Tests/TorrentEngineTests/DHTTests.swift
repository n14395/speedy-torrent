import Foundation
import Testing
@testable import TorrentEngine

@Suite struct NodeIDTests {
    @Test func xorDistanceOrdering() {
        let target = Data(repeating: 0x00, count: 20)
        let near = Data([0x01] + [UInt8](repeating: 0, count: 19))
        let far = Data([0x80] + [UInt8](repeating: 0, count: 19))
        #expect(NodeID.isCloser(near, than: far, to: target))
        #expect(!NodeID.isCloser(far, than: near, to: target))
    }

    @Test func commonPrefixBits() {
        let a = Data(repeating: 0x00, count: 20)
        var b = a
        #expect(NodeID.commonPrefixBits(a, b) == 160)
        b[0] = 0x80
        #expect(NodeID.commonPrefixBits(a, b) == 0)
        b[0] = 0x01
        #expect(NodeID.commonPrefixBits(a, b) == 7)
        b[0] = 0x00
        b[5] = 0x10
        #expect(NodeID.commonPrefixBits(a, b) == 43)
    }
}

@Suite struct KRPCTests {
    @Test func decodesQueryAndEncodesResponse() throws {
        let query = KRPC.encodeQuery(
            transaction: Data("aa".utf8),
            method: "ping",
            arguments: [("id", .string(Data(repeating: 1, count: 20)))]
        )
        guard case .query(let transaction, let method, let arguments)? = KRPC.decode(query) else {
            Issue.record("expected query")
            return
        }
        #expect(transaction == Data("aa".utf8))
        #expect(method == "ping")
        #expect(arguments["id"]?.stringData == Data(repeating: 1, count: 20))

        let response = KRPC.encodeResponse(
            transaction: transaction, body: [("id", .string(Data(repeating: 2, count: 20)))]
        )
        guard case .response(_, let body)? = KRPC.decode(response) else {
            Issue.record("expected response")
            return
        }
        #expect(body["id"]?.stringData == Data(repeating: 2, count: 20))
    }

    @Test func compactNodesRoundTrip() {
        let nodes = [
            KRPC.NodeInfo(id: Data(repeating: 5, count: 20), address: PeerAddress(host: "1.2.3.4", port: 6881)),
            KRPC.NodeInfo(id: Data(repeating: 6, count: 20), address: PeerAddress(host: "10.0.0.9", port: 51413)),
        ]
        let encoded = KRPC.encodeCompactNodes(nodes)
        #expect(encoded.count == 52)
        #expect(KRPC.parseCompactNodes(encoded) == nodes)
    }
}

@Suite struct RoutingTableTests {
    @Test func insertAndClosest() {
        let ownID = Data(repeating: 0x00, count: 20)
        let table = RoutingTable(ownID: ownID)
        for index in 0..<20 {
            var id = Data(repeating: 0, count: 20)
            id[19] = UInt8(index + 1)
            id[0] = index % 2 == 0 ? 0x80 : 0x40
            table.heard(from: KRPC.NodeInfo(
                id: id, address: PeerAddress(host: "10.0.0.\(index + 1)", port: 6881)
            ))
        }
        #expect(table.count > 0)
        var target = Data(repeating: 0, count: 20)
        target[0] = 0x80
        let closest = table.closest(to: target, count: 4)
        #expect(closest.count == 4)
        // All returned nodes should share the 0x80 prefix (closer to target).
        #expect(closest.allSatisfy { $0.id[0] == 0x80 })
    }

    @Test func ignoresOwnIDAndBadIDs() {
        let ownID = Data(repeating: 7, count: 20)
        let table = RoutingTable(ownID: ownID)
        table.heard(from: KRPC.NodeInfo(id: ownID, address: PeerAddress(host: "1.1.1.1", port: 1)))
        table.heard(from: KRPC.NodeInfo(id: Data([1, 2]), address: PeerAddress(host: "1.1.1.2", port: 1)))
        #expect(table.count == 0)
    }
}

@Suite struct DHTLoopbackTests {
    /// Two real DHT nodes over loopback UDP: A announces a peer for a hash to
    /// B; C (knowing only B) must find that peer via get_peers.
    @Test(.timeLimit(.minutes(1)))
    func announceAndFindPeersAcrossNodes() async throws {
        let nodeA = DHTNode()
        let nodeB = DHTNode()
        let nodeC = DHTNode()
        try await nodeA.start(port: 0)
        try await nodeB.start(port: 0)
        try await nodeC.start(port: 0)
        defer {
            Task {
                await nodeA.stop()
                await nodeB.stop()
                await nodeC.stop()
            }
        }

        let portB = await nodeB.port
        let addressB = PeerAddress(host: "127.0.0.1", port: portB)

        // A learns about B, then announces itself as a peer for `hash`.
        await nodeA.addCandidate(addressB)
        let hash = InfoHash(data: Data(repeating: 0x42, count: 20))!
        _ = await nodeA.findPeers(infoHash: hash, announcePort: 12345)
        // Give the fire-and-forget announce a moment to land.
        try await Task.sleep(for: .milliseconds(500))

        // C knows only B; the lookup must surface A's announced peer.
        await nodeC.addCandidate(addressB)
        let found = await nodeC.findPeers(infoHash: hash, announcePort: nil)
        #expect(found.contains(PeerAddress(host: "127.0.0.1", port: 12345)), "found: \(found)")
    }
}

@Suite struct ExtensionProtocolTests {
    @Test func handshakeRoundTrip() throws {
        let encoded = ExtensionHandshake.encode(metadataSize: 31337, listenPort: 6881)
        let parsed = try #require(ExtensionHandshake.parse(encoded))
        #expect(parsed.utMetadataID == ExtensionHandshake.utMetadataID)
        #expect(parsed.metadataSize == 31337)
    }

    @Test func utMetadataMessagesRoundTrip() throws {
        let chunk = Data(repeating: 9, count: 1000)
        let data = UTMetadata.data(piece: 2, totalSize: 33768, chunk: chunk)
        let parsed = try #require(UTMetadata.parse(data))
        #expect(parsed.type == .data)
        #expect(parsed.piece == 2)
        #expect(parsed.totalSize == 33768)
        #expect(parsed.trailing == chunk)

        let request = try #require(UTMetadata.parse(UTMetadata.request(piece: 1)))
        #expect(request.type == .request)
        #expect(request.piece == 1)

        let reject = try #require(UTMetadata.parse(UTMetadata.reject(piece: 0)))
        #expect(reject.type == .reject)
    }
}

@Suite struct MagnetLoopbackTests {
    /// A seeder with full data serves metadata over ut_metadata; a leecher
    /// starting from only a magnet link must fetch metadata, transition to a
    /// real download, and complete it.
    @Test(.timeLimit(.minutes(2)))
    func magnetResolvesAndDownloads() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("magnet-\(UUID().uuidString)")
        let seedDir = root.appendingPathComponent("seed")
        let leechDir = root.appendingPathComponent("leech")
        let contentDir = seedDir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<400_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try payload.write(to: contentDir.appendingPathComponent("file.bin"))
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: contentDir, pieceLength: 32 * 1024)
        let infoHash = try TorrentMetaInfo(torrentFileData: torrentData).info.infoHash

        let port = UInt16.random(in: 20000...60000)
        let seeder = TorrentSession(configuration: .init(
            downloadDirectory: seedDir, listenPort: port, enableDHT: false
        ))
        _ = try await seeder.startListening()
        _ = try await seeder.addTorrent(fileData: torrentData)

        let leecher = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0, enableDHT: false
        ))
        let magnetURI = "magnet:?xt=urn:btih:\(infoHash.hexString)&dn=payload"
        let hash = try await leecher.addMagnet(magnetURI)
        #expect(hash == infoHash)
        try await leecher.addPeers([PeerAddress(host: "127.0.0.1", port: port)], to: hash)

        var completed = false
        var sawMetadataFetch = false
        for _ in 0..<600 {
            try await Task.sleep(for: .milliseconds(100))
            guard let snap = await leecher.snapshots().first else { continue }
            if snap.state == .fetchingMetadata { sawMetadataFetch = true }
            if snap.state == .seeding {
                completed = true
                break
            }
        }
        #expect(sawMetadataFetch)
        #expect(completed)

        let got = try Data(contentsOf: leechDir.appendingPathComponent("payload/file.bin"))
        #expect(got == payload)

        await leecher.shutdown()
        await seeder.shutdown()
    }

    /// A metadata prefetch resolves the file list without adding the torrent to
    /// the list or touching disk; committing it then downloads to completion.
    @Test(.timeLimit(.minutes(2)))
    func prefetchResolvesMetadataThenCommitDownloads() async throws {
        let env = try MagnetTestEnv(fileCount: 3, bytesPerFile: 120_000)
        defer { env.cleanup() }
        try await env.startSeeding()

        let leecher = TorrentSession(configuration: .init(
            downloadDirectory: env.leechDir, listenPort: 0, enableDHT: false
        ))
        let hash = try await leecher.beginMetadataPrefetch(env.magnetURI)
        #expect(hash == env.infoHash)
        // A prefetch stays out of the torrent list.
        #expect(await leecher.snapshots().isEmpty)
        try await leecher.addPeers([env.seederAddress], to: hash)

        var metadata: TorrentSession.PrefetchedMetadata?
        for _ in 0..<600 {
            try await Task.sleep(for: .milliseconds(100))
            if let meta = await leecher.prefetchedMetadata(for: hash) {
                metadata = meta
                break
            }
        }
        let resolved = try #require(metadata)
        #expect(resolved.files.count == 3)
        #expect(resolved.totalLength == 360_000)
        // Still not in the list, still nothing on disk.
        #expect(await leecher.snapshots().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.contentDir(in: env.leechDir).path))

        let committed = try await leecher.commitMagnet(hash, downloadDirectory: env.leechDir)
        #expect(committed == env.infoHash)
        try await env.expectCompletion(on: leecher)
        try env.verifyContents(in: env.leechDir)

        await leecher.shutdown()
        await env.seeder.shutdown()
    }

    /// Committing a prefetch *before* metadata arrives promotes the in-flight
    /// fetch into a normal download that still completes.
    @Test(.timeLimit(.minutes(2)))
    func commitBeforeMetadataStillDownloads() async throws {
        let env = try MagnetTestEnv(fileCount: 1, bytesPerFile: 300_000)
        defer { env.cleanup() }
        try await env.startSeeding()

        let leecher = TorrentSession(configuration: .init(
            downloadDirectory: env.leechDir, listenPort: 0, enableDHT: false
        ))
        let hash = try await leecher.beginMetadataPrefetch(env.magnetURI)
        // Commit immediately, before any peer/metadata: promotes to a real add.
        let committed = try await leecher.commitMagnet(hash, downloadDirectory: env.leechDir)
        #expect(committed == env.infoHash)
        #expect(await leecher.snapshots().count == 1)
        try await leecher.addPeers([env.seederAddress], to: hash)

        try await env.expectCompletion(on: leecher)
        try env.verifyContents(in: env.leechDir)

        await leecher.shutdown()
        await env.seeder.shutdown()
    }
}

/// Shared loopback fixture: a seeder serving generated multi-file content plus
/// the magnet URI and info hash a leecher needs.
private struct MagnetTestEnv {
    let root: URL
    let seedDir: URL
    let leechDir: URL
    let infoHash: InfoHash
    let magnetURI: String
    let seeder: TorrentSession
    let seederAddress: PeerAddress
    private let files: [(name: String, bytes: Data)]

    init(fileCount: Int, bytesPerFile: Int) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefetch-\(UUID().uuidString)")
        seedDir = root.appendingPathComponent("seed")
        leechDir = root.appendingPathComponent("leech")
        let content = seedDir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)

        var generator = SystemRandomNumberGenerator()
        files = try (0..<fileCount).map { index in
            let bytes = Data((0..<bytesPerFile).map { _ in UInt8.random(in: 0...255, using: &generator) })
            let name = "file\(index).bin"
            try bytes.write(to: content.appendingPathComponent(name))
            return (name, bytes)
        }
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: content, pieceLength: 32 * 1024)
        infoHash = try TorrentMetaInfo(torrentFileData: torrentData).info.infoHash
        magnetURI = "magnet:?xt=urn:btih:\(infoHash.hexString)&dn=payload"

        let port = UInt16.random(in: 20000...60000)
        seeder = TorrentSession(configuration: .init(
            downloadDirectory: seedDir, listenPort: port, enableDHT: false
        ))
        seederAddress = PeerAddress(host: "127.0.0.1", port: port)
    }

    /// Must be called after init to bring the seeder online.
    func startSeeding() async throws {
        _ = try await seeder.startListening()
        let torrentData = try TorrentBuilder.makeTorrentData(
            contentsOf: seedDir.appendingPathComponent("payload"), pieceLength: 32 * 1024
        )
        _ = try await seeder.addTorrent(fileData: torrentData)
    }

    func contentDir(in base: URL) -> URL { base.appendingPathComponent("payload") }

    func expectCompletion(on session: TorrentSession) async throws {
        for _ in 0..<600 {
            try await Task.sleep(for: .milliseconds(100))
            if await session.snapshots().first?.state == .seeding { return }
        }
        Issue.record("torrent did not reach seeding state")
    }

    func verifyContents(in base: URL) throws {
        let dir = contentDir(in: base)
        for file in files {
            let got = try Data(contentsOf: dir.appendingPathComponent(file.name))
            #expect(got == file.bytes)
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

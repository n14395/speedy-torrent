import Foundation
import Network
import Testing
@testable import TorrentEngine

/// A minimal HTTP/1.1 server that serves one payload with Range support, for
/// exercising the web-seed download path over a real socket.
final class TinyRangeServer: @unchecked Sendable {
    private let listener: NWListener
    private let payload: Data
    private(set) var boundPort: UInt16 = 0

    init(payload: Data) throws {
        self.payload = payload
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    func start() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let port = self?.listener.port {
                    self?.boundPort = port.rawValue
                    continuation.resume()
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: DispatchQueue.global())
        }
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue.global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            connection.send(content: response(for: request), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for request: String) -> Data {
        var start = 0
        var end = payload.count - 1
        var partial = false
        for line in request.split(separator: "\r\n") where line.lowercased().hasPrefix("range:") {
            let spec = line.drop { $0 != "=" }.dropFirst()
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            if let low = Int(parts.first ?? "") {
                start = low
                if parts.count == 2, let high = Int(parts[1]) { end = high }
                partial = true
            }
        }
        start = max(0, min(start, payload.count - 1))
        end = max(start, min(end, payload.count - 1))
        let slice = payload.subdata(in: start..<end + 1)

        var header = partial
            ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(end)/\(payload.count)\r\n"
            : "HTTP/1.1 200 OK\r\n"
        header += "Content-Length: \(slice.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        return Data(header.utf8) + slice
    }
}

@Suite struct WebSeedTests {
    @Test func parsesUrlList() {
        let single = BValue.dictionary([("url-list", .string("http://mirror.example/"))])
        #expect(TorrentMetaInfo.parseWebSeeds(from: single) == ["http://mirror.example/"])
        let list = BValue.dictionary([("url-list", .list([.string("http://a"), .string("http://b")]))])
        #expect(TorrentMetaInfo.parseWebSeeds(from: list) == ["http://a", "http://b"])
        #expect(TorrentMetaInfo.parseWebSeeds(from: .dictionary([("announce", .string("x"))])) == [])
    }

    /// A torrent with no peers at all downloads to completion purely from an
    /// HTTP web seed.
    @Test(.timeLimit(.minutes(1)))
    func downloadsEntirelyFromWebSeed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webseed-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src")
        let content = src.appendingPathComponent("payload")
        let leechDir = root.appendingPathComponent("leech")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var gen = SystemRandomNumberGenerator()
        let payload = Data((0..<300_000).map { _ in UInt8.random(in: 0...255, using: &gen) })
        try payload.write(to: content.appendingPathComponent("file.bin"))
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: content, pieceLength: 32 * 1024)
        let meta = try TorrentMetaInfo(torrentFileData: torrentData)

        // The server ignores the path and serves the single file's bytes.
        let server = try TinyRangeServer(payload: payload)
        await server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.boundPort)"

        let session = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0, enableDHT: false
        ))
        _ = try await session.addTorrent(
            info: meta.info, announceTiers: [], downloadDirectory: leechDir, webSeeds: [base]
        )

        var completed = false
        for _ in 0..<600 {
            try await Task.sleep(for: .milliseconds(100))
            if await session.snapshots().first?.state == .seeding { completed = true; break }
        }
        #expect(completed)
        let got = try Data(contentsOf: leechDir.appendingPathComponent("payload/file.bin"))
        #expect(got == payload)

        await session.shutdown()
    }

    /// Which bucket the cap is set on. HTTP mirror traffic crosses the same
    /// link as peer traffic, so both must hold it back.
    enum LimitScope: Sendable {
        case session
        case torrent
    }

    @Test(.timeLimit(.minutes(1)), arguments: [LimitScope.session, LimitScope.torrent])
    func webSeedTrafficRespectsRateLimits(_ scope: LimitScope) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webseed-limit-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src")
        let content = src.appendingPathComponent("payload")
        let leechDir = root.appendingPathComponent("leech")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leechDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var gen = SystemRandomNumberGenerator()
        let payload = Data((0..<300_000).map { _ in UInt8.random(in: 0...255, using: &gen) })
        try payload.write(to: content.appendingPathComponent("file.bin"))
        let torrentData = try TorrentBuilder.makeTorrentData(contentsOf: content, pieceLength: 32 * 1024)
        let meta = try TorrentMetaInfo(torrentFileData: torrentData)

        let server = try TinyRangeServer(payload: payload)
        await server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.boundPort)"

        // 300 KB at 100 KiB/s → ~3s, and ≥ ~2s even after the 1s burst.
        let limit = 100 * 1024
        let session = TorrentSession(configuration: .init(
            downloadDirectory: leechDir, listenPort: 0,
            downloadRateLimit: scope == .session ? limit : nil,
            enableDHT: false
        ))
        let start = ContinuousClock.now
        let hash = try await session.addTorrent(
            info: meta.info, announceTiers: [], downloadDirectory: leechDir, webSeeds: [base]
        )
        if scope == .torrent {
            try await session.setRateLimits(download: limit, upload: nil, for: hash)
        }

        var completed = false
        for _ in 0..<600 {
            try await Task.sleep(for: .milliseconds(100))
            if await session.snapshots().first?.state == .seeding { completed = true; break }
        }
        let elapsed = start.duration(to: .now)

        #expect(completed)
        #expect(elapsed >= .seconds(1.5), "\(scope) limit did not hold web seeds back: \(elapsed)")
        let got = try Data(contentsOf: leechDir.appendingPathComponent("payload/file.bin"))
        #expect(got == payload)
        await session.shutdown()
    }
}

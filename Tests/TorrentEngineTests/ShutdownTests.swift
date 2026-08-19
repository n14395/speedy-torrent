import Foundation
import Testing
@testable import TorrentEngine

@Suite struct ShutdownTests {
    /// Quitting must not wait on the network. Telling trackers we've stopped is
    /// a courtesy: it gets a short budget, and torrents stop concurrently, so
    /// an unreachable tracker can't add 30 seconds per torrent to Cmd-Q.
    @Test(.timeLimit(.minutes(1)))
    func shutdownIsPromptWhenTrackersAreUnreachable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shutdown-\(UUID().uuidString)")
        let seedDir = root.appendingPathComponent("seed")
        defer { try? FileManager.default.removeItem(at: root) }

        // TEST-NET-1 (RFC 5737): guaranteed not to route anywhere.
        let blackHole = "http://192.0.2.1:6969/announce"
        let session = TorrentSession(configuration: .init(
            downloadDirectory: seedDir, listenPort: 0, enableDHT: false
        ))

        for index in 0..<3 {
            let content = seedDir.appendingPathComponent("payload-\(index)")
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 48 * 1024)
                .write(to: content.appendingPathComponent("file.bin"))
            let torrentData = try TorrentBuilder.makeTorrentData(
                contentsOf: content,
                pieceLength: 16 * 1024,
                announceTiers: [[blackHole]]
            )
            _ = try await session.addTorrent(fileData: torrentData, downloadDirectory: seedDir)
        }
        // Let the torrents come up so they count as active on the way down.
        try await Task.sleep(for: .milliseconds(500))

        let start = ContinuousClock.now
        await session.shutdown()
        let elapsed = ContinuousClock.now - start

        // Each torrent's announce is capped at ~2s and they run concurrently;
        // before this was bounded, three dead trackers cost ~90s.
        #expect(elapsed < .seconds(8), "shutdown took \(elapsed)")
    }
}

import Foundation
import Testing
@testable import TorrentEngine

/// `TorrentSnapshot.isComplete` is what the app's percent readout keys off, so
/// it has to mean "every wanted byte verified" and nothing looser.
@Suite struct ProgressReadoutTests {
    private func snapshot(completed: Int64, wanted: Int64) -> TorrentSnapshot {
        TorrentSnapshot(
            infoHash: InfoHash(data: Data(repeating: 1, count: 20))!,
            name: "t",
            totalLength: wanted,
            wantedLength: wanted,
            completedLength: completed,
            downloadedTotal: completed,
            uploadedTotal: 0,
            downloadRate: 0,
            uploadRate: 0,
            state: .downloading,
            peerCount: 0,
            pieceCount: 1,
            havePieces: 0,
            errorMessage: nil,
            downloadDirectory: "/tmp",
            sequential: false,
            downloadRateLimit: nil,
            uploadRateLimit: nil,
            addedAt: 0,
            pieceLength: 16384
        )
    }

    /// The case behind the bug: 99.6% used to round to "100%" while minutes of
    /// downloading remained on a large torrent.
    @Test func nearlyDoneIsNotComplete() {
        let almost = snapshot(completed: 9_960_000_000, wanted: 10_000_000_000)
        #expect(!almost.isComplete)
        #expect(almost.progress > 0.99)
    }

    @Test func everyWantedByteMeansComplete() {
        #expect(snapshot(completed: 500, wanted: 500).isComplete)
    }

    /// A single byte short is still not complete.
    @Test func oneByteShortIsNotComplete() {
        #expect(!snapshot(completed: 499, wanted: 500).isComplete)
    }

    /// A magnet with no metadata yet has nothing to be complete about.
    @Test func unknownSizeIsNotComplete() {
        #expect(!snapshot(completed: 0, wanted: 0).isComplete)
    }
}

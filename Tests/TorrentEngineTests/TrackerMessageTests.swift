import Foundation
import Network
import Testing
@testable import TorrentEngine

/// The tracker list shows these strings verbatim, so they have to read as
/// English rather than as Swift. The old readout printed `String(describing:)`,
/// which surfaced `network("Could not connect to the server.")` in the UI.
@Suite struct TrackerMessageTests {
    @Test func namesEachFailureWithoutEnumSyntax() {
        #expect(TrackerError.timeout.displayMessage == "No response (timed out)")
        #expect(TrackerError.badResponse.displayMessage == "Invalid response")
        #expect(TrackerError.unsupportedURL("wss://x").displayMessage == "Unsupported tracker URL")

        // No `case(payload)` spelling: a leading lowercase identifier followed
        // by "(", or a quoted payload, is the shape the old readout produced.
        for error in [TrackerError.timeout, .badResponse, .unsupportedURL("x"), .network("y")] {
            let message = error.displayMessage
            let looksLikeEnumCase = message.contains("(")
                && !message.prefix(while: { $0 != "(" }).contains(" ")
            #expect(!looksLikeEnumCase)
            #expect(!message.contains("\""))
            #expect(message.first?.isUppercase == true)
        }
    }

    /// `localizedDescription` ends in a full stop and tracker operators are
    /// inconsistent about capitals; the readout should be uniform.
    @Test func tidiesTrailingStopsAndCapitals() {
        #expect(TrackerError.network("Could not connect to the server.").displayMessage
            == "Could not connect to the server")
        #expect(TrackerError.failure("torrent not registered").displayMessage
            == "Torrent not registered")
        #expect(TrackerError.network("  spaced out  ").displayMessage == "Spaced out")
        // An ellipsis is deliberate punctuation, not a stray full stop.
        #expect(TrackerError.network("Retrying...").displayMessage == "Retrying...")
        #expect(TrackerError.network("").displayMessage.isEmpty)
    }

    @Test func describesErrorsThatNeverBecameTrackerErrors() {
        #expect(TrackerError.displayMessage(for: CancellationError()) == "Cancelled")
        #expect(TrackerError.displayMessage(for: TrackerError.timeout) == "No response (timed out)")
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 61, userInfo: [
            NSLocalizedDescriptionKey: "connection refused.",
        ])
        #expect(TrackerError.displayMessage(for: posix) == "Connection refused")
    }

    /// An HTTP timeout is the same event as a UDP timeout and should read the
    /// same, rather than arriving as a wrapped `network(...)` string.
    @Test func mapsURLErrorsToTrackerVocabulary() {
        #expect(HTTPTrackerClient.translate(URLError(.timedOut)) == .timeout)
        #expect(HTTPTrackerClient.translate(URLError(.cannotConnectToHost))
            == .network("Connection refused"))
        #expect(HTTPTrackerClient.translate(URLError(.cannotFindHost))
            == .network("Host not found"))
        #expect(HTTPTrackerClient.translate(URLError(.notConnectedToInternet))
            == .network("No internet connection"))
        #expect(HTTPTrackerClient.translate(URLError(.serverCertificateUntrusted))
            == .network("Untrusted certificate"))
        #expect(HTTPTrackerClient.translate(CancellationError()) == .network("Cancelled"))
    }

    @Test func mapsNetworkFrameworkErrors() {
        #expect(UDPTrackerClient.translate(.posix(.ECONNREFUSED)) == .network("Connection refused"))
        #expect(UDPTrackerClient.translate(.posix(.EHOSTUNREACH)) == .network("Host unreachable"))
        #expect(UDPTrackerClient.translate(.posix(.ENETUNREACH)) == .network("Network unreachable"))
        #expect(UDPTrackerClient.translate(.posix(.ETIMEDOUT)) == .timeout)
    }

    /// A 404 used to reach the bencode parser and surface as "Invalid
    /// response", which points the user at the wrong problem.
    @Test func reportsHTTPStatusButPrefersTheTrackersOwnWording() {
        #expect(HTTPTrackerClient.failureReason(Data("not bencode".utf8)) == nil)
        let body = Bencode.encode(.dictionary([
            ("failure reason", .string("access denied")),
        ]))
        #expect(HTTPTrackerClient.failureReason(body) == "access denied")
    }
}

// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum AnnounceEvent: Sendable, Equatable {
    case none
    case started
    case stopped
    case completed

    var queryValue: String? {
        switch self {
        case .none: nil
        case .started: "started"
        case .stopped: "stopped"
        case .completed: "completed"
        }
    }

    /// BEP 15 wire value.
    var udpValue: UInt32 {
        switch self {
        case .none: 0
        case .completed: 1
        case .started: 2
        case .stopped: 3
        }
    }
}

public struct AnnounceRequest: Sendable {
    public let infoHash: InfoHash
    public let peerID: Data
    public let port: UInt16
    public let uploaded: Int64
    public let downloaded: Int64
    public let left: Int64
    public let event: AnnounceEvent
    public let numWant: Int
    /// Random per-session key so trackers can recognize us across IP changes.
    public let key: UInt32

    public init(
        infoHash: InfoHash,
        peerID: Data,
        port: UInt16,
        uploaded: Int64 = 0,
        downloaded: Int64 = 0,
        left: Int64,
        event: AnnounceEvent = .none,
        numWant: Int = 50,
        key: UInt32
    ) {
        self.infoHash = infoHash
        self.peerID = peerID
        self.port = port
        self.uploaded = uploaded
        self.downloaded = downloaded
        self.left = left
        self.event = event
        self.numWant = numWant
        self.key = key
    }
}

public struct AnnounceResponse: Sendable {
    public let interval: Int
    public let minInterval: Int?
    public let peers: [PeerAddress]
    public let seeders: Int?
    public let leechers: Int?
    public let warning: String?
}

public enum TrackerError: Error, Equatable {
    case unsupportedURL(String)
    case failure(String)
    case badResponse
    case timeout
    case network(String)
}

extension TrackerError: LocalizedError {
    public var errorDescription: String? { displayMessage }

    /// Human-readable text for the tracker list. The row already shows the URL,
    /// so these say what went wrong and nothing more.
    public var displayMessage: String {
        switch self {
        case .unsupportedURL:
            "Unsupported tracker URL"
        case .failure(let reason):
            // The tracker's own "failure reason" — its wording, tidied.
            Self.tidied(reason)
        case .badResponse:
            "Invalid response"
        case .timeout:
            "No response (timed out)"
        case .network(let detail):
            Self.tidied(detail)
        }
    }

    /// Display text for any error that reached the announce path, including
    /// ones that never became a `TrackerError`.
    public static func displayMessage(for error: Error) -> String {
        if let tracker = error as? TrackerError { return tracker.displayMessage }
        if error is CancellationError { return "Cancelled" }
        return tidied((error as NSError).localizedDescription)
    }

    /// Sentence-cases a message and drops the trailing full stop that
    /// `localizedDescription` and tracker operators both like to add.
    static func tidied(_ message: String) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".") && !text.hasSuffix("..") { text.removeLast() }
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

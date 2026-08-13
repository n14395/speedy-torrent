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

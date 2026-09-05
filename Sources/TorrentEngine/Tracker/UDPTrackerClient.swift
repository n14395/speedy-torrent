import Foundation
import Network

/// UDP tracker protocol (BEP 15): connect handshake then announce, with
/// retransmission on timeout.
public struct UDPTrackerClient: Sendable {
    public init() {}

    public func announce(urlString: String, request: AnnounceRequest) async throws -> AnnounceResponse {
        guard let components = URLComponents(string: urlString),
              components.scheme?.lowercased() == "udp",
              let host = components.host,
              let port = components.port.flatMap(UInt16.init(exactly:))
        else { throw TrackerError.unsupportedURL(urlString) }

        guard let socket = UDPRequester(host: host, port: port) else {
            throw TrackerError.unsupportedURL(urlString)
        }
        defer { socket.cancel() }
        try await socket.waitReady(timeout: .seconds(10))

        // Connect handshake.
        let connectTID = UInt32.random(in: .min ... .max)
        let connectResponse = try await socket.exchange(
            UDPTrackerPacket.connectRequest(transactionID: connectTID),
            timeouts: [.seconds(5), .seconds(10), .seconds(15)]
        ) { UDPTrackerPacket.parseConnectResponse($0, transactionID: connectTID) != nil }
        guard let connectionID = UDPTrackerPacket.parseConnectResponse(connectResponse, transactionID: connectTID) else {
            throw TrackerError.badResponse
        }

        // Announce.
        let announceTID = UInt32.random(in: .min ... .max)
        let packet = UDPTrackerPacket.announceRequest(
            connectionID: connectionID, transactionID: announceTID, request: request
        )
        let response = try await socket.exchange(
            packet,
            timeouts: [.seconds(5), .seconds(10), .seconds(15)]
        ) { data in
            data.readUInt32(at: 4) == announceTID
        }
        return try UDPTrackerPacket.parseAnnounceResponse(response, transactionID: announceTID)
    }

    /// Network.framework's `localizedDescription` reads like a debugger dump
    /// ("POSIXErrorCode(rawValue: 61): Connection refused"), so name the common
    /// failures ourselves.
    static func translate(_ error: NWError) -> TrackerError {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .network("Connection refused")
            case .EHOSTUNREACH, .EHOSTDOWN: return .network("Host unreachable")
            case .ENETUNREACH, .ENETDOWN: return .network("Network unreachable")
            case .ETIMEDOUT: return .timeout
            case .ECANCELED: return .network("Cancelled")
            default: return .network(TrackerError.tidied(error.localizedDescription))
            }
        case .dns:
            return .network("Host not found")
        default:
            return .network(TrackerError.tidied(error.localizedDescription))
        }
    }
}

/// Pure packet codec, separated for unit testing.
enum UDPTrackerPacket {
    static let protocolMagic: UInt64 = 0x0000_0417_2710_1980

    static func connectRequest(transactionID: UInt32) -> Data {
        var data = Data(capacity: 16)
        data.appendUInt64(protocolMagic)
        data.appendUInt32(0) // action: connect
        data.appendUInt32(transactionID)
        return data
    }

    static func parseConnectResponse(_ data: Data, transactionID: UInt32) -> UInt64? {
        guard data.count >= 16,
              data.readUInt32(at: 0) == 0,
              data.readUInt32(at: 4) == transactionID
        else { return nil }
        return data.readUInt64(at: 8)
    }

    static func announceRequest(
        connectionID: UInt64, transactionID: UInt32, request: AnnounceRequest
    ) -> Data {
        var data = Data(capacity: 98)
        data.appendUInt64(connectionID)
        data.appendUInt32(1) // action: announce
        data.appendUInt32(transactionID)
        data.append(request.infoHash.data)
        data.append(request.peerID)
        data.appendUInt64(UInt64(max(0, request.downloaded)))
        data.appendUInt64(UInt64(max(0, request.left)))
        data.appendUInt64(UInt64(max(0, request.uploaded)))
        data.appendUInt32(request.event.udpValue)
        data.appendUInt32(0) // IP address: default
        data.appendUInt32(request.key)
        data.appendUInt32(UInt32(bitPattern: Int32(clamping: request.numWant)))
        data.appendUInt16(request.port)
        return data
    }

    static func parseAnnounceResponse(_ data: Data, transactionID: UInt32) throws -> AnnounceResponse {
        guard let action = data.readUInt32(at: 0),
              data.readUInt32(at: 4) == transactionID
        else { throw TrackerError.badResponse }
        if action == 3 { // error
            let message = data.readData(at: 8, count: data.count - 8)
                .map { String(decoding: $0, as: UTF8.self) } ?? "tracker error"
            throw TrackerError.failure(message)
        }
        guard action == 1, data.count >= 20,
              let interval = data.readUInt32(at: 8),
              let leechers = data.readUInt32(at: 12),
              let seeders = data.readUInt32(at: 16),
              let peerBlob = data.readData(at: 20, count: ((data.count - 20) / 6) * 6)
        else { throw TrackerError.badResponse }

        return AnnounceResponse(
            interval: Int(interval),
            minInterval: nil,
            peers: CompactPeers.parseIPv4(peerBlob),
            seeders: Int(seeders),
            leechers: Int(leechers),
            warning: nil
        )
    }
}

/// A connected UDP socket with a persistent receive pump. Incoming datagrams
/// are buffered on the actor; exchanges poll the buffer against a deadline,
/// retransmitting per BEP 15. One request in flight at a time.
actor UDPRequester {
    private let connection: NWConnection
    private var state: NWConnection.State = .setup
    private var buffered: [Data] = []
    private var closed = false
    private var started = false

    private static let maxBuffered = 64

    /// Fails rather than trapping on a port a `.torrent` file supplied: tracker
    /// URLs are untrusted input, and the caller already has an error for it.
    init?(host: String, port: UInt16) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: .udp
        )
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.updateState(state) }
        }
        pump()
        connection.start(queue: DispatchQueue(label: "udp-requester"))
    }

    private nonisolated func pump() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { await self.enqueue(data) }
            }
            if error == nil {
                self.pump()
            } else {
                Task { await self.markClosed() }
            }
        }
    }

    private func updateState(_ newState: NWConnection.State) {
        state = newState
        if case .cancelled = newState { closed = true }
        if case .failed = newState { closed = true }
    }

    private func enqueue(_ datagram: Data) {
        buffered.append(datagram)
        if buffered.count > Self.maxBuffered {
            buffered.removeFirst()
        }
    }

    private func markClosed() {
        closed = true
    }

    func waitReady(timeout: Duration) async throws {
        startIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            switch state {
            case .ready:
                return
            case .failed(let error):
                throw UDPTrackerClient.translate(error)
            case .cancelled:
                throw TrackerError.network("Cancelled")
            default:
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        throw TrackerError.timeout
    }

    /// Sends the payload and waits for a datagram matching `accept`,
    /// retransmitting once per entry in `timeouts`.
    func exchange(
        _ payload: Data,
        timeouts: [Duration],
        accept: @escaping @Sendable (Data) -> Bool
    ) async throws -> Data {
        for timeout in timeouts {
            connection.send(content: payload, completion: .contentProcessed { _ in })
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if closed { throw TrackerError.network("Connection closed") }
                while !buffered.isEmpty {
                    let datagram = buffered.removeFirst()
                    if accept(datagram) { return datagram }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        throw TrackerError.timeout
    }

    nonisolated func cancel() {
        connection.cancel()
    }
}

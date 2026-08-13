import Foundation
import Network

/// A single peer's TCP connection: connect/accept, handshake, and framed
/// message send/receive. Protocol state (choking, interest, requests) lives in
/// the torrent controller — this actor is just the wire.
actor PeerConnection {
    nonisolated let address: PeerAddress
    nonisolated let isIncoming: Bool

    private let connection: NWConnection
    private var buffer = Data()
    private var receivedChunks: [Data] = []
    private var closed = false
    private var closeError: Error?
    private var state: NWConnection.State = .setup
    private var started = false

    /// Bytes received off the wire, for rate accounting (read+reset by owner).
    private var bytesReceived: Int64 = 0
    private var bytesSent: Int64 = 0

    /// Session-wide token buckets; receive re-arming and sends block on them.
    private var downloadLimiter: RateLimiter?
    private var uploadLimiter: RateLimiter?

    func setLimiters(download: RateLimiter?, upload: RateLimiter?) {
        downloadLimiter = download
        uploadLimiter = upload
    }

    init(address: PeerAddress) {
        self.address = address
        self.isIncoming = false
        self.connection = NWConnection(
            host: NWEndpoint.Host(address.host),
            port: NWEndpoint.Port(rawValue: address.port) ?? 6881,
            using: .tcp
        )
    }

    init(incoming connection: NWConnection) {
        let endpoint = connection.endpoint
        if case .hostPort(let host, let port) = endpoint {
            self.address = PeerAddress(host: "\(host)", port: port.rawValue)
        } else {
            self.address = PeerAddress(host: "?", port: 0)
        }
        self.isIncoming = true
        self.connection = connection
    }

    // MARK: - Lifecycle

    func start(timeout: Duration = .seconds(10)) async throws {
        guard !started else { return }
        started = true
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.updateState(state) }
        }
        pump()
        connection.start(queue: DispatchQueue(label: "peer-\(address)"))

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            switch state {
            case .ready:
                return
            case .failed(let error):
                throw PeerWireError.network(error.localizedDescription)
            case .cancelled:
                throw PeerWireError.connectionClosed
            default:
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        connection.cancel()
        throw PeerWireError.timeout
    }

    nonisolated func close() {
        connection.cancel()
    }

    private func updateState(_ newState: NWConnection.State) {
        state = newState
        switch newState {
        case .failed(let error):
            closed = true
            closeError = PeerWireError.network(error.localizedDescription)
        case .cancelled:
            closed = true
        default:
            break
        }
    }

    private nonisolated func pump() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            receivedChunks.append(data)
            bytesReceived += Int64(data.count)
        }
        if let error {
            closed = true
            closeError = PeerWireError.network(error.localizedDescription)
        } else if isComplete {
            closed = true
        } else if let limiter = downloadLimiter, let count = data?.count, count > 0 {
            // Throttle by delaying the next read; TCP backpressure does the rest.
            Task {
                await limiter.acquire(count)
                self.pump()
            }
        } else {
            pump()
        }
    }

    // MARK: - Reading

    /// Waits until `count` bytes are buffered and returns them.
    private func receiveExactly(_ count: Int, deadline: ContinuousClock.Instant) async throws -> Data {
        while true {
            if !receivedChunks.isEmpty {
                for chunk in receivedChunks { buffer.append(chunk) }
                receivedChunks.removeAll(keepingCapacity: true)
            }
            if buffer.count >= count {
                let out = buffer.prefix(count)
                buffer.removeFirst(count)
                return Data(out)
            }
            if closed {
                throw closeError ?? PeerWireError.connectionClosed
            }
            if ContinuousClock.now >= deadline {
                throw PeerWireError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Reads one framed message. `idleTimeout` bounds the wait for the start
    /// of a message; the body must then arrive within 60s.
    func receiveMessage(idleTimeout: Duration = .seconds(150)) async throws -> PeerMessage {
        let header = try await receiveExactly(4, deadline: .now.advanced(by: idleTimeout))
        guard let length = header.readUInt32(at: 0) else { throw PeerWireError.malformedMessage }
        guard length <= UInt32(PeerMessage.maxPayloadLength) else {
            throw PeerWireError.oversizedMessage(Int(length))
        }
        if length == 0 { return .keepAlive }
        let payload = try await receiveExactly(Int(length), deadline: .now.advanced(by: .seconds(60)))
        return try PeerMessage.decode(payload: payload)
    }

    func receiveHandshake(timeout: Duration = .seconds(20)) async throws -> Handshake {
        let raw = try await receiveExactly(Handshake.length, deadline: .now.advanced(by: timeout))
        return try Handshake.decode(raw)
    }

    // MARK: - Writing

    func send(_ message: PeerMessage) async throws {
        try await sendRaw(message.encoded())
    }

    func sendHandshake(_ handshake: Handshake) async throws {
        try await sendRaw(handshake.encoded())
    }

    private func sendRaw(_ data: Data) async throws {
        guard !closed else { throw closeError ?? PeerWireError.connectionClosed }
        if let uploadLimiter {
            await uploadLimiter.acquire(data.count)
        }
        bytesSent += Int64(data.count)
        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: PeerWireError.network(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - Accounting

    func takeTransferCounts() -> (received: Int64, sent: Int64) {
        defer {
            bytesReceived = 0
            bytesSent = 0
        }
        return (bytesReceived, bytesSent)
    }
}

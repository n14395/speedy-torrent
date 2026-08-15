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

    /// MSE/PE stream ciphers, installed once the encrypted handshake completes.
    /// While nil, the wire is plaintext (and the MSE handshake reads/writes raw
    /// bytes, applying its own transient ciphers).
    private var rc4Send: RC4?
    private var rc4Receive: RC4?
    /// True once an MSE handshake negotiated RC4 for this connection.
    private(set) var isEncrypted = false

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
            // Post-handshake traffic arrives encrypted; decrypt as it lands so
            // the buffer always holds plaintext.
            let chunk = rc4Receive != nil ? rc4Receive!.process(data) : data
            receivedChunks.append(chunk)
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
        let payload = rc4Send != nil ? rc4Send!.process(data) : data
        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: PeerWireError.network(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - MSE / PE encryption handshake

    /// Installs the negotiated stream ciphers, decrypting any ciphertext that
    /// already arrived after the handshake in the same TCP segment.
    private func installCiphers(send: RC4, receive: RC4) {
        var receive = receive
        if !buffer.isEmpty { buffer = receive.process(buffer) }
        for index in receivedChunks.indices {
            receivedChunks[index] = receive.process(receivedChunks[index])
        }
        rc4Receive = receive
        rc4Send = send
        isEncrypted = true
    }

    private func randomPad() -> [UInt8] {
        (0..<Int.random(in: 0...MSEHandshake.maxPad)).map { _ in UInt8.random(in: 0...255) }
    }

    /// Consumes bytes until `pattern` has just been read (used to skip the
    /// random pre-handshake padding whose length is unknown).
    private func syncToPattern(
        _ pattern: [UInt8], maxSkip: Int, deadline: ContinuousClock.Instant
    ) async throws {
        var window: [UInt8] = []
        var scanned = 0
        while true {
            let byte = try await receiveExactly(1, deadline: deadline)
            window.append(byte[byte.startIndex])
            if window.count > pattern.count { window.removeFirst() }
            if window.count == pattern.count, window == pattern { return }
            scanned += 1
            if scanned > maxSkip + pattern.count {
                throw PeerWireError.handshakeFailed("MSE: could not synchronize")
            }
        }
    }

    /// MSE/PE handshake as the connecting side. Returns true if RC4 was
    /// negotiated (ciphers installed); false if plaintext was selected.
    func mseInitiatorHandshake(infoHash: InfoHash, requireEncryption: Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        let privateKey = MSEHandshake.randomPrivateKey()
        let publicKey = MSEHandshake.publicKey(privateKey: privateKey)
        try await sendRaw(Data(publicKey + randomPad()))

        let yb = try await receiveExactly(MSEHandshake.keyLength, deadline: deadline)
        let secret = MSEHandshake.sharedSecret(peerPublicKey: [UInt8](yb), privateKey: privateKey)
        let skey = [UInt8](infoHash.data)
        var encrypt = MSEHandshake.rc4Cipher(label: "keyA", secret: secret, skey: skey) // A→B
        var decrypt = MSEHandshake.rc4Cipher(label: "keyB", secret: secret, skey: skey) // B→A

        let cryptoProvide = requireEncryption
            ? MSEHandshake.cryptoRC4
            : (MSEHandshake.cryptoRC4 | MSEHandshake.cryptoPlaintext)
        var plain = Data()
        plain.append(contentsOf: MSEHandshake.vc)
        plain.appendUInt32(cryptoProvide)
        plain.appendUInt16(0) // len(PadC)
        plain.appendUInt16(0) // len(IA)
        var message = Data()
        message.append(contentsOf: MSEHandshake.req1(secret: secret))
        message.append(contentsOf: MSEHandshake.req2XorReq3(skey: skey, secret: secret))
        message.append(encrypt.process(plain))
        try await sendRaw(message)

        // Sync on ENCRYPT(VC): since VC is zeros it equals decrypt's first 8
        // keystream bytes (computed on a copy so `decrypt` stays put).
        var probe = decrypt
        let encryptedVC = [UInt8](probe.process(Data(MSEHandshake.vc)))
        try await syncToPattern(
            encryptedVC, maxSkip: MSEHandshake.keyLength + MSEHandshake.maxPad, deadline: deadline
        )
        _ = decrypt.process(Data(MSEHandshake.vc)) // advance past the VC we synced past

        let selectPlain = decrypt.process(try await receiveExactly(6, deadline: deadline))
        guard let cryptoSelect = selectPlain.readUInt32(at: 0),
              let padDLen = selectPlain.readUInt16(at: 4)
        else { throw PeerWireError.handshakeFailed("MSE: malformed select") }
        if padDLen > 0 {
            _ = decrypt.process(try await receiveExactly(Int(padDLen), deadline: deadline))
        }

        if cryptoSelect & MSEHandshake.cryptoRC4 != 0 {
            installCiphers(send: encrypt, receive: decrypt)
            return true
        }
        if !requireEncryption, cryptoSelect & MSEHandshake.cryptoPlaintext != 0 {
            return false
        }
        throw PeerWireError.handshakeFailed("MSE: peer selected no supported method")
    }

    /// MSE/PE handshake as the accepting side. `prefix` is the bytes already
    /// read while detecting the connection type (the start of the peer's DH
    /// key). Returns the matched torrent and whether RC4 was negotiated.
    func mseResponderHandshake(
        prefix: Data, infoHashes: [InfoHash], allowPlaintext: Bool
    ) async throws -> (infoHash: InfoHash, encrypted: Bool) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var ya = [UInt8](prefix)
        if ya.count < MSEHandshake.keyLength {
            ya += [UInt8](try await receiveExactly(MSEHandshake.keyLength - ya.count, deadline: deadline))
        }
        let privateKey = MSEHandshake.randomPrivateKey()
        let publicKey = MSEHandshake.publicKey(privateKey: privateKey)
        try await sendRaw(Data(publicKey + randomPad()))

        let secret = MSEHandshake.sharedSecret(
            peerPublicKey: Array(ya.prefix(MSEHandshake.keyLength)), privateKey: privateKey
        )

        // Skip PadA by syncing to the plaintext HASH('req1', S), then read the
        // obfuscated SKEY marker and identify which torrent it names.
        try await syncToPattern(
            MSEHandshake.req1(secret: secret), maxSkip: MSEHandshake.maxPad, deadline: deadline
        )
        let obfuscated = [UInt8](try await receiveExactly(20, deadline: deadline))
        let req2 = zip(obfuscated, MSEHandshake.req3(secret: secret)).map(^)
        guard let infoHash = infoHashes.first(where: {
            MSEHandshake.req2(skey: [UInt8]($0.data)) == req2
        }) else {
            throw PeerWireError.handshakeFailed("MSE: unknown torrent")
        }
        let skey = [UInt8](infoHash.data)
        var decrypt = MSEHandshake.rc4Cipher(label: "keyA", secret: secret, skey: skey) // A→B
        var encrypt = MSEHandshake.rc4Cipher(label: "keyB", secret: secret, skey: skey) // B→A

        let vc = decrypt.process(try await receiveExactly(8, deadline: deadline))
        guard [UInt8](vc) == MSEHandshake.vc else {
            throw PeerWireError.handshakeFailed("MSE: bad verification constant")
        }
        let provide = decrypt.process(try await receiveExactly(6, deadline: deadline))
        guard let cryptoProvide = provide.readUInt32(at: 0),
              let padCLen = provide.readUInt16(at: 4)
        else { throw PeerWireError.handshakeFailed("MSE: malformed provide") }
        if padCLen > 0 {
            _ = decrypt.process(try await receiveExactly(Int(padCLen), deadline: deadline))
        }
        let iaLen = Int(decrypt.process(try await receiveExactly(2, deadline: deadline)).readUInt16(at: 0) ?? 0)
        var iaPlain = Data()
        if iaLen > 0 {
            iaPlain = decrypt.process(try await receiveExactly(iaLen, deadline: deadline))
        }

        let useRC4 = cryptoProvide & MSEHandshake.cryptoRC4 != 0
        let cryptoSelect = useRC4
            ? MSEHandshake.cryptoRC4
            : (allowPlaintext && cryptoProvide & MSEHandshake.cryptoPlaintext != 0
               ? MSEHandshake.cryptoPlaintext : 0)
        guard cryptoSelect != 0 else {
            throw PeerWireError.handshakeFailed("MSE: no common method")
        }

        var response = Data()
        response.append(contentsOf: MSEHandshake.vc)
        response.appendUInt32(cryptoSelect)
        response.appendUInt16(0) // len(PadD)
        try await sendRaw(encrypt.process(response))

        if cryptoSelect == MSEHandshake.cryptoRC4 {
            installCiphers(send: encrypt, receive: decrypt)
        }
        // Any initial payload the peer inlined precedes the following stream.
        if !iaPlain.isEmpty { buffer = iaPlain + buffer }
        return (infoHash, cryptoSelect == MSEHandshake.cryptoRC4)
    }

    /// Reads exactly `count` plaintext bytes (used by incoming-connection type
    /// detection before any encryption is set up).
    func receiveRawBytes(_ count: Int, timeout: Duration = .seconds(20)) async throws -> Data {
        try await receiveExactly(count, deadline: .now.advanced(by: timeout))
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

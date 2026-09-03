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
    /// Bytes before this index in `buffer` have already been handed out.
    /// Advancing an index beats `removeFirst`, which copied the remainder on
    /// every read and made the byte-at-a-time MSE scan quadratic.
    private var bufferOffset = 0
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
    /// This torrent's own buckets, when it carries a limit of its own. Taken
    /// *before* the session's: the shared budget is the contended one, so it is
    /// held for as short a time as possible — acquiring it first would leave
    /// bandwidth idle while a capped torrent waits on its own bucket.
    private var torrentDownloadLimiter: RateLimiter?
    private var torrentUploadLimiter: RateLimiter?

    /// MSE/PE stream ciphers, installed once the encrypted handshake completes.
    /// While nil, the wire is plaintext (and the MSE handshake reads/writes raw
    /// bytes, applying its own transient ciphers).
    private var rc4Send: RC4?
    private var rc4Receive: RC4?
    /// True once an MSE handshake negotiated RC4 for this connection.
    private(set) var isEncrypted = false

    func setLimiters(
        download: RateLimiter?,
        upload: RateLimiter?,
        torrentDownload: RateLimiter? = nil,
        torrentUpload: RateLimiter? = nil
    ) {
        downloadLimiter = download
        uploadLimiter = upload
        torrentDownloadLimiter = torrentDownload
        torrentUploadLimiter = torrentUpload
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
        if case .ready = state { return }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            await self?.failReadyWaiter(PeerWireError.timeout)
        }
        defer { timeoutTask.cancel() }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                readyWaiter = continuation
                resolveReadyWaiter() // in case the state moved before we parked
            }
        } catch {
            connection.cancel()
            throw error
        }
    }

    /// Parked caller of `start`, waiting for the connection to become ready.
    private var readyWaiter: CheckedContinuation<Void, Error>?

    private func resolveReadyWaiter() {
        guard let continuation = readyWaiter else { return }
        switch state {
        case .ready:
            readyWaiter = nil
            continuation.resume()
        case .failed(let error):
            readyWaiter = nil
            continuation.resume(throwing: PeerWireError.network(error.localizedDescription))
        case .cancelled:
            readyWaiter = nil
            continuation.resume(throwing: PeerWireError.connectionClosed)
        default:
            break
        }
    }

    private func failReadyWaiter(_ error: Error) {
        guard let continuation = readyWaiter else { return }
        readyWaiter = nil
        continuation.resume(throwing: error)
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
        resolveReadyWaiter()
        if closed { serviceWaiter() }
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
        } else if let count = data?.count, count > 0,
                  downloadLimiter != nil || torrentDownloadLimiter != nil {
            // Throttle by delaying the next read; TCP backpressure does the rest.
            let torrent = torrentDownloadLimiter
            let session = downloadLimiter
            Task {
                await torrent?.acquire(count)
                await session?.acquire(count)
                self.pump()
            }
        } else {
            pump()
        }
        serviceWaiter()
    }

    // MARK: - Reading

    /// The single outstanding reader. Only one exists at a time — the peer loop
    /// reads sequentially and the handshakes are strictly ordered. `generation`
    /// lets a timeout fire harmlessly against a read that has since replaced it.
    private struct Waiter {
        let count: Int
        let generation: UInt64
        let continuation: CheckedContinuation<Data, Error>
    }
    private var waiter: Waiter?
    private var waiterGeneration: UInt64 = 0

    private func drainChunks() {
        guard !receivedChunks.isEmpty else { return }
        for chunk in receivedChunks { buffer.append(chunk) }
        receivedChunks.removeAll(keepingCapacity: true)
    }

    private var availableBytes: Int { buffer.count - bufferOffset }

    /// Drops the already-consumed prefix. Called when it grows large, and before
    /// any in-place rewrite of the buffer.
    private func compactBuffer() {
        guard bufferOffset > 0 else { return }
        buffer.removeFirst(bufferOffset)
        bufferOffset = 0
    }

    private func takeExactly(_ count: Int) -> Data {
        let start = buffer.startIndex + bufferOffset
        let out = Data(buffer[start..<start + count])
        bufferOffset += count
        // Amortised compaction: reclaim once the consumed prefix is both large
        // and most of the buffer.
        if bufferOffset > 4096, bufferOffset * 2 >= buffer.count {
            compactBuffer()
        }
        return out
    }

    /// Suspends until `count` bytes are buffered, the connection closes, or the
    /// deadline passes.
    ///
    /// This used to poll every 10 ms, so every connected peer held a task waking
    /// 100 times a second whether or not traffic was flowing — tens of thousands
    /// of wakeups per second across a normal peer set, and up to 10 ms of added
    /// latency on every message.
    private func receiveExactly(_ count: Int, deadline: ContinuousClock.Instant) async throws -> Data {
        drainChunks()
        if availableBytes >= count { return takeExactly(count) }
        if closed { throw closeError ?? PeerWireError.connectionClosed }
        if ContinuousClock.now >= deadline { throw PeerWireError.timeout }
        precondition(waiter == nil, "PeerConnection supports one reader at a time")

        waiterGeneration &+= 1
        let generation = waiterGeneration
        let timeout = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            await self?.failWaiter(generation: generation, with: PeerWireError.timeout)
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            // Runs synchronously before this function suspends, so the timeout
            // task above cannot slip in ahead of the waiter being installed.
            waiter = Waiter(count: count, generation: generation, continuation: continuation)
        }
    }

    /// Hands buffered bytes to the waiting reader once its request can be met,
    /// or fails it if the connection died first.
    private func serviceWaiter() {
        guard let pending = waiter else { return }
        drainChunks()
        if availableBytes >= pending.count {
            waiter = nil
            pending.continuation.resume(returning: takeExactly(pending.count))
        } else if closed {
            waiter = nil
            pending.continuation.resume(throwing: closeError ?? PeerWireError.connectionClosed)
        }
    }

    private func failWaiter(generation: UInt64, with error: Error) {
        guard let pending = waiter, pending.generation == generation else { return }
        waiter = nil
        pending.continuation.resume(throwing: error)
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

    /// Cap on unsent messages. A peer that isn't draining is a dead peer.
    private static let maxQueuedMessages = 512

    private var outbound: [Data] = []
    private var draining = false

    /// Queues a message and returns without waiting for the wire.
    ///
    /// Callers used to `await send(_:)`, which parks on the upload rate limiter.
    /// Doing that in a loop — a HAVE to every peer on each completed piece, the
    /// keep-alive sweep, the choker's round — stalled the *calling* peer's read
    /// loop for as long as all those sends took to clear the bucket, which on
    /// the peer that had just delivered a piece is exactly the connection you
    /// least want to stall.
    ///
    /// Everything after the BitTorrent handshake must go through here rather
    /// than `send`: the queue is what keeps `bitfield` ahead of any `have` that
    /// lands while it is still waiting on the limiter.
    func enqueue(_ message: PeerMessage) {
        guard !closed else { return }
        guard outbound.count < Self.maxQueuedMessages else {
            outbound.removeAll()
            connection.cancel()
            return
        }
        outbound.append(message.encoded())
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    /// Single drain task per connection, so the RC4 keystream stays aligned
    /// with the order bytes hit the socket.
    private func drain() async {
        while !outbound.isEmpty, !closed {
            let payload = outbound.removeFirst()
            await torrentUploadLimiter?.acquire(payload.count)
            await uploadLimiter?.acquire(payload.count)
            guard !closed else { break }
            bytesSent += Int64(payload.count)
            // No await between the cipher and the send, so this pair is atomic
            // against any other writer on this actor.
            let wire = rc4Send != nil ? rc4Send!.process(payload) : payload
            connection.send(content: wire, completion: .contentProcessed { _ in })
        }
        draining = false
    }

    func send(_ message: PeerMessage) async throws {
        try await sendRaw(message.encoded())
    }

    func sendHandshake(_ handshake: Handshake) async throws {
        try await sendRaw(handshake.encoded())
    }

    private func sendRaw(_ data: Data) async throws {
        guard !closed else { throw closeError ?? PeerWireError.connectionClosed }
        await torrentUploadLimiter?.acquire(data.count)
        await uploadLimiter?.acquire(data.count)
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
        // Only the unread remainder is ciphertext; drop the consumed prefix so
        // the decrypt below lines up with the keystream.
        compactBuffer()
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
        guard let secret = MSEHandshake.sharedSecret(
            peerPublicKey: [UInt8](yb), privateKey: privateKey
        ) else {
            throw PeerWireError.handshakeFailed("MSE: degenerate public key")
        }
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

        guard let secret = MSEHandshake.sharedSecret(
            peerPublicKey: Array(ya.prefix(MSEHandshake.keyLength)), privateKey: privateKey
        ) else {
            throw PeerWireError.handshakeFailed("MSE: degenerate public key")
        }

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
        if !iaPlain.isEmpty {
            compactBuffer()
            buffer = iaPlain + buffer
        }
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

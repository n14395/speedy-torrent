// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit

/// Resolves a magnet link into a verified info dictionary by fetching it from
/// peers via ut_metadata (BEP 9). Once resolved, the session replaces this
/// with a real TorrentController.
actor MagnetController {
    nonisolated let magnet: MagnetLink
    private let sessionPeerID: Data
    private let listenPort: UInt16
    private let trackers: TrackerManager
    private let announceKey = UInt32.random(in: .min ... .max)
    /// Called once metadata is verified. Absent while the magnet is only being
    /// prefetched (see TorrentSession's metadata prefetch); set by `commit`
    /// when the user turns a prefetch into a real download before it resolves.
    private var onResolved: (@Sendable (Data) async -> Void)?
    /// Session-provided DHT lookup; polled until the magnet resolves.
    private let discoverPeers: (@Sendable () async -> [PeerAddress])?
    private var discovering = false
    /// Where the torrent will download once metadata arrives (settable while
    /// unresolved — there are no files to move yet).
    private(set) var downloadDirectory: URL
    private(set) var sequential: Bool
    private let encryptionPolicy: EncryptionPolicy

    private var knownAddresses: Set<PeerAddress> = []
    private var attemptedRecently: Set<PeerAddress> = []
    private var activeFetches = 0
    private var resolved = false
    /// The verified raw info dictionary once resolved (held for prefetch/commit).
    private var resolvedData: Data?
    private var stopped = false
    private var mainTask: Task<Void, Never>?
    /// Preserved across restarts for restored magnets.
    nonisolated let addedAt: Double

    init(
        magnet: MagnetLink,
        sessionPeerID: Data,
        listenPort: UInt16,
        downloadDirectory: URL,
        sequential: Bool,
        encryptionPolicy: EncryptionPolicy = .disabled,
        addedAt: Double = Date().timeIntervalSince1970,
        discoverPeers: (@Sendable () async -> [PeerAddress])? = nil,
        onResolved: (@Sendable (Data) async -> Void)? = nil
    ) {
        self.addedAt = addedAt
        self.magnet = magnet
        self.sessionPeerID = sessionPeerID
        self.listenPort = listenPort
        self.downloadDirectory = downloadDirectory
        self.sequential = sequential
        self.encryptionPolicy = encryptionPolicy
        self.trackers = TrackerManager(tiers: magnet.trackers.map { [$0] })
        self.discoverPeers = discoverPeers
        self.onResolved = onResolved
    }

    func setDownloadDirectory(_ url: URL) {
        downloadDirectory = url
    }

    func setSequential(_ sequential: Bool) {
        self.sequential = sequential
    }

    func start() {
        mainTask = Task { await self.run() }
    }

    func stop() {
        stopped = true
        mainTask?.cancel()
    }

    func addKnownPeers(_ addresses: [PeerAddress]) {
        knownAddresses.formUnion(addresses)
    }

    var knownPeers: Set<PeerAddress> { knownAddresses }

    func snapshot() -> TorrentSnapshot {
        TorrentSnapshot(
            infoHash: magnet.infoHash,
            name: magnet.displayName ?? magnet.infoHash.hexString,
            totalLength: 0,
            wantedLength: 0,
            completedLength: 0,
            downloadedTotal: 0,
            uploadedTotal: 0,
            downloadRate: 0,
            uploadRate: 0,
            state: .fetchingMetadata,
            peerCount: knownAddresses.count,
            pieceCount: 0,
            havePieces: 0,
            errorMessage: nil,
            downloadDirectory: downloadDirectory.path,
            sequential: sequential,
            // A magnet has no transfer to cap yet; limits become settable once
            // metadata arrives and it becomes a real torrent.
            downloadRateLimit: nil,
            uploadRateLimit: nil,
            addedAt: addedAt,
            pieceLength: 0
        )
    }

    private func run() async {
        // Announce to the magnet's trackers on a slow loop while dialing peers.
        let announceTask = Task { await self.runAnnounces() }
        defer { announceTask.cancel() }

        var iteration = 0
        while !Task.isCancelled, !resolved, !stopped {
            // Poll the DHT frequently until resolved (a lookup takes seconds
            // itself, so run it as a side task, one at a time).
            if let discoverPeers, !discovering, iteration % 5 == 0 {
                discovering = true
                Task {
                    let found = await discoverPeers()
                    await self.discoveryFinished(found)
                }
            }
            iteration += 1

            let candidates = knownAddresses.subtracting(attemptedRecently).shuffled()
            for address in candidates.prefix(max(0, 5 - activeFetches)) {
                attemptedRecently.insert(address)
                activeFetches += 1
                Task {
                    await self.fetchMetadata(from: address)
                    await self.fetchFinished()
                }
            }
            // Let stalled addresses be retried once the pool drains.
            if attemptedRecently.count >= knownAddresses.count, activeFetches == 0 {
                attemptedRecently.removeAll()
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func fetchFinished() {
        activeFetches -= 1
    }

    private func discoveryFinished(_ found: [PeerAddress]) {
        discovering = false
        knownAddresses.formUnion(found)
    }

    private func runAnnounces() async {
        guard !magnet.trackers.isEmpty else { return }
        while !Task.isCancelled, !resolved {
            let request = AnnounceRequest(
                infoHash: magnet.infoHash,
                peerID: sessionPeerID,
                port: listenPort,
                left: 65536, // unknown size
                event: .none,
                numWant: 80,
                key: announceKey
            )
            if let response = try? await trackers.announce(request) {
                addKnownPeers(response.peers)
            }
            try? await Task.sleep(for: .seconds(120))
        }
    }

    /// One peer's metadata fetch, mirroring the download path's encryption
    /// policy: try MSE first, then retry in plaintext for peers that can't do
    /// it (without the retry, magnets stall forever in a plaintext swarm).
    private func fetchMetadata(from address: PeerAddress) async {
        if await attemptFetch(
            from: address,
            encrypt: encryptionPolicy != .disabled,
            require: encryptionPolicy == .required
        ) {
            return
        }
        if encryptionPolicy == .preferred, !resolved, !stopped {
            _ = await attemptFetch(from: address, encrypt: false, require: false)
        }
    }

    /// One peer's metadata-fetch conversation. Returns false when the
    /// connection failed outright, so the caller may retry differently.
    private func attemptFetch(
        from address: PeerAddress, encrypt: Bool, require: Bool
    ) async -> Bool {
        let connection = PeerConnection(address: address)
        defer { connection.close() }
        do {
            try await connection.start()
            if encrypt {
                _ = try await connection.mseInitiatorHandshake(
                    infoHash: magnet.infoHash, requireEncryption: require
                )
            }
            try await connection.sendHandshake(Handshake(
                infoHash: magnet.infoHash, peerID: sessionPeerID
            ))
            let theirs = try await connection.receiveHandshake()
            guard theirs.infoHash == magnet.infoHash,
                  theirs.supportsExtensions,
                  theirs.peerID != sessionPeerID
            else { return true } // reachable, just not useful — don't retry
            try await connection.send(.extended(id: 0, payload: ExtensionHandshake.encode(
                metadataSize: nil, listenPort: listenPort
            )))

            var theirUTMetadataID: UInt8?
            var metadataSize = 0
            var assembled: [Int: Data] = [:]
            var requested = -1
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))

            while ContinuousClock.now < deadline, !resolved {
                let message = try await connection.receiveMessage(idleTimeout: .seconds(30))
                guard case .extended(let id, let payload) = message else { continue }

                if id == 0 {
                    guard let parsed = ExtensionHandshake.parse(payload),
                          let utID = parsed.utMetadataID,
                          let size = parsed.metadataSize,
                          size > 0, size <= UTMetadata.maxMetadataSize
                    else { return true }
                    theirUTMetadataID = utID
                    metadataSize = size
                    requested = 0
                    try await connection.send(.extended(
                        id: utID, payload: UTMetadata.request(piece: 0)
                    ))
                    continue
                }

                guard id == ExtensionHandshake.utMetadataID,
                      let utID = theirUTMetadataID,
                      let parsed = UTMetadata.parse(payload)
                else { continue }
                switch parsed.type {
                case .data:
                    // Bound the chunk before storing it. An extended message may
                    // carry up to PeerMessage.maxPayloadLength (4 MB) and
                    // metadataSize permits 512 pieces, so an unchecked peer
                    // could push ~2 GB into `assembled` before the info-hash
                    // check at the end ever got to reject it.
                    guard parsed.piece == requested,
                          parsed.trailing.count <= UTMetadata.pieceSize
                    else { continue }
                    assembled[parsed.piece] = parsed.trailing
                    let pieceCount = (metadataSize + UTMetadata.pieceSize - 1) / UTMetadata.pieceSize
                    if assembled.count == pieceCount {
                        var full = Data(capacity: metadataSize)
                        for index in 0..<pieceCount {
                            full.append(assembled[index] ?? Data())
                        }
                        guard full.count == metadataSize,
                              InfoHash(hashing: full) == magnet.infoHash
                        else { return true } // corrupt metadata from this peer
                        await deliver(full)
                        return true
                    }
                    requested += 1
                    try await connection.send(.extended(
                        id: utID, payload: UTMetadata.request(piece: requested)
                    ))
                case .reject:
                    return true
                case .request:
                    // We have nothing to serve yet.
                    try await connection.send(.extended(
                        id: utID, payload: UTMetadata.reject(piece: parsed.piece)
                    ))
                }
            }
            return true
        } catch {
            // Connection failed or timed out: worth one retry with different
            // encryption; failing that, the dial loop tries other peers.
            return false
        }
    }

    private func deliver(_ infoData: Data) async {
        guard !resolved else { return }
        resolved = true
        resolvedData = infoData
        if let onResolved {
            await onResolved(infoData)
        }
    }

    /// The verified raw info dictionary, or nil while metadata is still being
    /// fetched. Used by prefetch to populate the add sheet before committing.
    var resolvedInfoData: Data? { resolvedData }

    enum CommitOutcome: Sendable {
        /// Metadata already arrived; caller builds the torrent from this data.
        case resolved(Data)
        /// Still fetching; `convert` has been armed and will fire on resolve.
        case pending
    }

    /// Turns a prefetch into a committed download. If metadata already arrived
    /// it is returned so the session can build the torrent immediately;
    /// otherwise the resolve callback is armed so the in-flight fetch converts
    /// itself once it completes. Atomic with `deliver` (both actor-isolated).
    func commit(onResolve convert: @escaping @Sendable (Data) async -> Void) -> CommitOutcome {
        if let resolvedData {
            return .resolved(resolvedData)
        }
        onResolved = convert
        return .pending
    }
}

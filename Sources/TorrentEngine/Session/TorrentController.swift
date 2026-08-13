import Foundation
import CryptoKit

public enum TorrentState: String, Sendable {
    case fetchingMetadata
    case checking
    /// Content is being relocated to a new download directory.
    case moving
    case downloading
    case seeding
    case paused
    case failed
}

/// One file inside a torrent, with its selection state.
public struct TorrentFileStatus: Sendable, Identifiable, Equatable {
    public var id: Int { index }
    public let index: Int
    public let path: [String]
    public let length: Int64
    public let wanted: Bool
}

/// A point-in-time view of one torrent, for UI/CLI display.
public struct TorrentSnapshot: Sendable, Identifiable {
    public var id: InfoHash { infoHash }
    public let infoHash: InfoHash
    public let name: String
    public let totalLength: Int64
    /// Bytes covered by the wanted-file selection (progress denominator).
    public let wantedLength: Int64
    public let completedLength: Int64
    public let downloadedTotal: Int64
    public let uploadedTotal: Int64
    public let downloadRate: Double
    public let uploadRate: Double
    public let state: TorrentState
    public let peerCount: Int
    public let pieceCount: Int
    public let havePieces: Int
    public let errorMessage: String?
    /// Per-torrent settings, for the settings UI.
    public let downloadDirectory: String
    public let sequential: Bool

    public var progress: Double {
        wantedLength > 0 ? Double(completedLength) / Double(wantedLength) : 0
    }

    public var eta: TimeInterval? {
        guard state == .downloading, downloadRate > 1 else { return nil }
        return Double(max(0, wantedLength - completedLength)) / downloadRate
    }

    public var ratio: Double {
        downloadedTotal > 0 ? Double(uploadedTotal) / Double(downloadedTotal)
            : (completedLength > 0 ? Double(uploadedTotal) / Double(completedLength) : 0)
    }
}

struct ControllerConfig: Sendable {
    var maxPeers = 40
    var maxOutstandingPerPeer = 32
    var listenPort: UInt16 = 6881
    var sequential = false
}

/// Per-torrent orchestrator: owns the peer set, piece manager, storage, and
/// announce/tick loops.
actor TorrentController {
    typealias PeerKey = ObjectIdentifier

    /// Per-peer protocol state (confined to this actor).
    private final class Peer {
        let connection: PeerConnection
        let peerID: Data
        var amChoking = true
        var amInterested = false
        var peerChoking = true
        var peerInterested = false
        var bitfield: Bitfield
        var outstanding: [BlockRef: ContinuousClock.Instant] = [:]
        var downloadedPayload: Int64 = 0
        var uploadedPayload: Int64 = 0
        var corruptPieces = 0
        var lastReceived = ContinuousClock.now
        var supportsExtensions: Bool
        // Per-peer transfer rates (1s-tick EMAs) driving the choke algorithm.
        var downloadRateEMA: Double = 0
        var uploadRateEMA: Double = 0
        var lastDownloadedPayload: Int64 = 0
        var lastUploadedPayload: Int64 = 0
        /// The peer's message ID for ut_metadata (from its extended handshake).
        var theirUTMetadataID: UInt8?

        init(connection: PeerConnection, peerID: Data, pieceCount: Int, supportsExtensions: Bool) {
            self.connection = connection
            self.peerID = peerID
            self.bitfield = Bitfield(count: pieceCount)
            self.supportsExtensions = supportsExtensions
        }
    }

    let info: TorrentInfo
    private var store: FileStore
    private let pieces: PieceManager
    private let trackers: TrackerManager
    private let sessionPeerID: Data
    private let announceKey = UInt32.random(in: .min ... .max)
    private var config: ControllerConfig
    private var downloadDirectory: URL
    private let persistence: PersistenceStore?
    private let initialResume: ResumeData?
    private let addedAt: Double
    private let downloadLimiter: RateLimiter?
    private let uploadLimiter: RateLimiter?

    private var peers: [PeerKey: Peer] = [:]
    private var peerTasks: [UUID: Task<Void, Never>] = [:]
    private var knownAddresses: Set<PeerAddress> = []
    private var connectedAddresses: Set<PeerAddress> = []
    private var bannedAddresses: Set<PeerAddress> = []
    /// Peers that supplied blocks for a piece, for corruption attribution.
    private var pieceContributors: [Int: Set<PeerKey>] = [:]

    private var state: TorrentState = .checking
    private var errorMessage: String?
    private var uploadedTotal: Int64 = 0
    private var downloadedTotal: Int64 = 0
    private var downloadRate: Double = 0
    private var uploadRate: Double = 0
    private var lastDownloadedTotal: Int64 = 0
    private var lastUploadedTotal: Int64 = 0
    private var tickCount = 0

    private var tickTask: Task<Void, Never>?
    private var announceTask: Task<Void, Never>?

    init(
        info: TorrentInfo,
        announceTiers: [[String]],
        downloadDirectory: URL,
        sessionPeerID: Data,
        config: ControllerConfig,
        persistence: PersistenceStore? = nil,
        initialResume: ResumeData? = nil,
        wantedFiles: Set<Int>? = nil,
        downloadLimiter: RateLimiter? = nil,
        uploadLimiter: RateLimiter? = nil
    ) {
        self.info = info
        self.store = FileStore(info: info, downloadDirectory: downloadDirectory)
        let resumeWanted = initialResume?.unwantedFiles.map {
            Set(info.files.indices).subtracting($0)
        }
        self.pieces = PieceManager(
            info: info,
            sequential: initialResume?.sequential ?? config.sequential,
            wantedFiles: wantedFiles ?? resumeWanted
        )
        self.trackers = TrackerManager(tiers: announceTiers)
        self.sessionPeerID = sessionPeerID
        self.config = config
        self.downloadDirectory = downloadDirectory
        self.persistence = persistence
        self.initialResume = initialResume
        self.addedAt = initialResume?.addedAt ?? Date().timeIntervalSince1970
        self.downloadLimiter = downloadLimiter
        self.uploadLimiter = uploadLimiter
    }

    // MARK: - Lifecycle

    func start() async {
        state = .checking
        do {
            let hadExistingData = try await store.preallocate(wantedPieces: pieces.wantedPieceBitfield())
            var trustedResume = false
            if let resume = initialResume,
               let bitfieldData = Data(base64Encoded: resume.bitfieldBase64),
               let saved = Bitfield(data: bitfieldData, count: info.pieceCount) {
                uploadedTotal = resume.uploaded
                downloadedTotal = resume.downloaded
                lastUploadedTotal = uploadedTotal
                lastDownloadedTotal = downloadedTotal
                // Trust the saved bitfield only if no file changed since save.
                if await store.fileStamps() == resume.fileStamps {
                    for index in 0..<info.pieceCount where saved[index] {
                        pieces.markHave(index)
                    }
                    trustedResume = true
                }
            }
            if !trustedResume, hadExistingData {
                let existing = await store.verifyAllPieces()
                for index in 0..<info.pieceCount where existing[index] {
                    pieces.markHave(index)
                }
            }
            // Rename any already-complete files to their final names (and
            // revert wrongly-named ones back to .part).
            await store.reconcile(have: pieces.have)
        } catch {
            state = .failed
            errorMessage = "storage: \(error)"
            return
        }

        if initialResume?.paused == true {
            state = .paused
            tickTask = Task { await self.runTicks() }
            return
        }
        state = pieces.isWantedComplete ? .seeding : .downloading
        tickTask = Task { await self.runTicks() }
        announceTask = Task { await self.runAnnounces() }
    }

    func stop() async {
        let wasActive = state == .downloading || state == .seeding
        tickTask?.cancel()
        announceTask?.cancel()
        for task in peerTasks.values {
            task.cancel()
        }
        for peer in peers.values {
            peer.connection.close()
        }
        peers.removeAll()
        connectedAddresses.removeAll()
        await store.close()
        await saveResume()
        if wasActive {
            await trackers.announceAll(makeAnnounceRequest(event: .stopped))
        }
    }

    func pause() async {
        guard state == .downloading || state == .seeding else { return }
        state = .paused
        announceTask?.cancel()
        announceTask = nil
        for peer in peers.values {
            peer.connection.close()
        }
        await saveResume()
        Task { await self.trackers.announceAll(self.makeAnnounceRequest(event: .stopped)) }
    }

    func resumeActivity() async {
        guard state == .paused else { return }
        state = pieces.isWantedComplete ? .seeding : .downloading
        announceTask = Task { await self.runAnnounces() }
        dialPeers()
        await saveResume()
    }

    func deleteFiles() async {
        await store.deleteAllFiles()
    }

    private func saveResume() async {
        guard let persistence else { return }
        let resume = ResumeData(
            infoHashHex: info.infoHash.hexString,
            bitfieldBase64: pieces.have.data.base64EncodedString(),
            downloadDirectory: downloadDirectory.path,
            uploaded: uploadedTotal,
            downloaded: downloadedTotal,
            paused: state == .paused,
            sequential: pieces.sequential,
            unwantedFiles: {
                let unwanted = Set(info.files.indices).subtracting(pieces.wantedFiles)
                return unwanted.isEmpty ? nil : unwanted.sorted()
            }(),
            addedAt: addedAt,
            fileStamps: await store.fileStamps()
        )
        persistence.saveResume(resume, for: info.infoHash)
    }

    func setSequential(_ sequential: Bool) async {
        guard pieces.sequential != sequential else { return }
        pieces.sequential = sequential
        await saveResume()
    }

    /// Relocates the torrent to a new download directory: transfer stops,
    /// existing content is moved on disk, storage is remapped, and the
    /// download/seed continues. Verified pieces stay verified.
    func setDownloadDirectory(_ newDirectory: URL) async throws {
        let normalizedNew = newDirectory.standardizedFileURL
        guard normalizedNew != downloadDirectory.standardizedFileURL else { return }
        guard state != .moving else { throw SessionError.moveFailed("a move is already in progress") }

        let previousState = state
        state = .moving
        // Stop transfer: peers drop, their read loops unwind, and the
        // message-handling guards below keep the old store untouched.
        for peer in peers.values {
            peer.connection.close()
        }
        await store.close()

        let newStore = FileStore(info: info, downloadDirectory: normalizedNew)
        // Relocate every top-level on-disk entry (content dir, or the single
        // final/.part file) into the new download directory.
        let items = await store.onDiskItems()
        do {
            let fileManager = FileManager.default
            let moves = items.map { source -> (URL, URL) in
                (source, normalizedNew.appendingPathComponent(source.lastPathComponent))
            }
            for (_, destination) in moves where fileManager.fileExists(atPath: destination.path) {
                throw SessionError.moveFailed("“\(destination.lastPathComponent)” already exists in the destination folder")
            }
            try fileManager.createDirectory(at: normalizedNew, withIntermediateDirectories: true)
            // Off-actor: cross-volume moves copy and can take a while.
            try await Task.detached(priority: .utility) {
                for (source, destination) in moves {
                    try fileManager.moveItem(at: source, to: destination)
                }
            }.value
        } catch let error as SessionError {
            state = previousState
            throw error
        } catch {
            state = previousState
            throw SessionError.moveFailed(error.localizedDescription)
        }

        store = newStore
        downloadDirectory = normalizedNew
        do {
            _ = try await store.preallocate(wantedPieces: pieces.wantedPieceBitfield())
            await store.reconcile(have: pieces.have)
        } catch {
            state = .failed
            errorMessage = "storage: \(error)"
            throw SessionError.moveFailed("moved, but could not reopen files: \(error)")
        }
        state = previousState == .paused ? .paused : (pieces.isWantedComplete ? .seeding : .downloading)
        await saveResume()
        dialPeers()
    }

    // MARK: - File selection

    func fileStatuses() -> [TorrentFileStatus] {
        info.files.enumerated().map { index, file in
            TorrentFileStatus(
                index: index,
                path: file.path,
                length: file.length,
                wanted: pieces.wantedFiles.contains(index)
            )
        }
    }

    /// Changes which files are downloaded. A seeding torrent that gains new
    /// wanted files goes back to downloading; a downloading torrent whose
    /// remaining wants are already on disk flips to seeding.
    func setWantedFiles(_ wanted: Set<Int>) async {
        guard !wanted.isEmpty else { return }
        pieces.setWantedFiles(wanted)
        // Create any newly-wanted files that were skipped at allocation time.
        _ = try? await store.preallocate(wantedPieces: pieces.wantedPieceBitfield())

        if state == .seeding, !pieces.isWantedComplete {
            state = .downloading
            dialPeers()
        } else if state == .downloading, pieces.isWantedComplete {
            await downloadCompleted()
        }
        // Interest can flip in either direction for every peer.
        for (key, peer) in peers {
            try? await updateInterest(peer: peer, key: key)
        }
        // A newly-wanted file already present on disk should be finalized.
        await store.reconcile(have: pieces.have)
        await saveResume()
    }

    var contentURL: URL { store.revealURL() }

    func addKnownPeers(_ addresses: [PeerAddress]) {
        for address in addresses where !bannedAddresses.contains(address) {
            knownAddresses.insert(address)
        }
        dialPeers()
    }

    // MARK: - Snapshot

    func snapshot() -> TorrentSnapshot {
        TorrentSnapshot(
            infoHash: info.infoHash,
            name: info.name,
            totalLength: info.totalLength,
            wantedLength: pieces.wantedBytes,
            completedLength: pieces.completedWantedBytes,
            downloadedTotal: downloadedTotal,
            uploadedTotal: uploadedTotal,
            downloadRate: downloadRate,
            uploadRate: uploadRate,
            state: state,
            peerCount: peers.count,
            pieceCount: info.pieceCount,
            havePieces: pieces.have.setCount,
            errorMessage: errorMessage,
            downloadDirectory: downloadDirectory.path,
            sequential: pieces.sequential
        )
    }

    // MARK: - Announce loop

    private func makeAnnounceRequest(event: AnnounceEvent) -> AnnounceRequest {
        AnnounceRequest(
            infoHash: info.infoHash,
            peerID: sessionPeerID,
            port: config.listenPort,
            uploaded: uploadedTotal,
            downloaded: downloadedTotal,
            left: max(0, pieces.wantedBytes - pieces.completedWantedBytes),
            event: event,
            key: announceKey
        )
    }

    private func runAnnounces() async {
        let tiers = await trackers.allTrackers
        guard !tiers.isEmpty else { return }
        var event = AnnounceEvent.started
        // Runs until cancelled (stop/pause cancel the task); keeps announcing
        // through transient states like .moving.
        while !Task.isCancelled, state != .failed {
            var interval = 120
            do {
                let response = try await trackers.announce(makeAnnounceRequest(event: event))
                event = .none
                interval = min(max(response.interval, 60), 3600)
                addKnownPeers(response.peers)
            } catch {
                // Keep retrying on a slow cadence; peers may still arrive via
                // incoming connections or DHT.
            }
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
        }
    }

    func announceCompleted() async {
        _ = try? await trackers.announce(makeAnnounceRequest(event: .completed))
    }

    // MARK: - Peer dialing

    private func dialPeers() {
        guard state == .downloading || state == .seeding else { return }
        for address in knownAddresses.shuffled() {
            guard connectedAddresses.count < config.maxPeers else { break }
            guard !connectedAddresses.contains(address), !bannedAddresses.contains(address) else { continue }
            connectedAddresses.insert(address)
            let taskID = UUID()
            peerTasks[taskID] = Task {
                await self.runOutgoingPeer(address)
                await self.finishPeerTask(taskID)
            }
        }
    }

    private func finishPeerTask(_ id: UUID) {
        peerTasks[id] = nil
    }

    private func runOutgoingPeer(_ address: PeerAddress) async {
        let connection = PeerConnection(address: address)
        do {
            await connection.setLimiters(download: downloadLimiter, upload: uploadLimiter)
            try await connection.start()
            try await connection.sendHandshake(
                Handshake(infoHash: info.infoHash, peerID: sessionPeerID)
            )
            let theirs = try await connection.receiveHandshake()
            guard theirs.infoHash == info.infoHash, theirs.peerID != sessionPeerID else {
                throw PeerWireError.handshakeFailed("wrong torrent or self-connection")
            }
            await runPeerLoop(connection: connection, handshake: theirs, address: address)
        } catch {
            connection.close()
            connectedAddresses.remove(address)
        }
    }

    /// Adopts an incoming connection whose handshake the session already read.
    func adoptIncoming(connection: PeerConnection, handshake: Handshake) async {
        guard state == .downloading || state == .seeding,
              peers.count < config.maxPeers + 10,
              handshake.peerID != sessionPeerID
        else {
            connection.close()
            return
        }
        await connection.setLimiters(download: downloadLimiter, upload: uploadLimiter)
        let address = connection.address
        connectedAddresses.insert(address)
        let taskID = UUID()
        peerTasks[taskID] = Task {
            do {
                try await connection.sendHandshake(
                    Handshake(infoHash: self.info.infoHash, peerID: self.sessionPeerID)
                )
                await self.runPeerLoop(connection: connection, handshake: handshake, address: address)
            } catch {
                connection.close()
                await self.removeAddress(address)
            }
            await self.finishPeerTask(taskID)
        }
    }

    private func removeAddress(_ address: PeerAddress) {
        connectedAddresses.remove(address)
    }

    private func runPeerLoop(connection: PeerConnection, handshake: Handshake, address: PeerAddress) async {
        let key = PeerKey(connection)
        let peer = Peer(
            connection: connection,
            peerID: handshake.peerID,
            pieceCount: info.pieceCount,
            supportsExtensions: handshake.supportsExtensions
        )
        peers[key] = peer

        do {
            if handshake.supportsExtensions {
                try await connection.send(.extended(id: 0, payload: ExtensionHandshake.encode(
                    metadataSize: info.rawData.count, listenPort: config.listenPort
                )))
            }
            if !pieces.have.isEmpty {
                try await connection.send(.bitfield(pieces.have.data))
            }

            while !Task.isCancelled {
                let message = try await connection.receiveMessage()
                try await handle(message, peer: peer, key: key)
            }
        } catch {
            // Normal teardown path for closed/failed/timed-out connections.
        }

        connection.close()
        removePeer(key: key, address: address)
    }

    private func removePeer(key: PeerKey, address: PeerAddress) {
        guard let peer = peers.removeValue(forKey: key) else { return }
        pieces.peerLeft(with: peer.bitfield)
        for ref in peer.outstanding.keys {
            pieces.cancelRequest(ref)
        }
        peers[key] = nil
        connectedAddresses.remove(address)
    }

    // MARK: - Message handling

    private func handle(_ message: PeerMessage, peer: Peer, key: PeerKey) async throws {
        peer.lastReceived = .now
        switch message {
        case .keepAlive:
            break

        case .choke:
            peer.peerChoking = true
            for ref in peer.outstanding.keys {
                pieces.cancelRequest(ref)
            }
            peer.outstanding.removeAll()

        case .unchoke:
            peer.peerChoking = false
            try await fillRequests(peer: peer, key: key)

        case .interested:
            peer.peerInterested = true
            // Grant an unchoke immediately if we have spare slots; the
            // periodic choker will reevaluate against transfer rates.
            if peer.amChoking, unchokedCount < Self.unchokeSlots + 1 {
                peer.amChoking = false
                try await peer.connection.send(.unchoke)
            }

        case .notInterested:
            peer.peerInterested = false

        case .have(let index):
            let index = Int(index)
            guard index < info.pieceCount else { throw PeerWireError.malformedMessage }
            if !peer.bitfield[index] {
                peer.bitfield[index] = true
                pieces.peerHas(index)
            }
            try await updateInterest(peer: peer, key: key)

        case .bitfield(let data):
            guard let bitfield = Bitfield(data: data, count: info.pieceCount) else {
                throw PeerWireError.malformedMessage
            }
            pieces.peerLeft(with: peer.bitfield)
            peer.bitfield = bitfield
            pieces.peerJoined(with: bitfield)
            try await updateInterest(peer: peer, key: key)

        case .request(let index, let begin, let length):
            try await serveRequest(
                index: Int(index), begin: Int(begin), length: Int(length), peer: peer
            )

        case .piece(let index, let begin, let block):
            try await receivedBlock(
                index: Int(index), begin: Int(begin), block: block, peer: peer, key: key
            )

        case .cancel:
            break // We serve requests immediately; nothing is queued to cancel.

        case .port(let dhtPort):
            onPeerDHTPort?(PeerAddress(host: peer.connection.address.host, port: dhtPort))

        case .extended(let id, let payload):
            try await handleExtended(id: id, payload: payload, peer: peer)
        }
    }

    /// Session-injected hook: peers advertising their DHT port feed the table.
    var onPeerDHTPort: (@Sendable (PeerAddress) -> Void)?

    func setPeerDHTPortHandler(_ handler: @escaping @Sendable (PeerAddress) -> Void) {
        onPeerDHTPort = handler
    }

    private func handleExtended(id: UInt8, payload: Data, peer: Peer) async throws {
        if id == 0 {
            if let parsed = ExtensionHandshake.parse(payload) {
                peer.theirUTMetadataID = parsed.utMetadataID
            }
            return
        }
        guard id == ExtensionHandshake.utMetadataID,
              let message = UTMetadata.parse(payload)
        else { return }
        switch message.type {
        case .request:
            guard let theirID = peer.theirUTMetadataID else { return }
            let raw = info.rawData
            let start = message.piece * UTMetadata.pieceSize
            if start >= 0, start < raw.count {
                let chunk = raw.readData(
                    at: start, count: min(UTMetadata.pieceSize, raw.count - start)
                ) ?? Data()
                try await peer.connection.send(.extended(
                    id: theirID,
                    payload: UTMetadata.data(piece: message.piece, totalSize: raw.count, chunk: chunk)
                ))
            } else {
                try await peer.connection.send(.extended(
                    id: theirID, payload: UTMetadata.reject(piece: message.piece)
                ))
            }
        case .data, .reject:
            break // We already have metadata; nothing to do.
        }
    }

    private func updateInterest(peer: Peer, key: PeerKey) async throws {
        let shouldBeInterested = pieces.peerHasUsefulPiece(peer.bitfield)
        if shouldBeInterested != peer.amInterested {
            peer.amInterested = shouldBeInterested
            try await peer.connection.send(shouldBeInterested ? .interested : .notInterested)
        }
        if shouldBeInterested, !peer.peerChoking {
            try await fillRequests(peer: peer, key: key)
        }
    }

    private func fillRequests(peer: Peer, key: PeerKey) async throws {
        guard state == .downloading, peer.amInterested, !peer.peerChoking else { return }
        while peer.outstanding.count < config.maxOutstandingPerPeer {
            guard let ref = pieces.nextRequest(
                peerHas: peer.bitfield,
                excluding: Set(peer.outstanding.keys)
            ) else { break }
            pieces.markRequested(ref)
            peer.outstanding[ref] = .now
            do {
                try await peer.connection.send(.request(
                    index: UInt32(ref.index), begin: UInt32(ref.begin), length: UInt32(ref.length)
                ))
            } catch {
                pieces.cancelRequest(ref)
                peer.outstanding[ref] = nil
                throw error
            }
        }
    }

    private func serveRequest(index: Int, begin: Int, length: Int, peer: Peer) async throws {
        guard state == .downloading || state == .seeding else { return }
        guard !peer.amChoking,
              length > 0, length <= 128 * 1024,
              index >= 0, index < info.pieceCount,
              pieces.have[index]
        else { return }
        let block = try await store.readBlock(index: index, begin: begin, length: length)
        try await peer.connection.send(.piece(
            index: UInt32(index), begin: UInt32(begin), block: block
        ))
        peer.uploadedPayload += Int64(length)
        uploadedTotal += Int64(length)
    }

    private func receivedBlock(index: Int, begin: Int, block: Data, peer: Peer, key: PeerKey) async throws {
        // Never touch storage while content is being relocated (or when not
        // actively downloading); dropped blocks are simply re-requested.
        guard state == .downloading else { return }
        let ref = BlockRef(index: index, begin: begin, length: block.count)
        peer.outstanding[ref] = nil
        peer.downloadedPayload += Int64(block.count)
        downloadedTotal += Int64(block.count)

        switch pieces.receivedBlock(index: index, begin: begin, block: block) {
        case .ignored:
            break
        case .progress:
            pieceContributors[index, default: []].insert(key)
        case .pieceComplete(let data):
            pieceContributors[index, default: []].insert(key)
            let contributors = pieceContributors.removeValue(forKey: index) ?? []
            if Data(Insecure.SHA1.hash(data: data)) == info.pieceHashes[index] {
                try await store.writePiece(data, at: index)
                pieces.pieceVerified(index)
                // Rename any file this piece just completed to its final name.
                await store.finalizeCompletedFiles(after: index, have: pieces.have)
                await broadcastHave(index)
                if pieces.isWantedComplete {
                    await downloadCompleted()
                }
            } else {
                pieces.pieceFailed(index)
                punishCorruption(contributors: contributors)
            }
        }
        try await fillRequests(peer: peer, key: key)
    }

    private func punishCorruption(contributors: Set<PeerKey>) {
        for contributorKey in contributors {
            guard let contributor = peers[contributorKey] else { continue }
            contributor.corruptPieces += 1
            if contributor.corruptPieces >= 2 {
                bannedAddresses.insert(contributor.connection.address)
                contributor.connection.close()
            }
        }
    }

    private func broadcastHave(_ index: Int) async {
        for peer in peers.values {
            try? await peer.connection.send(.have(UInt32(index)))
        }
    }

    private func downloadCompleted() async {
        state = .seeding
        // No longer interested in anyone.
        for peer in peers.values where peer.amInterested {
            peer.amInterested = false
            try? await peer.connection.send(.notInterested)
        }
        Task { await self.announceCompleted() }
    }

    // MARK: - Tick loop

    private func runTicks() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            await tick()
        }
    }

    private func tick() async {
        tickCount += 1

        // Rates: exponential moving average of 1s deltas.
        let downloadDelta = Double(downloadedTotal - lastDownloadedTotal)
        let uploadDelta = Double(uploadedTotal - lastUploadedTotal)
        lastDownloadedTotal = downloadedTotal
        lastUploadedTotal = uploadedTotal
        downloadRate = downloadRate * 0.6 + downloadDelta * 0.4
        uploadRate = uploadRate * 0.6 + uploadDelta * 0.4

        for peer in peers.values {
            peer.downloadRateEMA = peer.downloadRateEMA * 0.6
                + Double(peer.downloadedPayload - peer.lastDownloadedPayload) * 0.4
            peer.uploadRateEMA = peer.uploadRateEMA * 0.6
                + Double(peer.uploadedPayload - peer.lastUploadedPayload) * 0.4
            peer.lastDownloadedPayload = peer.downloadedPayload
            peer.lastUploadedPayload = peer.uploadedPayload
        }

        // Choke algorithm every 10s, optimistic rotation every 30s.
        if tickCount % 10 == 0 {
            await runChoker(rotateOptimistic: tickCount % 30 == 0)
        }

        // Re-queue stale requests (peer never answered).
        let staleCutoff = ContinuousClock.now.advanced(by: .seconds(-45))
        for (key, peer) in peers {
            var refilled = false
            for (ref, requestedAt) in peer.outstanding where requestedAt < staleCutoff {
                pieces.cancelRequest(ref)
                peer.outstanding[ref] = nil
                refilled = true
            }
            if refilled {
                try? await fillRequests(peer: peer, key: key)
            }
        }

        // Drop peers that have gone silent.
        let idleCutoff = ContinuousClock.now.advanced(by: .seconds(-150))
        for peer in peers.values where peer.lastReceived < idleCutoff {
            peer.connection.close()
        }

        // Keep-alives every 60s.
        if tickCount % 60 == 0 {
            for peer in peers.values {
                try? await peer.connection.send(.keepAlive)
            }
        }

        // Top up connections.
        if tickCount % 5 == 0 {
            dialPeers()
        }

        // Periodic resume-data checkpoint.
        if tickCount % 30 == 0 {
            await saveResume()
        }
    }

    // MARK: - Choking

    static let unchokeSlots = 4
    private var optimisticKey: PeerKey?

    private var unchokedCount: Int {
        peers.values.count { !$0.amChoking }
    }

    /// Classic tit-for-tat: unchoke the 4 best-transferring interested peers
    /// (by what they give us while downloading, by what they take while
    /// seeding), plus one optimistically unchoked peer rotated every 30s.
    private func runChoker(rotateOptimistic: Bool) async {
        let interested = peers.filter { $0.value.peerInterested }

        let ranked = interested.sorted { lhs, rhs in
            state == .seeding
                ? lhs.value.uploadRateEMA > rhs.value.uploadRateEMA
                : lhs.value.downloadRateEMA > rhs.value.downloadRateEMA
        }
        var toUnchoke = Set(ranked.prefix(Self.unchokeSlots).map(\.key))

        if rotateOptimistic || optimisticKey == nil || peers[optimisticKey!] == nil {
            optimisticKey = interested.keys.filter { !toUnchoke.contains($0) }.randomElement()
        }
        if let optimisticKey {
            toUnchoke.insert(optimisticKey)
        }

        for (key, peer) in peers {
            let shouldUnchoke = toUnchoke.contains(key)
            guard shouldUnchoke == peer.amChoking else { continue }
            peer.amChoking = !shouldUnchoke
            try? await peer.connection.send(shouldUnchoke ? .unchoke : .choke)
        }
    }
}

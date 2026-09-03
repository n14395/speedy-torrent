import Foundation
import Network

public enum SessionError: Error, Equatable {
    case duplicateTorrent
    case unknownTorrent
    case invalidMagnet
    case listenFailed(String)
    case moveFailed(String)
}

/// How the engine uses MSE/PE stream encryption.
public enum EncryptionPolicy: String, Sendable, CaseIterable {
    /// Plaintext only.
    case disabled
    /// Prefer encryption; fall back to plaintext for peers that can't do it.
    case preferred
    /// Only connect to (and accept) encrypted peers.
    case required
}

/// One-shot resume guard for an `NWListener`'s readiness. Its state handler
/// fires repeatedly and off-actor, so the continuation needs a lock and a
/// "already resumed" flag to avoid a double resume (which traps).
private final class ListenerReadyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var armed = false
    private var lastWaitingReason: String?

    func arm(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        armed = true
        lock.unlock()
    }

    func succeed() { resume(failure: nil) }

    func fail(_ reason: String) { resume(failure: reason) }

    /// `.waiting` is recorded rather than acted on — it may clear on its own.
    func noteWaiting(_ reason: String) {
        lock.lock()
        lastWaitingReason = reason
        lock.unlock()
    }

    /// Grace period over: whatever kept us waiting is the failure.
    func expire() {
        lock.lock()
        let reason = lastWaitingReason
        lock.unlock()
        resume(failure: reason ?? "timed out binding the port")
    }

    private func resume(failure: String?) {
        lock.lock()
        guard armed, let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        if let failure {
            continuation.resume(throwing: SessionError.listenFailed(failure))
        } else {
            continuation.resume()
        }
    }
}

/// The engine's top-level API: owns all torrents, the shared listening socket,
/// and global settings.
public actor TorrentSession {
    public struct Configuration: Sendable {
        public var downloadDirectory: URL
        /// 0 disables incoming connections.
        public var listenPort: UInt16
        public var maxPeersPerTorrent: Int
        public var sequentialDownload: Bool
        /// Where resume data lives; nil disables persistence.
        public var stateDirectory: URL?
        /// Bytes/second; nil = unlimited.
        public var downloadRateLimit: Int?
        public var uploadRateLimit: Int?
        public var enableDHT: Bool
        /// Seconds between ut_pex updates (BEP 11); 0 disables sending.
        public var pexIntervalSeconds: Int
        /// Map the listening port on the router via NAT-PMP.
        public var enablePortMapping: Bool
        /// Discover LAN peers via Local Service Discovery (BEP 14).
        public var enableLSD: Bool
        /// MSE/PE stream-encryption policy.
        public var encryptionPolicy: EncryptionPolicy
        /// Stop seeding at this share ratio (nil = never).
        public var seedRatioLimit: Double?
        /// Stop seeding after this many seconds (nil = never).
        public var seedTimeLimit: TimeInterval?
        /// Max torrents downloading at once; the rest queue (nil = unlimited).
        /// Completed torrents seed without counting against this.
        public var maxActiveDownloads: Int?

        public init(
            downloadDirectory: URL,
            listenPort: UInt16 = 6881,
            maxPeersPerTorrent: Int = 40,
            sequentialDownload: Bool = false,
            stateDirectory: URL? = nil,
            downloadRateLimit: Int? = nil,
            uploadRateLimit: Int? = nil,
            enableDHT: Bool = true,
            pexIntervalSeconds: Int = 60,
            enablePortMapping: Bool = false,
            enableLSD: Bool = false,
            encryptionPolicy: EncryptionPolicy = .disabled,
            seedRatioLimit: Double? = nil,
            seedTimeLimit: TimeInterval? = nil,
            maxActiveDownloads: Int? = nil
        ) {
            self.downloadDirectory = downloadDirectory
            self.listenPort = listenPort
            self.maxPeersPerTorrent = maxPeersPerTorrent
            self.sequentialDownload = sequentialDownload
            self.stateDirectory = stateDirectory
            self.downloadRateLimit = downloadRateLimit
            self.uploadRateLimit = uploadRateLimit
            self.enableDHT = enableDHT
            self.pexIntervalSeconds = pexIntervalSeconds
            self.enablePortMapping = enablePortMapping
            self.enableLSD = enableLSD
            self.encryptionPolicy = encryptionPolicy
            self.seedRatioLimit = seedRatioLimit
            self.seedTimeLimit = seedTimeLimit
            self.maxActiveDownloads = maxActiveDownloads
        }
    }

    public let peerID = PeerID.generate()
    private var configuration: Configuration
    private var controllers: [InfoHash: TorrentController] = [:]
    private var magnets: [InfoHash: MagnetController] = [:]
    /// Magnets whose metadata is being fetched *before* the user has confirmed
    /// the add. Kept out of `order`/`snapshots()` so they don't appear in the
    /// torrent list, and never touch disk until committed.
    private var prefetches: [InfoHash: MagnetController] = [:]
    private var order: [InfoHash] = []
    private var listener: NWListener?
    private let persistence: PersistenceStore?
    private let downloadLimiter: RateLimiter
    private let uploadLimiter: RateLimiter
    private let dht = DHTNode()
    private var dhtTask: Task<Void, Never>?
    private let portMapper = PortMapper()
    private let lsd = LSDService()
    private var lsdTask: Task<Void, Never>?

    // Global transfer statistics: per-torrent baselines let session counters
    // accumulate deltas without double-counting totals restored from disk.
    private var statsBase = StatsFile()
    private var sessionDownloaded: Int64 = 0
    private var sessionUploaded: Int64 = 0
    private var statsBaselines: [InfoHash: (downloaded: Int64, uploaded: Int64)] = [:]
    private let sessionStart = Date()
    private var lastStatsSave = Date()

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.persistence = configuration.stateDirectory.map(PersistenceStore.init(baseURL:))
        self.downloadLimiter = RateLimiter(bytesPerSecond: configuration.downloadRateLimit)
        self.uploadLimiter = RateLimiter(bytesPerSecond: configuration.uploadRateLimit)
        if let persistence {
            var base = persistence.loadStats()
            base.launches += 1
            statsBase = base
            persistence.saveStats(base)
        }
    }

    public func setRateLimits(download: Int?, upload: Int?) async {
        configuration.downloadRateLimit = download
        configuration.uploadRateLimit = upload
        await downloadLimiter.setRate(download)
        await uploadLimiter.setRate(upload)
    }

    /// Updates the seed-goal limits for new and existing torrents (nil = none).
    public func setSeedingLimits(ratio: Double?, time: TimeInterval?) async {
        configuration.seedRatioLimit = ratio
        configuration.seedTimeLimit = time
        for controller in controllers.values {
            await controller.setSeedingLimits(ratio: ratio, time: time)
        }
    }

    /// Re-adds every persisted torrent (call once at startup).
    public func restore() async {
        guard let persistence else { return }
        for entry in persistence.loadEntries() {
            switch entry {
            case .torrent(let infoHashHex, let torrentData, let resume):
                let meta: TorrentMetaInfo
                do {
                    meta = try TorrentMetaInfo(torrentFileData: torrentData)
                } catch {
                    // Don't drop it. A torrent whose metadata no longer parses
                    // — a truncated write, or a validation rule this build
                    // tightened — would otherwise just vanish from the user's
                    // list with no way to tell what happened or remove it.
                    noteUnreadable(infoHashHex: infoHashHex, reason: "\(error)")
                    continue
                }
                let directory = resume.map { URL(fileURLWithPath: $0.downloadDirectory) }
                _ = try? await addTorrent(
                    info: meta.info,
                    announceTiers: meta.announceTiers,
                    downloadDirectory: directory,
                    resume: resume,
                    persistTorrentData: nil,
                    webSeeds: meta.webSeeds
                )
            case .magnet(let record):
                guard let hash = InfoHash(hex: record.infoHashHex) else { continue }
                let magnet = MagnetLink(
                    infoHash: hash,
                    displayName: record.displayName,
                    trackers: record.trackers
                )
                _ = try? await addMagnet(
                    magnet,
                    downloadDirectory: URL(fileURLWithPath: record.downloadDirectory),
                    sequential: record.sequential,
                    addedAt: record.addedAt
                )
            }
        }
    }

    /// Persisted torrents whose `meta.torrent` could not be parsed on restore,
    /// by info hash → reason. They appear in the list as `.failed` so the user
    /// can see and remove them; nothing else in the engine touches them.
    private var unreadableTorrents: [InfoHash: String] = [:]

    private func noteUnreadable(infoHashHex: String, reason: String) {
        guard let hash = InfoHash(hex: infoHashHex),
              controllers[hash] == nil, magnets[hash] == nil
        else { return }
        unreadableTorrents[hash] = reason
        if !order.contains(hash) { order.append(hash) }
    }

    /// The list row for an unreadable torrent: enough to identify and remove it.
    private func unreadableSnapshot(_ hash: InfoHash, reason: String) -> TorrentSnapshot {
        TorrentSnapshot(
            infoHash: hash,
            name: hash.hexString,
            totalLength: 0,
            wantedLength: 0,
            completedLength: 0,
            downloadedTotal: 0,
            uploadedTotal: 0,
            downloadRate: 0,
            uploadRate: 0,
            state: .failed,
            peerCount: 0,
            pieceCount: 0,
            havePieces: 0,
            errorMessage: "Could not read this torrent's metadata: \(reason)",
            downloadDirectory: configuration.downloadDirectory.path,
            sequential: false,
            downloadRateLimit: nil,
            uploadRateLimit: nil,
            addedAt: 0,
            pieceLength: 0
        )
    }

    // MARK: - Torrent management

    @discardableResult
    public func addTorrent(
        fileData: Data,
        downloadDirectory: URL? = nil,
        sequential: Bool? = nil,
        wantedFiles: Set<Int>? = nil,
        filePriorities: [Int: FilePriority]? = nil
    ) async throws -> InfoHash {
        let meta = try TorrentMetaInfo(torrentFileData: fileData)
        return try await addTorrent(
            info: meta.info,
            announceTiers: meta.announceTiers,
            downloadDirectory: downloadDirectory,
            sequential: sequential,
            wantedFiles: wantedFiles,
            filePriorities: filePriorities,
            resume: nil,
            persistTorrentData: fileData,
            webSeeds: meta.webSeeds
        )
    }

    func addTorrent(
        info: TorrentInfo,
        announceTiers: [[String]],
        downloadDirectory: URL?,
        sequential: Bool? = nil,
        wantedFiles: Set<Int>? = nil,
        filePriorities: [Int: FilePriority]? = nil,
        resume: ResumeData? = nil,
        persistTorrentData: Data? = nil,
        webSeeds: [String] = [],
        insertAt: Int? = nil
    ) async throws -> InfoHash {
        guard controllers[info.infoHash] == nil else { throw SessionError.duplicateTorrent }
        var config = ControllerConfig()
        config.maxPeers = configuration.maxPeersPerTorrent
        config.listenPort = configuration.listenPort
        config.sequential = sequential ?? configuration.sequentialDownload
        config.pexIntervalSeconds = configuration.pexIntervalSeconds
        config.encryptionPolicy = configuration.encryptionPolicy
        config.seedRatioLimit = configuration.seedRatioLimit
        config.seedTimeLimit = configuration.seedTimeLimit
        let controller = TorrentController(
            info: info,
            announceTiers: announceTiers,
            downloadDirectory: downloadDirectory ?? configuration.downloadDirectory,
            sessionPeerID: peerID,
            config: config,
            persistence: persistence,
            initialResume: resume,
            wantedFiles: wantedFiles,
            filePriorities: filePriorities,
            downloadLimiter: downloadLimiter,
            uploadLimiter: uploadLimiter,
            webSeeds: webSeeds
        )
        controllers[info.infoHash] = controller
        // A magnet that resolves keeps the slot it was dragged to, rather than
        // being appended and losing the user's ordering — which also decides
        // which torrents an active-download cap admits.
        if let insertAt, insertAt <= order.count {
            order.insert(info.infoHash, at: insertAt)
        } else {
            order.append(info.infoHash)
        }
        // Baseline the stats counters now (not at first observation): totals
        // restored from disk must not count into this session, but everything
        // transferred from here on must — even before the first snapshot.
        statsBaselines[info.infoHash] = (resume?.downloaded ?? 0, resume?.uploaded ?? 0)
        if let persistTorrentData, let persistence {
            persistence.saveTorrentData(persistTorrentData, for: info.infoHash)
        }
        if configuration.enableDHT, !info.isPrivate {
            let dht = dht
            await controller.setPeerDHTPortHandler { address in
                Task { await dht.addCandidate(address) }
            }
        }
        await controller.setOnBecameSeed { [weak self] in
            await self?.rescheduleQueue()
        }
        persistOrder()
        await controller.start()
        await rescheduleQueue()
        return info.infoHash
    }

    /// Keeps at most `maxActiveDownloads` torrents actively downloading (in
    /// `order`); the rest wait in `.queued`. Completed (seeding) torrents are
    /// unaffected.
    private func rescheduleQueue() async {
        let cap = configuration.maxActiveDownloads ?? 0
        var managed: [TorrentController] = []
        for hash in order {
            guard let controller = controllers[hash] else { continue }
            let state = await controller.currentState
            if state == .downloading || state == .queued {
                managed.append(controller)
            }
        }
        for (index, controller) in managed.enumerated() {
            if cap == 0 || index < cap {
                await controller.startFromQueue()
            } else {
                await controller.moveToQueue()
            }
        }
    }

    /// Updates the active-download cap and reschedules (nil/0 = unlimited).
    public func setMaxActiveDownloads(_ limit: Int?) async {
        configuration.maxActiveDownloads = limit
        await rescheduleQueue()
    }

    /// Directions for reordering a torrent within the queue.
    public enum QueueMove: Sendable {
        case up, down, top, bottom
    }

    /// Moves a torrent within the list order — which is also download
    /// priority when an active-download cap is set — then reschedules.
    public func moveTorrent(_ infoHash: InfoHash, _ move: QueueMove) async throws {
        guard let index = order.firstIndex(of: infoHash) else {
            throw SessionError.unknownTorrent
        }
        let target: Int = switch move {
        case .up: max(0, index - 1)
        case .down: min(order.count - 1, index + 1)
        case .top: 0
        case .bottom: order.count - 1
        }
        guard target != index else { return }
        order.remove(at: index)
        order.insert(infoHash, at: target)
        persistOrder()
        await rescheduleQueue()
    }

    /// Saves the current list order so queue priority survives restarts.
    private func persistOrder() {
        persistence?.saveQueueOrder(order.map(\.hexString))
    }

    // MARK: - Magnets

    @discardableResult
    public func addMagnet(
        _ magnetString: String,
        downloadDirectory: URL? = nil,
        sequential: Bool? = nil
    ) async throws -> InfoHash {
        guard let magnet = MagnetLink(string: magnetString) else {
            throw SessionError.invalidMagnet
        }
        return try await addMagnet(
            magnet,
            downloadDirectory: downloadDirectory,
            sequential: sequential,
            addedAt: Date().timeIntervalSince1970
        )
    }

    @discardableResult
    private func addMagnet(
        _ magnet: MagnetLink,
        downloadDirectory: URL?,
        sequential: Bool?,
        addedAt: Double
    ) async throws -> InfoHash {
        guard controllers[magnet.infoHash] == nil, magnets[magnet.infoHash] == nil else {
            throw SessionError.duplicateTorrent
        }
        let discover = makeDiscoverClosure(for: magnet.infoHash)
        let controller = MagnetController(
            magnet: magnet,
            sessionPeerID: peerID,
            listenPort: configuration.listenPort,
            downloadDirectory: downloadDirectory ?? configuration.downloadDirectory,
            sequential: sequential ?? configuration.sequentialDownload,
            encryptionPolicy: configuration.encryptionPolicy,
            addedAt: addedAt,
            discoverPeers: discover
        ) { [weak self] infoData in
            await self?.metadataResolved(magnet: magnet, infoData: infoData)
        }
        magnets[magnet.infoHash] = controller
        order.append(magnet.infoHash)
        await persistMagnet(controller)
        persistOrder()
        await controller.start()
        return magnet.infoHash
    }

    /// Records an unresolved magnet so it comes back after a relaunch,
    /// carrying whatever settings it has been given so far.
    private func persistMagnet(_ controller: MagnetController) async {
        guard let persistence else { return }
        let magnet = controller.magnet
        persistence.saveMagnet(
            MagnetRecord(
                infoHashHex: magnet.infoHash.hexString,
                displayName: magnet.displayName,
                trackers: magnet.trackers,
                downloadDirectory: await controller.downloadDirectory.path,
                sequential: await controller.sequential,
                addedAt: controller.addedAt
            ),
            for: magnet.infoHash
        )
    }

    private func metadataResolved(magnet: MagnetLink, infoData: Data) async {
        guard let magnetController = magnets.removeValue(forKey: magnet.infoHash),
              let info = try? TorrentInfo(bencodedData: infoData)
        else { return }
        let transferredPeers = await magnetController.knownPeers
        // Settings chosen while the magnet was resolving carry over.
        let directory = await magnetController.downloadDirectory
        let sequential = await magnetController.sequential
        await magnetController.stop()
        let queuePosition = order.firstIndex(of: magnet.infoHash)
        order.removeAll { $0 == magnet.infoHash }
        // The pending-magnet marker is superseded by real torrent state.
        persistence?.removeMagnet(for: magnet.infoHash)

        let tiers = magnet.trackers.map { [$0] }
        let assembled = TorrentMetaInfo.assembleTorrentData(
            infoDictData: infoData, announceTiers: tiers
        )
        guard let hash = try? await addTorrent(
            info: info,
            announceTiers: tiers,
            downloadDirectory: directory,
            sequential: sequential,
            resume: nil,
            persistTorrentData: assembled,
            insertAt: queuePosition
        ) else { return }
        if let controller = controllers[hash] {
            await controller.addKnownPeers(Array(transferredPeers))
        }
    }

    /// DHT peer-discovery closure for a magnet/torrent, or nil when DHT is off.
    private func makeDiscoverClosure(
        for infoHash: InfoHash
    ) -> (@Sendable () async -> [PeerAddress])? {
        guard configuration.enableDHT else { return nil }
        let dht = dht
        let port = configuration.listenPort
        return { await dht.findPeers(infoHash: infoHash, announcePort: port) }
    }

    // MARK: - Magnet metadata prefetch

    /// Resolved-but-not-yet-added magnet metadata, for the add sheet.
    public struct PrefetchedMetadata: Sendable {
        public let name: String
        public let totalLength: Int64
        public let files: [FileEntry]
    }

    /// Starts fetching a magnet's metadata *without* adding it as a download.
    /// The torrent stays out of the list and off disk; call `commitMagnet` to
    /// turn it into a real download, or `cancelMetadataPrefetch` to abandon it.
    @discardableResult
    public func beginMetadataPrefetch(_ magnetString: String) async throws -> InfoHash {
        guard let magnet = MagnetLink(string: magnetString) else {
            throw SessionError.invalidMagnet
        }
        guard controllers[magnet.infoHash] == nil,
              magnets[magnet.infoHash] == nil,
              prefetches[magnet.infoHash] == nil
        else {
            throw SessionError.duplicateTorrent
        }
        let controller = MagnetController(
            magnet: magnet,
            sessionPeerID: peerID,
            listenPort: configuration.listenPort,
            downloadDirectory: configuration.downloadDirectory,
            sequential: configuration.sequentialDownload,
            encryptionPolicy: configuration.encryptionPolicy,
            discoverPeers: makeDiscoverClosure(for: magnet.infoHash)
        )
        prefetches[magnet.infoHash] = controller
        await controller.start()
        return magnet.infoHash
    }

    /// A prefetch's metadata once it has resolved (nil while still fetching, or
    /// if there is no such prefetch).
    public func prefetchedMetadata(for infoHash: InfoHash) async -> PrefetchedMetadata? {
        guard let controller = prefetches[infoHash],
              let data = await controller.resolvedInfoData,
              let info = try? TorrentInfo(bencodedData: data)
        else { return nil }
        return PrefetchedMetadata(
            name: info.name, totalLength: info.totalLength, files: info.files
        )
    }

    /// Abandons a metadata prefetch (nothing was added or written).
    public func cancelMetadataPrefetch(_ infoHash: InfoHash) async {
        guard let controller = prefetches.removeValue(forKey: infoHash) else { return }
        await controller.stop()
    }

    /// Turns a metadata prefetch into a real download. If metadata already
    /// arrived the torrent is built immediately with the chosen selection;
    /// otherwise the in-flight fetch is promoted to a committed magnet that
    /// converts itself on resolve (ignoring `wantedFiles` and `filePriorities`,
    /// since files are unknown until then).
    @discardableResult
    public func commitMagnet(
        _ infoHash: InfoHash,
        downloadDirectory: URL? = nil,
        sequential: Bool? = nil,
        wantedFiles: Set<Int>? = nil,
        filePriorities: [Int: FilePriority]? = nil
    ) async throws -> InfoHash {
        guard let controller = prefetches.removeValue(forKey: infoHash) else {
            throw SessionError.unknownTorrent
        }
        let magnet = controller.magnet
        let directory = downloadDirectory ?? configuration.downloadDirectory
        let wantSequential = sequential ?? configuration.sequentialDownload
        await controller.setDownloadDirectory(directory)
        await controller.setSequential(wantSequential)

        let outcome = await controller.commit { [weak self] infoData in
            await self?.metadataResolved(magnet: magnet, infoData: infoData)
        }
        switch outcome {
        case .resolved(let infoData):
            let peers = await controller.knownPeers
            await controller.stop()
            guard let info = try? TorrentInfo(bencodedData: infoData) else {
                throw SessionError.invalidMagnet
            }
            let tiers = magnet.trackers.map { [$0] }
            let assembled = TorrentMetaInfo.assembleTorrentData(
                infoDictData: infoData, announceTiers: tiers
            )
            // A full selection is stored as nil (download everything).
            let wanted = wantedFiles.flatMap { $0.count == info.files.count ? nil : $0 }
            let hash = try await addTorrent(
                info: info,
                announceTiers: tiers,
                downloadDirectory: directory,
                sequential: wantSequential,
                wantedFiles: wanted,
                filePriorities: filePriorities,
                resume: nil,
                persistTorrentData: assembled
            )
            if let added = controllers[hash] {
                await added.addKnownPeers(Array(peers))
            }
            return hash
        case .pending:
            // Metadata not in yet: keep the same controller running as a normal
            // committed magnet so no peers/progress are lost.
            magnets[infoHash] = controller
            order.append(infoHash)
            await persistMagnet(controller)
            persistOrder()
            return infoHash
        }
    }

    // MARK: - Per-torrent settings

    /// Enables/disables sequential piece order for one torrent.
    public func setSequential(_ sequential: Bool, for infoHash: InfoHash) async throws {
        if let controller = controllers[infoHash] {
            await controller.setSequential(sequential)
        } else if let magnet = magnets[infoHash] {
            await magnet.setSequential(sequential)
            await persistMagnet(magnet)
        } else {
            throw SessionError.unknownTorrent
        }
    }

    /// Changes one torrent's download directory, moving any existing content
    /// there before the transfer continues.
    public func setDownloadDirectory(_ directory: URL, for infoHash: InfoHash) async throws {
        if let controller = controllers[infoHash] {
            try await controller.setDownloadDirectory(directory)
        } else if let magnet = magnets[infoHash] {
            await magnet.setDownloadDirectory(directory)
            await persistMagnet(magnet)
        } else {
            throw SessionError.unknownTorrent
        }
    }

    /// The torrent's files with their selection state (empty while a magnet
    /// is still resolving metadata).
    public func fileStatuses(for infoHash: InfoHash) async throws -> [TorrentFileStatus] {
        if let controller = controllers[infoHash] {
            return await controller.fileStatuses()
        }
        if magnets[infoHash] != nil {
            return []
        }
        throw SessionError.unknownTorrent
    }

    /// Live per-peer details for the inspector (empty for an unresolved magnet).
    public func peerDetails(for infoHash: InfoHash) async -> [PeerDetail] {
        guard let controller = controllers[infoHash] else { return [] }
        return await controller.peerDetails()
    }

    /// Per-tracker status for the inspector (empty for an unresolved magnet).
    public func trackerDetails(for infoHash: InfoHash) async -> [TrackerDetail] {
        guard let controller = controllers[infoHash] else { return [] }
        return await controller.trackerDetails()
    }

    /// Restricts the download to the given file indices (must be non-empty).
    /// Caps one torrent's transfer rates in bytes/second (nil or 0 clears the
    /// cap). The session-wide limits still apply on top: a torrent can be held
    /// below the global budget, never granted more than it.
    public func setRateLimits(download: Int?, upload: Int?, for infoHash: InfoHash) async throws {
        guard let controller = controllers[infoHash] else { throw SessionError.unknownTorrent }
        await controller.setRateLimits(download: download, upload: upload)
    }

    /// Changes how urgently the given files are requested within one torrent.
    /// Priority orders the request queue; it does not reserve bandwidth, and it
    /// has no effect on files that aren't wanted.
    public func setFilePriority(
        _ priority: FilePriority, forFiles files: Set<Int>, in infoHash: InfoHash
    ) async throws {
        guard let controller = controllers[infoHash] else { throw SessionError.unknownTorrent }
        await controller.setFilePriority(priority, for: files)
    }

    public func setWantedFiles(_ wanted: Set<Int>, for infoHash: InfoHash) async throws {
        guard let controller = controllers[infoHash] else {
            throw SessionError.unknownTorrent
        }
        await controller.setWantedFiles(wanted)
    }

    public func removeTorrent(_ infoHash: InfoHash, deleteFiles: Bool = false) async throws {
        if unreadableTorrents.removeValue(forKey: infoHash) != nil {
            // Nothing was ever started for it; just forget the state directory.
            order.removeAll { $0 == infoHash }
            persistence?.remove(for: infoHash)
            persistOrder()
            return
        }
        if let magnet = magnets.removeValue(forKey: infoHash) {
            order.removeAll { $0 == infoHash }
            statsBaselines[infoHash] = nil
            await magnet.stop()
            persistence?.remove(for: infoHash)
            persistOrder()
            return
        }
        guard let controller = controllers.removeValue(forKey: infoHash) else {
            throw SessionError.unknownTorrent
        }
        order.removeAll { $0 == infoHash }
        // Fold the torrent's final transfer into the global counters before
        // its baseline disappears.
        accumulateStats([await controller.snapshot()])
        statsBaselines[infoHash] = nil
        await controller.stop()
        if deleteFiles {
            await controller.deleteFiles()
        }
        persistence?.remove(for: infoHash)
        persistOrder()
        await rescheduleQueue()
    }

    /// Re-verifies a torrent's data on disk against its piece hashes.
    public func recheckTorrent(_ infoHash: InfoHash) async throws {
        guard let controller = controllers[infoHash] else { throw SessionError.unknownTorrent }
        await controller.recheck()
    }

    public func pauseTorrent(_ infoHash: InfoHash) async throws {
        guard let controller = controllers[infoHash] else { throw SessionError.unknownTorrent }
        await controller.pause()
        await rescheduleQueue()
    }

    public func resumeTorrent(_ infoHash: InfoHash) async throws {
        guard let controller = controllers[infoHash] else { throw SessionError.unknownTorrent }
        await controller.resumeActivity()
        await rescheduleQueue()
    }

    public func pauseAll() async {
        for controller in controllers.values {
            await controller.pause()
        }
        await rescheduleQueue()
    }

    public func resumeAll() async {
        for controller in controllers.values {
            await controller.resumeActivity()
        }
        await rescheduleQueue()
    }

    /// Manually introduces peers (used by tests, DHT, and the UI).
    public func addPeers(_ addresses: [PeerAddress], to infoHash: InfoHash) async throws {
        if let controller = controllers[infoHash] {
            await controller.addKnownPeers(addresses)
        } else if let magnet = magnets[infoHash] {
            await magnet.addKnownPeers(addresses)
        } else if let prefetch = prefetches[infoHash] {
            await prefetch.addKnownPeers(addresses)
        } else {
            throw SessionError.unknownTorrent
        }
    }

    /// Where a torrent's content lives on disk (for reveal-in-Finder).
    public func contentURL(for infoHash: InfoHash) async -> URL? {
        guard let controller = controllers[infoHash] else { return nil }
        return await controller.contentURL
    }

    /// DHT routing-table size (0 when DHT is disabled or failed to start).
    public func dhtNodeCount() async -> Int {
        await dht.nodeCount
    }

    /// Sets the *default* for newly added torrents; existing torrents keep
    /// their per-torrent setting (see `setSequential(_:for:)`).
    public func setSequentialDownload(_ sequential: Bool) {
        configuration.sequentialDownload = sequential
    }

    public func snapshots() async -> [TorrentSnapshot] {
        var result: [TorrentSnapshot] = []
        for infoHash in order {
            if let controller = controllers[infoHash] {
                result.append(await controller.snapshot())
            } else if let magnet = magnets[infoHash] {
                result.append(await magnet.snapshot())
            } else if let reason = unreadableTorrents[infoHash] {
                result.append(unreadableSnapshot(infoHash, reason: reason))
            }
        }
        for index in result.indices {
            result[index].queuePosition = index + 1
        }
        accumulateStats(result)
        if Date().timeIntervalSince(lastStatsSave) > 60 {
            persistStats()
        }
        return result
    }

    // MARK: - Statistics

    /// Global transfer counters for this session and all-time (persisted).
    /// Pass the snapshots from a just-completed `snapshots()` call rather than
    /// letting this build a second set — the UI polls both every second, and
    /// each snapshot is not free.
    public func statistics(using snapshots: [TorrentSnapshot]? = nil) async -> SessionStatistics {
        // Fold in any transfer since the last observation.
        if let snapshots {
            accumulateStats(snapshots)
        } else {
            var current: [TorrentSnapshot] = []
            for controller in controllers.values {
                current.append(await controller.snapshot())
            }
            accumulateStats(current)
        }
        let uptime = Date().timeIntervalSince(sessionStart)
        return SessionStatistics(
            sessionDownloaded: sessionDownloaded,
            sessionUploaded: sessionUploaded,
            sessionDuration: uptime,
            allTimeDownloaded: statsBase.downloaded + sessionDownloaded,
            allTimeUploaded: statsBase.uploaded + sessionUploaded,
            allTimeUptime: statsBase.uptime + uptime,
            launchCount: statsBase.launches
        )
    }

    /// Advances the session counters by each torrent's transfer since it was
    /// last observed. The first observation only seeds the baseline, so
    /// totals restored from resume data are never counted twice.
    private func accumulateStats(_ snapshots: [TorrentSnapshot]) {
        for snapshot in snapshots {
            let baseline = statsBaselines[snapshot.infoHash]
                ?? (snapshot.downloadedTotal, snapshot.uploadedTotal)
            sessionDownloaded += max(0, snapshot.downloadedTotal - baseline.downloaded)
            sessionUploaded += max(0, snapshot.uploadedTotal - baseline.uploaded)
            statsBaselines[snapshot.infoHash] = (snapshot.downloadedTotal, snapshot.uploadedTotal)
        }
    }

    /// Writes all-time counters as (loaded base) + (session so far); the base
    /// never changes while running, so repeated saves are idempotent.
    private func persistStats() {
        guard let persistence else { return }
        var file = statsBase
        file.downloaded += sessionDownloaded
        file.uploaded += sessionUploaded
        file.uptime += Date().timeIntervalSince(sessionStart)
        persistence.saveStats(file)
        lastStatsSave = Date()
    }

    /// Router port-mapping status (NAT-PMP), for display.
    public func portMappingStatus() async -> PortMappingStatus {
        await portMapper.status()
    }

    public func shutdown() async {
        listener?.cancel()
        listener = nil
        let portMapper = portMapper
        await withDeadline(seconds: 2) { await portMapper.stop() }
        lsdTask?.cancel()
        await lsd.stop()
        dhtTask?.cancel()
        await dht.stop()
        for magnet in magnets.values {
            await magnet.stop()
        }
        magnets.removeAll()
        for prefetch in prefetches.values {
            await prefetch.stop()
        }
        prefetches.removeAll()
        for controller in controllers.values {
            accumulateStats([await controller.snapshot()])
        }
        // Stop torrents concurrently: one unreachable tracker must not delay
        // every other torrent's resume save.
        let stopping = Array(controllers.values)
        await withTaskGroup(of: Void.self) { group in
            for controller in stopping {
                group.addTask { await controller.stop() }
            }
        }
        persistStats()
        controllers.removeAll()
        order.removeAll()
    }

    // MARK: - Incoming connections

    /// Starts accepting incoming peer connections (and DHT, when enabled).
    /// Returns the bound port.
    @discardableResult
    public func startListening() async throws -> UInt16 {
        guard configuration.listenPort != 0 else { return 0 }
        guard listener == nil else { return configuration.listenPort }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: configuration.listenPort) else {
            throw SessionError.listenFailed("bad port")
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            throw SessionError.listenFailed("\(error)")
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.handleIncoming(connection) }
        }
        // Constructing an NWListener proves nothing: a busy port surfaces
        // asynchronously through the state handler (usually as `.waiting` with
        // EADDRINUSE, not `.failed`). Without this the app ran with no incoming
        // connections at all, no error anywhere, and DHT and port mapping
        // pointed at a port nothing was bound to.
        do {
            try await Self.waitUntilReady(listener)
        } catch {
            listener.cancel()
            throw error
        }
        self.listener = listener

        if configuration.enablePortMapping {
            await portMapper.start(internalPort: configuration.listenPort)
        }

        if configuration.enableDHT {
            let statePath = configuration.stateDirectory?.appendingPathComponent("dht-nodes.json")
            try? await dht.start(port: configuration.listenPort, statePath: statePath)
            dhtTask = Task { await self.runDHTDiscovery() }
        }

        if configuration.enableLSD {
            try? await lsd.start { [weak self] address, hashes in
                Task { await self?.lsdDiscovered(address, hashes) }
            }
            lsdTask = Task { await self.runLSDAnnounce() }
        }
        return configuration.listenPort
    }

    /// Starts `listener` and returns once it has actually bound, throwing if it
    /// cannot. `.waiting` is not treated as failure immediately — it also covers
    /// transient conditions like an interface coming up — but a listener still
    /// waiting when the grace period expires has not got the port.
    private static func waitUntilReady(_ listener: NWListener) async throws {
        let gate = ListenerReadyGate()
        try await withCheckedThrowingContinuation { continuation in
            gate.arm(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:             gate.succeed()
                case .failed(let error): gate.fail("\(error)")
                case .cancelled:         gate.fail("listener was cancelled")
                case .waiting(let error): gate.noteWaiting("\(error)")
                default:                 break
                }
            }
            listener.start(queue: DispatchQueue(label: "torrent-listener"))
            Task {
                try? await Task.sleep(for: .seconds(5))
                gate.expire()
            }
        }
    }

    /// Info hashes of active, non-private torrents (LSD/PEX-eligible).
    private func publicActiveHashes() async -> [InfoHash] {
        var hashes: [InfoHash] = []
        for (hash, controller) in controllers where !controller.info.isPrivate {
            let state = await controller.currentState
            if state == .downloading || state == .seeding { hashes.append(hash) }
        }
        return hashes
    }

    private func runLSDAnnounce() async {
        try? await Task.sleep(for: .seconds(2))
        while !Task.isCancelled {
            let hashes = await publicActiveHashes()
            if !hashes.isEmpty {
                await lsd.announce(port: configuration.listenPort, infoHashes: hashes)
            }
            // BEP 14 suggests re-announcing on a slow cadence.
            try? await Task.sleep(for: .seconds(300))
        }
    }

    private func lsdDiscovered(_ address: PeerAddress, _ hashes: [InfoHash]) async {
        for hash in hashes {
            guard let controller = controllers[hash], !controller.info.isPrivate else { continue }
            await controller.addKnownPeers([address])
        }
    }

    /// Periodically asks the DHT for peers for every active public torrent
    /// and unresolved magnet.
    private func runDHTDiscovery() async {
        try? await Task.sleep(for: .seconds(5)) // let bootstrap make progress
        while !Task.isCancelled {
            // Unresolved magnets poll the DHT themselves (see MagnetController).
            for (hash, controller) in controllers where !controller.info.isPrivate {
                let state = await controller.snapshot().state
                guard state == .downloading || state == .seeding else { continue }
                let peers = await dht.findPeers(infoHash: hash, announcePort: configuration.listenPort)
                if state == .downloading, !peers.isEmpty {
                    await controller.addKnownPeers(peers)
                }
            }
            try? await Task.sleep(for: .seconds(180))
        }
    }

    /// Ceiling on incoming connections still working through their handshake.
    /// Each one costs an actor, a dispatch queue, and up to 20s of waiting
    /// before `adoptIncoming`'s per-torrent cap gets a chance to reject it —
    /// so without a bound here, anyone who can reach the port can make us
    /// allocate thousands of them.
    private static let maxPendingHandshakes = 200
    private var pendingHandshakes = 0

    private func handleIncoming(_ rawConnection: NWConnection) async {
        guard pendingHandshakes < Self.maxPendingHandshakes else {
            rawConnection.cancel()
            return
        }
        pendingHandshakes += 1
        defer { pendingHandshakes -= 1 }
        let connection = PeerConnection(incoming: rawConnection)
        do {
            try await connection.start()
            let policy = configuration.encryptionPolicy
            // A plaintext BT handshake starts with 0x13 "BitTorrent protocol";
            // anything else from an encryption-capable setup is an MSE DH key.
            let prefix = try await connection.receiveRawBytes(20)
            let plaintextPrefix = Data([19] + Array("BitTorrent protocol".utf8))

            let handshake: Handshake
            if prefix == plaintextPrefix {
                guard policy != .required else {
                    throw PeerWireError.handshakeFailed("plaintext peer refused")
                }
                let rest = try await connection.receiveRawBytes(Handshake.length - 20)
                handshake = try Handshake.decode(prefix + rest)
            } else {
                guard policy != .disabled else {
                    throw PeerWireError.handshakeFailed("encryption disabled")
                }
                let (infoHash, _) = try await connection.mseResponderHandshake(
                    prefix: prefix,
                    infoHashes: Array(controllers.keys),
                    allowPlaintext: policy != .required
                )
                // The BT handshake follows on the negotiated stream.
                handshake = try await connection.receiveHandshake()
                guard handshake.infoHash == infoHash else {
                    throw PeerWireError.handshakeFailed("MSE torrent mismatch")
                }
            }

            guard let controller = controllers[handshake.infoHash] else {
                throw PeerWireError.handshakeFailed("unknown torrent")
            }
            await controller.adoptIncoming(connection: connection, handshake: handshake)
        } catch {
            connection.close()
        }
    }
}

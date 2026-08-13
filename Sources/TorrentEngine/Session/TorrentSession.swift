import Foundation
import Network

public enum SessionError: Error, Equatable {
    case duplicateTorrent
    case unknownTorrent
    case invalidMagnet
    case listenFailed(String)
    case moveFailed(String)
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

        public init(
            downloadDirectory: URL,
            listenPort: UInt16 = 6881,
            maxPeersPerTorrent: Int = 40,
            sequentialDownload: Bool = false,
            stateDirectory: URL? = nil,
            downloadRateLimit: Int? = nil,
            uploadRateLimit: Int? = nil,
            enableDHT: Bool = true
        ) {
            self.downloadDirectory = downloadDirectory
            self.listenPort = listenPort
            self.maxPeersPerTorrent = maxPeersPerTorrent
            self.sequentialDownload = sequentialDownload
            self.stateDirectory = stateDirectory
            self.downloadRateLimit = downloadRateLimit
            self.uploadRateLimit = uploadRateLimit
            self.enableDHT = enableDHT
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

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.persistence = configuration.stateDirectory.map(PersistenceStore.init(baseURL:))
        self.downloadLimiter = RateLimiter(bytesPerSecond: configuration.downloadRateLimit)
        self.uploadLimiter = RateLimiter(bytesPerSecond: configuration.uploadRateLimit)
    }

    public func setRateLimits(download: Int?, upload: Int?) async {
        configuration.downloadRateLimit = download
        configuration.uploadRateLimit = upload
        await downloadLimiter.setRate(download)
        await uploadLimiter.setRate(upload)
    }

    /// Re-adds every persisted torrent (call once at startup).
    public func restore() async {
        guard let persistence else { return }
        for entry in persistence.loadAll() {
            guard let meta = try? TorrentMetaInfo(torrentFileData: entry.torrentData) else { continue }
            let directory = entry.resume.map { URL(fileURLWithPath: $0.downloadDirectory) }
            _ = try? await addTorrent(
                info: meta.info,
                announceTiers: meta.announceTiers,
                downloadDirectory: directory,
                resume: entry.resume,
                persistTorrentData: nil
            )
        }
    }

    // MARK: - Torrent management

    @discardableResult
    public func addTorrent(
        fileData: Data,
        downloadDirectory: URL? = nil,
        sequential: Bool? = nil,
        wantedFiles: Set<Int>? = nil
    ) async throws -> InfoHash {
        let meta = try TorrentMetaInfo(torrentFileData: fileData)
        return try await addTorrent(
            info: meta.info,
            announceTiers: meta.announceTiers,
            downloadDirectory: downloadDirectory,
            sequential: sequential,
            wantedFiles: wantedFiles,
            resume: nil,
            persistTorrentData: fileData
        )
    }

    func addTorrent(
        info: TorrentInfo,
        announceTiers: [[String]],
        downloadDirectory: URL?,
        sequential: Bool? = nil,
        wantedFiles: Set<Int>? = nil,
        resume: ResumeData? = nil,
        persistTorrentData: Data? = nil
    ) async throws -> InfoHash {
        guard controllers[info.infoHash] == nil else { throw SessionError.duplicateTorrent }
        var config = ControllerConfig()
        config.maxPeers = configuration.maxPeersPerTorrent
        config.listenPort = configuration.listenPort
        config.sequential = sequential ?? configuration.sequentialDownload
        let controller = TorrentController(
            info: info,
            announceTiers: announceTiers,
            downloadDirectory: downloadDirectory ?? configuration.downloadDirectory,
            sessionPeerID: peerID,
            config: config,
            persistence: persistence,
            initialResume: resume,
            wantedFiles: wantedFiles,
            downloadLimiter: downloadLimiter,
            uploadLimiter: uploadLimiter
        )
        controllers[info.infoHash] = controller
        order.append(info.infoHash)
        if let persistTorrentData, let persistence {
            persistence.saveTorrentData(persistTorrentData, for: info.infoHash)
        }
        if configuration.enableDHT, !info.isPrivate {
            let dht = dht
            await controller.setPeerDHTPortHandler { address in
                Task { await dht.addCandidate(address) }
            }
        }
        await controller.start()
        return info.infoHash
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
            discoverPeers: discover
        ) { [weak self] infoData in
            await self?.metadataResolved(magnet: magnet, infoData: infoData)
        }
        magnets[magnet.infoHash] = controller
        order.append(magnet.infoHash)
        await controller.start()
        return magnet.infoHash
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
        order.removeAll { $0 == magnet.infoHash }

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
            persistTorrentData: assembled
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
    /// converts itself on resolve (ignoring `wantedFiles`, since files are
    /// unknown until then).
    @discardableResult
    public func commitMagnet(
        _ infoHash: InfoHash,
        downloadDirectory: URL? = nil,
        sequential: Bool? = nil,
        wantedFiles: Set<Int>? = nil
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

    /// Restricts the download to the given file indices (must be non-empty).
    public func setWantedFiles(_ wanted: Set<Int>, for infoHash: InfoHash) async throws {
        guard let controller = controllers[infoHash] else {
            throw SessionError.unknownTorrent
        }
        await controller.setWantedFiles(wanted)
    }

    public func removeTorrent(_ infoHash: InfoHash, deleteFiles: Bool = false) async throws {
        if let magnet = magnets.removeValue(forKey: infoHash) {
            order.removeAll { $0 == infoHash }
            await magnet.stop()
            persistence?.remove(for: infoHash)
            return
        }
        guard let controller = controllers.removeValue(forKey: infoHash) else {
            throw SessionError.unknownTorrent
        }
        order.removeAll { $0 == infoHash }
        await controller.stop()
        if deleteFiles {
            await controller.deleteFiles()
        }
        persistence?.remove(for: infoHash)
    }

    public func pauseTorrent(_ infoHash: InfoHash) async throws {
        guard let controller = controllers[infoHash] else { throw SessionError.unknownTorrent }
        await controller.pause()
    }

    public func resumeTorrent(_ infoHash: InfoHash) async throws {
        guard let controller = controllers[infoHash] else { throw SessionError.unknownTorrent }
        await controller.resumeActivity()
    }

    public func pauseAll() async {
        for controller in controllers.values {
            await controller.pause()
        }
    }

    public func resumeAll() async {
        for controller in controllers.values {
            await controller.resumeActivity()
        }
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
            }
        }
        return result
    }

    public func shutdown() async {
        listener?.cancel()
        listener = nil
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
            await controller.stop()
        }
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
        listener.start(queue: DispatchQueue(label: "torrent-listener"))
        self.listener = listener

        if configuration.enableDHT {
            let statePath = configuration.stateDirectory?.appendingPathComponent("dht-nodes.json")
            try? await dht.start(port: configuration.listenPort, statePath: statePath)
            dhtTask = Task { await self.runDHTDiscovery() }
        }
        return configuration.listenPort
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

    private func handleIncoming(_ rawConnection: NWConnection) async {
        let connection = PeerConnection(incoming: rawConnection)
        do {
            try await connection.start()
            let handshake = try await connection.receiveHandshake()
            guard let controller = controllers[handshake.infoHash] else {
                throw PeerWireError.handshakeFailed("unknown torrent")
            }
            await controller.adoptIncoming(connection: connection, handshake: handshake)
        } catch {
            connection.close()
        }
    }
}

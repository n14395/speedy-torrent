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
    /// Waiting for an active-download slot (see max active downloads).
    case queued
    case failed
}

/// How urgently a file's pieces are requested, relative to the torrent's other
/// files. Orthogonal to selection: priority orders what is fetched next,
/// `wanted` decides whether it is fetched at all.
public enum FilePriority: Int, Sendable, Codable, CaseIterable, Comparable {
    case low = -1
    case normal = 0
    case high = 1

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One file inside a torrent, with its selection state and progress.
public struct TorrentFileStatus: Sendable, Identifiable, Equatable {
    public var id: Int { index }
    public let index: Int
    public let path: [String]
    public let length: Int64
    public let wanted: Bool
    public let priority: FilePriority
    public let completedLength: Int64

    public var progress: Double {
        length > 0 ? Double(completedLength) / Double(length) : 1
    }
}

/// A live view of one connected peer, for the inspector.
public struct PeerDetail: Sendable, Identifiable {
    public var id: String { address }
    public let address: String
    public let client: String
    public let downloadRate: Double
    public let uploadRate: Double
    /// Fraction of the torrent this peer has.
    public let progress: Double
    public let isSeed: Bool
    public let incoming: Bool
    public let encrypted: Bool
    /// We are choking / interested in them.
    public let chokingPeer: Bool
    public let interestedInPeer: Bool
    /// They are choking / interested in us.
    public let peerChokingUs: Bool
    public let peerInterestedInUs: Bool
}

/// A tracker's URL, tier, and most recent announce outcome, for the inspector.
public struct TrackerDetail: Sendable, Identifiable {
    public var id: String { url }
    public let url: String
    public let tier: Int
    public let lastError: String?
    public let lastSuccess: Date?
    public let seeders: Int?
    public let leechers: Int?
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
    /// Per-torrent speed caps in bytes/second; nil = only the session's limit
    /// applies.
    public let downloadRateLimit: Int?
    public let uploadRateLimit: Int?
    /// When the torrent was first added (Unix time; 0 when unknown).
    public let addedAt: Double
    /// Piece size in bytes (0 while metadata is unknown).
    public let pieceLength: Int
    /// How far a hash re-check has got, 0...1. Only meaningful in `.checking`;
    /// before this the UI had nothing to show for what can be minutes of work.
    public var checkProgress: Double = 0
    /// How far a move to another folder has got, 0...1. Only meaningful in
    /// `.moving`, and only interesting when the destination is on another
    /// volume — a move within one volume is a rename and finishes at once.
    public var moveProgress: Double = 0
    /// 1-based position in the session's queue (= download priority); 0 for
    /// snapshots taken outside a session's ordered listing.
    public var queuePosition: Int = 0

    public var progress: Double {
        wantedLength > 0 ? Double(completedLength) / Double(wantedLength) : 0
    }

    public var eta: TimeInterval? {
        guard state == .downloading, downloadRate > 1 else { return nil }
        return Double(max(0, wantedLength - completedLength)) / downloadRate
    }

    public var ratio: Double {
        shareRatio(uploaded: uploadedTotal, downloaded: downloadedTotal, completed: completedLength)
    }
}

/// Share ratio, in one place so the seed goal that enforces it and the
/// inspector that displays it can never drift apart. Falls back to verified
/// bytes when nothing was downloaded — a torrent seeded from existing data on
/// disk still has a meaningful ratio.
func shareRatio(uploaded: Int64, downloaded: Int64, completed: Int64) -> Double {
    if downloaded > 0 { return Double(uploaded) / Double(downloaded) }
    return completed > 0 ? Double(uploaded) / Double(completed) : 0
}

struct ControllerConfig: Sendable {
    var maxPeers = 40
    var maxOutstandingPerPeer = 32
    var listenPort: UInt16 = 6881
    var sequential = false
    /// Seconds between ut_pex (BEP 11) updates; 0 disables sending.
    var pexIntervalSeconds = 60
    /// MSE/PE stream-encryption policy for peer connections.
    var encryptionPolicy: EncryptionPolicy = .disabled
    /// Stop seeding once the share ratio reaches this (nil = never).
    var seedRatioLimit: Double?
    /// Stop seeding after this many seconds of seeding (nil = never).
    var seedTimeLimit: TimeInterval?
}

/// Per-torrent orchestrator: owns the peer set, piece manager, storage, and
/// announce/tick loops.
actor TorrentController {
    /// A stable per-peer identity. This used to be `ObjectIdentifier` of the
    /// connection — but that value is recycled once the object deallocates, and
    /// `pieceContributors` holds keys for peers that have long since gone, so a
    /// later connection could inherit a departed peer's corruption record.
    typealias PeerKey = UUID

    /// Per-peer protocol state (confined to this actor).
    private final class Peer {
        let id = PeerKey()
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
        /// The peer's message ID for ut_pex, or nil if it doesn't support it.
        var theirUTPexID: UInt8?
        /// The peer's reachable listening endpoint, for gossip via PEX. Known
        /// immediately for peers we dialed; for incoming peers it's learned
        /// from the `p` field of their extension handshake.
        var listenEndpoint: PeerAddress?
        /// Peers last advertised to this peer, to compute added/dropped deltas.
        var lastPexAdvertised: Set<PeerAddress> = []
        /// True if this peer connected to us (rather than us dialing it).
        var incoming = false
        /// True if the connection negotiated MSE/PE encryption.
        var encrypted = false
        /// The peer's client name/version (`v` handshake string), if sent.
        var clientVersion: String?

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
    /// This torrent's own buckets, created only while it carries an override so
    /// unlimited torrents don't pay for an extra actor hop per block.
    private var torrentDownloadLimiter: RateLimiter?
    private var torrentUploadLimiter: RateLimiter?
    private(set) var downloadRateLimit: Int?
    private(set) var uploadRateLimit: Int?
    private let webSeeds: [String]
    private let webSeedClient: WebSeedClient
    private var webSeedTask: Task<Void, Never>?

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
    /// When the torrent most recently entered the seeding state.
    private var seedingSince: ContinuousClock.Instant?
    /// Set once a seed goal has auto-paused this torrent, so a manual resume
    /// isn't immediately re-paused.
    private var seedGoalEnforced = false
    /// Whether the tracker has already been told this torrent finished. Kept in
    /// resume data so a relaunch doesn't announce `completed` a second time.
    private var hasAnnouncedCompleted = false

    private var tickTask: Task<Void, Never>?
    private var announceTask: Task<Void, Never>?
    /// The in-flight hash scan, held so `stop()` can cancel it instead of
    /// waiting out a re-check of a very large torrent.
    private var verifyTask: Task<Bitfield, Never>?
    private var checkProgress: Double = 0
    private var moveProgress: Double = 0
    /// Where the move in flight is writing, and how many bytes it is carrying,
    /// so the tick can weigh what has landed against what was picked up.
    private var moveDestinations: [URL] = []
    private var moveTotalBytes: Int64 = 0

    init(
        info: TorrentInfo,
        announceTiers: [[String]],
        downloadDirectory: URL,
        sessionPeerID: Data,
        config: ControllerConfig,
        persistence: PersistenceStore? = nil,
        initialResume: ResumeData? = nil,
        wantedFiles: Set<Int>? = nil,
        filePriorities: [Int: FilePriority]? = nil,
        downloadLimiter: RateLimiter? = nil,
        uploadLimiter: RateLimiter? = nil,
        webSeeds: [String] = []
    ) {
        self.info = info
        self.webSeeds = webSeeds
        self.webSeedClient = WebSeedClient(info: info)
        self.store = FileStore(info: info, downloadDirectory: downloadDirectory)
        let resumeWanted = initialResume?.unwantedFiles.map {
            Set(info.files.indices).subtracting($0)
        }
        self.pieces = PieceManager(
            info: info,
            sequential: initialResume?.sequential ?? config.sequential,
            wantedFiles: wantedFiles ?? resumeWanted,
            filePriorities: filePriorities ?? initialResume?.savedFilePriorities ?? [:]
        )
        self.trackers = TrackerManager(tiers: announceTiers)
        self.sessionPeerID = sessionPeerID
        self.config = config
        self.downloadDirectory = downloadDirectory
        self.persistence = persistence
        self.initialResume = initialResume
        self.addedAt = initialResume?.addedAt ?? Date().timeIntervalSince1970
        self.hasAnnouncedCompleted = initialResume?.announcedCompleted ?? false
        self.downloadLimiter = downloadLimiter
        self.uploadLimiter = uploadLimiter
        self.downloadRateLimit = initialResume?.downloadRateLimit
        self.uploadRateLimit = initialResume?.uploadRateLimit
        self.torrentDownloadLimiter = Self.makeLimiter(self.downloadRateLimit)
        self.torrentUploadLimiter = Self.makeLimiter(self.uploadRateLimit)
    }

    private static func makeLimiter(_ bytesPerSecond: Int?) -> RateLimiter? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return RateLimiter(bytesPerSecond: bytesPerSecond)
    }

    // MARK: - Lifecycle

    func start() async {
        state = .checking
        tickTask = Task { await self.runTicks() }
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
                let existing = await verifyOnDisk()
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
            return
        }
        state = pieces.isWantedComplete ? .seeding : .downloading
        announceTask = Task { await self.runAnnounces() }
        if state == .downloading { startWebSeeds() }
    }

    func stop() async {
        let wasActive = state == .downloading || state == .seeding
        stopWebSeeds()
        verifyTask?.cancel()
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
            // Telling the tracker we've stopped is a courtesy; it must never
            // delay quitting, so give it a short budget and move on.
            let trackers = self.trackers
            let request = makeAnnounceRequest(event: .stopped)
            await withDeadline(seconds: 2) { await trackers.announceAll(request) }
        }
    }

    func pause() async {
        guard state == .downloading || state == .seeding || state == .queued else { return }
        let wasActive = state != .queued
        state = .paused
        stopWebSeeds()
        announceTask?.cancel()
        announceTask = nil
        for peer in peers.values {
            peer.connection.close()
        }
        await saveResume()
        if wasActive {
            Task { await self.trackers.announceAll(self.makeAnnounceRequest(event: .stopped)) }
        }
    }

    var currentState: TorrentState { state }

    /// Session-injected hook fired when a download completes (frees a slot).
    private var onBecameSeed: (@Sendable () async -> Void)?

    func setOnBecameSeed(_ handler: @escaping @Sendable () async -> Void) {
        onBecameSeed = handler
    }

    /// Parks an actively-downloading torrent while it waits for a slot.
    func moveToQueue() async {
        guard state == .downloading else { return }
        state = .queued
        stopWebSeeds()
        announceTask?.cancel()
        announceTask = nil
        for peer in peers.values { peer.connection.close() }
        await saveResume()
        Task { await self.trackers.announceAll(self.makeAnnounceRequest(event: .stopped)) }
    }

    /// Starts a queued (incomplete) torrent once a slot is free.
    func startFromQueue() async {
        guard state == .queued else { return }
        state = .downloading
        announceTask = Task { await self.runAnnounces() }
        dialPeers()
        startWebSeeds()
        await saveResume()
    }

    func resumeActivity() async {
        guard state == .paused else { return }
        state = pieces.isWantedComplete ? .seeding : .downloading
        announceTask = Task { await self.runAnnounces() }
        dialPeers()
        if state == .downloading { startWebSeeds() }
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
            highPriorityFiles: pieces.fileIndices(at: .high),
            lowPriorityFiles: pieces.fileIndices(at: .low),
            downloadRateLimit: downloadRateLimit,
            uploadRateLimit: uploadRateLimit,
            addedAt: addedAt,
            announcedCompleted: hasAnnouncedCompleted ? true : nil,
            fileStamps: await store.fileStamps()
        )
        persistence.saveResume(resume, for: info.infoHash)
    }

    func setSequential(_ sequential: Bool) async {
        guard pieces.sequential != sequential else { return }
        pieces.sequential = sequential
        await saveResume()
    }

    /// Updates the seed-goal limits (nil = unlimited). Does not re-enforce a
    /// goal already applied to a torrent the user manually resumed — but a
    /// change to the goal itself clears that latch, so raising a ratio limit
    /// applies to torrents the old one already stopped.
    func setSeedingLimits(ratio: Double?, time: TimeInterval?) {
        let changed = ratio != config.seedRatioLimit || time != config.seedTimeLimit
        config.seedRatioLimit = ratio
        config.seedTimeLimit = time
        if changed { seedGoalEnforced = false }
    }

    private var currentRatio: Double {
        shareRatio(
            uploaded: uploadedTotal,
            downloaded: downloadedTotal,
            completed: pieces.completedWantedBytes
        )
    }

    private func seedGoalReached() -> Bool {
        if let ratioLimit = config.seedRatioLimit, ratioLimit > 0, currentRatio >= ratioLimit {
            return true
        }
        if let timeLimit = config.seedTimeLimit, timeLimit > 0, let since = seedingSince,
           ContinuousClock.now - since >= .seconds(timeLimit) {
            return true
        }
        return false
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
            // Measured before anything moves: once a cross-volume move starts
            // deleting its sources, the total it started with is gone.
            let sources = moves.map(\.0)
            moveTotalBytes = await Task.detached(priority: .utility) {
                Self.bytesOnDisk(sources)
            }.value
            moveDestinations = moves.map(\.1)
            moveProgress = 0
            // Off-actor: cross-volume moves copy and can take a while.
            try await Task.detached(priority: .utility) {
                for (source, destination) in moves {
                    try SparseMove.move(from: source, to: destination)
                }
            }.value
            endMoveTracking()
        } catch let error as SessionError {
            endMoveTracking()
            state = previousState
            throw error
        } catch {
            endMoveTracking()
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

    private func endMoveTracking() {
        moveDestinations = []
        moveTotalBytes = 0
        moveProgress = 0
    }

    /// Bytes actually occupied on disk by everything at these paths,
    /// descending into directories. A path that isn't there yet counts as
    /// zero, which is exactly what makes this usable on a destination that is
    /// still filling up.
    ///
    /// Blocks rather than length, because the engine's files are sparse: a
    /// half-downloaded torrent is as long as the finished one would be, and
    /// measuring length would have every move read as complete from the first
    /// tick. Blocks measure the data that genuinely has to travel.
    ///
    /// Deliberately `stat` rather than `URL.resourceValues`, which caches: on a
    /// single-file torrent the same URL is re-read every tick, and the cached
    /// answer pinned a 150 GB move's progress at whatever it read first.
    static func bytesOnDisk(_ urls: [URL]) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            var info = stat()
            guard stat(url.path, &info) == 0 else { continue }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                total += Int64(info.st_blocks) * 512
                continue
            }
            // Relative paths, so no URL objects are involved to cache anything.
            guard let enumerator = FileManager.default.enumerator(atPath: url.path) else { continue }
            for case let relative as String in enumerator {
                total += blocksOnDisk(atPath: url.appendingPathComponent(relative).path)
            }
        }
        return total
    }

    private static func blocksOnDisk(atPath path: String) -> Int64 {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return 0 }
        return Int64(info.st_blocks) * 512
    }

    /// Re-hashes everything on disk and rebuilds the have-set from scratch —
    /// the user's "verify data" action. Transfer pauses during the scan.
    func recheck() async {
        guard state == .downloading || state == .seeding || state == .paused else { return }
        let wasPaused = state == .paused
        state = .checking
        announceTask?.cancel()
        announceTask = nil
        for peer in peers.values { peer.connection.close() }

        pieces.resetHave()
        let existing = await verifyOnDisk()
        for index in 0..<info.pieceCount where existing[index] {
            pieces.markHave(index)
        }
        await store.reconcile(have: pieces.have)
        await saveResume()

        if wasPaused {
            state = .paused
        } else {
            state = pieces.isWantedComplete ? .seeding : .downloading
            announceTask = Task { await self.runAnnounces() }
            dialPeers()
        }
    }

    /// Runs the hash scan in a task we can cancel, and clears the progress
    /// reading afterwards.
    private func verifyOnDisk() async -> Bitfield {
        let store = self.store
        let task = Task { await store.verifyAllPieces() }
        verifyTask = task
        let result = await task.value
        verifyTask = nil
        checkProgress = 0
        return result
    }

    // MARK: - File selection

    func fileStatuses() -> [TorrentFileStatus] {
        let pieceLen = Int64(info.pieceLength)
        var offset: Int64 = 0
        return info.files.enumerated().map { index, file in
            let fileStart = offset
            let fileEnd = offset + file.length
            offset = fileEnd
            // Completed bytes = the portions of each verified piece overlapping
            // this file's byte range.
            var done: Int64 = 0
            if file.length > 0 {
                for piece in Int(fileStart / pieceLen)...Int((fileEnd - 1) / pieceLen)
                where pieces.have[piece] {
                    let pieceStart = Int64(piece) * pieceLen
                    let pieceEnd = pieceStart + Int64(info.pieceSize(at: piece))
                    done += max(0, min(pieceEnd, fileEnd) - max(pieceStart, fileStart))
                }
            }
            return TorrentFileStatus(
                index: index,
                path: file.path,
                length: file.length,
                wanted: pieces.wantedFiles.contains(index),
                priority: pieces.priority(for: index),
                completedLength: done
            )
        }
    }

    /// Live details of every connected peer, for the inspector.
    func peerDetails() -> [PeerDetail] {
        peers.values.map { peer in
            let endpoint = peer.listenEndpoint ?? peer.connection.address
            return PeerDetail(
                address: endpoint.description,
                client: PeerClient.describe(peerID: peer.peerID, version: peer.clientVersion),
                downloadRate: peer.downloadRateEMA,
                uploadRate: peer.uploadRateEMA,
                progress: info.pieceCount > 0
                    ? Double(peer.bitfield.setCount) / Double(info.pieceCount) : 0,
                isSeed: peer.bitfield.isFull,
                incoming: peer.incoming,
                encrypted: peer.encrypted,
                chokingPeer: peer.amChoking,
                interestedInPeer: peer.amInterested,
                peerChokingUs: peer.peerChoking,
                peerInterestedInUs: peer.peerInterested
            )
        }
        .sorted { $0.address < $1.address }
    }

    /// Per-tracker status for the inspector.
    func trackerDetails() async -> [TrackerDetail] {
        let tiers = await trackers.allTrackers
        let errors = await trackers.lastErrors
        let success = await trackers.lastSuccess
        let seeders = await trackers.lastSeeders
        let leechers = await trackers.lastLeechers
        var out: [TrackerDetail] = []
        for (tierIndex, tier) in tiers.enumerated() {
            for url in tier {
                out.append(TrackerDetail(
                    url: url,
                    tier: tierIndex,
                    lastError: errors[url],
                    lastSuccess: success[url],
                    seeders: seeders[url],
                    leechers: leechers[url]
                ))
            }
        }
        return out
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
            await enterSeeding()
        }
        // Interest can flip in either direction for every peer.
        for (key, peer) in peers {
            try? await updateInterest(peer: peer, key: key)
        }
        // A newly-wanted file already present on disk should be finalized.
        await store.reconcile(have: pieces.have)
        await saveResume()
    }

    private func applyLimiters(to connection: PeerConnection) async {
        await connection.setLimiters(
            download: downloadLimiter,
            upload: uploadLimiter,
            torrentDownload: torrentDownloadLimiter,
            torrentUpload: torrentUploadLimiter
        )
    }

    /// Sets this torrent's own speed caps in bytes/second (nil or 0 = follow
    /// only the session's). Takes effect on connections that are already open:
    /// a limit you have to reconnect for isn't a limit anyone would trust.
    func setRateLimits(download: Int?, upload: Int?) async {
        let newDownload = (download ?? 0) > 0 ? download : nil
        let newUpload = (upload ?? 0) > 0 ? upload : nil
        guard newDownload != downloadRateLimit || newUpload != uploadRateLimit else { return }
        downloadRateLimit = newDownload
        uploadRateLimit = newUpload

        // Re-rate the buckets in place where they already exist, so tokens
        // banked a moment ago aren't discarded by a small edit.
        if let newDownload, let limiter = torrentDownloadLimiter {
            await limiter.setRate(newDownload)
        } else {
            torrentDownloadLimiter = Self.makeLimiter(newDownload)
        }
        if let newUpload, let limiter = torrentUploadLimiter {
            await limiter.setRate(newUpload)
        } else {
            torrentUploadLimiter = Self.makeLimiter(newUpload)
        }

        for peer in peers.values {
            await applyLimiters(to: peer.connection)
        }
        await saveResume()
    }

    /// Changes how urgently the given files are requested. Nothing about the
    /// transfer stops or restarts — the next piece picked simply comes from the
    /// most urgent file that still has work left.
    func setFilePriority(_ priority: FilePriority, for files: Set<Int>) async {
        pieces.setPriority(priority, for: files)
        await saveResume()
    }

    var contentURL: URL { store.revealURL() }

    /// Upper bound on the candidate pool. Trackers, PEX, LSD and the DHT all
    /// feed it and nothing used to remove from it, so on a popular torrent it
    /// grew into the thousands — and `dialPeers` copied the whole thing every
    /// five seconds to shuffle it.
    private static let maxKnownAddresses = 500

    func addKnownPeers(_ addresses: [PeerAddress]) {
        for address in addresses where !bannedAddresses.contains(address) {
            if knownAddresses.count >= Self.maxKnownAddresses {
                // Evict an address we aren't using rather than growing without
                // bound; the pool is a hint, not a record.
                guard let victim = knownAddresses.first(where: {
                    !connectedAddresses.contains($0)
                }) else { break }
                knownAddresses.remove(victim)
            }
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
            sequential: pieces.sequential,
            downloadRateLimit: downloadRateLimit,
            uploadRateLimit: uploadRateLimit,
            addedAt: addedAt,
            pieceLength: info.pieceLength,
            checkProgress: checkProgress,
            moveProgress: moveProgress
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

    // MARK: - Web seeds (BEP 19)

    private func startWebSeeds() {
        guard !webSeeds.isEmpty, webSeedTask == nil else { return }
        webSeedTask = Task { await self.runWebSeeds() }
    }

    private func stopWebSeeds() {
        webSeedTask?.cancel()
        webSeedTask = nil
    }

    /// Pulls missing pieces from HTTP mirrors while downloading — an extra
    /// source alongside peers. Sequential; rotates mirrors on failure.
    private func runWebSeeds() async {
        var urlIndex = 0
        while !Task.isCancelled {
            guard state == .downloading else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            guard let piece = pieces.nextMissingWantedPiece() else {
                try? await Task.sleep(for: .seconds(2)) // wait for peers to free work / finish
                continue
            }
            let base = webSeeds[urlIndex % webSeeds.count]
            do {
                let data = try await webSeedClient.fetchPiece(
                    piece, from: base,
                    torrentLimiter: torrentDownloadLimiter,
                    sessionLimiter: downloadLimiter
                )
                await ingestWebSeedPiece(piece, data: data)
            } catch {
                urlIndex += 1 // rotate to another mirror
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func ingestWebSeedPiece(_ index: Int, data: Data) async {
        guard state == .downloading, !pieces.have[index],
              data.count == info.pieceSize(at: index),
              Data(Insecure.SHA1.hash(data: data)) == info.pieceHashes[index]
        else { return }
        do {
            try await store.writePiece(data, at: index)
        } catch {
            return
        }
        pieces.pieceVerified(index)
        downloadedTotal += Int64(data.count)
        await store.finalizeCompletedFiles(after: index, have: pieces.have)
        await broadcastHave(index)
        if pieces.isWantedComplete {
            await enterSeeding()
        }
    }

    // MARK: - Peer dialing

    private func dialPeers() {
        guard state == .downloading || state == .seeding else { return }
        let wanted = config.maxPeers - connectedAddresses.count
        guard wanted > 0 else { return }
        // Sample rather than shuffling the whole pool: this runs every five
        // seconds per torrent and only ever dials a handful.
        let candidates = knownAddresses.count <= wanted * 4
            ? Array(knownAddresses)
            : (0..<(wanted * 4)).compactMap { _ in knownAddresses.randomElement() }
        for address in candidates {
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
        let policy = config.encryptionPolicy
        if await attemptOutgoing(address, encrypt: policy != .disabled, require: policy == .required) {
            return
        }
        // "Preferred" retries once in plaintext for peers that can't do MSE.
        if policy == .preferred, await attemptOutgoing(address, encrypt: false, require: false) {
            return
        }
        connectedAddresses.remove(address)
    }

    /// One outgoing connection attempt. Returns true if the peer loop ran to
    /// completion (so no fallback is needed), false if the caller may retry.
    private func attemptOutgoing(_ address: PeerAddress, encrypt: Bool, require: Bool) async -> Bool {
        let connection = PeerConnection(address: address)
        do {
            await applyLimiters(to: connection)
            try await connection.start()
            if encrypt {
                _ = try await connection.mseInitiatorHandshake(
                    infoHash: info.infoHash, requireEncryption: require
                )
            }
            try await connection.sendHandshake(
                Handshake(infoHash: info.infoHash, peerID: sessionPeerID)
            )
            let theirs = try await connection.receiveHandshake()
            guard theirs.infoHash == info.infoHash, theirs.peerID != sessionPeerID else {
                throw PeerWireError.handshakeFailed("wrong torrent or self-connection")
            }
            await runPeerLoop(connection: connection, handshake: theirs, address: address, outgoing: true)
            return true
        } catch {
            connection.close()
            return false
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
        await applyLimiters(to: connection)
        let address = connection.address
        connectedAddresses.insert(address)
        let taskID = UUID()
        peerTasks[taskID] = Task {
            do {
                try await connection.sendHandshake(
                    Handshake(infoHash: self.info.infoHash, peerID: self.sessionPeerID)
                )
                await self.runPeerLoop(connection: connection, handshake: handshake, address: address, outgoing: false)
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

    private func runPeerLoop(
        connection: PeerConnection, handshake: Handshake, address: PeerAddress, outgoing: Bool
    ) async {
        let peer = Peer(
            connection: connection,
            peerID: handshake.peerID,
            pieceCount: info.pieceCount,
            supportsExtensions: handshake.supportsExtensions
        )
        let key = peer.id
        // For peers we dialed, the address we dialed is their listening
        // endpoint; incoming peers' endpoints are learned from `p` later.
        peer.incoming = !outgoing
        peer.encrypted = await connection.isEncrypted
        if outgoing { peer.listenEndpoint = address }
        peers[key] = peer

        do {
            if handshake.supportsExtensions {
                await connection.enqueue(.extended(id: 0, payload: ExtensionHandshake.encode(
                    metadataSize: info.rawData.count,
                    listenPort: config.listenPort,
                    pexID: info.isPrivate ? nil : ExtensionHandshake.utPexID
                )))
            }
            if !pieces.have.isEmpty {
                await connection.enqueue(.bitfield(pieces.have.data))
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
            await fillRequests(peer: peer, key: key)

        case .interested:
            peer.peerInterested = true
            // Grant an unchoke immediately if we have spare slots; the
            // periodic choker will reevaluate against transfer rates.
            if peer.amChoking, unchokedCount < Self.unchokeSlots + 1 {
                peer.amChoking = false
                await peer.connection.enqueue(.unchoke)
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
                peer.theirUTPexID = parsed.utPexID
                if let client = parsed.client { peer.clientVersion = client }
                // Learn an incoming peer's real listening endpoint from `p`.
                if peer.listenEndpoint == nil, let listenPort = parsed.listenPort {
                    let endpoint = PeerAddress(
                        host: peer.connection.address.host, port: listenPort
                    )
                    peer.listenEndpoint = endpoint
                    // Track it under the endpoint we would dial, not the
                    // ephemeral source port it arrived on — otherwise the
                    // dedupe in `dialPeers` never matches and we redial peers
                    // we are already talking to.
                    connectedAddresses.remove(peer.connection.address)
                    connectedAddresses.insert(endpoint)
                }
            }
            return
        }
        if id == ExtensionHandshake.utPexID {
            // BEP 11 is disabled for private torrents.
            guard !info.isPrivate else { return }
            addKnownPeers(UTPex.parseAdded(payload))
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
                await peer.connection.enqueue(.extended(
                    id: theirID,
                    payload: UTMetadata.data(piece: message.piece, totalSize: raw.count, chunk: chunk)
                ))
            } else {
                await peer.connection.enqueue(.extended(
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
            await peer.connection.enqueue(shouldBeInterested ? .interested : .notInterested)
        }
        if shouldBeInterested, !peer.peerChoking {
            await fillRequests(peer: peer, key: key)
        }
    }

    /// Tops up a peer's request pipeline.
    ///
    /// The requests are queued rather than awaited, so there is no synchronous
    /// failure to roll back on any more. Nothing leaks: a connection that dies
    /// surfaces on the read side, and `removePeer` and the stale-request sweep
    /// in `tick` both cancel everything left in `peer.outstanding`.
    private func fillRequests(peer: Peer, key: PeerKey) async {
        guard state == .downloading, peer.amInterested, !peer.peerChoking else { return }
        while peer.outstanding.count < config.maxOutstandingPerPeer {
            guard let ref = pieces.nextRequest(
                peerHas: peer.bitfield,
                excluding: Set(peer.outstanding.keys)
            ) else { break }
            pieces.markRequested(ref)
            peer.outstanding[ref] = .now
            await peer.connection.enqueue(.request(
                index: UInt32(ref.index), begin: UInt32(ref.begin), length: UInt32(ref.length)
            ))
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
        await peer.connection.enqueue(.piece(
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

        let result = pieces.receivedBlock(index: index, begin: begin, block: block)
        if case .ignored = result {
            // Nothing consumed the request this block was answering — a wrong
            // length, a duplicate, or one we never asked for. Release the
            // counter, or the block stalls until endgame duplication finds it.
            pieces.cancelRequest(ref)
        }
        switch result {
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
                    await enterSeeding()
                }
            } else {
                pieces.pieceFailed(index)
                punishCorruption(contributors: contributors)
            }
        }
        await fillRequests(peer: peer, key: key)
    }

    private func punishCorruption(contributors: Set<PeerKey>) {
        for contributorKey in contributors {
            guard let contributor = peers[contributorKey] else { continue }
            contributor.corruptPieces += 1
            if contributor.corruptPieces >= 2 {
                let endpoint = contributor.listenEndpoint ?? contributor.connection.address
                bannedAddresses.insert(endpoint)
                knownAddresses.remove(endpoint)
                contributor.connection.close()
            }
        }
    }

    private func broadcastHave(_ index: Int) async {
        for peer in peers.values {
            await peer.connection.enqueue(.have(UInt32(index)))
        }
    }

    /// Sends each PEX-capable peer the added/dropped deltas of our *other*
    /// peers' reachable endpoints since the last update (BEP 11).
    private func sendPEXUpdates() async {
        let pool = Set(peers.values.compactMap(\.listenEndpoint))
        for peer in Array(peers.values) {
            guard let pexID = peer.theirUTPexID else { continue }
            // Never advertise a peer to itself.
            var current = pool
            if let own = peer.listenEndpoint { current.remove(own) }

            let added = Array(current.subtracting(peer.lastPexAdvertised).prefix(UTPex.maxPerMessage))
            let dropped = Array(peer.lastPexAdvertised.subtracting(current).prefix(UTPex.maxPerMessage))
            guard !added.isEmpty || !dropped.isEmpty else { continue }

            // Record exactly what we sent so future deltas stay accurate.
            peer.lastPexAdvertised.subtract(dropped)
            peer.lastPexAdvertised.formUnion(added)
            await peer.connection.enqueue(.extended(
                id: pexID, payload: UTPex.encode(added: added, dropped: dropped)
            ))
        }
    }

    /// Everything wanted is on disk: switch to seeding.
    ///
    /// The tracker `completed` event is separate because "wanted is complete"
    /// and "the torrent is complete" are different things. Deselecting files
    /// also satisfies the first, and announcing completion for a torrent we
    /// have barely any of — repeatedly, every time the selection is toggled —
    /// is not what a tracker is being told.
    private func enterSeeding() async {
        state = .seeding
        stopWebSeeds()
        // No longer interested in anyone.
        for peer in peers.values where peer.amInterested {
            peer.amInterested = false
            await peer.connection.enqueue(.notInterested)
        }
        if pieces.have.isFull, !hasAnnouncedCompleted {
            hasAnnouncedCompleted = true
            Task { await self.announceCompleted() }
        }
        // Freed an active-download slot — let the session promote a queued one.
        if let onBecameSeed {
            Task { await onBecameSeed() }
        }
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
        if state == .checking {
            checkProgress = await store.verifyProgress
        }
        // What has landed at the destination against what was picked up. The
        // sizing walk happens off the actor: on a torrent of many files it is
        // thousands of stats, and this runs every second.
        if state == .moving, moveTotalBytes > 0 {
            let destinations = moveDestinations
            let landed = await Task.detached(priority: .utility) {
                Self.bytesOnDisk(destinations)
            }.value
            moveProgress = min(1, max(0, Double(landed) / Double(moveTotalBytes)))
        }

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
                await fillRequests(peer: peer, key: key)
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
                await peer.connection.enqueue(.keepAlive)
            }
        }

        // Peer exchange (BEP 11) updates on the configured cadence.
        if config.pexIntervalSeconds > 0, !info.isPrivate,
           tickCount % config.pexIntervalSeconds == 0 {
            await sendPEXUpdates()
        }

        // Top up connections.
        if tickCount % 5 == 0 {
            dialPeers()
        }

        // Enforce seed goals (ratio / time), once per torrent.
        if state == .seeding {
            if seedingSince == nil { seedingSince = .now }
            if !seedGoalEnforced, seedGoalReached() {
                seedGoalEnforced = true
                await pause()
            }
        } else {
            seedingSince = nil
        }

        // Periodic resume-data checkpoint.
        if tickCount % 30 == 0 {
            await saveResume()
            // Contributor sets were only cleared when a piece completed, so
            // every piece abandoned by a hash failure, a deselected file, or a
            // re-check stranded one. Prune against what is actually in flight
            // rather than chasing each of those paths.
            let live = pieces.inProgressIndices
            if pieceContributors.count > live.count {
                pieceContributors = pieceContributors.filter { live.contains($0.key) }
            }
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
            await peer.connection.enqueue(shouldUnchoke ? .unchoke : .choke)
        }
    }
}

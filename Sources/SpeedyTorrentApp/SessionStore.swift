import Foundation
import SwiftUI
import UserNotifications
import TorrentEngine

/// App settings persisted in UserDefaults.
enum Defaults {
    static let downloadDirectory = "downloadDirectory"
    static let listenPort = "listenPort"
    static let sequentialDownload = "sequentialDownload"
    static let downloadRateLimitKiB = "downloadRateLimitKiB" // 0 = unlimited
    static let uploadRateLimitKiB = "uploadRateLimitKiB"
    static let maxPeers = "maxPeers"
    static let encryptionPolicy = "encryptionPolicy"
    static let seedRatioLimit = "seedRatioLimit"        // 0 = unlimited
    static let seedTimeLimitMinutes = "seedTimeLimitMinutes" // 0 = unlimited
    static let maxActiveDownloads = "maxActiveDownloads"     // 0 = unlimited

    static func register() {
        UserDefaults.standard.register(defaults: [
            downloadDirectory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
                .first?.path ?? NSHomeDirectory() + "/Downloads",
            listenPort: 6881,
            sequentialDownload: false,
            downloadRateLimitKiB: 0,
            uploadRateLimitKiB: 0,
            maxPeers: 40,
            encryptionPolicy: EncryptionPolicy.preferred.rawValue,
            seedRatioLimit: 0.0,
            seedTimeLimitMinutes: 0,
            maxActiveDownloads: 0,
        ])
    }
}

/// A torrent the user has opened but not yet confirmed via the per-torrent
/// settings sheet.
struct PendingTorrentAdd: Identifiable, Equatable {
    enum Source: Equatable {
        case torrentFile(data: Data)
        case magnet(uri: String)
    }

    let id = UUID()
    let source: Source
    let infoHash: InfoHash
    /// Metadata shown in the sheet. For magnets these start as placeholders and
    /// are filled in live once the background prefetch resolves.
    var displayName: String
    var totalSize: Int64?
    /// The torrent's files (empty for magnets until metadata arrives).
    var files: [FileEntry]
    /// True once a magnet's metadata has arrived (always true for .torrent).
    var metadataResolved: Bool

    var isMagnet: Bool {
        if case .magnet = source { return true }
        return false
    }
}

/// Main-actor bridge between the engine session and SwiftUI.
@MainActor
@Observable
final class SessionStore {
    private(set) var session: TorrentSession?
    private(set) var snapshots: [TorrentSnapshot] = []
    private(set) var startupError: String?
    private(set) var portMappingStatus: PortMappingStatus = .disabled
    private(set) var dhtNodeCount = 0
    /// Session + all-time transfer counters (nil until the first poll).
    private(set) var stats: SessionStatistics?
    /// Rolling 1 Hz rate samples per torrent, for the inspector speed graph.
    private(set) var rateHistory: [InfoHash: [RateSample]] = [:]
    /// Aggregate rate samples across all torrents, for the Statistics window.
    private(set) var totalRateHistory: [RateSample] = []
    /// The encryption policy the session was started with (status-bar display).
    private(set) var activeEncryptionPolicy: EncryptionPolicy = .preferred
    var lastActionError: String?

    /// FIFO of opened-but-unconfirmed torrents; the first drives the
    /// add-torrent settings sheet.
    private(set) var pendingAdds: [PendingTorrentAdd] = []
    var currentPendingAdd: PendingTorrentAdd? { pendingAdds.first }

    /// Set by the menu bar (or anything outside the main window) to ask the
    /// torrent list to open the settings sheet for a torrent.
    var settingsRequest: InfoHash?

    private var pollTask: Task<Void, Never>?
    private var completedHashes: Set<InfoHash> = []
    private var notificationsAllowed = false

    var totalDownloadRate: Double { snapshots.reduce(0) { $0 + $1.downloadRate } }
    var totalUploadRate: Double { snapshots.reduce(0) { $0 + $1.uploadRate } }

    // MARK: - Lifecycle

    func start() {
        guard session == nil else { return }
        Defaults.register()
        let defaults = UserDefaults.standard
        let downKiB = defaults.integer(forKey: Defaults.downloadRateLimitKiB)
        let upKiB = defaults.integer(forKey: Defaults.uploadRateLimitKiB)
        let stateDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("SpeedyTorrent", isDirectory: true)

        let configuration = TorrentSession.Configuration(
            downloadDirectory: URL(fileURLWithPath: defaults.string(forKey: Defaults.downloadDirectory) ?? "~/Downloads"),
            listenPort: UInt16(clamping: defaults.integer(forKey: Defaults.listenPort)),
            maxPeersPerTorrent: max(10, defaults.integer(forKey: Defaults.maxPeers)),
            sequentialDownload: defaults.bool(forKey: Defaults.sequentialDownload),
            stateDirectory: stateDir,
            downloadRateLimit: downKiB > 0 ? downKiB * 1024 : nil,
            uploadRateLimit: upKiB > 0 ? upKiB * 1024 : nil,
            enablePortMapping: true,
            enableLSD: true,
            encryptionPolicy: EncryptionPolicy(
                rawValue: defaults.string(forKey: Defaults.encryptionPolicy) ?? ""
            ) ?? .preferred,
            seedRatioLimit: Self.seedRatio(defaults),
            seedTimeLimit: Self.seedTime(defaults),
            maxActiveDownloads: Self.maxActive(defaults)
        )
        let session = TorrentSession(configuration: configuration)
        self.session = session
        self.activeEncryptionPolicy = configuration.encryptionPolicy

        pollTask = Task {
            await session.restore()
            do {
                _ = try await session.startListening()
            } catch {
                self.startupError = "Could not open listening port: \(error)"
            }
            if Bundle.main.bundleIdentifier != nil {
                let center = UNUserNotificationCenter.current()
                self.notificationsAllowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            // Seed the completion tracker so restored torrents don't notify.
            for snapshot in await session.snapshots() where snapshot.state == .seeding {
                self.completedHashes.insert(snapshot.infoHash)
            }
            while !Task.isCancelled {
                let snaps = await session.snapshots()
                self.noticeCompletions(snaps)
                // Don't rebuild the torrent table mid mouse-gesture: a reload
                // can cancel an in-flight click/drag on a row, reverting the
                // selection the user just made. Deferred ticks are caught up
                // on the next poll after the button is released.
                if !NSApplication.shared.isActive || NSEvent.pressedMouseButtons == 0 {
                    self.snapshots = snaps
                }
                self.recordRateHistory(snaps)
                self.updateDockTile(snaps)
                await self.refreshPendingMetadata(session)
                self.portMappingStatus = await session.portMappingStatus()
                self.dhtNodeCount = await session.dhtNodeCount()
                self.stats = await session.statistics()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Appends one rate sample per torrent (and one aggregate), keeping a few
    /// minutes of history; entries for removed torrents are pruned.
    private func recordRateHistory(_ snaps: [TorrentSnapshot]) {
        let now = Date()
        let cap = 180
        for snap in snaps {
            var samples = rateHistory[snap.infoHash, default: []]
            samples.append(RateSample(time: now, download: snap.downloadRate, upload: snap.uploadRate))
            if samples.count > cap { samples.removeFirst(samples.count - cap) }
            rateHistory[snap.infoHash] = samples
        }
        totalRateHistory.append(RateSample(
            time: now,
            download: snaps.reduce(0) { $0 + $1.downloadRate },
            upload: snaps.reduce(0) { $0 + $1.uploadRate }
        ))
        if totalRateHistory.count > cap {
            totalRateHistory.removeFirst(totalRateHistory.count - cap)
        }
        if rateHistory.count > snaps.count {
            let live = Set(snaps.map(\.infoHash))
            rateHistory = rateHistory.filter { live.contains($0.key) }
        }
    }

    // MARK: - Dock tile

    private let dockProgressView = DockProgressView()

    /// Overlays an aggregate progress bar on the Dock icon while anything is
    /// downloading; restores the plain icon otherwise.
    private func updateDockTile(_ snaps: [TorrentSnapshot]) {
        let tile = NSApplication.shared.dockTile
        let downloading = snaps.filter { $0.state == .downloading }
        guard !downloading.isEmpty else {
            if tile.contentView != nil {
                tile.contentView = nil
                tile.badgeLabel = nil
                tile.display()
            }
            return
        }
        let wanted = downloading.reduce(Int64(0)) { $0 + $1.wantedLength }
        let done = downloading.reduce(Int64(0)) { $0 + min($1.completedLength, $1.wantedLength) }
        dockProgressView.progress = wanted > 0 ? Double(done) / Double(wanted) : 0
        if tile.contentView !== dockProgressView {
            dockProgressView.frame = NSRect(origin: .zero, size: tile.size)
            tile.contentView = dockProgressView
        }
        tile.badgeLabel = downloading.count > 1 ? "\(downloading.count)" : nil
        tile.display()
    }

    /// Fills in a magnet's metadata (name/size/files) on its pending-add row
    /// once the background prefetch resolves, so an open add sheet updates live.
    private func refreshPendingMetadata(_ session: TorrentSession) async {
        for pending in pendingAdds where pending.isMagnet && !pending.metadataResolved {
            guard let meta = await session.prefetchedMetadata(for: pending.infoHash),
                  let index = pendingAdds.firstIndex(where: { $0.id == pending.id })
            else { continue }
            pendingAdds[index].displayName = meta.name
            pendingAdds[index].totalSize = meta.totalLength
            pendingAdds[index].files = meta.files
            pendingAdds[index].metadataResolved = true
        }
    }

    func shutdown() async {
        pollTask?.cancel()
        if let session {
            await session.shutdown()
        }
        session = nil
    }

    private func noticeCompletions(_ snaps: [TorrentSnapshot]) {
        for snapshot in snaps where snapshot.state == .seeding && !completedHashes.contains(snapshot.infoHash) {
            completedHashes.insert(snapshot.infoHash)
            guard notificationsAllowed else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Download Complete"
            content.body = snapshot.name
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: snapshot.infoHash.hexString, content: content, trigger: nil
            ))
        }
    }

    // MARK: - Adding torrents (via the per-torrent settings sheet)

    /// Queues a .torrent file; the settings sheet confirms the actual add.
    func addTorrentFile(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let meta = try TorrentMetaInfo(torrentFileData: data)
            guard !isKnown(meta.info.infoHash),
                  !pendingAdds.contains(where: { $0.source == .torrentFile(data: data) })
            else {
                lastActionError = "Could not add torrent: it is already added."
                return
            }
            pendingAdds.append(PendingTorrentAdd(
                source: .torrentFile(data: data),
                infoHash: meta.info.infoHash,
                displayName: meta.info.name,
                totalSize: meta.info.totalLength,
                files: meta.info.files,
                metadataResolved: true
            ))
        } catch {
            lastActionError = "Could not read torrent file: \(friendly(error))"
        }
    }

    /// Queues a magnet link and immediately begins fetching its metadata in the
    /// background, so the add sheet can fill in the file list before the user
    /// confirms. The settings sheet confirms the actual add.
    func addMagnet(_ string: String) {
        guard let magnet = MagnetLink(string: string) else {
            lastActionError = "Could not add magnet: that is not a valid magnet link."
            return
        }
        guard !isKnown(magnet.infoHash),
              !pendingAdds.contains(where: { $0.infoHash == magnet.infoHash })
        else {
            lastActionError = "Could not add magnet: it is already added."
            return
        }
        pendingAdds.append(PendingTorrentAdd(
            source: .magnet(uri: string),
            infoHash: magnet.infoHash,
            displayName: magnet.displayName ?? magnet.infoHash.hexString,
            totalSize: nil,
            files: [],
            metadataResolved: false
        ))
        let id = pendingAdds.last!.id
        run("start fetching metadata") { [weak self] session in
            do {
                _ = try await session.beginMetadataPrefetch(string)
            } catch {
                // Most likely a race where it became known; drop the pending row.
                await MainActor.run { self?.pendingAdds.removeAll { $0.id == id } }
                throw error
            }
        }
    }

    private func isKnown(_ infoHash: InfoHash) -> Bool {
        snapshots.contains { $0.infoHash == infoHash }
    }

    func confirmPendingAdd(
        id: PendingTorrentAdd.ID,
        directory: URL,
        sequential: Bool,
        wantedFiles: Set<Int>?
    ) {
        guard let index = pendingAdds.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingAdds.remove(at: index)
        // A full selection is stored as nil (the default). File selection only
        // applies once files are known (immediately for .torrent, after
        // metadata for magnets).
        let wanted = pending.files.isEmpty
            ? nil
            : wantedFiles.flatMap { $0.count == pending.files.count ? nil : $0 }
        run("add torrent") { session in
            switch pending.source {
            case .torrentFile(let data):
                _ = try await session.addTorrent(
                    fileData: data,
                    downloadDirectory: directory,
                    sequential: sequential,
                    wantedFiles: wanted
                )
            case .magnet:
                _ = try await session.commitMagnet(
                    pending.infoHash,
                    downloadDirectory: directory,
                    sequential: sequential,
                    wantedFiles: wanted
                )
            }
        }
    }

    func fileStatuses(for infoHash: InfoHash) async -> [TorrentFileStatus] {
        guard let session else { return [] }
        return (try? await session.fileStatuses(for: infoHash)) ?? []
    }

    func peerDetails(for infoHash: InfoHash) async -> [PeerDetail] {
        guard let session else { return [] }
        return await session.peerDetails(for: infoHash)
    }

    func trackerDetails(for infoHash: InfoHash) async -> [TrackerDetail] {
        guard let session else { return [] }
        return await session.trackerDetails(for: infoHash)
    }

    func setWantedFiles(_ wanted: Set<Int>, for infoHash: InfoHash) {
        run("change the file selection") { try await $0.setWantedFiles(wanted, for: infoHash) }
    }

    func dismissPendingAdd(id: PendingTorrentAdd.ID) {
        guard let index = pendingAdds.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingAdds.remove(at: index)
        // Abandon the background metadata fetch started for a magnet.
        if pending.isMagnet {
            run("cancel metadata fetch") { await $0.cancelMetadataPrefetch(pending.infoHash) }
        }
    }

    /// Handles both magnet: URLs and .torrent file URLs (dock/Finder opens).
    func handleOpenedURL(_ url: URL) {
        if url.scheme?.lowercased() == "magnet" {
            addMagnet(url.absoluteString)
        } else if url.isFileURL {
            addTorrentFile(at: url)
        }
    }

    // MARK: - Per-torrent settings

    func requestSettings(for infoHash: InfoHash) {
        settingsRequest = infoHash
    }

    func setSequential(_ sequential: Bool, for infoHash: InfoHash) {
        run("change piece order") { try await $0.setSequential(sequential, for: infoHash) }
    }

    /// Changes the download location; the engine moves existing content
    /// before the transfer continues.
    func setDownloadLocation(_ directory: URL, for infoHash: InfoHash) {
        run("move the torrent") { try await $0.setDownloadDirectory(directory, for: infoHash) }
    }

    // MARK: - Actions

    func recheck(_ infoHash: InfoHash) {
        run("verify data") { try await $0.recheckTorrent(infoHash) }
    }

    func move(_ infoHash: InfoHash, _ direction: TorrentSession.QueueMove) {
        run("reorder") { try await $0.moveTorrent(infoHash, direction) }
    }

    func pause(_ infoHash: InfoHash) {
        run("pause") { try await $0.pauseTorrent(infoHash) }
    }

    func resume(_ infoHash: InfoHash) {
        run("resume") { try await $0.resumeTorrent(infoHash) }
    }

    func pauseAll() {
        run("pause all") { await $0.pauseAll() }
    }

    func resumeAll() {
        run("resume all") { await $0.resumeAll() }
    }

    func remove(_ infoHash: InfoHash, deleteFiles: Bool) {
        run("remove") { try await $0.removeTorrent(infoHash, deleteFiles: deleteFiles) }
    }

    func revealInFinder(_ infoHash: InfoHash) {
        run("reveal") { session in
            if let url = await session.contentURL(for: infoHash) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    /// Settings that can change live.
    func applySettings() {
        let defaults = UserDefaults.standard
        let downKiB = defaults.integer(forKey: Defaults.downloadRateLimitKiB)
        let upKiB = defaults.integer(forKey: Defaults.uploadRateLimitKiB)
        let sequential = defaults.bool(forKey: Defaults.sequentialDownload)
        let ratio = Self.seedRatio(defaults)
        let time = Self.seedTime(defaults)
        let active = Self.maxActive(defaults)
        run("apply settings") { session in
            await session.setRateLimits(
                download: downKiB > 0 ? downKiB * 1024 : nil,
                upload: upKiB > 0 ? upKiB * 1024 : nil
            )
            await session.setSequentialDownload(sequential)
            await session.setSeedingLimits(ratio: ratio, time: time)
            await session.setMaxActiveDownloads(active)
        }
    }

    private static func seedRatio(_ defaults: UserDefaults) -> Double? {
        let value = defaults.double(forKey: Defaults.seedRatioLimit)
        return value > 0 ? value : nil
    }

    private static func seedTime(_ defaults: UserDefaults) -> TimeInterval? {
        let minutes = defaults.integer(forKey: Defaults.seedTimeLimitMinutes)
        return minutes > 0 ? TimeInterval(minutes * 60) : nil
    }

    private static func maxActive(_ defaults: UserDefaults) -> Int? {
        let value = defaults.integer(forKey: Defaults.maxActiveDownloads)
        return value > 0 ? value : nil
    }

    private func run(_ label: String, _ body: @escaping @Sendable (TorrentSession) async throws -> Void) {
        guard let session else { return }
        Task {
            do {
                try await body(session)
            } catch {
                self.lastActionError = "Could not \(label): \(friendly(error))"
            }
        }
    }

    private nonisolated func friendly(_ error: Error) -> String {
        switch error {
        case SessionError.duplicateTorrent: "it is already added."
        case SessionError.invalidMagnet: "that is not a valid magnet link."
        case SessionError.unknownTorrent: "the torrent no longer exists."
        case SessionError.moveFailed(let reason): reason
        default: "\(error)"
        }
    }
}

// MARK: - Formatting helpers

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .binary
    formatter.allowsNonnumericFormatting = false // "0 bytes", not "Zero KB"
    return formatter.string(fromByteCount: bytes)
}

func formatRate(_ rate: Double) -> String {
    rate < 1024 ? "—" : formatBytes(Int64(rate)) + "/s"
}

func formatETA(_ eta: TimeInterval?) -> String {
    guard let eta, eta.isFinite, eta < 30 * 24 * 3600 else { return "—" }
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = eta >= 3600 ? [.hour, .minute] : [.minute, .second]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: eta) ?? "—"
}

extension TorrentState {
    var displayName: String {
        switch self {
        case .fetchingMetadata: "Fetching metadata"
        case .checking: "Checking"
        case .moving: "Moving"
        case .downloading: "Downloading"
        case .seeding: "Seeding"
        case .paused: "Paused"
        case .queued: "Queued"
        case .failed: "Error"
        }
    }

    var iconName: String {
        switch self {
        case .fetchingMetadata: "antenna.radiowaves.left.and.right"
        case .checking: "magnifyingglass.circle.fill"
        case .moving: "shippingbox.fill"
        case .downloading: "arrow.down.circle.fill"
        case .seeding: "arrow.up.circle.fill"
        case .paused: "pause.circle.fill"
        case .queued: "clock.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .downloading: .blue
        case .seeding: .green
        case .failed: .red
        case .fetchingMetadata, .checking, .moving: .orange
        case .paused, .queued: .secondary
        }
    }
}

/// One 1 Hz sample of transfer rates, for the speed graphs.
struct RateSample: Identifiable {
    var id: Date { time }
    let time: Date
    let download: Double
    let upload: Double
}

/// The app icon with a progress bar along the bottom, drawn into the Dock
/// tile while downloads are active.
final class DockProgressView: NSView {
    var progress: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApplication.shared.applicationIconImage?.draw(in: bounds)
        let barHeight = bounds.height * 0.085
        let inset = bounds.width * 0.14
        let bar = NSRect(
            x: inset, y: bounds.height * 0.055,
            width: bounds.width - inset * 2, height: barHeight
        )
        let radius = barHeight / 2
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bar.insetBy(dx: -1.5, dy: -1.5), xRadius: radius, yRadius: radius).fill()
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
        var fill = bar
        fill.size.width = max(barHeight, bar.width * min(1, max(0, progress)))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}

/// Compact duration like "3m 20s", "2h 5m", or "1d 4h".
func formatDuration(_ seconds: TimeInterval) -> String {
    Duration.seconds(max(0, seconds)).formatted(
        .units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)
    )
}

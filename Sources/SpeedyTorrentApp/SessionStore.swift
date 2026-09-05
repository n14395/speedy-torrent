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
    /// Skip the add-torrent sheet and start opened torrents right away.
    static let autoStartTorrents = "autoStartTorrents"
    /// Set by "Don't Ask Again" in the default-app prompt.
    static let skipDefaultHandlerPrompt = "skipDefaultHandlerPrompt"
    /// Closing the window leaves the app seeding in the menu bar.
    static let keepRunningInMenuBar = "keepRunningInMenuBar"
    // What the menu bar item shows. At least one must stay on, or there would
    // be nothing left to click.
    static let menuBarShowsIcon = "menuBarShowsIcon"
    static let menuBarShowsDownloadRate = "menuBarShowsDownloadRate"
    static let menuBarShowsUploadRate = "menuBarShowsUploadRate"
    /// Whether the popup shows its whole torrent list rather than the first few.
    static let menuBarExpanded = "menuBarExpanded"
    /// Backing store for File ▸ Open Recent. We are not a document-based app,
    /// so macOS keeps no recents list for us and we maintain our own.
    static let recentTorrentPaths = "recentTorrentPaths"

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
            autoStartTorrents: false,
            skipDefaultHandlerPrompt: false,
            keepRunningInMenuBar: true,
            menuBarShowsIcon: true,
            menuBarShowsDownloadRate: true,
            menuBarShowsUploadRate: true,
            menuBarExpanded: false,
            recentTorrentPaths: [String](),
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
    /// Trackers known before the torrent exists, so the detail view's Trackers
    /// tab has something to show.
    var trackers: [String] = []

    // Settings the user picks before confirming. They live here rather than in
    // the popup so the shared detail view has one source of truth in both the
    // pending and the live case.
    var downloadDirectory: URL
    var sequential: Bool
    /// Indices to download; seeded to everything when the file list arrives.
    var wantedFiles: Set<Int> = []
    /// Non-normal priorities picked before the torrent starts, by file index.
    var filePriorities: [Int: FilePriority] = [:]

    var isMagnet: Bool {
        if case .magnet = source { return true }
        return false
    }

    /// The file list as tree rows. Indices are positions in the torrent's own
    /// file array, so this must be built from the unsorted list — never from a
    /// sorted or filtered copy.
    var fileRows: [FileRow] {
        files.enumerated().map {
            FileRow(
                index: $0, path: $1.path, length: $1.length, completedLength: nil,
                priority: filePriorities[$0] ?? .normal
            )
        }
    }

    /// Total size of the files currently ticked.
    var selectedSize: Int64 {
        wantedFiles.reduce(Int64(0)) { $0 + (files.indices.contains($1) ? files[$1].length : 0) }
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

    /// Set by the menu bar to ask the torrent list to open its add-magnet
    /// sheet. A sheet needs a window to attach to, which the popup has not got.
    var magnetRequest = false

    /// Whether this app owns both the .torrent and magnet: handlers.
    private(set) var isDefaultHandler = true

    /// Torrent files opened lately, newest first, for File ▸ Open Recent.
    /// Filtered to what still exists, so a menu of dead paths never builds up.
    private(set) var recentTorrents: [URL] = SessionStore.loadRecentTorrents()
    private static let recentTorrentLimit = 10

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
        checkDefaultHandler()

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
                self.stats = await session.statistics(using: snaps)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Default app for torrents and magnet links

    /// Checks the handlers shortly after launch and offers to claim them,
    /// unless the user has silenced the prompt. Once per launch.
    private func checkDefaultHandler() {
        // A `swift run` build has no bundle to register.
        guard DefaultHandler.isRegisterableBundle else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.refreshDefaultHandlerStatus()
            guard ProcessInfo.processInfo.environment["SPEEDYTORRENT_FORCE_HANDLER_PROMPT"] == nil else {
                DefaultHandler.presentPrompt { _ in }
                return
            }
            guard !self.isDefaultHandler,
                  !UserDefaults.standard.bool(forKey: Defaults.skipDefaultHandlerPrompt)
            else { return }
            DefaultHandler.presentPrompt { choice in
                switch choice {
                case .claim: self.makeDefaultHandler()
                case .later: break
                case .never:
                    UserDefaults.standard.set(true, forKey: Defaults.skipDefaultHandlerPrompt)
                }
            }
        }
    }

    /// Re-reads the handler status (it can change in System Settings while
    /// the app runs).
    func refreshDefaultHandlerStatus() {
        isDefaultHandler = !DefaultHandler.isRegisterableBundle || DefaultHandler.handlesEverything
    }

    func makeDefaultHandler() {
        Task {
            let error = await DefaultHandler.claimAll()
            self.refreshDefaultHandlerStatus()
            // macOS asks for confirmation on some of these changes; a decline
            // surfaces as an error, so only complain if it really didn't take.
            if let error, !self.isDefaultHandler {
                self.lastActionError = "Could not set SpeedyTorrent as the default app: "
                    + error.localizedDescription
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
            // Select everything in the same mutation that publishes the files:
            // a second pass would briefly render "0 of N selected" with the Add
            // button disabled.
            pendingAdds[index].wantedFiles = Set(meta.files.indices)
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

    /// Whether opened torrents skip the add sheet and start immediately with
    /// the app-wide defaults ("Start torrents automatically" in Settings).
    private var startsTorrentsAutomatically: Bool {
        UserDefaults.standard.bool(forKey: Defaults.autoStartTorrents)
    }

    /// The download folder new torrents land in unless the user picks another.
    private var defaultDownloadDirectory: URL {
        URL(fileURLWithPath: UserDefaults.standard.string(forKey: Defaults.downloadDirectory)
            ?? NSHomeDirectory() + "/Downloads")
    }

    /// Queues a .torrent file; the settings sheet confirms the actual add.
    /// With auto-start on it is added straight away instead, with every file
    /// selected.
    func addTorrentFile(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let meta = try TorrentMetaInfo(torrentFileData: data)
            // Noted before the duplicate check, not after: the user opened this
            // file, and "recently opened" is the question the menu answers.
            noteRecentTorrent(url)
            guard !isKnown(meta.info.infoHash),
                  !pendingAdds.contains(where: { $0.source == .torrentFile(data: data) })
            else {
                lastActionError = "Could not add torrent: it is already added."
                return
            }
            if startsTorrentsAutomatically {
                let directory = defaultDownloadDirectory
                let sequential = UserDefaults.standard.bool(forKey: Defaults.sequentialDownload)
                run("add torrent") { session in
                    _ = try await session.addTorrent(
                        fileData: data,
                        downloadDirectory: directory,
                        sequential: sequential
                    )
                }
                return
            }
            pendingAdds.append(PendingTorrentAdd(
                source: .torrentFile(data: data),
                infoHash: meta.info.infoHash,
                displayName: meta.info.name,
                totalSize: meta.info.totalLength,
                files: meta.info.files,
                metadataResolved: true,
                trackers: meta.announceTiers.flatMap { $0 },
                downloadDirectory: defaultDownloadDirectory,
                sequential: UserDefaults.standard.bool(forKey: Defaults.sequentialDownload),
                wantedFiles: Set(meta.info.files.indices)
            ))
        } catch {
            lastActionError = "Could not read torrent file: \(friendly(error))"
        }
    }

    /// Queues a magnet link and immediately begins fetching its metadata in the
    /// background, so the add sheet can fill in the file list before the user
    /// confirms. The settings sheet confirms the actual add. With auto-start on
    /// there is no sheet to fill in, so the magnet is added as a download right
    /// away and its metadata resolves in place.
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
        if startsTorrentsAutomatically {
            let directory = defaultDownloadDirectory
            let sequential = UserDefaults.standard.bool(forKey: Defaults.sequentialDownload)
            run("add magnet") { session in
                _ = try await session.addMagnet(
                    string,
                    downloadDirectory: directory,
                    sequential: sequential
                )
            }
            return
        }
        pendingAdds.append(PendingTorrentAdd(
            source: .magnet(uri: string),
            infoHash: magnet.infoHash,
            displayName: magnet.displayName ?? magnet.infoHash.hexString,
            totalSize: nil,
            files: [],
            metadataResolved: false,
            trackers: magnet.trackers,
            downloadDirectory: defaultDownloadDirectory,
            sequential: UserDefaults.standard.bool(forKey: Defaults.sequentialDownload)
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

    /// Starts the download with whatever settings the record carries.
    func confirmPendingAdd(id: PendingTorrentAdd.ID) {
        guard let index = pendingAdds.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingAdds.remove(at: index)
        let directory = pending.downloadDirectory
        let sequential = pending.sequential
        // A full selection is stored as nil (the default). File selection only
        // applies once files are known (immediately for .torrent, after
        // metadata for magnets).
        let wanted = pending.files.isEmpty || pending.wantedFiles.count == pending.files.count
            ? nil
            : pending.wantedFiles
        // All-normal is the default; send nothing rather than an empty map.
        let priorities = pending.filePriorities.isEmpty ? nil : pending.filePriorities
        run("add torrent") { session in
            switch pending.source {
            case .torrentFile(let data):
                _ = try await session.addTorrent(
                    fileData: data,
                    downloadDirectory: directory,
                    sequential: sequential,
                    wantedFiles: wanted,
                    filePriorities: priorities
                )
            case .magnet:
                _ = try await session.commitMagnet(
                    pending.infoHash,
                    downloadDirectory: directory,
                    sequential: sequential,
                    wantedFiles: wanted,
                    filePriorities: priorities
                )
            }
        }
    }

    /// The pending record the detail view edits (nil once confirmed/dismissed).
    func pendingAdd(id: PendingTorrentAdd.ID) -> PendingTorrentAdd? {
        pendingAdds.first { $0.id == id }
    }

    func setPendingDirectory(_ directory: URL, id: PendingTorrentAdd.ID) {
        mutatePending(id) { $0.downloadDirectory = directory }
    }

    func setPendingSequential(_ sequential: Bool, id: PendingTorrentAdd.ID) {
        mutatePending(id) { $0.sequential = sequential }
    }

    func setPendingWantedFiles(_ wanted: Set<Int>, id: PendingTorrentAdd.ID) {
        mutatePending(id) { $0.wantedFiles = wanted }
    }

    func setPendingFilePriority(
        _ priority: FilePriority, forFiles files: Set<Int>, id: PendingTorrentAdd.ID
    ) {
        mutatePending(id) { pending in
            for index in files where pending.files.indices.contains(index) {
                if priority == .normal {
                    pending.filePriorities.removeValue(forKey: index)
                } else {
                    pending.filePriorities[index] = priority
                }
            }
        }
    }

    private func mutatePending(_ id: PendingTorrentAdd.ID, _ body: (inout PendingTorrentAdd) -> Void) {
        guard let index = pendingAdds.firstIndex(where: { $0.id == id }) else { return }
        body(&pendingAdds[index])
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

    func setFilePriority(
        _ priority: FilePriority, forFiles files: Set<Int>, for infoHash: InfoHash
    ) {
        run("change file priority") {
            try await $0.setFilePriority(priority, forFiles: files, in: infoHash)
        }
    }

    /// Caps one torrent's rates. Takes KiB/s the way the fields are labelled;
    /// 0 means "no limit of its own", leaving only the session's.
    func setRateLimits(downloadKiB: Int, uploadKiB: Int, for infoHash: InfoHash) {
        let download = downloadKiB > 0 ? downloadKiB * 1024 : nil
        let upload = uploadKiB > 0 ? uploadKiB * 1024 : nil
        run("change the speed limits") {
            try await $0.setRateLimits(download: download, upload: upload, for: infoHash)
        }
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

    // MARK: - Recent torrent files

    private static func loadRecentTorrents() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: Defaults.recentTorrentPaths) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func noteRecentTorrent(_ url: URL) {
        guard url.isFileURL else { return }
        let standardized = url.standardizedFileURL
        var urls = recentTorrents.filter { $0 != standardized }
        urls.insert(standardized, at: 0)
        recentTorrents = Array(urls.prefix(Self.recentTorrentLimit))
        UserDefaults.standard.set(recentTorrents.map(\.path), forKey: Defaults.recentTorrentPaths)
    }

    func clearRecentTorrents() {
        recentTorrents = []
        UserDefaults.standard.set([String](), forKey: Defaults.recentTorrentPaths)
    }

    // MARK: - Copying

    /// Puts magnet links for the given torrents on the pasteboard, one per
    /// line. Trackers come from the engine rather than the original file, so a
    /// copied link carries whatever the torrent is actually announcing to.
    func copyMagnetLinks(for hashes: [InfoHash]) {
        let selected = snapshots.filter { hashes.contains($0.infoHash) }
        guard !selected.isEmpty else { return }
        Task { @MainActor in
            var links: [String] = []
            for snapshot in selected {
                let trackers = await self.trackerDetails(for: snapshot.infoHash)
                links.append(Self.magnetLink(for: snapshot, trackers: trackers.map(\.url)))
            }
            Self.copyToPasteboard(links.joined(separator: "\n"))
        }
    }

    func copyInfoHashes(for hashes: [InfoHash]) {
        let selected = snapshots.filter { hashes.contains($0.infoHash) }
        guard !selected.isEmpty else { return }
        Self.copyToPasteboard(selected.map(\.infoHash.hexString).joined(separator: "\n"))
    }

    static func magnetLink(for snapshot: TorrentSnapshot, trackers: [String]) -> String {
        // The query separators have to survive as separators, so they come out
        // of the allowed set before anything is escaped into a parameter.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        var link = "magnet:?xt=urn:btih:\(snapshot.infoHash.hexString)"
        if let name = snapshot.name.addingPercentEncoding(withAllowedCharacters: allowed),
           !name.isEmpty {
            link += "&dn=\(name)"
        }
        for tracker in trackers {
            guard let encoded = tracker.addingPercentEncoding(withAllowedCharacters: allowed)
            else { continue }
            link += "&tr=\(encoded)"
        }
        return link
    }

    private static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Per-torrent settings

    /// Asks for a new download folder and moves the torrent there, warning
    /// first if there is data on disk to move. Driven by AppKit rather than
    /// `.fileImporter` so the main menu can reach it with no window open.
    func chooseDownloadLocation(for infoHash: InfoHash) {
        guard let snapshot = snapshots.first(where: { $0.infoHash == infoHash }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where “\(snapshot.name)” should be stored."
        panel.directoryURL = URL(fileURLWithPath: snapshot.downloadDirectory)
        NSApplication.shared.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Nothing on disk yet (or not even resolved) — no move to warn about.
        guard snapshot.state != .fetchingMetadata, snapshot.completedLength > 0 else {
            setDownloadLocation(url, for: infoHash)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Move “\(snapshot.name)” to \(url.lastPathComponent)?"
        alert.informativeText =
            "Existing data will be moved to the new location before the transfer continues."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setDownloadLocation(url, for: infoHash)
    }

    func requestSettings(for infoHash: InfoHash) {
        settingsRequest = infoHash
    }

    func requestMagnetSheet() {
        magnetRequest = true
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

    /// Whether the torrent is doing work right now, as opposed to sitting
    /// paused, queued behind another download, or stopped on an error.
    var isActive: Bool {
        switch self {
        case .downloading, .seeding, .checking, .moving, .fetchingMetadata: true
        case .paused, .queued, .failed: false
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

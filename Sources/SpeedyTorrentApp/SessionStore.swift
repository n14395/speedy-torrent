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

    static func register() {
        UserDefaults.standard.register(defaults: [
            downloadDirectory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
                .first?.path ?? NSHomeDirectory() + "/Downloads",
            listenPort: 6881,
            sequentialDownload: false,
            downloadRateLimitKiB: 0,
            uploadRateLimitKiB: 0,
            maxPeers: 40,
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
    let displayName: String
    let totalSize: Int64?
    /// The torrent's files (empty for magnets — unknown until metadata arrives).
    let files: [FileEntry]
}

/// Main-actor bridge between the engine session and SwiftUI.
@MainActor
@Observable
final class SessionStore {
    private(set) var session: TorrentSession?
    private(set) var snapshots: [TorrentSnapshot] = []
    private(set) var startupError: String?
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
            uploadRateLimit: upKiB > 0 ? upKiB * 1024 : nil
        )
        let session = TorrentSession(configuration: configuration)
        self.session = session

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
                self.snapshots = snaps
                try? await Task.sleep(for: .seconds(1))
            }
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
                displayName: meta.info.name,
                totalSize: meta.info.totalLength,
                files: meta.info.files
            ))
        } catch {
            lastActionError = "Could not read torrent file: \(friendly(error))"
        }
    }

    /// Queues a magnet link; the settings sheet confirms the actual add.
    func addMagnet(_ string: String) {
        guard let magnet = MagnetLink(string: string) else {
            lastActionError = "Could not add magnet: that is not a valid magnet link."
            return
        }
        guard !isKnown(magnet.infoHash),
              !pendingAdds.contains(where: { $0.source == .magnet(uri: string) })
        else {
            lastActionError = "Could not add magnet: it is already added."
            return
        }
        pendingAdds.append(PendingTorrentAdd(
            source: .magnet(uri: string),
            displayName: magnet.displayName ?? magnet.infoHash.hexString,
            totalSize: nil,
            files: []
        ))
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
        // A full selection is stored as nil (the default).
        let wanted = wantedFiles.flatMap { $0.count == pending.files.count ? nil : $0 }
        run("add torrent") { session in
            switch pending.source {
            case .torrentFile(let data):
                _ = try await session.addTorrent(
                    fileData: data,
                    downloadDirectory: directory,
                    sequential: sequential,
                    wantedFiles: wanted
                )
            case .magnet(let uri):
                _ = try await session.addMagnet(
                    uri, downloadDirectory: directory, sequential: sequential
                )
            }
        }
    }

    func fileStatuses(for infoHash: InfoHash) async -> [TorrentFileStatus] {
        guard let session else { return [] }
        return (try? await session.fileStatuses(for: infoHash)) ?? []
    }

    func setWantedFiles(_ wanted: Set<Int>, for infoHash: InfoHash) {
        run("change the file selection") { try await $0.setWantedFiles(wanted, for: infoHash) }
    }

    func dismissPendingAdd(id: PendingTorrentAdd.ID) {
        pendingAdds.removeAll { $0.id == id }
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
        run("apply settings") { session in
            await session.setRateLimits(
                download: downKiB > 0 ? downKiB * 1024 : nil,
                upload: upKiB > 0 ? upKiB * 1024 : nil
            )
            await session.setSequentialDownload(sequential)
        }
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
        case .failed: "Error"
        }
    }
}

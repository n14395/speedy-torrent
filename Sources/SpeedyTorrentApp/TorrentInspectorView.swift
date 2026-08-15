import SwiftUI
import TorrentEngine

/// Trailing inspector: live, tabbed detail (Peers / Trackers / Files) for the
/// selected torrent. Polls the engine ~1 Hz while visible.
struct TorrentInspectorView: View {
    @Environment(SessionStore.self) private var store
    let infoHash: InfoHash

    enum Tab: String, CaseIterable, Identifiable {
        case info = "Info"
        case peers = "Peers"
        case trackers = "Trackers"
        case files = "Files"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .info
    @State private var peers: [PeerDetail] = []
    @State private var trackers: [TrackerDetail] = []
    @State private var files: [TorrentFileStatus] = []
    @State private var copiedMagnet = false

    private var snapshot: TorrentSnapshot? {
        store.snapshots.first { $0.infoHash == infoHash }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            switch tab {
            case .info: infoTab
            case .peers: peersTable
            case .trackers: trackersTable
            case .files: filesTable
            }
        }
        .task(id: infoHash) {
            while !Task.isCancelled {
                peers = await store.peerDetails(for: infoHash)
                trackers = await store.trackerDetails(for: infoHash)
                files = await store.fileStatuses(for: infoHash)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot?.name ?? "—")
                .font(.headline)
                .lineLimit(2)
            if let snapshot {
                HStack(spacing: 12) {
                    Label("\(snapshot.peerCount)", systemImage: "person.2")
                    Label(formatRate(snapshot.downloadRate), systemImage: "arrow.down")
                    Label(formatRate(snapshot.uploadRate), systemImage: "arrow.up")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    // MARK: Info

    private var infoTab: some View {
        Group {
            if let snapshot {
                Form {
                    Section("Torrent") {
                        infoRow("Name", snapshot.name)
                        infoRow("Info hash", snapshot.infoHash.hexString, monospaced: true)
                        infoRow("Size", snapshot.totalLength > 0 ? formatBytes(snapshot.totalLength) : "—")
                        if snapshot.pieceCount > 0 {
                            infoRow(
                                "Pieces",
                                "\(snapshot.pieceCount) × \(formatBytes(Int64(snapshot.pieceLength)))"
                            )
                        }
                        if snapshot.addedAt > 0 {
                            infoRow(
                                "Added",
                                Date(timeIntervalSince1970: snapshot.addedAt)
                                    .formatted(date: .abbreviated, time: .shortened)
                            )
                        }
                    }
                    Section("Transfer") {
                        infoRow("State", snapshot.state.displayName)
                        infoRow("Downloaded", formatBytes(snapshot.downloadedTotal))
                        infoRow("Uploaded", formatBytes(snapshot.uploadedTotal))
                        infoRow("Ratio", String(format: "%.2f", snapshot.ratio))
                        infoRow(
                            "Location",
                            (snapshot.downloadDirectory as NSString).abbreviatingWithTildeInPath
                        )
                        infoRow("Piece order", snapshot.sequential ? "Sequential" : "Rarest first")
                    }
                    Section {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(magnetLink(for: snapshot), forType: .string)
                            copiedMagnet = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copiedMagnet = false
                            }
                        } label: {
                            Label(
                                copiedMagnet ? "Copied!" : "Copy Magnet Link",
                                systemImage: copiedMagnet ? "checkmark" : "link"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .help("Copy a magnet link for this torrent (info hash, name, and trackers)")
                    }
                }
                .formStyle(.grouped)
            } else {
                emptyState("Torrent not found")
            }
        }
    }

    /// magnet:?xt=urn:btih:… with the display name and known trackers.
    private func magnetLink(for snapshot: TorrentSnapshot) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ string: String) -> String {
            string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
        }
        var link = "magnet:?xt=urn:btih:\(snapshot.infoHash.hexString)"
        link += "&dn=" + encode(snapshot.name)
        for tracker in trackers {
            link += "&tr=" + encode(tracker.url)
        }
        return link
    }

    private func infoRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(monospaced ? .caption.monospaced() : .body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
        }
    }

    // MARK: Peers

    private var peersTable: some View {
        Group {
            if peers.isEmpty {
                emptyState("No connected peers")
            } else {
                Table(peers) {
                    TableColumn("Peer") { peer in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(peer.address).lineLimit(1).truncationMode(.middle)
                            Text(peerFlags(peer))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 120, ideal: 150)
                    TableColumn("Client") { Text($0.client).lineLimit(1) }
                        .width(min: 80, ideal: 110)
                    TableColumn("%") { peer in
                        Text(peer.progress.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                    }
                    .width(44)
                    TableColumn("↓") { Text(compactRate($0.downloadRate)).monospacedDigit() }
                        .width(60)
                    TableColumn("↑") { Text(compactRate($0.uploadRate)).monospacedDigit() }
                        .width(60)
                }
            }
        }
    }

    private func peerFlags(_ peer: PeerDetail) -> String {
        var flags: [String] = []
        flags.append(peer.incoming ? "incoming" : "outgoing")
        if peer.encrypted { flags.append("🔒 encrypted") }
        if peer.isSeed { flags.append("seed") }
        if peer.interestedInPeer, !peer.peerChokingUs { flags.append("downloading") }
        if peer.peerInterestedInUs, !peer.chokingPeer { flags.append("uploading") }
        return flags.joined(separator: " · ")
    }

    // MARK: Trackers

    private var trackersTable: some View {
        Group {
            if trackers.isEmpty {
                emptyState("No trackers")
            } else {
                Table(trackers) {
                    TableColumn("Tracker") { tracker in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tracker.url).lineLimit(1).truncationMode(.middle)
                            Text("Tier \(tracker.tier + 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 150, ideal: 220)
                    TableColumn("Status") { tracker in
                        trackerStatus(tracker)
                    }
                    .width(min: 90, ideal: 130)
                }
            }
        }
    }

    @ViewBuilder
    private func trackerStatus(_ tracker: TrackerDetail) -> some View {
        if let error = tracker.lastError {
            Text(error)
                .lineLimit(2)
                .foregroundStyle(.red)
                .help(error)
        } else if tracker.seeders != nil || tracker.leechers != nil {
            HStack(spacing: 8) {
                Label("\(tracker.seeders ?? 0)", systemImage: "arrow.up.circle")
                    .foregroundStyle(.green)
                Label("\(tracker.leechers ?? 0)", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
        } else if tracker.lastSuccess != nil {
            Text("Working").foregroundStyle(.green)
        } else {
            Text("Waiting…").foregroundStyle(.secondary)
        }
    }

    // MARK: Files

    private var filesTable: some View {
        Group {
            if files.isEmpty {
                emptyState("Metadata not available yet")
            } else {
                let nodes = TorrentFileNode.build(from: files.map { ($0.index, $0.path, $0.length) })
                Table(nodes, children: \.children) {
                    TableColumn("Name") { node in
                        HStack(spacing: 5) {
                            Image(systemName: node.fileIndex == nil ? "folder" : "doc")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(node.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(rowStatus(node).skipped ? .secondary : .primary)
                        }
                    }
                    .width(min: 120, ideal: 180)
                    TableColumn("Size") { node in
                        Text(formatBytes(node.length)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(64)
                    TableColumn("Progress") { node in
                        let status = rowStatus(node)
                        HStack(spacing: 6) {
                            ProgressView(value: status.progress).controlSize(.small)
                            if status.skipped {
                                Text("Skipped").font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text(status.progress.formatted(.percent.precision(.fractionLength(0))))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .width(min: 90, ideal: 130)
                }
            }
        }
    }

    /// Row progress over wanted descendants when any are wanted; otherwise raw
    /// completion, so a partially downloaded skipped file still shows its bar.
    private func rowStatus(_ node: TorrentFileNode) -> (skipped: Bool, progress: Double) {
        let indices = node.descendantIndices
        var wantedLength: Int64 = 0
        var wantedDone: Int64 = 0
        var totalDone: Int64 = 0
        var anyWanted = false
        for file in files where indices.contains(file.index) {
            totalDone += file.completedLength
            if file.wanted {
                anyWanted = true
                wantedLength += file.length
                wantedDone += file.completedLength
            }
        }
        if wantedLength > 0 {
            return (false, Double(wantedDone) / Double(wantedLength))
        }
        // A wanted zero-byte file counts as complete.
        if anyWanted { return (false, 1) }
        return (true, node.length > 0 ? Double(totalDone) / Double(node.length) : 1)
    }

    // MARK: Helpers

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows the inspector for a single selection, or guidance otherwise.
struct InspectorPane: View {
    @Environment(SessionStore.self) private var store
    let selection: Set<InfoHash>

    var body: some View {
        if selection.count == 1, let hash = selection.first {
            TorrentInspectorView(infoHash: hash)
                .environment(store)
        } else {
            ContentUnavailableView(
                selection.isEmpty ? "No Selection" : "Multiple Torrents",
                systemImage: "info.circle",
                description: Text(selection.isEmpty
                    ? "Select a torrent to see its peers, trackers, and files."
                    : "Select a single torrent to inspect it.")
            )
        }
    }
}

/// Compact per-peer rate (e.g. "1.2M", "—").
private func compactRate(_ rate: Double) -> String {
    guard rate >= 1024 else { return "—" }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .binary
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    return formatter.string(fromByteCount: Int64(rate))
}

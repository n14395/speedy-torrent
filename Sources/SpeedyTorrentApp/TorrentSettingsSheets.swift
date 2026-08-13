import SwiftUI
import TorrentEngine

/// Shared form for per-torrent settings: download location + piece order.
private struct TorrentSettingsForm: View {
    let name: String
    let detail: String?
    @Binding var directoryPath: String
    @Binding var sequential: Bool
    let footnote: String?

    @State private var showingFolderPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.headline)
                        .lineLimit(2)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            LabeledContent("Download to") {
                HStack {
                    Text((directoryPath as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 260, alignment: .trailing)
                    Button("Choose…") { showingFolderPicker = true }
                }
            }

            Toggle(isOn: $sequential) {
                Text("Sequential order")
                Text("Download pieces in file order — useful for previewing media early.")
            }

            if let footnote {
                Label(footnote, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            if let url = try? result.get() {
                directoryPath = url.path
            }
        }
    }
}

/// Shown when a torrent/magnet is opened, before it is actually added. For
/// magnets, the file list and size fill in live as the background metadata
/// prefetch resolves — the sheet reads the pending add from the store each
/// render rather than capturing a snapshot of it.
struct AddTorrentSheet: View {
    @Environment(SessionStore.self) private var store
    /// Identity (and fallback if the store row disappears mid-dismiss).
    let pending: PendingTorrentAdd

    @State private var directoryPath = UserDefaults.standard.string(forKey: Defaults.downloadDirectory)
        ?? NSHomeDirectory() + "/Downloads"
    @State private var sequential = UserDefaults.standard.bool(forKey: Defaults.sequentialDownload)
    @State private var wanted: Set<Int> = []
    /// Whether `wanted` has been seeded from a (now-known) file list.
    @State private var seededSelection = false

    /// The current state of this pending add (metadata may have arrived since
    /// presentation).
    private var live: PendingTorrentAdd {
        store.pendingAdds.first { $0.id == pending.id } ?? pending
    }

    private func selectedSize(_ files: [FileEntry]) -> Int64 {
        wanted.reduce(Int64(0)) { $0 + (files.indices.contains($1) ? files[$1].length : 0) }
    }

    private func detail(_ live: PendingTorrentAdd) -> String {
        if let total = live.totalSize {
            return wanted.count == live.files.count
                ? formatBytes(total)
                : "\(formatBytes(selectedSize(live.files))) of \(formatBytes(total)) selected"
        }
        return "Magnet link — fetching metadata to list files…"
    }

    var body: some View {
        let live = self.live
        let fileNodes = TorrentFileNode.build(
            from: live.files.enumerated().map { ($0, $1.path, $1.length) }
        )
        VStack(alignment: .leading, spacing: 16) {
            TorrentSettingsForm(
                name: live.displayName,
                detail: detail(live),
                directoryPath: $directoryPath,
                sequential: $sequential,
                footnote: nil
            )
            if !live.files.isEmpty {
                FileSelectionList(
                    nodes: fileNodes, wanted: $wanted, fileCount: live.files.count
                )
            } else if live.isMagnet {
                HStack(spacing: 6) {
                    SpinningSymbol(systemName: "arrow.triangle.2.circlepath")
                    Text("Fetching metadata… the file list will appear here.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    store.dismissPendingAdd(id: pending.id)
                }
                .keyboardShortcut(.cancelAction)
                Button("Add Torrent") {
                    store.confirmPendingAdd(
                        id: pending.id,
                        directory: URL(fileURLWithPath: directoryPath),
                        sequential: sequential,
                        wantedFiles: live.files.isEmpty ? nil : wanted
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!live.files.isEmpty && wanted.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { seedSelection(live) }
        .onChange(of: live.files) { seedSelection(live) }
    }

    /// Selects every file the first time a non-empty list is known.
    private func seedSelection(_ live: PendingTorrentAdd) {
        guard !live.files.isEmpty, !seededSelection else { return }
        wanted = Set(live.files.indices)
        seededSelection = true
    }
}

/// Shown from the context menu / gear buttons for an existing torrent.
struct EditTorrentSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let snapshot: TorrentSnapshot

    @State private var directoryPath: String
    @State private var sequential: Bool
    @State private var statuses: [TorrentFileStatus] = []
    @State private var originalWanted: Set<Int> = []
    @State private var wanted: Set<Int> = []
    @State private var fileNodes: [TorrentFileNode] = []

    init(snapshot: TorrentSnapshot) {
        self.snapshot = snapshot
        _directoryPath = State(initialValue: snapshot.downloadDirectory)
        _sequential = State(initialValue: snapshot.sequential)
    }

    private var directoryChanged: Bool {
        URL(fileURLWithPath: directoryPath).standardizedFileURL
            != URL(fileURLWithPath: snapshot.downloadDirectory).standardizedFileURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TorrentSettingsForm(
                name: snapshot.name,
                detail: snapshot.totalLength > 0 ? formatBytes(snapshot.totalLength) : nil,
                directoryPath: $directoryPath,
                sequential: $sequential,
                footnote: directoryChanged
                    ? "Existing data will be moved to the new location before the transfer continues."
                    : nil
            )
            if !statuses.isEmpty {
                FileSelectionList(nodes: fileNodes, wanted: $wanted, fileCount: statuses.count)
            } else if snapshot.state == .fetchingMetadata {
                Label("Files can be selected once the magnet's metadata arrives.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    if sequential != snapshot.sequential {
                        store.setSequential(sequential, for: snapshot.infoHash)
                    }
                    if !wanted.isEmpty, wanted != originalWanted {
                        store.setWantedFiles(wanted, for: snapshot.infoHash)
                    }
                    if directoryChanged {
                        store.setDownloadLocation(
                            URL(fileURLWithPath: directoryPath), for: snapshot.infoHash
                        )
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            statuses = await store.fileStatuses(for: snapshot.infoHash)
            originalWanted = Set(statuses.filter(\.wanted).map(\.index))
            wanted = originalWanted
            fileNodes = TorrentFileNode.build(
                from: statuses.map { ($0.index, $0.path, $0.length) }
            )
        }
    }
}

/// An SF Symbol that rotates steadily, for inline "working…" indicators.
/// Driven by `TimelineView` (not an implicit animation) so it keeps spinning
/// even as the surrounding sheet re-renders on each metadata poll. Honors
/// Reduce Motion by holding still.
private struct SpinningSymbol: View {
    let systemName: String
    /// Seconds per full revolution.
    var period: Double = 1.2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Image(systemName: systemName)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period)
                Image(systemName: systemName)
                    .rotationEffect(.degrees(t / period * 360))
            }
        }
    }
}

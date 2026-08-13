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

/// Shown when a torrent/magnet is opened, before it is actually added.
struct AddTorrentSheet: View {
    @Environment(SessionStore.self) private var store
    let pending: PendingTorrentAdd

    @State private var directoryPath = UserDefaults.standard.string(forKey: Defaults.downloadDirectory)
        ?? NSHomeDirectory() + "/Downloads"
    @State private var sequential = UserDefaults.standard.bool(forKey: Defaults.sequentialDownload)
    @State private var wanted: Set<Int>
    private let fileNodes: [TorrentFileNode]

    init(pending: PendingTorrentAdd) {
        self.pending = pending
        self.fileNodes = TorrentFileNode.build(
            from: pending.files.enumerated().map { ($0, $1.path, $1.length) }
        )
        _wanted = State(initialValue: Set(pending.files.indices))
    }

    private var selectedSize: Int64 {
        wanted.reduce(Int64(0)) { $0 + pending.files[$1].length }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TorrentSettingsForm(
                name: pending.displayName,
                detail: pending.totalSize.map { total in
                    wanted.count == pending.files.count
                        ? formatBytes(total)
                        : "\(formatBytes(selectedSize)) of \(formatBytes(total)) selected"
                } ?? "Magnet link — files known after metadata arrives",
                directoryPath: $directoryPath,
                sequential: $sequential,
                footnote: nil
            )
            if !pending.files.isEmpty {
                FileSelectionList(
                    nodes: fileNodes, wanted: $wanted, fileCount: pending.files.count
                )
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
                        wantedFiles: wanted
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!pending.files.isEmpty && wanted.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
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

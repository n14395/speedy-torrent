import SwiftUI
import UniformTypeIdentifiers
import TorrentEngine

struct TorrentListView: View {
    @Environment(SessionStore.self) private var store
    @State private var selection: Set<InfoHash> = []
    @State private var showingFileImporter = false
    @State private var showingMagnetSheet = false
    @State private var magnetText = ""
    @State private var pendingRemoval: [TorrentSnapshot] = []
    @State private var editingTorrent: TorrentSnapshot?

    var body: some View {
        Group {
            if store.snapshots.isEmpty {
                ContentUnavailableView {
                    Label("No Torrents", systemImage: "arrow.down.circle")
                } description: {
                    Text("Open a .torrent file or paste a magnet link to start downloading.")
                } actions: {
                    Button("Open Torrent…") { showingFileImporter = true }
                    Button("Add Magnet Link…") { showingMagnetSheet = true }
                }
            } else {
                table
            }
        }
        .toolbar { toolbarContent }
        .navigationTitle("SpeedyTorrent")
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data],
            allowsMultipleSelection: true
        ) { result in
            for url in (try? result.get()) ?? [] {
                let scoped = url.startAccessingSecurityScopedResource()
                store.addTorrentFile(at: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
        .sheet(isPresented: $showingMagnetSheet) { magnetSheet }
        .sheet(item: Binding(
            get: { store.currentPendingAdd },
            set: { newValue in
                if newValue == nil, let current = store.currentPendingAdd {
                    store.dismissPendingAdd(id: current.id)
                }
            }
        )) { pending in
            AddTorrentSheet(pending: pending)
                .environment(store)
        }
        .sheet(item: $editingTorrent) { snapshot in
            EditTorrentSheet(snapshot: snapshot)
                .environment(store)
        }
        .onChange(of: store.settingsRequest) {
            guard let hash = store.settingsRequest else { return }
            store.settingsRequest = nil
            editingTorrent = store.snapshots.first { $0.infoHash == hash }
        }
        .confirmationDialog(
            removalTitle,
            isPresented: .init(
                get: { !pendingRemoval.isEmpty },
                set: { if !$0 { pendingRemoval = [] } }
            )
        ) {
            Button("Remove", role: .destructive) {
                for snapshot in pendingRemoval {
                    store.remove(snapshot.infoHash, deleteFiles: false)
                }
                pendingRemoval = []
            }
            Button("Remove and Trash Data", role: .destructive) {
                for snapshot in pendingRemoval {
                    store.remove(snapshot.infoHash, deleteFiles: true)
                }
                pendingRemoval = []
            }
            Button("Cancel", role: .cancel) { pendingRemoval = [] }
        } message: {
            Text("The torrent will stop and be forgotten. “Remove and Trash Data” also deletes the downloaded files.")
        }
        .alert(
            "Something Went Wrong",
            isPresented: .init(
                get: { store.lastActionError != nil },
                set: { if !$0 { store.lastActionError = nil } }
            )
        ) {
            Button("OK") { store.lastActionError = nil }
        } message: {
            Text(store.lastActionError ?? "")
        }
        .dropDestination(for: URL.self) { urls, _ in
            let torrents = urls.filter { $0.pathExtension.lowercased() == "torrent" }
            torrents.forEach { store.addTorrentFile(at: $0) }
            return !torrents.isEmpty
        }
    }

    private var removalTitle: String {
        pendingRemoval.count == 1
            ? "Remove “\(pendingRemoval[0].name)”?"
            : "Remove \(pendingRemoval.count) torrents?"
    }

    private var table: some View {
        Table(store.snapshots, selection: $selection) {
            TableColumn("Name") { snapshot in
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.name)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        ProgressView(value: snapshot.progress)
                            .controlSize(.small)
                        Text(snapshot.progress.formatted(.percent.precision(.fractionLength(1))))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, 2)
            }
            .width(min: 220, ideal: 320)

            TableColumn("Status") { snapshot in
                Text(statusText(snapshot))
                    .foregroundStyle(snapshot.state == .failed ? .red : .secondary)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Size") { snapshot in
                Text(snapshot.totalLength > 0 ? formatBytes(snapshot.totalLength) : "—")
                    .monospacedDigit()
            }
            .width(70)

            TableColumn("Down") { snapshot in
                Text(formatRate(snapshot.downloadRate)).monospacedDigit()
            }
            .width(80)

            TableColumn("Up") { snapshot in
                Text(formatRate(snapshot.uploadRate)).monospacedDigit()
            }
            .width(80)

            TableColumn("ETA") { snapshot in
                Text(formatETA(snapshot.eta)).monospacedDigit()
            }
            .width(70)

            TableColumn("Peers") { snapshot in
                Text("\(snapshot.peerCount)").monospacedDigit()
            }
            .width(45)

            TableColumn("Ratio") { snapshot in
                Text(String(format: "%.2f", snapshot.ratio)).monospacedDigit()
            }
            .width(45)
        }
        .contextMenu(forSelectionType: InfoHash.self) { hashes in
            contextMenu(for: hashes)
        } primaryAction: { hashes in
            for hash in hashes {
                store.revealInFinder(hash)
            }
        }
    }

    private func statusText(_ snapshot: TorrentSnapshot) -> String {
        if snapshot.state == .failed, let message = snapshot.errorMessage {
            return message
        }
        return snapshot.state.displayName
    }

    @ViewBuilder
    private func contextMenu(for hashes: Set<InfoHash>) -> some View {
        let selected = store.snapshots.filter { hashes.contains($0.infoHash) }
        if !selected.isEmpty {
            if selected.contains(where: { $0.state == .paused }) {
                Button("Resume") { selected.forEach { store.resume($0.infoHash) } }
            }
            if selected.contains(where: { $0.state == .downloading || $0.state == .seeding }) {
                Button("Pause") { selected.forEach { store.pause($0.infoHash) } }
            }
            Button("Show in Finder") { selected.forEach { store.revealInFinder($0.infoHash) } }
            if selected.count == 1 {
                Button("Settings…") { editingTorrent = selected[0] }
            }
            Divider()
            Button("Remove…", role: .destructive) { pendingRemoval = selected }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showingFileImporter = true
            } label: {
                Label("Open Torrent", systemImage: "plus")
            }
            .help("Open a .torrent file")

            Button {
                showingMagnetSheet = true
            } label: {
                Label("Add Magnet", systemImage: "link.badge.plus")
            }
            .help("Add a magnet link")

            Spacer()

            Button {
                selectedOrAll.forEach { store.resume($0.infoHash) }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .help("Resume")
            .disabled(!selectedOrAll.contains { $0.state == .paused })

            Button {
                selectedOrAll.forEach { store.pause($0.infoHash) }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .help("Pause")
            .disabled(!selectedOrAll.contains { $0.state == .downloading || $0.state == .seeding })

            Button {
                pendingRemoval = store.snapshots.filter { selection.contains($0.infoHash) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .help("Remove selected")
            .disabled(selection.isEmpty)

            Button {
                editingTorrent = store.snapshots.first { selection.contains($0.infoHash) }
            } label: {
                Label("Torrent Settings", systemImage: "gearshape")
            }
            .help("Per-torrent settings (download location, piece order)")
            .disabled(selection.count != 1)
        }
    }

    private var selectedOrAll: [TorrentSnapshot] {
        let selected = store.snapshots.filter { selection.contains($0.infoHash) }
        return selected.isEmpty ? store.snapshots : selected
    }

    private func pasteboardMagnet() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string),
              text.lowercased().hasPrefix("magnet:")
        else { return nil }
        return text
    }

    private var magnetSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Magnet Link")
                .font(.headline)
            TextField("magnet:?xt=urn:btih:…", text: $magnetText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
                .onSubmit(submitMagnet)
            HStack {
                Spacer()
                Button("Cancel") {
                    showingMagnetSheet = false
                    magnetText = ""
                }
                .keyboardShortcut(.cancelAction)
                Button("Add") { submitMagnet() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!magnetText.lowercased().hasPrefix("magnet:"))
            }
        }
        .padding(20)
        // Auto-fill a magnet link sitting on the clipboard so the common case
        // (copy a magnet, open the app) is one click.
        .onAppear {
            if magnetText.isEmpty, let clipboard = pasteboardMagnet() {
                magnetText = clipboard
            }
        }
    }

    private func submitMagnet() {
        guard magnetText.lowercased().hasPrefix("magnet:") else { return }
        store.addMagnet(magnetText.trimmingCharacters(in: .whitespacesAndNewlines))
        magnetText = ""
        showingMagnetSheet = false
    }
}

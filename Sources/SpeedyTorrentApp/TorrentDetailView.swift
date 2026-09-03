import SwiftUI
import TorrentEngine

/// What a detail view describes: a torrent the engine already has, or one the
/// user has opened but not confirmed yet.
enum TorrentSubject: Hashable {
    /// Already added — edits apply immediately.
    case live(InfoHash)
    /// Opened but unconfirmed — edits buffer on the pending record until "Add".
    case pending(PendingTorrentAdd.ID)
}

enum TorrentDetailTab: String, CaseIterable, Identifiable {
    case files = "Files"
    case info = "Info"
    case peers = "Peers"
    case trackers = "Trackers"
    var id: String { rawValue }
}

/// The torrent detail pane: settings and files, plus live peers, trackers and
/// transfer info. Used both as the trailing inspector and as the body of the
/// sheet shown when a torrent is opened.
struct TorrentDetailView: View {
    @Environment(SessionStore.self) private var store
    let subject: TorrentSubject
    @Binding var tab: TorrentDetailTab

    @State private var peers: [PeerDetail] = []
    @State private var trackers: [TrackerDetail] = []
    @State private var files: [TorrentFileStatus] = []
    @State private var copiedMagnet = false

    /// Checkbox edits the engine hasn't confirmed yet. Covers only the wanted
    /// flags, so progress keeps updating live while the user edits.
    @State private var localWanted: Set<Int>?
    /// Set when a write is dispatched; a safety valve for the cases where the
    /// engine never converges (removed torrent, rejected empty set).
    @State private var localWantedDeadline: Date?
    @State private var wantedWriteTask: Task<Void, Never>?
    /// Priority edits the engine hasn't reported back yet, by file index.
    @State private var localPriorities: [Int: FilePriority] = [:]
    /// The speed-limit fields, in KiB/s. Seeded from the snapshot when the
    /// subject changes and owned by the user from then on, so typing is never
    /// clobbered by a poll.
    @State private var limitDownloadKiB = 0
    @State private var limitUploadKiB = 0
    /// Which torrent the fields above describe. Switching rows blurs the field,
    /// which commits it — without this the committed value would land on the
    /// torrent just selected instead of the one it was typed for.
    @State private var limitSubject: InfoHash?

    @State private var showingFolderPicker = false
    /// Folder awaiting confirmation, because moving existing data is costly.
    @State private var pendingMove: URL?

    // MARK: - Subject accessors

    private var liveHash: InfoHash? {
        if case .live(let hash) = subject { return hash }
        return nil
    }

    private var pendingID: PendingTorrentAdd.ID? {
        if case .pending(let id) = subject { return id }
        return nil
    }

    private var snapshot: TorrentSnapshot? {
        guard let liveHash else { return nil }
        return store.snapshots.first { $0.infoHash == liveHash }
    }

    private var pending: PendingTorrentAdd? {
        guard let pendingID else { return nil }
        return store.pendingAdd(id: pendingID)
    }

    private var name: String {
        snapshot?.name ?? pending?.displayName ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PillSegmentedControl(
                options: TorrentDetailTab.allCases,
                title: \.rawValue,
                selection: $tab
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            switch tab {
            case .files: filesTab
            case .info: infoTab
            case .peers: peersTab
            case .trackers: trackersTab
            }
        }
        .task(id: subject) {
            // A pending add has no engine state to poll: its record is updated
            // by the store's own metadata refresh and published via @Observable.
            guard liveHash != nil else { return }
            while !Task.isCancelled {
                await refreshLiveData()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // Selecting another torrent reuses this view, so every @State below
        // still describes the last one. Land any in-flight edit on the torrent
        // it was actually made on, then clear — otherwise the pane shows the
        // previous selection's files until the first poll of the new one lands.
        .onChange(of: subject) { previous, _ in
            wantedWriteTask?.cancel()
            flushWantedEdit(for: previous)
            peers = []
            trackers = []
            files = []
            localWanted = nil
            localWantedDeadline = nil
            localPriorities = [:]
        }
        .onDisappear {
            wantedWriteTask?.cancel()
            flushWantedEdit(for: subject)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 11) {
            if let snapshot {
                ProgressRing(snapshot: snapshot, diameter: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    /// Size, peers and what the torrent is doing, on one line. The rates that
    /// used to sit here are on the torrent's own row in the list, which stays
    /// selected while this pane is open.
    private var subtitle: String {
        if let snapshot {
            var parts = [formatBytes(snapshot.totalLength)]
            parts.append("\(snapshot.peerCount) peer" + (snapshot.peerCount == 1 ? "" : "s"))
            switch snapshot.state {
            case .downloading:
                if snapshot.eta != nil { parts.append(formatETA(snapshot.eta) + " left") }
            case .seeding:
                parts.append("ratio " + String(format: "%.2f", snapshot.ratio))
            default:
                parts.append(snapshot.state.displayName)
            }
            return parts.joined(separator: " · ")
        }
        if let pending { return pendingDetail(pending) }
        return "—"
    }

    private func pendingDetail(_ pending: PendingTorrentAdd) -> String {
        guard let total = pending.totalSize else {
            return "Magnet link — fetching metadata to list files…"
        }
        return pending.wantedFiles.count == pending.files.count
            ? formatBytes(total)
            : "\(formatBytes(pending.selectedSize)) of \(formatBytes(total)) selected"
    }

    // MARK: - Files

    private var filesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Where and how this torrent downloads, above the list it governs.
            // A card each rather than two rows of one: they are unrelated
            // settings, and the gap says so more clearly than a hairline.
            locationRow
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Surface.fill)
                .clipShape(.rect(cornerRadius: Surface.corner))

            sequentialToggle
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Surface.fill)
                .clipShape(.rect(cornerRadius: Surface.corner))

            if liveHash != nil {
                speedLimitRow
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Surface.fill)
                    .clipShape(.rect(cornerRadius: Surface.corner))
            }

            fileTree
                .frame(maxHeight: .infinity)
                .background(Surface.fill)
                .clipShape(.rect(cornerRadius: Surface.corner))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            guard let url = try? result.get() else { return }
            chooseDirectory(url)
        }
        .confirmationDialog(
            "Move “\(name)” to \(pendingMove?.lastPathComponent ?? "")?",
            isPresented: Binding(
                get: { pendingMove != nil },
                set: { if !$0 { pendingMove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move") {
                if let url = pendingMove, let liveHash {
                    store.setDownloadLocation(url, for: liveHash)
                }
                pendingMove = nil
            }
            Button("Cancel", role: .cancel) { pendingMove = nil }
        } message: {
            Text("Existing data will be moved to the new location before the transfer continues.")
        }
    }

    private var locationRow: some View {
        let path = (currentDirectory.path as NSString).abbreviatingWithTildeInPath
        return HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            chooseButton
        }
    }

    /// A link, not a bordered button: the row is one line tall and a bezel
    /// there reads as a second card inside the first.
    private var chooseButton: some View {
        Button("Change…") { showingFolderPicker = true }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(snapshot?.state == .moving
                ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Surface.prominent))
            .disabled(snapshot?.state == .moving)
            .help(snapshot?.state == .moving
                ? "A move is already in progress"
                : "Where this torrent's files are saved")
    }

    /// This torrent's own caps, on top of the session-wide ones in Settings.
    /// Blank (0) means it just follows the global limit.
    private var speedLimitRow: some View {
        let fetching = snapshot?.state == .fetchingMetadata
        return HStack(spacing: 8) {
            Text("Speed limits")
                .font(.system(size: 12))
            Spacer(minLength: 8)
            limitField(systemImage: "arrow.down", value: $limitDownloadKiB)
            limitField(systemImage: "arrow.up", value: $limitUploadKiB)
            Text("KiB/s")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .disabled(fetching)
        .opacity(fetching ? 0.4 : 1)
        .help(fetching
            ? "Available once the magnet's metadata arrives"
            : "Caps this torrent alone. 0 follows the global limit in Settings.")
        .onAppear { syncLimitFields() }
        .onChange(of: snapshot?.infoHash) { syncLimitFields() }
    }

    private func limitField(systemImage: String, value: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("0", value: value, format: .number)
                .surfaceField(width: 52)
                .onSubmit { flushLimitEdit() }
                .onChange(of: value.wrappedValue) { flushLimitEdit() }
        }
    }

    /// Pulls the engine's values into the fields. Only while the user isn't
    /// mid-edit: the 1 Hz poll would otherwise overwrite half-typed numbers.
    private func syncLimitFields() {
        guard let snapshot else { return }
        limitDownloadKiB = (snapshot.downloadRateLimit ?? 0) / 1024
        limitUploadKiB = (snapshot.uploadRateLimit ?? 0) / 1024
        limitSubject = snapshot.infoHash
    }

    private func flushLimitEdit() {
        guard let liveHash, limitSubject == liveHash else { return }
        store.setRateLimits(
            downloadKiB: max(0, limitDownloadKiB),
            uploadKiB: max(0, limitUploadKiB),
            for: liveHash
        )
    }

    /// An iOS-style switch in the panel's blue — the checkbox this used to be
    /// disappeared against the card.
    private var sequentialToggle: some View {
        HStack(spacing: 8) {
            Text("Sequential download")
                .font(.system(size: 12))
            Spacer(minLength: 8)
            sequentialSwitch.surfaceSwitch()
        }
        .help("Download pieces in file order — useful for previewing media early.")
    }

    private var sequentialSwitch: some View {
        Toggle("Sequential download", isOn: Binding(
            get: { snapshot?.sequential ?? pending?.sequential ?? false },
            set: { newValue in
                switch subject {
                case .live(let hash): store.setSequential(newValue, for: hash)
                case .pending(let id): store.setPendingSequential(newValue, id: id)
                }
            }
        ))
    }

    @ViewBuilder
    private var fileTree: some View {
        if let pending {
            if pending.files.isEmpty {
                if pending.isMagnet {
                    HStack(spacing: 6) {
                        SpinningSymbol(systemName: "arrow.triangle.2.circlepath")
                        Text("Fetching metadata… the file list will appear here.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyState("No files")
                }
            } else {
                TorrentFileTree(
                    rows: pending.fileRows,
                    selection: Binding(
                        get: { pending.wantedFiles },
                        set: { store.setPendingWantedFiles($0, id: pending.id) }
                    ),
                    onSetPriority: { priority, files in
                        store.setPendingFilePriority(priority, forFiles: files, id: pending.id)
                    }
                )
            }
        } else if files.isEmpty {
            emptyState(snapshot?.state == .fetchingMetadata
                ? "Files can be chosen once the magnet's metadata arrives."
                : "Metadata not available yet")
        } else {
            TorrentFileTree(
                rows: liveFileRows,
                selection: liveWantedBinding,
                onSetPriority: setLivePriority
            )
        }
    }

    private var currentDirectory: URL {
        if let pending { return pending.downloadDirectory }
        return URL(fileURLWithPath: snapshot?.downloadDirectory ?? NSHomeDirectory())
    }

    private func chooseDirectory(_ url: URL) {
        switch subject {
        case .pending(let id):
            store.setPendingDirectory(url, id: id)
        case .live(let hash):
            guard let snapshot else { return }
            // Nothing on disk yet (or not even resolved) — no move to warn about.
            if snapshot.state == .fetchingMetadata || snapshot.completedLength == 0 {
                store.setDownloadLocation(url, for: hash)
            } else {
                pendingMove = url
            }
        }
    }

    // MARK: - Live file selection

    /// The engine's selection, overlaid with any edit it hasn't confirmed yet.
    /// Applies a priority to a live torrent's files. The engine write is cheap
    /// (no reallocation, no re-check), so it goes straight out; the overlay
    /// just spares the glyph a wait for the next 1 Hz poll.
    private func setLivePriority(_ priority: FilePriority, files: Set<Int>) {
        guard let liveHash else { return }
        store.setFilePriority(priority, forFiles: files, for: liveHash)
        for index in files {
            localPriorities[index] = priority
        }
    }

    /// Engine rows with any not-yet-confirmed priority edit applied.
    private var liveFileRows: [FileRow] {
        files.fileRows.map { row in
            guard let pending = localPriorities[row.index] else { return row }
            var row = row
            row.priority = pending
            return row
        }
    }

    private var liveWantedBinding: Binding<Set<Int>> {
        Binding(
            get: { localWanted ?? Set(files.filter(\.wanted).map(\.index)) },
            set: { newValue in
                localWanted = newValue
                // Coalesce rapid clicks: each write costs the engine a
                // preallocate + reconcile + resume save.
                wantedWriteTask?.cancel()
                wantedWriteTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    flushWantedEdit(for: subject)
                }
            }
        )
    }

    /// Takes its target explicitly: the debounced write below outlives a
    /// selection change, and must land on the torrent the checkbox was on.
    private func flushWantedEdit(for subject: TorrentSubject) {
        guard case .live(let hash) = subject,
              let wanted = localWanted, !wanted.isEmpty,
              // Don't write (and alert) for a torrent that has since gone away.
              store.snapshots.contains(where: { $0.infoHash == hash })
        else { return }
        guard wanted != Set(files.filter(\.wanted).map(\.index)) else {
            localWanted = nil
            return
        }
        store.setWantedFiles(wanted, for: hash)
        localWantedDeadline = Date().addingTimeInterval(10)
    }

    private func refreshLiveData() async {
        guard let liveHash else { return }
        peers = await store.peerDetails(for: liveHash)
        trackers = await store.trackerDetails(for: liveHash)
        let fresh = await store.fileStatuses(for: liveHash)
        files = fresh
        // Priority writes can't be rejected, so agreement is the only exit.
        if !localPriorities.isEmpty {
            let engine = Dictionary(uniqueKeysWithValues: fresh.map { ($0.index, $0.priority) })
            localPriorities = localPriorities.filter { engine[$0.key] != $0.value }
        }
        // Drop the overlay once the engine agrees — or once it clearly never will.
        if let wanted = localWanted {
            let engineWanted = Set(fresh.filter(\.wanted).map(\.index))
            let expired = localWantedDeadline.map { Date() > $0 } ?? false
            if wanted == engineWanted || expired {
                localWanted = nil
                localWantedDeadline = nil
            }
        }
    }

    // MARK: - Info

    private var infoTab: some View {
        Group {
            if let snapshot {
                liveInfo(snapshot)
            } else if let pending {
                pendingInfo(pending)
            } else {
                emptyState("Torrent not found")
            }
        }
    }

    private func liveInfo(_ snapshot: TorrentSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                copyMagnetButton(hash: snapshot.infoHash.hexString, name: snapshot.name)

                SurfaceSection(title: "Speed") {
                    VStack(spacing: 6) {
                        RateChart(samples: store.rateHistory[snapshot.infoHash] ?? [])
                            .frame(height: 92)
                        RateChartLegend(
                            download: snapshot.downloadRate,
                            upload: snapshot.uploadRate
                        )
                    }
                    .padding(12)
                }

                SurfaceSection(title: "Torrent") {
                    SurfaceRow("Name", snapshot.name)
                    SurfaceSeparator()
                    SurfaceRow("Info hash", snapshot.infoHash.hexString, monospaced: true)
                    SurfaceSeparator()
                    SurfaceRow("Size", snapshot.totalLength > 0 ? formatBytes(snapshot.totalLength) : "—")
                    if snapshot.pieceCount > 0 {
                        SurfaceSeparator()
                        SurfaceRow("Pieces", "\(snapshot.pieceCount) × \(formatBytes(Int64(snapshot.pieceLength)))")
                    }
                    if snapshot.addedAt > 0 {
                        SurfaceSeparator()
                        SurfaceRow("Added", Date(timeIntervalSince1970: snapshot.addedAt)
                            .formatted(date: .abbreviated, time: .shortened))
                    }
                }

                SurfaceSection(title: "Transfer") {
                    SurfaceRow("State", snapshot.state.displayName)
                    SurfaceSeparator()
                    SurfaceRow("Downloaded", formatBytes(snapshot.downloadedTotal))
                    SurfaceSeparator()
                    SurfaceRow("Uploaded", formatBytes(snapshot.uploadedTotal))
                    SurfaceSeparator()
                    SurfaceRow("Ratio", String(format: "%.2f", snapshot.ratio))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .scrollContentBackground(.hidden)
    }

    private func pendingInfo(_ pending: PendingTorrentAdd) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if case .magnet(let uri) = pending.source {
                    copyButton(label: "Copy Magnet Link", value: uri)
                }

                SurfaceSection(title: "Torrent") {
                    SurfaceRow("Name", pending.displayName)
                    SurfaceSeparator()
                    SurfaceRow("Info hash", pending.infoHash.hexString, monospaced: true)
                    SurfaceSeparator()
                    SurfaceRow("Size", pending.totalSize.map(formatBytes) ?? "Unknown until metadata arrives")
                    SurfaceSeparator()
                    SurfaceRow("Source", pending.isMagnet ? "Magnet link" : "Torrent file")
                    if !pending.files.isEmpty {
                        SurfaceSeparator()
                        SurfaceRow("Files", "\(pending.wantedFiles.count) of \(pending.files.count) selected")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .scrollContentBackground(.hidden)
    }

    private func copyMagnetButton(hash: String, name: String) -> some View {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ string: String) -> String {
            string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
        }
        var link = "magnet:?xt=urn:btih:\(hash)&dn=" + encode(name)
        for tracker in trackers {
            link += "&tr=" + encode(tracker.url)
        }
        return copyButton(label: "Copy Magnet Link", value: link)
    }

    private func copyButton(label: String, value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copiedMagnet = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copiedMagnet = false
            }
        } label: {
            Label(
                copiedMagnet ? "Copied!" : label,
                systemImage: copiedMagnet ? "checkmark" : "link"
            )
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Surface.fill, in: .rect(cornerRadius: Surface.corner))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Copy a magnet link for this torrent (info hash, name, and trackers)")
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

    // MARK: - Peers

    private var peersTab: some View {
        Group {
            if pending != nil {
                emptyState("Peers appear once the download starts.")
            } else if peers.isEmpty {
                emptyState("No connected peers")
            } else {
                ScrollView {
                    SurfaceSection {
                        ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
                            if index > 0 { SurfaceSeparator() }
                            peerRow(peer)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func peerRow(_ peer: PeerDetail) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(peer.address)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(peer.client)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(peerFlags(peer))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(peer.progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 12))
                    .monospacedDigit()
                HStack(spacing: 8) {
                    Label(compactRate(peer.downloadRate), systemImage: "arrow.down")
                        .foregroundStyle(peer.downloadRate >= 1024 ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.tertiary))
                    Label(compactRate(peer.uploadRate), systemImage: "arrow.up")
                        .foregroundStyle(peer.uploadRate >= 1024 ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                }
                .font(.system(size: 11))
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func peerFlags(_ peer: PeerDetail) -> String {
        var flags: [String] = []
        flags.append(peer.incoming ? "incoming" : "outgoing")
        if peer.encrypted { flags.append("encrypted") }
        if peer.isSeed { flags.append("seed") }
        if peer.interestedInPeer, !peer.peerChokingUs { flags.append("downloading") }
        if peer.peerInterestedInUs, !peer.chokingPeer { flags.append("uploading") }
        return flags.joined(separator: " · ")
    }

    // MARK: - Trackers

    private var trackersTab: some View {
        Group {
            if let pending {
                if pending.trackers.isEmpty {
                    emptyState("No trackers — peers will come from the DHT.")
                } else {
                    ScrollView {
                        SurfaceSection {
                            ForEach(Array(pending.trackers.enumerated()), id: \.element) { index, tracker in
                                if index > 0 { SurfaceSeparator() }
                                Text(tracker)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                    .scrollContentBackground(.hidden)
                }
            } else if trackers.isEmpty {
                emptyState("No trackers")
            } else {
                ScrollView {
                    SurfaceSection {
                        ForEach(Array(trackers.enumerated()), id: \.element.id) { index, tracker in
                            if index > 0 { SurfaceSeparator() }
                            trackerRow(tracker)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func trackerRow(_ tracker: TrackerDetail) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tracker.url)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Tier \(tracker.tier + 1)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            trackerStatus(tracker)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func trackerStatus(_ tracker: TrackerDetail) -> some View {
        if let error = tracker.lastError {
            Text(error)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.red)
                .help(error)
        } else if tracker.seeders != nil || tracker.leechers != nil {
            HStack(spacing: 8) {
                Label("\(tracker.seeders ?? 0)", systemImage: "arrow.up")
                    .foregroundStyle(.green)
                Label("\(tracker.leechers ?? 0)", systemImage: "arrow.down")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .monospacedDigit()
        } else if tracker.lastSuccess != nil {
            Text("Working").font(.system(size: 11)).foregroundStyle(.green)
        } else {
            Text("Waiting…").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows the detail view for a single selection, or guidance otherwise.
struct InspectorPane: View {
    @Environment(SessionStore.self) private var store
    let selection: Set<InfoHash>
    /// Owned here (not inside the detail view) so it survives the 0/multi
    /// selection states that swap the view out.
    @Binding var tab: TorrentDetailTab

    var body: some View {
        Group {
            if selection.count == 1, let hash = selection.first {
                TorrentDetailView(subject: .live(hash), tab: $tab)
                    .environment(store)
            } else {
                ContentUnavailableView(
                    selection.isEmpty ? "No Selection" : "Multiple Torrents",
                    systemImage: "info.circle",
                    description: Text(selection.isEmpty
                        ? "Select a torrent to see its files, peers and trackers."
                        : "Select a single torrent to inspect it.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The status bar is applied outside the inspector split, so its inset
        // never reaches this pane — it has to keep clear of the bar itself.
        .safeAreaPadding(.bottom, Surface.statusBarHeight)
        // The inspector is part of the same panel as the window body, not a
        // separate vibrant sidebar.
        .background(Surface.panel)
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

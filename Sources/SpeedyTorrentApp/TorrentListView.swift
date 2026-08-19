import SwiftUI
import UniformTypeIdentifiers
import TorrentEngine

/// Sort key for an optional snapshot field (the table needs a Comparable).
extension TorrentSnapshot {
    var etaSortKey: Double { eta ?? .infinity }
}

/// The status-bar filter over the torrent list.
enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case downloading = "Downloading"
    case seeding = "Seeding"
    case paused = "Paused"
    case queued = "Queued"
    var id: String { rawValue }

    /// The footer pills are icon-led, so "All" is the only one that keeps its
    /// word — the rest read faster as the same glyphs the rings use.
    var systemImage: String? {
        switch self {
        case .all: nil
        case .downloading: "arrow.down"
        case .seeding: "arrow.up"
        case .paused: "pause.fill"
        case .queued: "clock"
        }
    }

    func matches(_ snapshot: TorrentSnapshot) -> Bool {
        switch self {
        case .all: true
        case .downloading: snapshot.state == .downloading || snapshot.state == .fetchingMetadata
            || snapshot.state == .checking || snapshot.state == .moving
        case .seeding: snapshot.state == .seeding
        case .paused: snapshot.state == .paused || snapshot.state == .failed
        case .queued: snapshot.state == .queued
        }
    }
}

struct TorrentListView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Set<InfoHash> = []
    @State private var showingFileImporter = false
    @State private var showingMagnetSheet = false
    @State private var magnetText = ""
    @State private var pendingRemoval: [TorrentSnapshot] = []
    @State private var showInspector = false
    /// Which inspector tab is showing. Owned here so it survives selection
    /// changes, and kept separate from the add sheet's own tab state.
    @State private var inspectorTab: TorrentDetailTab = .files
    @State private var sortOrder: [KeyPathComparator<TorrentSnapshot>] =
        [KeyPathComparator(\.queuePosition)]
    @State private var searchText = ""
    @State private var statusFilter: StatusFilter = .all
    /// Bumped once after launch to re-create toolbar buttons (see workaround).
    @State private var toolbarRefresh = 0

    /// True while the table shows the engine's queue order — the default "#"
    /// ascending sort (or no sort at all) — the only mode where the rows can
    /// be reordered.
    private var isQueueOrdered: Bool {
        sortOrder.isEmpty || (
            sortOrder.count == 1
                && sortOrder[0].keyPath == \TorrentSnapshot.queuePosition
                && sortOrder[0].order == .forward
        )
    }

    /// Snapshots after search + status filter + column sort. In queue order
    /// the engine's own ordering passes through untouched.
    private var displayedSnapshots: [TorrentSnapshot] {
        var rows = store.snapshots.filter { statusFilter.matches($0) }
        if !searchText.isEmpty {
            rows = rows.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        if !isQueueOrdered {
            rows.sort(using: sortOrder)
        }
        return rows
    }

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
                VStack(spacing: 10) {
                    heroTiles
                    torrentCard
                    // The card is sized to its rows, as in the design; the
                    // panel shows through beneath a short list.
                    Spacer(minLength: 0)
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Surface.panel)
        .toolbar { toolbarContent }
        .toolbarBackground(Surface.chrome, for: .windowToolbar)
        .navigationTitle("SpeedyTorrent")
        // Workaround: toolbar buttons render with a stale dimmed appearance on
        // first launch until an event (e.g. mouse-over) refreshes them.
        // Detaching and re-attaching the toolbar forces AppKit to rebuild the
        // item views against the current (active) state.
        .task {
            try? await Task.sleep(for: .milliseconds(450))
            for window in NSApplication.shared.windows {
                guard let toolbar = window.toolbar else { continue }
                window.toolbar = nil
                window.toolbar = toolbar
            }
            toolbarRefresh += 1
        }
        .inspector(isPresented: $showInspector) {
            InspectorPane(selection: selection, tab: $inspectorTab)
                .environment(store)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 460)
        }
        // Below the inspector split, not inside it, so the bar runs the full
        // width of the window the way the design draws it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !store.snapshots.isEmpty {
                statusBar
            }
        }
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
        // Presented by id, not by value: the pending record now carries the
        // user's settings, so binding to the value would re-present the sheet
        // on every edit.
        .sheet(item: Binding(
            get: { store.currentPendingAdd.map { PendingAddID(id: $0.id) } },
            set: { newValue in
                if newValue == nil, let current = store.currentPendingAdd {
                    store.dismissPendingAdd(id: current.id)
                }
            }
        )) { pending in
            AddTorrentSheet(pendingID: pending.id)
                .environment(store)
        }
        .onChange(of: store.settingsRequest) { consumeSettingsRequest() }
        .onChange(of: store.magnetRequest) { consumeMagnetRequest() }
        .onAppear {
            // The menu bar sets the request before opening this window, so a
            // change notification alone would miss it.
            consumeSettingsRequest()
            consumeMagnetRequest()
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

    /// Selects a torrent and reveals its settings in the inspector — the one
    /// place per-torrent settings live now.
    private func showSettings(for infoHash: InfoHash) {
        selection = [infoHash]
        inspectorTab = .files
        showInspector = true
    }

    private func consumeSettingsRequest() {
        guard let hash = store.settingsRequest else { return }
        store.settingsRequest = nil
        showSettings(for: hash)
    }

    private func consumeMagnetRequest() {
        guard store.magnetRequest else { return }
        store.magnetRequest = false
        showingMagnetSheet = true
    }

    private var removalTitle: String {
        pendingRemoval.count == 1
            ? "Remove “\(pendingRemoval[0].name)”?"
            : "Remove \(pendingRemoval.count) torrents?"
    }

    // MARK: - Hero tiles

    private var activeCount: Int {
        store.snapshots.count { $0.state == .downloading || $0.state == .seeding }
    }

    private var heroTiles: some View {
        HStack(spacing: 10) {
            RateTile(
                title: "Download", icon: "arrow.down", tint: .blue,
                rate: store.totalDownloadRate,
                samples: store.totalRateHistory, value: \.download,
                height: Surface.windowTileHeight
            )
            RateTile(
                title: "Upload", icon: "arrow.up", tint: .green,
                rate: store.totalUploadRate,
                samples: store.totalRateHistory, value: \.upload,
                height: Surface.windowTileHeight
            )
            StatTile(
                title: "Active", icon: "list.bullet",
                value: "\(activeCount)", unit: "of \(store.snapshots.count)",
                caption: activeCaption, height: Surface.windowTileHeight
            )
            StatTile(
                title: "This session", icon: "clock",
                value: session.value, unit: session.unit, caption: session.caption,
                height: Surface.windowTileHeight
            )
        }
    }

    private var activeCaption: String {
        let downloading = store.snapshots.count { $0.state == .downloading }
        let seeding = store.snapshots.count { $0.state == .seeding }
        return "\(downloading) downloading · \(seeding) seeding"
    }

    /// Session counters split into a big number and its unit. `store.stats` is
    /// nil until the first poll, and a zero there would read as "nothing has
    /// happened" rather than "not known yet".
    private var session: (value: String, unit: String, caption: String) {
        guard let stats = store.stats else { return ("—", "", "Starting up…") }
        let parts = formatBytes(stats.sessionDownloaded).split(separator: " ")
        return (
            String(parts.first ?? "—"),
            parts.count > 1 ? String(parts[1]) : "",
            "↑ \(formatBytes(stats.sessionUploaded)) · ratio \(String(format: "%.2f", stats.sessionRatio))"
        )
    }

    // MARK: - Torrent table

    /// Fixed column widths, shared by the table and the header drawn above it.
    /// The two have to agree pixel-for-pixel, so they read from one place.
    private enum Col {
        static let number: CGFloat = 30
        static let size: CGFloat = 74
        static let rate: CGFloat = 80
        static let eta: CGFloat = 70
        static let ratio: CGFloat = 59

        /// The header and the rows are built from these same two numbers, so
        /// they line up by construction.
        static let inset: CGFloat = 12
        static let spacing: CGFloat = 8

        /// Row height, and the gap between a row's ring and its name.
        static let rowHeight: CGFloat = 40
        static let headerHeight: CGFloat = 25.5
        static let ring: CGFloat = 24
        static let ringGap: CGFloat = 10
    }

    private var torrentCard: some View {
        VStack(spacing: 0) {
            tableHeader
            SurfaceSeparator()
            table
        }
        .background(Surface.fill)
        .clipShape(.rect(cornerRadius: Surface.corner))
        .overlay {
            if displayedSnapshots.isEmpty {
                ContentUnavailableView.search
            }
        }
        // Hugs its rows rather than filling the window, as the design draws
        // it; a longer list is still capped by whatever height is available.
        .frame(maxHeight: Col.headerHeight + 0.5
            + CGFloat(max(displayedSnapshots.count, 1)) * Col.rowHeight)
    }

    /// Our own header, because `TableColumn` takes a title string and offers no
    /// way to style it. `Table` never sorted anything anyway — `displayedSnapshots`
    /// does that — so owning the header only costs column resizing.
    private var tableHeader: some View {
        HStack(spacing: Col.spacing) {
            sortHeader("#", \.queuePosition, width: Col.number, alignment: .leading)
            sortHeader("Name", \.name, width: nil, alignment: .leading)
            sortHeader("Size", \.totalLength, width: Col.size)
            sortHeader("Down", \.downloadRate, width: Col.rate)
            sortHeader("Up", \.uploadRate, width: Col.rate)
            sortHeader("ETA", \.etaSortKey, width: Col.eta)
            sortHeader("Ratio", \.ratio, width: Col.ratio)
        }
        .padding(.horizontal, Col.inset)
        .frame(height: Col.headerHeight)
    }

    @ViewBuilder
    private func sortHeader<V: Comparable>(
        _ title: String,
        // `KeyPathComparator` wants a Sendable key path under Swift 6.
        _ keyPath: any KeyPath<TorrentSnapshot, V> & Sendable,
        width: CGFloat?,
        alignment: Alignment = .trailing
    ) -> some View {
        let isActive = sortOrder.first.map { $0.keyPath as AnyKeyPath } == keyPath as AnyKeyPath
        let label = Button {
            if isActive {
                sortOrder[0].order = sortOrder[0].order == .forward ? .reverse : .forward
            } else {
                sortOrder = [KeyPathComparator(keyPath, order: .forward)]
            }
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if isActive {
                    Image(systemName: sortOrder[0].order == .forward ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Sort by \(title)")

        if let width {
            label.frame(width: width)
        } else {
            label.frame(maxWidth: .infinity)
        }
    }

    /// A `List`, not a `Table`: `Table` lays its columns out to insets it
    /// does not expose, so the styled header above could never be lined up
    /// with the cells for certain. Rows and header now read the same `Col`
    /// numbers and agree by construction — and the row keeps the selection,
    /// keyboard navigation and context menus a plain stack would lose.
    private var table: some View {
        List(selection: $selection) {
            ForEach(displayedSnapshots) { snapshot in
                row(snapshot)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .tag(snapshot.infoHash)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .padding(.leading, -Surface.listLeadingBleed)
        .padding(.trailing, -Surface.listTrailingBleed)
        .environment(\.defaultMinListRowHeight, Col.rowHeight)
        .contextMenu(forSelectionType: InfoHash.self) { hashes in
            contextMenu(for: hashes)
        } primaryAction: { hashes in
            for hash in hashes {
                store.revealInFinder(hash)
            }
        }
    }

    private func row(_ snapshot: TorrentSnapshot) -> some View {
        let isSelected = selection.contains(snapshot.infoHash)
        return HStack(spacing: Col.spacing) {
            Text("\(snapshot.queuePosition)")
                .foregroundStyle(.secondary)
                .frame(width: Col.number, alignment: .leading)

            // The ring carries the state the Status column used to spell out:
            // tint for which state, glyph for which action, arc for progress.
            HStack(spacing: Col.ringGap) {
                ProgressRing(snapshot: snapshot, diameter: Col.ring, compact: true)
                Text(snapshot.name)
                    .lineLimit(1)
                    .foregroundStyle(
                        snapshot.state == .paused
                            ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(statusText(snapshot))

            Text(snapshot.totalLength > 0 ? formatBytes(snapshot.totalLength) : "—")
                .foregroundStyle(.secondary)
                .frame(width: Col.size, alignment: .trailing)

            Text(formatRate(snapshot.downloadRate))
                .foregroundStyle(snapshot.downloadRate >= 1024
                    ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.secondary))
                .frame(width: Col.rate, alignment: .trailing)

            Text(formatRate(snapshot.uploadRate))
                .foregroundStyle(snapshot.uploadRate >= 1024
                    ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                .frame(width: Col.rate, alignment: .trailing)

            Text(formatETA(snapshot.eta))
                .foregroundStyle(.secondary)
                .frame(width: Col.eta, alignment: .trailing)

            // Green once a torrent has given back at least what it took.
            Text(String(format: "%.2f", snapshot.ratio))
                .foregroundStyle(snapshot.ratio >= 1 ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                .frame(width: Col.ratio, alignment: .trailing)
        }
        .font(.system(size: 13))
        .monospacedDigit()
        .padding(.horizontal, Col.inset)
        .frame(height: Col.rowHeight)
        // Opaque, and drawn by the row rather than behind it, so it covers the
        // system highlight instead of tinting it.
        .background(isSelected ? AnyShapeStyle(Surface.selection) : AnyShapeStyle(.clear))
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            filterPills

            if !isQueueOrdered {
                Button("Queue Order") { sortOrder = [KeyPathComparator(\.queuePosition)] }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Return to queue-priority order")
            }

            Spacer()

            Group {
                // Total rates live in the hero tiles now; what is left here is
                // the network's health, which has nowhere better to sit.
                Label("\(store.dhtNodeCount) nodes", systemImage: "point.3.connected.trianglepath.dotted")
                    .help("DHT nodes in the routing table")

                Label(portMappingSummary, systemImage: "network")
                    .help("Router port mapping (NAT-PMP)")

                if store.activeEncryptionPolicy != .disabled {
                    Label(
                        store.activeEncryptionPolicy == .required ? "Required" : "Preferred",
                        systemImage: "lock"
                    )
                    .help("Peer-connection encryption (MSE/PE)")
                }

                Button {
                    openWindow(id: "stats")
                } label: {
                    Image(systemName: "chart.xyaxis.line")
                }
                .buttonStyle(.borderless)
                .help("Transfer statistics")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(height: Surface.statusBarHeight)
        .background(Surface.chrome)
        .overlay(alignment: .top) { SurfaceSeparator() }
    }

    /// The status filter as pills with live counts. As a menu it was a setting
    /// nobody found; as counts it doubles as a summary of the session.
    private var filterPills: some View {
        HStack(spacing: 5) {
            ForEach(StatusFilter.allCases) { filter in
                let count = store.snapshots.count { filter.matches($0) }
                let isOn = statusFilter == filter
                Button {
                    statusFilter = filter
                } label: {
                    HStack(spacing: 4) {
                        if let icon = filter.systemImage {
                            Image(systemName: icon).font(.system(size: 8, weight: .semibold))
                        } else {
                            Text(filter.rawValue).font(.system(size: 11, weight: .semibold))
                        }
                        Text("\(count)").font(.system(size: 11)).monospacedDigit()
                    }
                    .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        Capsule().fill(isOn ? AnyShapeStyle(Surface.prominent) : AnyShapeStyle(Surface.fill))
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help("Show only torrents that are \(filter.rawValue.lowercased())")
            }
        }
    }

    private var portMappingSummary: String {
        switch store.portMappingStatus {
        case .disabled: "Off"
        case .mapping: "Mapping…"
        case .mapped(let port, _): "Port \(port) mapped"
        case .failed: "No mapping"
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
            if selected.contains(where: { $0.state == .downloading || $0.state == .seeding || $0.state == .queued }) {
                Button("Pause") { selected.forEach { store.pause($0.infoHash) } }
            }
            Button("Show in Finder") { selected.forEach { store.revealInFinder($0.infoHash) } }
            Button("Verify Data") { selected.forEach { store.recheck($0.infoHash) } }
            if selected.count == 1 {
                Button("Settings…") { showSettings(for: selected[0].infoHash) }
            }
            // Reordering is only meaningful in the queue-priority order.
            if selected.count == 1, isQueueOrdered, searchText.isEmpty, statusFilter == .all {
                let hash = selected[0].infoHash
                let index = store.snapshots.firstIndex { $0.infoHash == hash } ?? 0
                Menu("Move") {
                    Button("To Top") { store.move(hash, .top) }
                        .disabled(index == 0)
                    Button("Up") { store.move(hash, .up) }
                        .disabled(index == 0)
                    Button("Down") { store.move(hash, .down) }
                        .disabled(index == store.snapshots.count - 1)
                    Button("To Bottom") { store.move(hash, .bottom) }
                        .disabled(index == store.snapshots.count - 1)
                }
            }
            Divider()
            Button("Remove…", role: .destructive) { pendingRemoval = selected }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // After the window title, before the action icons: the name filter.
        ToolbarItem(placement: .principal) {
            ToolbarSearchField(text: $searchText, prompt: "Filter by name")
                .frame(width: 200)
        }

        // One Add control with two destinations, matching the menu bar popup —
        // two separate toolbar buttons made "open a file" and "paste a link"
        // look like unrelated actions.
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Add .torrent…") { showingFileImporter = true }
                Button("Add Magnet Link…") { showingMagnetSheet = true }
            } label: {
                Label("Add", systemImage: "plus")
            }
            // The design leads the toolbar with a filled, labelled Add: it is
            // the one action a new window is for, and an unlabelled "+" beside
            // five other glyphs did not read that way. macOS 26 draws its own
            // bezel for a toolbar menu, so this gets the label and the tint but
            // not the design's solid fill.
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .labelStyle(.titleAndIcon)
            .tint(Surface.prominent)
            .help("Add a torrent file or magnet link")
            .id(toolbarRefresh)
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                selectedSnapshots.forEach { store.pause($0.infoHash) }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .help("Pause the selected torrents")
            .id(toolbarRefresh)
            .disabled(!selectedSnapshots.contains { $0.state == .downloading || $0.state == .seeding || $0.state == .queued })

            Button {
                selectedSnapshots.forEach { store.resume($0.infoHash) }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .help("Resume the selected torrents")
            .id(toolbarRefresh)
            .disabled(!selectedSnapshots.contains { $0.state == .paused })

            Button {
                store.snapshots.filter { selection.contains($0.infoHash) }
                    .forEach { store.revealInFinder($0.infoHash) }
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help("Show the downloaded files in Finder")
            .id(toolbarRefresh)
            .disabled(selection.isEmpty)

            Button {
                pendingRemoval = store.snapshots.filter { selection.contains($0.infoHash) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .help("Remove selected")
            .id(toolbarRefresh)
            .disabled(selection.isEmpty)
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show peers, trackers, and files for the selected torrent")
            .id(toolbarRefresh)
        }
    }

    private var selectedSnapshots: [TorrentSnapshot] {
        store.snapshots.filter { selection.contains($0.infoHash) }
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

/// A native search field for toolbar placement (SwiftUI's `.searchable` pins
/// itself to the trailing edge; this one goes wherever it's declared). Clicking
/// anywhere outside the field gives up keyboard focus, like Finder's search.
private struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.controlSize = .regular
        // Don't grab keyboard focus at launch (clicking still focuses it).
        field.refusesFirstResponder = true
        context.coordinator.installClickAwayMonitor(for: field)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.removeClickAwayMonitor()
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let text: Binding<String>
        private var clickMonitor: Any?

        init(text: Binding<String>) {
            self.text = text
        }

        deinit {
            removeClickAwayMonitor()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        /// Resigns focus when a click in the same window lands outside the
        /// field (the table only takes focus for row clicks, not empty space).
        func installClickAwayMonitor(for field: NSSearchField) {
            removeClickAwayMonitor()
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak field] event in
                guard let field,
                      let window = field.window,
                      event.window === window,
                      field.currentEditor() != nil // focused
                else { return event }
                let point = field.convert(event.locationInWindow, from: nil)
                if !field.bounds.contains(point) {
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        func removeClickAwayMonitor() {
            if let clickMonitor {
                NSEvent.removeMonitor(clickMonitor)
                self.clickMonitor = nil
            }
        }
    }
}

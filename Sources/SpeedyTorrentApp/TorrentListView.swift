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

    /// What an empty list under this filter actually means — the search
    /// field's "check the spelling" is nonsense when nothing was typed.
    var emptyTitle: String {
        switch self {
        case .all: "No torrents"
        case .downloading: "Nothing is downloading"
        case .seeding: "Nothing is seeding"
        case .paused: "Nothing is paused"
        case .queued: "Nothing is queued"
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
    /// Selection, filter, sort and inspector state, shared with the main menu:
    /// commands are built outside the view tree and cannot reach `@State`.
    @Environment(ListState.self) private var listState
    @Environment(\.openWindow) private var openWindow
    @State private var showingFileImporter = false
    @State private var showingMagnetSheet = false
    @State private var magnetText = ""
    /// The row under the pointer, whose ring shows its pause/resume control.
    @State private var hoveredRow: InfoHash?
    /// Bumped once after launch to re-create toolbar buttons (see workaround).
    @State private var toolbarRefresh = 0
    /// Driven by Edit ▸ Find ▸ Filter by Name.
    @FocusState private var searchFocused: Bool

    /// Snapshots after search + status filter + column sort. In queue order
    /// the engine's own ordering passes through untouched.
    private var displayedSnapshots: [TorrentSnapshot] {
        var rows = store.snapshots.filter { listState.statusFilter.matches($0) }
        if !listState.searchText.isEmpty {
            rows = rows.filter { $0.name.localizedCaseInsensitiveContains(listState.searchText) }
        }
        if !listState.isQueueOrdered {
            rows.sort(using: listState.sortComparators)
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
        // A shape style, not `.toolbarBackground`: the view that modifier
        // inserts sits over the titlebar and swallows the mouse-down that drags
        // the window, whereas a shape style hit-tests nothing. The titlebar
        // itself is painted by the overlay further down.
        .background(Surface.panel)
        .background(alignment: .topLeading) { WindowChrome().frame(width: 0, height: 0) }
        .toolbar { toolbarContent }
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
        .inspector(isPresented: bind(\.showInspector)) {
            InspectorPane(selection: listState.selection, tab: bind(\.inspectorTab))
                .environment(store)
                .inspectorColumnWidth(min: 360, ideal: 480, max: 800)
        }
        // Below the inspector split, not inside it, so the bar runs the full
        // width of the window the way the design draws it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !store.snapshots.isEmpty {
                statusBar
            }
        }
        // The titlebar, painted last so it covers the split: the inspector's
        // divider runs the full height of the window, and the titlebar is
        // transparent, so without this the divider carries on up through the
        // toolbar. Hit-tests nothing, which is what leaves the titlebar
        // draggable, and sits under the toolbar's own controls, which AppKit
        // draws above the content.
        .overlay {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    Surface.chrome
                        .frame(height: proxy.safeAreaInsets.top)
                        .overlay(alignment: .bottom) { SurfaceSeparator() }
                    Color.clear
                }
                .ignoresSafeArea()
            }
            .allowsHitTesting(false)
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
        .onChange(of: listState.focusSearchRequest) { searchFocused = true }
        .onAppear {
            // The menu bar sets the request before opening this window, so a
            // change notification alone would miss it.
            consumeSettingsRequest()
            consumeMagnetRequest()
        }
        .confirmationDialog(
            removalTitle,
            isPresented: .init(
                get: { !listState.pendingRemoval.isEmpty },
                set: { if !$0 { listState.pendingRemoval = [] } }
            )
        ) {
            // Arriving by File ▸ Remove and Trash Data asks a narrower
            // question, so it gets the narrower dialog rather than re-offering
            // the choice the user already made in the menu.
            if !listState.removalTrashesData {
                Button("Remove", role: .destructive) { confirmRemoval(deleteFiles: false) }
            }
            Button("Remove and Trash Data", role: .destructive) {
                confirmRemoval(deleteFiles: true)
            }
            Button("Cancel", role: .cancel) { listState.pendingRemoval = [] }
        } message: {
            Text(listState.removalTrashesData
                ? "The torrent will stop, be forgotten, and its downloaded files will be moved to the Trash."
                : "The torrent will stop and be forgotten. “Remove and Trash Data” also deletes the downloaded files.")
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

    /// A binding into the shared list state. `@Bindable` reaches only as far as
    /// the body it is declared in, and this view is spread over a dozen
    /// computed properties that each need one.
    private func bind<Value>(
        _ keyPath: ReferenceWritableKeyPath<ListState, Value>
    ) -> Binding<Value> {
        Binding(
            get: { listState[keyPath: keyPath] },
            set: { listState[keyPath: keyPath] = $0 }
        )
    }

    private func confirmRemoval(deleteFiles: Bool) {
        for snapshot in listState.pendingRemoval {
            store.remove(snapshot.infoHash, deleteFiles: deleteFiles)
        }
        listState.pendingRemoval = []
    }

    private func consumeSettingsRequest() {
        guard let hash = store.settingsRequest else { return }
        store.settingsRequest = nil
        listState.showSettings(for: hash)
    }

    private func consumeMagnetRequest() {
        guard store.magnetRequest else { return }
        store.magnetRequest = false
        showingMagnetSheet = true
    }

    private var removalTitle: String {
        listState.pendingRemoval.count == 1
            ? "Remove “\(listState.pendingRemoval[0].name)”?"
            : "Remove \(listState.pendingRemoval.count) torrents?"
    }

    // MARK: - Hero tiles

    private var activeCount: Int {
        store.snapshots.count { $0.state == .downloading || $0.state == .seeding }
    }

    private var canPauseAll: Bool {
        store.snapshots.contains { $0.state == .downloading || $0.state == .seeding || $0.state == .queued }
    }

    private var canResumeAll: Bool {
        store.snapshots.contains { $0.state == .paused }
    }

    private var heroTiles: some View {
        HStack(spacing: 10) {
            AllDownloadsTile(
                canPause: canPauseAll, canResume: canResumeAll,
                pause: { store.pauseAll() }, resume: { store.resumeAll() }
            )
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
            // Capped: the two counters stop earning width long before the
            // graphs do, so a wide window grows the sparklines instead.
            StatTile(
                title: "Active", icon: "list.bullet",
                value: "\(activeCount)", unit: "of \(store.snapshots.count)",
                caption: activeCaption, height: Surface.windowTileHeight,
                maxWidth: Surface.statTileMaxWidth
            )
            StatTile(
                title: "This session", icon: "clock",
                value: session.value, unit: session.unit, caption: session.caption,
                height: Surface.windowTileHeight, maxWidth: Surface.statTileMaxWidth
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
        /// "100%" plus the header's sort chevron.
        static let percent: CGFloat = 50
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
        /// Enough for a title, a line of explanation and a button, with the
        /// breathing room an empty card wants.
        static let emptyStateHeight: CGFloat = 168
        static let headerHeight: CGFloat = 25.5
        static let ring: CGFloat = 24
        static let ringGap: CGFloat = 10
    }

    private var torrentCard: some View {
        VStack(spacing: 0) {
            tableHeader
            SurfaceSeparator()
            if displayedSnapshots.isEmpty {
                // Inside the card, under the header — as an overlay it landed
                // on top of the column titles and was squeezed into one row's
                // worth of height.
                emptyState
            } else {
                table
            }
        }
        .background(Surface.fill)
        .clipShape(.rect(cornerRadius: Surface.corner))
        // Hugs its rows rather than filling the window, as the design draws
        // it; a longer list is still capped by whatever height is available.
        .frame(maxHeight: Col.headerHeight + 0.5 + cardBodyHeight)
    }

    private var cardBodyHeight: CGFloat {
        displayedSnapshots.isEmpty
            ? Col.emptyStateHeight
            : CGFloat(displayedSnapshots.count) * Col.rowHeight
    }

    /// Why the list is empty, in the terms the user just used: a filter, a
    /// search, or both.
    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(listState.searchText.isEmpty ? listState.statusFilter.emptyTitle : "No matches")
                .font(.system(size: 13, weight: .medium))
            Text(emptyDetail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !listState.searchText.isEmpty || listState.statusFilter != .all {
                SurfaceButton(title: "Show All") {
                    listState.searchText = ""
                    listState.statusFilter = .all
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDetail: String {
        let filter = listState.statusFilter
        if !listState.searchText.isEmpty {
            return filter == .all
                ? "No torrent's name contains “\(listState.searchText)”."
                : "No \(filter.rawValue.lowercased()) torrent's name contains “\(listState.searchText)”."
        }
        return "Torrents appear here as soon as one is \(filter.rawValue.lowercased())."
    }

    /// Our own header, because `TableColumn` takes a title string and offers no
    /// way to style it. `Table` never sorted anything anyway — `displayedSnapshots`
    /// does that — so owning the header only costs column resizing.
    private var tableHeader: some View {
        HStack(spacing: Col.spacing) {
            sortHeader(.queue, width: Col.number, alignment: .leading)
            sortHeader(.name, width: nil, alignment: .leading)
            sortHeader(.percent, width: Col.percent)
            sortHeader(.size, width: Col.size)
            sortHeader(.downloadRate, width: Col.rate)
            sortHeader(.uploadRate, width: Col.rate)
            sortHeader(.eta, width: Col.eta)
            sortHeader(.ratio, width: Col.ratio)
        }
        .padding(.horizontal, Col.inset)
        .frame(height: Col.headerHeight)
    }

    @ViewBuilder
    private func sortHeader(
        _ field: SortField,
        width: CGFloat?,
        alignment: Alignment = .trailing
    ) -> some View {
        let isActive = listState.sortField == field
        let label = Button {
            if isActive {
                listState.sortAscending.toggle()
            } else {
                listState.sortField = field
                listState.sortAscending = true
            }
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(field.columnTitle.uppercased())
                    .font(.system(size: 9.5, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if isActive {
                    Image(systemName: listState.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Sort by \(field.menuTitle)")

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
        List(selection: bind(\.selection)) {
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
        let isSelected = listState.selection.contains(snapshot.infoHash)
        let isHovered = hoveredRow == snapshot.infoHash
        return HStack(spacing: Col.spacing) {
            Text("\(snapshot.queuePosition)")
                .foregroundStyle(.secondary)
                .frame(width: Col.number, alignment: .leading)

            // The ring carries the state the Status column used to spell out:
            // tint for which state, glyph for which action, arc for progress.
            HStack(spacing: Col.ringGap) {
                // The ring is the row's pause/resume control, as it is in the
                // popup: it swaps its readout for the action under the pointer.
                ProgressRing(
                    snapshot: snapshot, diameter: Col.ring, showsPercent: false,
                    showsControl: isHovered
                ) {
                    if snapshot.state == .paused {
                        store.resume(snapshot.infoHash)
                    } else {
                        store.pause(snapshot.infoHash)
                    }
                }
                Text(snapshot.name)
                    .lineLimit(1)
                    .foregroundStyle(
                        snapshot.state == .paused
                            ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(statusText(snapshot))

            // Always the download's own completeness, even while the ring is
            // tracking a check or a move: those are jobs the torrent is having
            // done to it, not progress toward having the data.
            Text(snapshot.totalLength > 0 ? percent(snapshot) : "—")
                .foregroundStyle(snapshot.isComplete
                    ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                .frame(width: Col.percent, alignment: .trailing)

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
        .onHover { hovering in
            if hovering {
                hoveredRow = snapshot.infoHash
            } else if hoveredRow == snapshot.infoHash {
                hoveredRow = nil
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            filterPills

            if !listState.isQueueOrdered {
                Button("Queue Order") {
                    listState.sortField = .queue
                    listState.sortAscending = true
                }
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
        // Opaque, and its own colour: the bar has to hide the inspector's
        // divider, which is drawn down the full height of the window behind it.
        .background(Surface.chrome)
        .overlay(alignment: .top) { SurfaceSeparator() }
    }

    /// The status filter as pills with live counts. As a menu it was a setting
    /// nobody found; as counts it doubles as a summary of the session.
    private var filterPills: some View {
        HStack(spacing: 5) {
            ForEach(StatusFilter.allCases) { filter in
                let count = store.snapshots.count { filter.matches($0) }
                let isOn = listState.statusFilter == filter
                Button {
                    listState.statusFilter = filter
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
                        Capsule().fill(isOn ? AnyShapeStyle(Surface.prominent) : AnyShapeStyle(Surface.controlFill))
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
        if snapshot.state == .checking, snapshot.checkProgress > 0 {
            // Still checking, so never 100 — same reason as the download readout.
            let text = percentText(snapshot.checkProgress, complete: false)
            return "\(snapshot.state.displayName) · \(text)"
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
                Button("Settings…") { listState.showSettings(for: selected[0].infoHash) }
            }
            // Reordering is only meaningful in the queue-priority order.
            if selected.count == 1, listState.isQueueOrdered,
               listState.searchText.isEmpty, listState.statusFilter == .all {
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
            Button("Remove…", role: .destructive) { listState.requestRemoval(of: selected) }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // One item, not seven: the design's toolbar is a row of flat fills, and
        // macOS re-skins each item it owns (a menu's label loses its background,
        // a button gains a bezel). Owning the whole row keeps it on-palette.
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 10) {
                searchField

                Menu {
                    Button("Add .torrent…") { showingFileImporter = true }
                    Button("Add Magnet Link…") { showingMagnetSheet = true }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                        Text("Add").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 24)
                // The same fill the action buttons carry while they are
                // clickable, so the whole row reads as one set of controls.
                .background(Surface.controlFill, in: .rect(cornerRadius: Surface.corner - 2))
                .help("Add a torrent file or magnet link")

                toolbarButton("pause.fill", "Pause the selected torrents",
                              enabled: selectedSnapshots.contains { $0.state == .downloading || $0.state == .seeding || $0.state == .queued }) {
                    selectedSnapshots.forEach { store.pause($0.infoHash) }
                }
                toolbarButton("play.fill", "Resume the selected torrents",
                              enabled: selectedSnapshots.contains { $0.state == .paused }) {
                    selectedSnapshots.forEach { store.resume($0.infoHash) }
                }
                toolbarButton("folder", "Show the downloaded files in Finder",
                              enabled: !listState.selection.isEmpty) {
                    selectedSnapshots.forEach { store.revealInFinder($0.infoHash) }
                }
                toolbarButton("trash", "Remove selected",
                              enabled: !listState.selection.isEmpty) {
                    listState.requestRemoval(of: selectedSnapshots)
                }
                toolbarButton("sidebar.trailing", "Show peers, trackers, and files for the selected torrent",
                              enabled: true) {
                    listState.showInspector.toggle()
                }
            }
            .id(toolbarRefresh)
        }
    }

    /// The design fills a toolbar button's background only while it can be
    /// pressed, which is what makes a disabled control read as disabled here.
    private func toolbarButton(
        _ icon: String, _ help: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 26, height: 24)
                .background {
                    if enabled {
                        RoundedRectangle(cornerRadius: Surface.corner - 2).fill(Surface.controlFill)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    /// The name filter. `NSSearchField` brings the system's bright bezel with
    /// it, so this is the app's own field: same shape and fill as everything
    /// else on the panel.
    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Filter by name", text: bind(\.searchText))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !listState.searchText.isEmpty {
                Button { listState.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear the filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 178, height: 24)
        .background(Surface.controlFill, in: .rect(cornerRadius: Surface.corner))
    }

    private var selectedSnapshots: [TorrentSnapshot] {
        store.snapshots.filter { listState.selection.contains($0.infoHash) }
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

/// Clears the system's toolbar material so the window's own painting shows
/// through the titlebar, and tints the window itself for the moments SwiftUI is
/// not drawing it (live resize, before first layout).
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    /// Carries no pixels and must catch no clicks — it exists only to reach the
    /// window it is installed in.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func updateNSView(_ view: NSView, context: Context) {
        configure(view.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Surface.chromeColor
    }
}

/// The hero row's one tile of controls: the same card, height and label as the
/// readouts beside it, with buttons where they put a number.
///
/// It earns its place in this row rather than the toolbar because it is
/// session-wide — the toolbar's pause and play act on the selection, and two
/// pairs of identical glyphs meaning different things would not read.
private struct AllDownloadsTile: View {
    let canPause: Bool
    let canResume: Bool
    let pause: () -> Void
    let resume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TileLabel(title: "All downloads")
            HStack(spacing: 6) {
                button("Pause", icon: "pause.fill", enabled: canPause, action: pause)
                button("Resume", icon: "play.fill", enabled: canResume, action: resume)
            }
        }
        .padding(.horizontal, 11)
        .padding(.top, 9.5)
        .frame(height: Surface.windowTileHeight, alignment: .topLeading)
        // Fixed: buttons gain nothing from a wider window, so the rate tiles
        // take that width instead.
        .frame(width: 176, alignment: .leading)
        .background(Surface.fill, in: .rect(cornerRadius: Surface.corner))
    }

    private func button(
        _ title: String, icon: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Capsule().fill(Surface.hover))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
        .help(enabled
            ? "\(title) every torrent"
            : "Nothing to \(title.lowercased())")
    }
}

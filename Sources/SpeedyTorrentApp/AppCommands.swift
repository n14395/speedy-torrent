import SwiftUI
import UniformTypeIdentifiers
import TorrentEngine

/// The app's main menu.
///
/// Each group's content is its own `View` rather than being written inline
/// here: a view's body is where SwiftUI installs observation tracking, so
/// putting the items in one is what keeps "Pause" greying itself out as the
/// selection changes. Written straight into `Commands`, the items would be
/// evaluated once and then sit there stale.
struct TorrentCommands: Commands {
    let store: SessionStore
    let listState: ListState

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            AppMenuItems(store: store)
        }
        // The group that would hold "New"; for a single-window app it is empty,
        // and replacing it puts the Open items at the top of File where they
        // belong.
        CommandGroup(replacing: .newItem) {
            FileMenuItems(store: store, listState: listState)
        }
        CommandGroup(after: .pasteboard) {
            EditMenuItems(store: store, listState: listState)
        }
        CommandMenu("Torrent") {
            TorrentMenuItems(store: store, listState: listState)
        }
        CommandGroup(after: .sidebar) {
            ViewMenuItems(listState: listState)
        }
        // The stock item opens a help book this app does not ship, so it can
        // only ever fail. Emptying the group leaves a Help menu with nothing
        // in it, which `AppDelegate` then removes outright.
        CommandGroup(replacing: .help) {}
    }
}

/// The Window menu's two entries, with keys on them.
///
/// Declared on the *Statistics* scene, not the main one. SwiftUI adds a Window
/// menu item per `Window` scene, and replacing `.singleWindowList` only
/// suppresses the auto item belonging to the scene the replacement is attached
/// to — declared on the main window instead, this list appears correctly but a
/// second, keyless "Statistics" appears beside it.
struct WindowCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .singleWindowList) {
            WindowMenuItems()
        }
    }
}

// MARK: - Shared helpers

/// Torrents the menu acts on: whatever is selected in the list.
@MainActor
private func selectedSnapshots(_ store: SessionStore, _ listState: ListState) -> [TorrentSnapshot] {
    store.snapshots.filter { listState.selection.contains($0.infoHash) }
}

/// Brings the torrent list up, opening it if "keep running in the menu bar"
/// left the app with no window at all.
@MainActor
private func openMain(_ openWindow: OpenWindowAction) {
    openWindow(id: "main")
    NSApplication.shared.activate()
}

// MARK: - SpeedyTorrent

private struct AppMenuItems: View {
    let store: SessionStore

    var body: some View {
        Divider()
        Button("Make SpeedyTorrent the Default Torrent App") {
            store.makeDefaultHandler()
        }
        .disabled(store.isDefaultHandler)
    }
}

// MARK: - File

private struct FileMenuItems: View {
    let store: SessionStore
    let listState: ListState
    @Environment(\.openWindow) private var openWindow

    private var selected: [TorrentSnapshot] { selectedSnapshots(store, listState) }

    var body: some View {
        Button("Open Torrent File…") { openTorrentFiles() }
            .keyboardShortcut("o")
        Button("Open Magnet Link…") {
            store.requestMagnetSheet()
            openMain(openWindow)
        }
        .keyboardShortcut("l")
        Menu("Open Recent") {
            ForEach(store.recentTorrents, id: \.self) { url in
                Button(url.lastPathComponent) { store.addTorrentFile(at: url) }
            }
            if !store.recentTorrents.isEmpty { Divider() }
            Button("Clear Menu") { store.clearRecentTorrents() }
                .disabled(store.recentTorrents.isEmpty)
        }
        Divider()
        Button("Show in Finder") {
            selected.forEach { store.revealInFinder($0.infoHash) }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(selected.isEmpty)
        Divider()
        Button("Remove…") {
            listState.requestRemoval(of: selected)
            openMain(openWindow)
        }
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(selected.isEmpty)
        Button("Remove and Trash Data…") {
            listState.requestRemoval(of: selected, trashingData: true)
            openMain(openWindow)
        }
        .keyboardShortcut(.delete, modifiers: [.command, .shift])
        .disabled(selected.isEmpty)
        // No trailing Divider: the group boundary contributes its own, and two
        // adjacent separators is what that looks like in the menu.
    }

    /// AppKit's panel rather than `.fileImporter`, which needs a view to hang
    /// off — and a menu item has none.
    private func openTorrentFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose torrent files to add."
        NSApplication.shared.activate()
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { store.addTorrentFile(at: $0) }
    }
}

// MARK: - Edit

private struct EditMenuItems: View {
    let store: SessionStore
    @Bindable var listState: ListState
    @Environment(\.openWindow) private var openWindow

    private var selected: [TorrentSnapshot] { selectedSnapshots(store, listState) }

    var body: some View {
        Divider()
        Button("Copy Magnet Link") {
            store.copyMagnetLinks(for: selected.map(\.infoHash))
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(selected.isEmpty)
        Button("Copy Info Hash") {
            store.copyInfoHashes(for: selected.map(\.infoHash))
        }
        .disabled(selected.isEmpty)
        Divider()
        // No "Select All" to match: a menu item would take ⌘A away from the
        // search field and every other text field in the app. The list already
        // handles ⌘A itself while it has focus.
        Button("Deselect All") { listState.selection = [] }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(listState.selection.isEmpty)
        Menu("Find") {
            Button("Filter by Name") {
                openMain(openWindow)
                listState.focusSearchRequest += 1
            }
            .keyboardShortcut("f")
            Button("Clear Filter") { listState.searchText = "" }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(listState.searchText.isEmpty)
        }
    }
}

// MARK: - Torrent

private struct TorrentMenuItems: View {
    let store: SessionStore
    let listState: ListState
    @Environment(\.openWindow) private var openWindow

    private var selected: [TorrentSnapshot] { selectedSnapshots(store, listState) }
    private var single: TorrentSnapshot? { selected.count == 1 ? selected[0] : nil }

    private var canResume: Bool { selected.contains { $0.state == .paused } }
    private var canPause: Bool {
        selected.contains { $0.state == .downloading || $0.state == .seeding || $0.state == .queued }
    }

    var body: some View {
        Button("Resume") { selected.forEach { store.resume($0.infoHash) } }
            .keyboardShortcut("r")
            .disabled(!canResume)
        Button("Pause") { selected.forEach { store.pause($0.infoHash) } }
            .keyboardShortcut("p")
            .disabled(!canPause)
        Divider()
        Button("Resume All") { store.resumeAll() }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!store.snapshots.contains { $0.state == .paused })
        Button("Pause All") { store.pauseAll() }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!store.snapshots.contains {
                $0.state == .downloading || $0.state == .seeding || $0.state == .queued
            })
        Divider()
        Button("Verify Local Data") { selected.forEach { store.recheck($0.infoHash) } }
            .keyboardShortcut("y")
            .disabled(selected.isEmpty)
        Toggle("Sequential Download", isOn: Binding(
            get: { !selected.isEmpty && selected.allSatisfy(\.sequential) },
            set: { on in selected.forEach { store.setSequential(on, for: $0.infoHash) } }
        ))
        .disabled(selected.isEmpty)
        Divider()
        Button("Change Download Location…") {
            if let single { store.chooseDownloadLocation(for: single.infoHash) }
        }
        .disabled(single == nil)
        Button("Torrent Settings…") {
            if let single {
                openMain(openWindow)
                listState.showSettings(for: single.infoHash)
            }
        }
        .disabled(single == nil)
        Divider()
        moveMenu
    }

    /// Reordering only means something in queue order over the whole list —
    /// the same rule the row's context menu follows.
    private var canReorder: Bool {
        single != nil && listState.isQueueOrdered
            && listState.searchText.isEmpty && listState.statusFilter == .all
    }

    private var queueIndex: Int? {
        guard let single else { return nil }
        return store.snapshots.firstIndex { $0.infoHash == single.infoHash }
    }

    private var moveMenu: some View {
        Menu("Move") {
            moveItem("To Top", .top, key: .upArrow, modifiers: [.command, .shift],
                     enabled: queueIndex != 0)
            moveItem("Up", .up, key: .upArrow, modifiers: .command, enabled: queueIndex != 0)
            moveItem("Down", .down, key: .downArrow, modifiers: .command,
                     enabled: queueIndex != store.snapshots.count - 1)
            moveItem("To Bottom", .bottom, key: .downArrow, modifiers: [.command, .shift],
                     enabled: queueIndex != store.snapshots.count - 1)
        }
        .disabled(!canReorder)
    }

    private func moveItem(
        _ title: String,
        _ direction: TorrentSession.QueueMove,
        key: KeyEquivalent,
        modifiers: EventModifiers,
        enabled: Bool
    ) -> some View {
        Button(title) {
            if let single { store.move(single.infoHash, direction) }
        }
        .keyboardShortcut(key, modifiers: modifiers)
        .disabled(!canReorder || !enabled)
    }
}

// MARK: - View

private struct ViewMenuItems: View {
    @Bindable var listState: ListState

    var body: some View {
        Button(listState.showInspector ? "Hide Inspector" : "Show Inspector") {
            listState.showInspector.toggle()
        }
        .keyboardShortcut("i")
        Menu("Inspector") {
            ForEach(TorrentDetailTab.allCases) { tab in
                Toggle(tab.rawValue, isOn: Binding(
                    get: { listState.inspectorTab == tab },
                    set: { on in
                        guard on else { return }
                        listState.inspectorTab = tab
                        listState.showInspector = true
                    }
                ))
            }
        }
        Divider()
        Menu("Filter") {
            // ⌘1…⌘5 in the order the status bar's pills run, so the two agree.
            ForEach(Array(StatusFilter.allCases.enumerated()), id: \.element.id) { index, filter in
                Toggle(filter.rawValue, isOn: Binding(
                    get: { listState.statusFilter == filter },
                    set: { if $0 { listState.statusFilter = filter } }
                ))
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        Menu("Sort By") {
            ForEach(SortField.allCases) { field in
                Toggle(field.menuTitle, isOn: Binding(
                    get: { listState.sortField == field },
                    set: { on in
                        guard on else { return }
                        listState.sortField = field
                        listState.sortAscending = true
                    }
                ))
            }
            Divider()
            Toggle("Ascending", isOn: Binding(
                get: { listState.sortAscending },
                set: { if $0 { listState.sortAscending = true } }
            ))
            Toggle("Descending", isOn: Binding(
                get: { !listState.sortAscending },
                set: { if $0 { listState.sortAscending = false } }
            ))
        }
    }
}

// MARK: - Window

private struct WindowMenuItems: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Main Window") { openMain(openWindow) }
            .keyboardShortcut("0")
        Button("Statistics") { openWindow(id: "stats") }
            .keyboardShortcut("s", modifiers: [.command, .option])
    }
}

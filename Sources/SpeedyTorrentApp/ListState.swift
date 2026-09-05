import SwiftUI
import TorrentEngine

/// A column the torrent list can be ordered by.
///
/// The table header and the View ▸ Sort By menu are two faces of one setting,
/// so the order is named here once rather than each of them holding key paths
/// of its own and hoping they agree.
enum SortField: String, CaseIterable, Identifiable {
    case queue, name, percent, size, downloadRate, uploadRate, eta, ratio

    var id: String { rawValue }

    /// The column header's label, which has one word's worth of room.
    var columnTitle: String {
        switch self {
        case .queue: "#"
        case .name: "Name"
        case .percent: "%"
        case .size: "Size"
        case .downloadRate: "Down"
        case .uploadRate: "Up"
        case .eta: "ETA"
        case .ratio: "Ratio"
        }
    }

    /// The menu's label, which has room to say what the column means.
    var menuTitle: String {
        switch self {
        case .queue: "Queue Order"
        case .name: "Name"
        case .percent: "Percent Complete"
        case .size: "Size"
        case .downloadRate: "Download Rate"
        case .uploadRate: "Upload Rate"
        case .eta: "Time Remaining"
        case .ratio: "Ratio"
        }
    }

    func comparators(ascending: Bool) -> [KeyPathComparator<TorrentSnapshot>] {
        let order: SortOrder = ascending ? .forward : .reverse
        return switch self {
        case .queue: [KeyPathComparator(\.queuePosition, order: order)]
        case .name: [KeyPathComparator(\.name, order: order)]
        case .percent: [KeyPathComparator(\.progress, order: order)]
        case .size: [KeyPathComparator(\.totalLength, order: order)]
        case .downloadRate: [KeyPathComparator(\.downloadRate, order: order)]
        case .uploadRate: [KeyPathComparator(\.uploadRate, order: order)]
        case .eta: [KeyPathComparator(\.etaSortKey, order: order)]
        case .ratio: [KeyPathComparator(\.ratio, order: order)]
        }
    }
}

/// The state of the torrent list that the main menu also acts on.
///
/// Menu commands are built in the `App` scene, outside the view tree, so they
/// cannot reach `TorrentListView`'s own `@State`. Everything a menu item reads
/// or writes — the selection, the filter, the sort, the inspector — lives here
/// instead, owned by the app and handed to both.
@MainActor @Observable
final class ListState {
    var selection: Set<InfoHash> = []
    var searchText = ""
    var statusFilter: StatusFilter = .all
    var sortField: SortField = .queue
    var sortAscending = true
    var showInspector = false
    var inspectorTab: TorrentDetailTab = .files

    /// Torrents waiting on the removal confirmation, and whether the user came
    /// in by the trash-the-data door — which asks a narrower question than the
    /// general "Remove…" does.
    var pendingRemoval: [TorrentSnapshot] = []
    var removalTrashesData = false

    /// Bumped by Edit ▸ Find; the list moves keyboard focus to its filter field
    /// whenever it changes. A counter rather than a flag, so a second ⌘F with
    /// the field already focused still registers as a request.
    var focusSearchRequest = 0

    /// True while the list shows the engine's queue order — the default "#"
    /// ascending — the only mode where the rows can be reordered.
    var isQueueOrdered: Bool { sortField == .queue && sortAscending }

    var sortComparators: [KeyPathComparator<TorrentSnapshot>] {
        sortField.comparators(ascending: sortAscending)
    }

    /// Puts a torrent's settings on screen: the one place per-torrent settings
    /// live now is the inspector's Files tab.
    func showSettings(for infoHash: InfoHash) {
        selection = [infoHash]
        inspectorTab = .files
        showInspector = true
    }

    func requestRemoval(of torrents: [TorrentSnapshot], trashingData: Bool = false) {
        guard !torrents.isEmpty else { return }
        removalTrashesData = trashingData
        pendingRemoval = torrents
    }
}

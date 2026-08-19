import SwiftUI
import TorrentEngine

/// One file of a torrent, from either an added torrent (`TorrentFileStatus`)
/// or one the user has opened but not confirmed yet (`FileEntry` offsets).
struct FileRow: Identifiable, Equatable {
    var id: Int { index }
    let index: Int
    let path: [String]
    let length: Int64
    /// Verified bytes on disk, or nil when the torrent isn't added yet.
    let completedLength: Int64?
    /// The engine's current selection, used when the tree is read-only.
    var wanted = true
}

extension Array where Element == TorrentFileStatus {
    /// Engine-authoritative rows, carrying download progress.
    var fileRows: [FileRow] {
        map {
            FileRow(
                index: $0.index, path: $0.path, length: $0.length,
                completedLength: $0.completedLength, wanted: $0.wanted
            )
        }
    }
}

/// The torrent's file hierarchy rebuilt from its flat path list.
struct TorrentFileNode: Identifiable {
    let id: String
    let name: String
    /// Set for leaves; directories have children instead.
    let fileIndex: Int?
    let length: Int64
    /// All file indices under this node (itself for a leaf). Precomputed
    /// during `build` — it is read per row, per render, at 1 Hz.
    let descendantIndices: Set<Int>
    var children: [TorrentFileNode]?

    static func build(from files: [(index: Int, path: [String], length: Int64)]) -> [TorrentFileNode] {
        buildLevel(files.map { ($0.index, $0.path, $0.length) }, prefix: "")
    }

    static func build(from rows: [FileRow]) -> [TorrentFileNode] {
        buildLevel(rows.map { ($0.index, $0.path, $0.length) }, prefix: "")
    }

    private static func buildLevel(
        _ entries: [(index: Int, path: [String], length: Int64)], prefix: String
    ) -> [TorrentFileNode] {
        var leaves: [TorrentFileNode] = []
        var groups: [String: [(index: Int, path: [String], length: Int64)]] = [:]
        var groupOrder: [String] = []

        for entry in entries {
            if entry.path.count == 1 {
                leaves.append(TorrentFileNode(
                    id: prefix + entry.path[0],
                    name: entry.path[0],
                    fileIndex: entry.index,
                    length: entry.length,
                    descendantIndices: [entry.index],
                    children: nil
                ))
            } else {
                let head = entry.path[0]
                if groups[head] == nil { groupOrder.append(head) }
                groups[head, default: []].append((entry.index, Array(entry.path.dropFirst()), entry.length))
            }
        }

        let directories = groupOrder.map { name -> TorrentFileNode in
            let children = buildLevel(groups[name]!, prefix: prefix + name + "/")
            return TorrentFileNode(
                id: prefix + name,
                name: name,
                fileIndex: nil,
                length: children.reduce(0) { $0 + $1.length },
                descendantIndices: children.reduce(into: []) { $0.formUnion($1.descendantIndices) },
                children: children
            )
        }
        return (directories + leaves).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// A native checkbox that can show the indeterminate (dash) state for
/// partially selected folders — SwiftUI's Toggle cannot.
struct TriStateCheckbox: NSViewRepresentable {
    enum CheckState {
        case off, mixed, on
    }

    let state: CheckState
    let enabled: Bool
    /// Called with the desired selection: true = select all, false = deselect.
    let onToggle: (Bool) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked(_:))
        )
        button.allowsMixedState = true
        button.controlSize = .small
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.state = switch state {
        case .off: .off
        case .mixed: .mixed
        case .on: .on
        }
        button.isEnabled = enabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject {
        var parent: TriStateCheckbox

        init(_ parent: TriStateCheckbox) {
            self.parent = parent
        }

        @objc func clicked(_ sender: NSButton) {
            // Clicking off/mixed selects everything; clicking on deselects.
            // Don't let AppKit's own click cycle land on .mixed.
            let selectAll = parent.state != .on
            sender.state = selectAll ? .on : .off
            parent.onToggle(selectAll)
        }
    }
}

/// The torrent's files as a tree: per-file download progress, and — when a
/// selection binding is supplied — checkboxes choosing what to download.
/// Directories toggle all of their descendants (showing a dash when partially
/// selected); the last selected file cannot be deselected. Sortable by name or
/// size.
struct TorrentFileTree: View {
    let rows: [FileRow]
    /// nil renders a read-only tree.
    var selection: Binding<Set<Int>>?

    /// Remembered across sheets and launches.
    @AppStorage("fileTreeSortBySize") private var sortBySize = false
    /// Rebuilt only when the file *shape* changes, not when progress ticks.
    @State private var nodes: [TorrentFileNode] = []
    @State private var builtShape: [Int] = []

    private var showsProgress: Bool {
        rows.contains { $0.completedLength != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            List {
                OutlineGroup(displayNodes, children: \.children) { node in
                    row(node, aggregate: aggregates[node.id] ?? .empty)
                        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                        .listRowSeparator(.hidden)
                }
            }
            // Plain, not `.bordered`: the caller wraps this in a card, and the
            // bordered style drew a second box inside it.
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .padding(.leading, -Surface.listLeadingBleed)
            .padding(.trailing, -Surface.listTrailingBleed)
            .frame(maxHeight: .infinity)
        }
        .onAppear { rebuildIfNeeded() }
        .onChange(of: rows.map(\.index)) { rebuildIfNeeded() }
    }

    /// A summary line, not a control strip: what the pane is showing, in the
    /// same uppercase key the tiles and table header use. Sorting and
    /// select-all stay reachable as quiet trailing controls rather than the
    /// segmented picker that used to lead the card.
    private var header: some View {
        HStack(spacing: 8) {
            Text(summary)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if selection != nil {
                Button(sortBySize ? "SIZE" : "NAME") { sortBySize.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                    .help("Order the file tree by name or by size")
                Button("ALL") { selection?.wrappedValue = allIndices }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(wanted == allIndices ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Surface.prominent))
                    .disabled(wanted == allIndices)
                    .help("Select every file")
            }
        }
    }

    /// "4 FILES · 3.5 GB SELECTED".
    private var summary: String {
        let selected = wanted
        let bytes = rows.filter { selected.contains($0.index) }.reduce(Int64(0)) { $0 + $1.length }
        let count = "\(rows.count) FILE" + (rows.count == 1 ? "" : "S")
        return "\(count) · \(formatBytes(bytes).uppercased()) SELECTED"
    }

    // MARK: - Data

    /// The editable selection when there is one, otherwise whatever the engine
    /// currently wants.
    private var wanted: Set<Int> {
        selection?.wrappedValue ?? Set(rows.filter(\.wanted).map(\.index))
    }

    private var allIndices: Set<Int> {
        Set(rows.map(\.index))
    }

    private func rebuildIfNeeded() {
        let shape = rows.map(\.index)
        guard shape != builtShape || nodes.isEmpty else { return }
        nodes = TorrentFileNode.build(from: rows)
        builtShape = shape
    }

    private var displayNodes: [TorrentFileNode] {
        sortBySize ? Self.sortedBySize(nodes) : nodes
    }

    /// Largest first at every level (the build order is already by name).
    private static func sortedBySize(_ nodes: [TorrentFileNode]) -> [TorrentFileNode] {
        nodes
            .map { node in
                var copy = node
                if let children = node.children {
                    copy.children = sortedBySize(children)
                }
                return copy
            }
            .sorted {
                $0.length != $1.length
                    ? $0.length > $1.length
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    /// Per-node rollups, computed in one pass instead of rescanning every file
    /// for every row.
    struct Aggregate {
        var selectedCount = 0
        var fileCount = 0
        var wantedLength: Int64 = 0
        var wantedDone: Int64 = 0
        var totalLength: Int64 = 0
        var totalDone: Int64 = 0

        static let empty = Aggregate()

        /// Progress over wanted bytes when anything is wanted; otherwise raw
        /// completion, so a partly downloaded skipped file still shows a bar.
        var progress: Double {
            if wantedLength > 0 { return Double(wantedDone) / Double(wantedLength) }
            if selectedCount > 0 { return 1 } // wanted zero-byte files are complete
            return totalLength > 0 ? Double(totalDone) / Double(totalLength) : 1
        }

        var skipped: Bool { selectedCount == 0 }
    }

    private var aggregates: [String: Aggregate] {
        var result: [String: Aggregate] = [:]
        let byIndex = Dictionary(uniqueKeysWithValues: rows.map { ($0.index, $0) })
        let selected = wanted

        @discardableResult
        func walk(_ node: TorrentFileNode) -> Aggregate {
            var aggregate = Aggregate()
            if let fileIndex = node.fileIndex {
                guard let row = byIndex[fileIndex] else { return aggregate }
                let done = row.completedLength ?? 0
                aggregate.fileCount = 1
                aggregate.totalLength = row.length
                aggregate.totalDone = done
                if selected.contains(fileIndex) {
                    aggregate.selectedCount = 1
                    aggregate.wantedLength = row.length
                    aggregate.wantedDone = done
                }
            } else {
                for child in node.children ?? [] {
                    let sub = walk(child)
                    aggregate.selectedCount += sub.selectedCount
                    aggregate.fileCount += sub.fileCount
                    aggregate.wantedLength += sub.wantedLength
                    aggregate.wantedDone += sub.wantedDone
                    aggregate.totalLength += sub.totalLength
                    aggregate.totalDone += sub.totalDone
                }
            }
            result[node.id] = aggregate
            return aggregate
        }

        for node in nodes { walk(node) }
        return result
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ node: TorrentFileNode, aggregate: Aggregate) -> some View {
        let checkState: TriStateCheckbox.CheckState = aggregate.selectedCount == aggregate.fileCount
            ? .on
            : (aggregate.selectedCount == 0 ? .off : .mixed)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if let selection {
                    TriStateCheckbox(
                        state: checkState,
                        // Fully deselecting this node would leave nothing selected.
                        enabled: !(checkState == .on
                            && selection.wrappedValue.subtracting(node.descendantIndices).isEmpty),
                        onToggle: { selectAll in
                            toggle(node, selectAll: selectAll, selection: selection)
                        }
                    )
                    .fixedSize()
                }

                // Only directories keep a glyph: a leading icon on every leaf
                // read as noise beside the checkbox that already marks a file.
                if node.fileIndex == nil {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Text(node.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(aggregate.skipped ? .secondary : .primary)
                if node.fileIndex == nil, checkState == .mixed {
                    Text("\(aggregate.selectedCount) of \(aggregate.fileCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text(formatBytes(node.length))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // The bar runs the width of the row rather than sharing it: a 44pt
            // gauge and a percentage stole the space the file names need.
            if showsProgress {
                progressBar(aggregate)
            }
        }
        .padding(.vertical, 5)
        .help(aggregate.skipped ? "Not being downloaded"
            : aggregate.progress.formatted(.percent.precision(.fractionLength(0))))
    }

    private func progressBar(_ aggregate: Aggregate) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Surface.ringTrack)
                if !aggregate.skipped {
                    Capsule()
                        .fill(Surface.prominent)
                        .frame(width: proxy.size.width * min(1, max(0, aggregate.progress)))
                }
            }
        }
        .frame(height: 4)
    }

    private func toggle(_ node: TorrentFileNode, selectAll: Bool, selection: Binding<Set<Int>>) {
        let descendants = node.descendantIndices
        if selectAll {
            selection.wrappedValue.formUnion(descendants)
        } else {
            let remaining = selection.wrappedValue.subtracting(descendants)
            if !remaining.isEmpty {
                selection.wrappedValue = remaining
            }
        }
    }
}

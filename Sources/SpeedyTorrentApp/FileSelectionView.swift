import SwiftUI
import TorrentEngine

/// The torrent's file hierarchy rebuilt from its flat path list.
struct TorrentFileNode: Identifiable {
    let id: String
    let name: String
    /// Set for leaves; directories have children instead.
    let fileIndex: Int?
    let length: Int64
    var children: [TorrentFileNode]?

    /// All file indices under this node (itself for a leaf).
    var descendantIndices: Set<Int> {
        if let fileIndex {
            return [fileIndex]
        }
        return (children ?? []).reduce(into: []) { $0.formUnion($1.descendantIndices) }
    }

    static func build(from files: [(index: Int, path: [String], length: Int64)]) -> [TorrentFileNode] {
        buildLevel(files.map { ($0.index, $0.path, $0.length) }, prefix: "")
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
private struct TriStateCheckbox: NSViewRepresentable {
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

/// Checkbox tree for choosing which files to download. Directories toggle all
/// of their descendants (showing a dash when partially selected); the last
/// selected file cannot be deselected. Sortable by name or size.
struct FileSelectionList: View {
    let nodes: [TorrentFileNode]
    @Binding var wanted: Set<Int>
    let fileCount: Int

    /// Remembered across sheets and launches.
    @AppStorage("fileTreeSortBySize") private var sortBySize = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files")
                    .font(.subheadline.weight(.medium))
                Picker("Sort", selection: $sortBySize) {
                    Text("Name").tag(false)
                    Text("Size").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)
                .help("Order the file tree by name or by size")
                Spacer()
                Text("\(wanted.count) of \(fileCount) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("All") { wanted = allIndices }
                    .controlSize(.small)
                    .disabled(wanted == allIndices)
            }
            List {
                OutlineGroup(displayNodes, children: \.children) { node in
                    row(node)
                }
            }
            .listStyle(.bordered)
            // Tall enough to show ~12 rows before scrolling.
            .frame(minHeight: 300, maxHeight: 340)
        }
    }

    private var allIndices: Set<Int> {
        nodes.reduce(into: []) { $0.formUnion($1.descendantIndices) }
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

    @ViewBuilder
    private func row(_ node: TorrentFileNode) -> some View {
        let descendants = node.descendantIndices
        let selectedCount = descendants.intersection(wanted).count
        let checkState: TriStateCheckbox.CheckState = selectedCount == descendants.count
            ? .on
            : (selectedCount == 0 ? .off : .mixed)
        HStack(spacing: 6) {
            TriStateCheckbox(
                state: checkState,
                // Fully deselecting this node would leave nothing selected.
                enabled: !(checkState == .on && wanted.subtracting(descendants).isEmpty),
                onToggle: { selectAll in
                    if selectAll {
                        wanted.formUnion(descendants)
                    } else {
                        let remaining = wanted.subtracting(descendants)
                        if !remaining.isEmpty {
                            wanted = remaining
                        }
                    }
                }
            )
            .fixedSize()

            Image(systemName: node.fileIndex == nil ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if node.fileIndex == nil, checkState == .mixed {
                Text("\(selectedCount) of \(descendants.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatBytes(node.length))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

import SwiftUI
import TorrentEngine

struct MenuBarView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.snapshots.isEmpty {
                Text("No torrents")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                ForEach(store.snapshots.prefix(8)) { snapshot in
                    compactRow(snapshot)
                }
                if store.snapshots.count > 8 {
                    Text("…and \(store.snapshots.count - 8) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Button("Pause All") { store.pauseAll() }
                    .disabled(!store.snapshots.contains { $0.state == .downloading || $0.state == .seeding })
                Button("Resume All") { store.resumeAll() }
                    .disabled(!store.snapshots.contains { $0.state == .paused })
            }
            .controlSize(.small)

            Divider()

            Button("Open SwiftTorrent") {
                openWindow(id: "main")
                NSApplication.shared.activate()
            }
            Button("Quit SwiftTorrent") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func compactRow(_ snapshot: TorrentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(snapshot.name)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Text(statusSuffix(snapshot))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    store.requestSettings(for: snapshot.infoHash)
                    openWindow(id: "main")
                    NSApplication.shared.activate()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Torrent settings")
            }
            ProgressView(value: snapshot.progress)
                .controlSize(.small)
        }
    }

    private func statusSuffix(_ snapshot: TorrentSnapshot) -> String {
        switch snapshot.state {
        case .downloading: formatRate(snapshot.downloadRate)
        case .seeding: "↑ " + formatRate(snapshot.uploadRate)
        default: snapshot.state.displayName
        }
    }
}

/// The menu bar label showing aggregate transfer rates. Because this view
/// lives in the status bar it is always alive, which also makes it the
/// reliable place to reopen the main window when a torrent is opened from
/// Finder/a magnet link while the window is closed (the add-settings sheet
/// needs a window to attach to).
struct MenuBarLabel: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        label
            .onChange(of: store.currentPendingAdd?.id) {
                if store.currentPendingAdd != nil {
                    openWindow(id: "main")
                    NSApplication.shared.activate()
                }
            }
    }

    @ViewBuilder
    private var label: some View {
        if store.totalDownloadRate >= 1024 || store.totalUploadRate >= 1024 {
            Text("↓\(shortRate(store.totalDownloadRate)) ↑\(shortRate(store.totalUploadRate))")
                .monospacedDigit()
        } else {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
    }

    private func shortRate(_ rate: Double) -> String {
        if rate >= 1024 * 1024 {
            return String(format: "%.1fM", rate / (1024 * 1024))
        }
        return String(format: "%.0fK", rate / 1024)
    }
}

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

            Button("Open SpeedyTorrent") {
                openWindow(id: "main")
                NSApplication.shared.activate()
            }
            Button("Quit SpeedyTorrent") {
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
            HStack(spacing: 3) {
                Image(nsImage: Self.magnetIcon)
                Text("↓\(shortRate(store.totalDownloadRate)) ↑\(shortRate(store.totalUploadRate))")
                    .monospacedDigit()
            }
        } else {
            Image(nsImage: Self.magnetIcon)
        }
    }

    private func shortRate(_ rate: Double) -> String {
        if rate >= 1024 * 1024 {
            return String(format: "%.1fM", rate / (1024 * 1024))
        }
        return String(format: "%.0fK", rate / 1024)
    }

    /// A template rendering of the app icon's magnet (arch, legs down,
    /// separated pole tips), sized for the menu bar.
    static let magnetIcon: NSImage = {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            // The app icon's magnet geometry (SVG coords: x 272–752, y 210–760).
            let s = (size * 0.86) / 550.0
            let ox = (size - 480 * s) / 2 - 272 * s
            let oy = (size - 550 * s) / 2 - 210 * s
            func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * s, y: oy + y * s) }

            let path = NSBezierPath()
            path.move(to: pt(272, 450))
            path.appendArc(withCenter: pt(512, 450), radius: 240 * s, startAngle: 180, endAngle: 360, clockwise: false)
            path.line(to: pt(752, 760))
            path.line(to: pt(632, 760))
            path.line(to: pt(632, 450))
            path.appendArc(withCenter: pt(512, 450), radius: 120 * s, startAngle: 360, endAngle: 180, clockwise: true)
            path.line(to: pt(392, 760))
            path.line(to: pt(272, 760))
            path.close()
            NSColor.black.setFill()
            path.fill()

            // Punch a thin gap above the pole tips (classic magnet look).
            if let cg = NSGraphicsContext.current?.cgContext {
                cg.setBlendMode(.clear)
                let gapTop: CGFloat = 655, gapBottom: CGFloat = 691
                for legX: CGFloat in [260, 620] {
                    cg.fill(CGRect(
                        x: pt(legX, gapTop).x, y: pt(legX, gapTop).y,
                        width: 144 * s, height: (gapBottom - gapTop) * s
                    ))
                }
                cg.setBlendMode(.normal)
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

import Charts
import SwiftUI
import UniformTypeIdentifiers
import TorrentEngine

/// The popup's own background.
///
/// The panel paints itself opaquely rather than sitting on the menu's vibrant
/// material: vibrancy let the desktop tint every fill, which is what made the
/// shipped popup read warm and washed-out next to the design. A normal window
/// needs none of this; everything drawn *above* a panel lives in `Surface`.
private enum Popup {
    /// The panel's slight lift towards the top of the window.
    static let background = LinearGradient(
        colors: [
            Color(nsColor: appearanceColor(dark: 0x1A242C, light: 0xF7F8FA)),
            Color(nsColor: appearanceColor(dark: 0x181D21, light: 0xEFF1F4)),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    private static func appearanceColor(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: Double((rgb >> 16) & 0xFF) / 255,
                green: Double((rgb >> 8) & 0xFF) / 255,
                blue: Double(rgb & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

/// The menu bar popup, laid out like a Control Center panel: two aggregate
/// rate tiles over a card of torrent rows, then a row of controls. Each row's
/// progress ring doubles as its pause/resume button, so the common actions no
/// longer require a trip to the main window.
struct MenuBarView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    /// The row under the pointer, whose ring shows its control instead of its
    /// progress readout.
    @State private var hovered: InfoHash?

    /// Rows past this fold into a "N more" row. The popup is a glance surface;
    /// past half a dozen rows it stops being one.
    private let rowLimit = 5

    /// Active transfers first, queue order within each group — the popup should
    /// lead with whatever is actually moving.
    private var ordered: [TorrentSnapshot] {
        store.snapshots.enumerated()
            .sorted { left, right in
                left.element.state.isActive == right.element.state.isActive
                    ? left.offset < right.offset
                    : left.element.state.isActive
            }
            .map(\.element)
    }

    private var visible: [TorrentSnapshot] { Array(ordered.prefix(rowLimit)) }
    private var overflow: Int { max(0, store.snapshots.count - rowLimit) }
    private var canPause: Bool {
        store.snapshots.contains { $0.state == .downloading || $0.state == .seeding || $0.state == .queued }
    }
    private var canResume: Bool { store.snapshots.contains { $0.state == .paused } }

    var body: some View {
        VStack(spacing: 8) {
            rateTiles
            torrents
            footer
        }
        .padding(10)
        .frame(width: 320)
        .background(Popup.background)
    }

    // MARK: - Aggregate rates

    private var rateTiles: some View {
        HStack(spacing: 8) {
            RateTile(
                title: "Download",
                icon: "arrow.down",
                tint: .blue,
                rate: store.totalDownloadRate,
                samples: store.totalRateHistory,
                value: \.download
            )
            RateTile(
                title: "Upload",
                icon: "arrow.up",
                tint: .green,
                rate: store.totalUploadRate,
                samples: store.totalRateHistory,
                value: \.upload
            )
        }
    }

    // MARK: - Torrent rows

    @ViewBuilder
    private var torrents: some View {
        if store.snapshots.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                Text("No torrents")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(Surface.fill, in: .rect(cornerRadius: Surface.corner))
        } else {
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, snapshot in
                    if index > 0 { SurfaceSeparator() }
                    row(snapshot)
                }
                if overflow > 0 {
                    SurfaceSeparator()
                    moreRow
                }
            }
            .background(Surface.fill)
            // Clipped rather than filled through a shape so a hovered first or
            // last row follows the card's corners instead of squaring them off.
            .clipShape(.rect(cornerRadius: Surface.corner))
        }
    }

    private func row(_ snapshot: TorrentSnapshot) -> some View {
        let isHovered = hovered == snapshot.infoHash
        return HStack(spacing: 10.5) {
            ProgressRing(snapshot: snapshot, showsControl: isHovered) {
                toggle(snapshot)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.name)
                    .font(.system(size: 13))
                    // A paused torrent recedes: the whole row drops to
                    // secondary rather than leading with a full-strength title.
                    .foregroundStyle(snapshot.state == .paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(snapshot))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(rateText(snapshot))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(rateTint(snapshot))
                    .monospacedDigit()
                if let detail = trailingDetail(snapshot) {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        // A hair more room on the leading edge: the ring is round, so it
        // needs it to sit as far from the card's edge as the rate text does.
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 7.5)
        .background(isHovered ? Surface.hover : .clear)
        .contentShape(.rect)
        .onTapGesture { showSettings(snapshot.infoHash) }
        .onHover { hovering in
            if hovering {
                hovered = snapshot.infoHash
            } else if hovered == snapshot.infoHash {
                hovered = nil
            }
        }
        .help("Settings for \(snapshot.name)")
    }

    private var moreRow: some View {
        HStack(spacing: 6) {
            Text("\(overflow) more torrent\(overflow == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(.rect)
        .onTapGesture { openMainWindow() }
        .help("Show all torrents")
    }

    // MARK: - Controls

    private var footer: some View {
        HStack(spacing: 6) {
            PillButton(
                title: canPause ? "Pause All" : "Resume All",
                icon: canPause ? "pause.fill" : "play.fill"
            ) {
                if canPause { store.pauseAll() } else { store.resumeAll() }
            }
            .disabled(!canPause && !canResume)

            PillMenu(title: "Add", icon: "plus", addFile: addTorrents, addMagnet: addMagnet)

            Spacer(minLength: 0)

            CircleButton(icon: "macwindow", prominent: true) { openMainWindow() }
                .help("Open SpeedyTorrent")
            CircleButton(icon: "power") { NSApplication.shared.terminate(nil) }
                .help("Quit SpeedyTorrent")
        }
    }

    // MARK: - Actions

    private func toggle(_ snapshot: TorrentSnapshot) {
        if snapshot.state == .paused {
            store.resume(snapshot.infoHash)
        } else {
            store.pause(snapshot.infoHash)
        }
    }

    private func showSettings(_ infoHash: InfoHash) {
        store.requestSettings(for: infoHash)
        openMainWindow()
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate()
    }

    /// Adds torrent files chosen from an open panel. The popup has no window
    /// for SwiftUI's `.fileImporter` to attach to, so this drives AppKit's
    /// panel directly — which also dismisses the popup, as picking a file
    /// should.
    private func addTorrents() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose torrent files to add."
        NSApplication.shared.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            store.addTorrentFile(at: url)
        }
    }

    /// Hands the magnet off to the main window's sheet, which already fills
    /// itself from a magnet sitting on the clipboard — the common case.
    private func addMagnet() {
        store.requestMagnetSheet()
        openMainWindow()
    }

    // MARK: - Row text

    /// The row's second line: whichever context the state makes useful.
    private func subtitle(_ snapshot: TorrentSnapshot) -> String {
        switch snapshot.state {
        case .downloading:
            let done = min(snapshot.completedLength, snapshot.wantedLength)
            let peers = "\(snapshot.peerCount) peer" + (snapshot.peerCount == 1 ? "" : "s")
            return "\(progressText(done: done, of: snapshot.wantedLength)) · \(peers)"
        case .seeding:
            return "Seeding · ratio \(String(format: "%.2f", snapshot.ratio))"
        case .failed:
            return snapshot.errorMessage ?? snapshot.state.displayName
        case .paused, .queued, .checking:
            return "\(snapshot.state.displayName) · \(percent(snapshot))"
        case .fetchingMetadata, .moving:
            return snapshot.state.displayName
        }
    }

    private func rateText(_ snapshot: TorrentSnapshot) -> String {
        switch snapshot.state {
        case .downloading: formatRate(snapshot.downloadRate)
        case .seeding: formatRate(snapshot.uploadRate)
        default: "—"
        }
    }

    private func rateTint(_ snapshot: TorrentSnapshot) -> Color {
        switch snapshot.state {
        case .downloading, .seeding: snapshot.state.tint
        default: .secondary
        }
    }

    private func trailingDetail(_ snapshot: TorrentSnapshot) -> String? {
        switch snapshot.state {
        case .downloading:
            guard snapshot.eta != nil else { return nil }
            return formatETA(snapshot.eta) + " left"
        case .seeding:
            guard snapshot.uploadedTotal > 0 else { return nil }
            return "↑ " + formatBytes(snapshot.uploadedTotal)
        default:
            return nil
        }
    }
}

/// "2.45 of 3.6 GB" rather than "2.45 GB of 3.6 GB" — in a 320pt row the unit
/// only earns its place once when both halves land on the same one.
private func progressText(done: Int64, of total: Int64) -> String {
    let doneText = formatBytes(done)
    let totalText = formatBytes(total)
    if let unit = totalText.split(separator: " ").last, doneText.hasSuffix(" \(unit)") {
        return "\(doneText.dropLast(unit.count + 1)) of \(totalText)"
    }
    return "\(doneText) of \(totalText)"
}

/// The menu bar label showing aggregate transfer rates. Because this view
/// lives in the status bar it is always alive, which also makes it the
/// reliable place to reopen the main window when a torrent is opened from
/// Finder/a magnet link while the window is closed (the add-settings sheet
/// needs a window to attach to).
struct MenuBarLabel: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    @AppStorage(Defaults.menuBarShowsIcon) private var showsIcon = true
    @AppStorage(Defaults.menuBarShowsDownloadRate) private var showsDownload = true
    @AppStorage(Defaults.menuBarShowsUploadRate) private var showsUpload = true

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
        // Rates are only shown while something is actually moving, so the menu
        // bar stays quiet when idle.
        let active = store.totalDownloadRate >= 1024 || store.totalUploadRate >= 1024
        let rates = active ? rateText : ""
        HStack(spacing: 3) {
            // With every option turned off there would be nothing to click, so
            // the icon comes back as the fallback.
            if showsIcon || rates.isEmpty {
                Image(nsImage: Self.magnetIcon)
            }
            if !rates.isEmpty {
                Text(rates).monospacedDigit()
            }
        }
    }

    private var rateText: String {
        var parts: [String] = []
        if showsDownload { parts.append("↓\(shortRate(store.totalDownloadRate))") }
        if showsUpload { parts.append("↑\(shortRate(store.totalUploadRate))") }
        return parts.joined(separator: " ")
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

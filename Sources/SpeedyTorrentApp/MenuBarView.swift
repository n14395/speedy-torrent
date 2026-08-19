import Charts
import SwiftUI
import UniformTypeIdentifiers
import TorrentEngine

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
            .background(.quaternary, in: .rect(cornerRadius: 9))
        } else {
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, snapshot in
                    if index > 0 { Divider().opacity(0.5) }
                    row(snapshot)
                }
                if overflow > 0 {
                    Divider().opacity(0.5)
                    moreRow
                }
            }
            .background(.quaternary, in: .rect(cornerRadius: 9))
        }
    }

    private func row(_ snapshot: TorrentSnapshot) -> some View {
        let isHovered = hovered == snapshot.infoHash
        return HStack(spacing: 9) {
            ProgressRing(snapshot: snapshot, showsControl: isHovered) {
                toggle(snapshot)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.name)
                    .font(.system(size: 13))
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
                    .font(.system(size: 11.5, weight: .semibold))
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
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear)
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
        .padding(.horizontal, 10)
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
            let done = formatBytes(min(snapshot.completedLength, snapshot.wantedLength))
            let peers = "\(snapshot.peerCount) peer" + (snapshot.peerCount == 1 ? "" : "s")
            return "\(done) of \(formatBytes(snapshot.wantedLength)) · \(peers)"
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

private func percent(_ snapshot: TorrentSnapshot) -> String {
    snapshot.progress.formatted(.percent.precision(.fractionLength(0)))
}

/// Splits a byte rate into a short value and its unit — "5.3" and "MB/s" — so
/// the tiles can set them at different sizes.
private func splitRate(_ rate: Double) -> (value: String, unit: String) {
    if rate >= 1024 * 1024 {
        let mib = rate / (1024 * 1024)
        return (String(format: mib < 10 ? "%.1f" : "%.0f", mib), "MB/s")
    }
    return (String(format: "%.0f", max(0, rate) / 1024), "KB/s")
}

// MARK: - Components

/// One aggregate rate tile: a large current-rate readout over a sparkline of
/// the last minute of samples.
private struct RateTile: View {
    let title: String
    let icon: String
    let tint: Color
    let rate: Double
    let samples: [RateSample]
    let value: KeyPath<RateSample, Double>

    /// The last minute of 1 Hz samples. The full three-minute history is too
    /// much detail for a tile this small.
    private var window: [RateSample] { Array(samples.suffix(60)) }

    private var ceiling: Double {
        max(20 * 1024, window.reduce(0) { max($0, $1[keyPath: value]) } * 1.2)
    }

    /// Nothing has moved in the last minute. Drawn anyway, a flat line pinned
    /// to the bottom of the tile reads as a stray rule rather than a graph, so
    /// an idle tile shows only its readout.
    private var isIdle: Bool {
        !window.contains { $0[keyPath: value] >= 1024 }
    }

    var body: some View {
        let parts = splitRate(rate)
        return ZStack(alignment: .topLeading) {
            if !isIdle { sparkline }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 8, weight: .bold))
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.4)
                }
                .foregroundStyle(tint)

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(parts.value)
                        .font(.system(size: 21, weight: .semibold))
                        .monospacedDigit()
                    Text(parts.unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .background(.quaternary, in: .rect(cornerRadius: 9))
    }

    private var sparkline: some View {
        Chart(window) { sample in
            AreaMark(
                x: .value("Time", sample.time),
                y: .value("Rate", sample[keyPath: value])
            )
            .foregroundStyle(tint.opacity(0.16))
            .interpolationMethod(.monotone)
            LineMark(
                x: .value("Time", sample.time),
                y: .value("Rate", sample[keyPath: value])
            )
            .foregroundStyle(tint)
            .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...ceiling)
        .chartLegend(.hidden)
        .chartPlotStyle { $0.padding(0) }
        .frame(height: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }
}

/// A row's leading progress ring. While the pointer is over the row it swaps
/// its readout for the pause/resume control, giving the action a 30pt target
/// where the old layout had a caption-sized gear.
private struct ProgressRing: View {
    let snapshot: TorrentSnapshot
    let showsControl: Bool
    let toggle: () -> Void

    /// Matches the list's context menu: only these states have a meaningful
    /// pause/resume toggle.
    private var isActionable: Bool {
        switch snapshot.state {
        case .downloading, .seeding, .queued, .paused: true
        default: false
        }
    }

    var body: some View {
        if isActionable {
            Button(action: toggle) { ring }
                .buttonStyle(.plain)
                .help(snapshot.state == .paused ? "Resume" : "Pause")
        } else {
            ring
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(1, max(0, snapshot.progress)))
                .stroke(
                    snapshot.state.tint,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            glyph
        }
        .frame(width: 30, height: 30)
        .contentShape(.circle)
    }

    @ViewBuilder
    private var glyph: some View {
        if showsControl, isActionable {
            Image(systemName: snapshot.state == .paused ? "play.fill" : "pause.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(snapshot.state.tint)
        } else if snapshot.state == .downloading {
            Text(percent(snapshot))
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
        } else {
            Image(systemName: glyphName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(snapshot.state.tint)
        }
    }

    /// A glyph light enough to sit inside the ring. `TorrentState.iconName` is
    /// tuned for the table's filled-circle badges, which read as a second ring
    /// here.
    private var glyphName: String {
        switch snapshot.state {
        case .downloading: "arrow.down"
        case .seeding: "arrow.up"
        case .paused: "play.fill"
        case .queued: "clock"
        case .checking: "magnifyingglass"
        case .moving: "shippingbox"
        case .fetchingMetadata: "antenna.radiowaves.left.and.right"
        case .failed: "exclamationmark"
        }
    }
}

/// The capsule look shared by the footer's labelled controls, so the plain
/// button and the menu are indistinguishable until one is opened.
private struct PillLabel: View {
    let title: String
    let icon: String
    let hovering: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background {
            Capsule().fill(.quaternary)
            if hovering { Capsule().fill(.primary.opacity(0.07)) }
        }
        .contentShape(.capsule)
    }
}

/// A labelled capsule control for the footer's primary actions.
private struct PillButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            PillLabel(title: title, icon: icon, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The footer's Add control. Its two destinations don't fit as separate pills
/// beside "Pause All" in a 320pt popup, so they hang off one menu.
private struct PillMenu: View {
    let title: String
    let icon: String
    let addFile: () -> Void
    let addMagnet: () -> Void
    @State private var hovering = false

    var body: some View {
        Menu {
            Button("Add .torrent…", action: addFile)
            Button("Add Magnet Link…", action: addMagnet)
        } label: {
            PillLabel(title: title, icon: icon, hovering: hovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

/// An icon-only round control for the footer's window actions.
private struct CircleButton: View {
    let icon: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: 28, height: 28)
                .background {
                    if prominent {
                        Circle().fill(Color.accentColor)
                    } else {
                        Circle().fill(.quaternary)
                    }
                    if hovering { Circle().fill(.primary.opacity(0.07)) }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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

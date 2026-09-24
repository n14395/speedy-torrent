// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

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
    /// Hover state for the expand/collapse row, which is a control like the
    /// torrent rows above it and should look like one.
    @State private var hoveringMore = false

    /// Rows past this fold into a "N more" row until the popup is expanded. The
    /// popup is a glance surface first; the whole list is one click away.
    private let rowLimit = 5

    /// Remembered across openings and launches: someone who wants the long list
    /// usually wants it every time.
    @AppStorage(Defaults.menuBarExpanded) private var expanded = false
    /// Measured height of the row stack, so the expanded list is exactly as
    /// tall as its rows until it hits the cap and starts scrolling.
    @State private var rowsHeight: CGFloat = 0
    /// Height the popup's content actually wants, which the panel is held to.
    @State private var contentHeight: CGFloat = 0

    /// Where a torrent sits in the popup: still working toward finishing, then
    /// finished and seeding, then stopped. Queued and errored torrents are
    /// unfinished business, so they lead alongside the live downloads rather
    /// than sinking below the things that are already done.
    private func group(_ state: TorrentState) -> Int {
        switch state {
        case .downloading, .fetchingMetadata, .checking, .moving, .queued, .failed: 0
        case .seeding: 1
        case .paused: 2
        }
    }

    /// Unfinished first, then seeding, then paused — queue order within each
    /// group, which the offset tiebreak keeps stable.
    private var ordered: [TorrentSnapshot] {
        store.snapshots.enumerated()
            .sorted { left, right in
                let leftGroup = group(left.element.state)
                let rightGroup = group(right.element.state)
                return leftGroup == rightGroup
                    ? left.offset < right.offset
                    : leftGroup < rightGroup
            }
            .map(\.element)
    }

    private var visible: [TorrentSnapshot] {
        expanded ? ordered : Array(ordered.prefix(rowLimit))
    }

    private var overflow: Int { max(0, ordered.count - rowLimit) }

    /// How tall the expanded list may grow. Generous, but never past the screen
    /// the popup hangs from — the rest scrolls.
    private var expandedListHeight: CGFloat {
        // Rate tiles, footer, padding and the menu bar itself.
        let chrome: CGFloat = 190
        let available = (NSScreen.main?.visibleFrame.height ?? 800) - chrome
        return max(240, min(560, available))
    }
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
        .background(Surface.panel)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .background(MenuBarWindowAnchor(contentHeight: contentHeight))
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
                if expanded {
                    ScrollView {
                        rowStack
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                rowsHeight = $0
                            }
                    }
                    // An explicit height rather than a maxHeight: a ScrollView
                    // asked to size itself inside a window that sizes itself
                    // has no height to settle on.
                    .frame(height: min(max(rowsHeight, 48), expandedListHeight))
                } else {
                    rowStack
                }
                // The collapse control stays even when the list has shrunk
                // below the fold, or an expanded popup could never be closed.
                if expanded || overflow > 0 {
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

    private var rowStack: some View {
        VStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, snapshot in
                if index > 0 { SurfaceSeparator() }
                row(snapshot)
            }
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

    /// Grows the popup instead of sending the user to the main window: the
    /// footer already has a button for that, and this is the row people reach
    /// for when they just want to see the rest.
    private var moreRow: some View {
        HStack(spacing: 6) {
            Text(expanded
                ? "Show fewer"
                : "\(overflow) more torrent\(overflow == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(hoveringMore ? Surface.hover : .clear)
        .contentShape(.rect)
        .onTapGesture { expanded.toggle() }
        .onHover { hoveringMore = $0 }
        .help(expanded ? "Show fewer torrents" : "Show every torrent")
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

/// Holds the popup's panel to the size of its content, hanging from the menu
/// bar.
///
/// Two AppKit behaviours conspire against a popup that changes height. SwiftUI
/// grows this panel to fit taller content but does not shrink it back, so a
/// collapsed popup keeps its expanded frame — the shadow stays the old size
/// while the content floats inside it. And a window's frame origin is its
/// *bottom* left, so any resize that does happen holds the bottom edge still
/// and moves the top. Setting the frame outright fixes both at once: the
/// height comes from what the content measured, and the top edge is planted
/// under the menu bar, so the popup only ever moves at the bottom.
private struct MenuBarWindowAnchor: NSViewRepresentable {
    /// The height SwiftUI's content wants the panel to be.
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> NSView { AnchorView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? AnchorView)?.desiredHeight = contentHeight
    }

    final class AnchorView: NSView {
        /// The panel rests a point below the usable top of the screen (measured
        /// on macOS 26: visible top 1289, panel top 1288). Deriving the anchor
        /// from the screen rather than remembering where the panel started
        /// means there is no reading that can be taken at the wrong moment —
        /// and nothing to re-learn if SwiftUI rebuilds this view mid-resize.
        private static let menuBarGap: CGFloat = 1
        private var observers: [NSObjectProtocol] = []

        /// Set from SwiftUI every time the content is measured.
        var desiredHeight: CGFloat = 0 {
            didSet {
                guard abs(desiredHeight - oldValue) > 0.5 else { return }
                applyGeometry()
                pinAfterSettling()
            }
        }

        // Torn down here rather than in `deinit`, which Swift 6 won't let touch
        // this array: AppKit calls this with a nil window when the view leaves,
        // which happens before it can be released. The observers hold `self`
        // weakly regardless, so a straggler is inert.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didMoveNotification,
                NSWindow.didBecomeKeyNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.applyGeometry()
                    }
                })
            }
            applyGeometry()
        }

        /// Re-applies over the next few frames: SwiftUI resizes, then
        /// repositions, and may animate the change, so whichever lands last
        /// has to be the one that ends up corrected.
        private func pinAfterSettling() {
            for delay in [0.0, 0.05, 0.12, 0.25, 0.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.applyGeometry()
                }
            }
        }

        private func applyGeometry() {
            guard let window, window.isVisible,
                  let screen = window.screen ?? NSScreen.main
            else { return }
            // Before the first measurement arrives, leave the height alone and
            // only look after the top edge.
            let height = desiredHeight > 0 ? desiredHeight : window.frame.height
            let frame = window.frame
            let target = NSRect(
                x: frame.origin.x,
                y: screen.visibleFrame.maxY - Self.menuBarGap - height,
                width: frame.width,
                height: height
            )
            guard abs(target.origin.y - frame.origin.y) > 0.5
                    || abs(target.height - frame.height) > 0.5
            else { return }
            window.setFrame(target, display: true)
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

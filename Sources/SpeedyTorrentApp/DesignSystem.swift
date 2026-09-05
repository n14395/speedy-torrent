import Charts
import SwiftUI
import TorrentEngine

/// The palette and metrics shared by the menu bar popup and the main window.
///
/// These numbers were measured pixel-by-pixel off a design mock, which is why
/// they are explicit rather than `.quaternary`/`Divider()`/`Color.accentColor`:
/// the system's semantic styles let the material underneath tint every fill,
/// which is what made an earlier build read warm and washed-out. Treat them as
/// design constants — a cleanup pass should not "simplify" them back.
///
/// Every card above a panel — tiles, sections, the torrent list — carries
/// `fill`; controls that sit on the window's *chrome* instead carry
/// `controlFill`, and `hover` lifts either by one more step.
enum Surface {
    static let corner: CGFloat = 8

    /// A card on the panel: a tile, a section, the torrent list. Opaque and
    /// explicit rather than a step of `primary`, because the panel underneath
    /// is dark enough now that a translucent white step washed out to grey
    /// instead of the design's slate.
    static let fillColor = appearanceColor(dark: 0x1B2026, light: 0xE2E3E5)
    static let fill = Color(nsColor: fillColor)

    /// A control that sits on the *chrome* rather than the panel — the toolbar
    /// buttons, the search field, the status bar's filter pills. A card's
    /// colour is now the chrome's own colour, so these have to lift off it
    /// instead of matching it.
    static let controlFill = Color.primary.opacity(0.10)

    static let hover = Color.primary.opacity(0.11)
    static let separator = Color.primary.opacity(0.15)
    static let ringTrack = Color.primary.opacity(0.21)

    /// The design's blue, not the system accent: the other blues on these
    /// surfaces (download rate, progress) are `.blue`, and a non-blue accent
    /// left prominent controls as the odd one out.
    static let prominent = Color.blue

    /// A selected row. Painted by the row itself, over the system highlight,
    /// which is either a saturated accent (focused) or a flat grey (not) —
    /// neither of which is the muted blue the design asks for.
    static let selection = Color(nsColor: appearanceColor(dark: 0x29415D, light: 0xD6E4FB))

    /// Tiles across a hero row share one height so their fills line up. The
    /// popup's rate tiles carry two lines; the window's carry three, and every
    /// tile in a row has to clear the tallest of them or its caption spills
    /// out from under the fill.
    static let tileHeight: CGFloat = 58
    static let windowTileHeight: CGFloat = 71

    /// A stat tile holds a count and a caption, and both stop needing room at
    /// about this width. Capping them hands the slack in a wide window to the
    /// rate tiles, whose sparklines actually read better for it.
    static let statTileMaxWidth: CGFloat = 200

    /// The status bar runs the full width of the window, under the inspector
    /// as well as the list, so both sides have to keep clear of it.
    static let statusBarHeight: CGFloat = 33

    /// `List` keeps a leading margin and a trailing scroller gutter that
    /// neither `.listRowInsets` nor `.contentMargins` reaches. Cancelling them
    /// with negative padding is what puts a row — and the selection band behind
    /// it — flush with its card. These are the only two numbers to revisit if a
    /// macOS update changes those metrics.
    static let listLeadingBleed: CGFloat = 8
    static let listTrailingBleed: CGFloat = 9.5

    /// The panel every surface sits on: opaque, replacing the system's vibrant
    /// material, which let the desktop tint each fill and made the whole app
    /// read warm. Flat in dark mode — at the design's near-black a vertical
    /// ramp reads as banding rather than lift — and still lifted towards the
    /// top of the window in light mode.
    static let panelTopColor = appearanceColor(dark: 0x081316, light: 0xF7F8FA)
    static let panelBottomColor = appearanceColor(dark: 0x081316, light: 0xEFF1F4)

    static let panel = LinearGradient(
        colors: [Color(nsColor: panelTopColor), Color(nsColor: panelBottomColor)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// The toolbar and status bar. In dark mode they carry a card's value, so
    /// the chrome reads as a frame of the same material the cards are cut from
    /// and the panel recedes behind both.
    static let chromeColor = appearanceColor(dark: 0x1B2026, light: 0xE8E8EC)
    static let chrome = Color(nsColor: chromeColor)

    static func appearanceColor(dark: UInt32, light: UInt32) -> NSColor {
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

/// A hairline between rows. `Divider()` is tuned for vibrant material and all
/// but vanishes against an opaque panel.
struct SurfaceSeparator: View {
    var body: some View {
        Rectangle().fill(Surface.separator).frame(height: 0.5)
    }
}

// MARK: - Formatting

/// A fraction as a whole-number percentage.
///
/// Floors rather than rounds, and holds at 99 until the work is genuinely
/// finished. `.percent.precision(.fractionLength(0))` rounds, so everything
/// from 99.5% up rendered as "100%" — which on a large torrent is minutes of
/// still-downloading, and 100% is the one number a progress readout must never
/// show early.
func percentValue(_ fraction: Double, complete: Bool) -> Int {
    if complete { return 100 }
    return min(Int((min(1, max(0, fraction)) * 100).rounded(.down)), 99)
}

func percentText(_ fraction: Double, complete: Bool) -> String {
    "\(percentValue(fraction, complete: complete))%"
}

/// The fraction to *draw*, held just short of full for the same reason: a
/// closed ring or a filled bar should only ever mean done.
func displayFraction(_ fraction: Double, complete: Bool) -> Double {
    complete ? 1 : min(0.99, max(0, fraction))
}

func percent(_ snapshot: TorrentSnapshot) -> String {
    percentText(snapshot.progress, complete: snapshot.isComplete)
}

/// Splits a byte rate into a short value and its unit — "5.3" and "MB/s" — so
/// the tiles can set them at different sizes.
func splitRate(_ rate: Double) -> (value: String, unit: String) {
    if rate >= 1024 * 1024 {
        let mib = rate / (1024 * 1024)
        return (String(format: mib < 10 ? "%.1f" : "%.0f", mib), "MB/s")
    }
    return (String(format: "%.0f", max(0, rate) / 1024), "KB/s")
}

// MARK: - Tiles

/// The label line shared by every tile kind, so a rate tile, a stat tile and a
/// tile of controls are indistinguishable above the fold.
struct TileLabel: View {
    let title: String
    /// Optional: a tile of controls says what it is with its buttons, and a
    /// glyph there only competes with them.
    var icon: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4.5) {
            // Only the word carries the tint — the glyph stays at full
            // strength, which is what keeps a tile legible when a sparkline
            // runs underneath it.
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .bold))
            }
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(tint)
                // Never two lines: a squeezed row should narrow the tile, not
                // break "DOWNLOAD" across the label.
                .lineLimit(1)
        }
    }
}

/// A large readout with its unit set smaller alongside.
private struct TileValue: View {
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: 21, weight: .semibold))
                .monospacedDigit()
                // The readout is the point of the tile: the unit gives way
                // first, and the number is never abbreviated.
                .fixedSize()
            Text(unit)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// One aggregate rate tile: a large current-rate readout over a sparkline of
/// the last minute of samples.
struct RateTile: View {
    let title: String
    let icon: String
    let tint: Color
    let rate: Double
    let samples: [RateSample]
    let value: KeyPath<RateSample, Double>
    var height: CGFloat = Surface.tileHeight

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
            VStack(alignment: .leading, spacing: 3) {
                TileLabel(title: title, icon: icon, tint: tint)
                TileValue(value: parts.value, unit: parts.unit)
            }
            .padding(.horizontal, 11)
            .padding(.top, 9.5)
        }
        // Top-leading, not centred: the sparkline is the only child that fills
        // the tile, so an idle tile would centre its readout and drop it ~4pt
        // the moment the transfer stops — the text visibly jumps as traffic
        // starts and stops. The readout also has to stay flush with the tile's
        // leading edge whether or not there is a graph behind it.
        .frame(height: height, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.fill, in: .rect(cornerRadius: Surface.corner))
    }

    private var sparkline: some View {
        Chart(window) { sample in
            AreaMark(
                x: .value("Time", sample.time),
                y: .value("Rate", sample[keyPath: value])
            )
            .foregroundStyle(tint.opacity(0.16))
            .interpolationMethod(.linear)
            LineMark(
                x: .value("Time", sample.time),
                y: .value("Rate", sample[keyPath: value])
            )
            .foregroundStyle(tint)
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            .interpolationMethod(.linear)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...ceiling)
        .chartLegend(.hidden)
        .chartPlotStyle { $0.padding(0) }
        // The graph keeps its share of the tile as the tile grows, so the
        // popup's 58pt tile and the window's 71pt one are one drawing scaled.
        .frame(height: height * (24 / Surface.tileHeight))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }
}

/// A tile for a counter that has no history to plot: the same label and
/// readout as `RateTile`, with a caption where the sparkline would be.
struct StatTile: View {
    let title: String
    let icon: String
    let value: String
    let unit: String
    let caption: String
    var tint: Color = .secondary
    var height: CGFloat = Surface.tileHeight
    /// Unbounded by default; a hero row caps it so the rate tiles take the
    /// extra width instead.
    var maxWidth: CGFloat = .infinity

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TileLabel(title: title, icon: icon, tint: tint)
            TileValue(value: value, unit: unit)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.top, 9.5)
        .frame(height: height, alignment: .topLeading)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(Surface.fill, in: .rect(cornerRadius: Surface.corner))
    }
}

// MARK: - Progress ring

/// A torrent's progress as a state-tinted ring. Given a `toggle` it becomes the
/// pause/resume control, swapping its readout for the action while
/// `showsControl` is set; without one it is decoration.
struct ProgressRing: View {
    let snapshot: TorrentSnapshot
    var diameter: CGFloat = 27
    /// Whether a downloading torrent shows its percentage inside the ring.
    /// Off where the percentage has a column of its own — the arc already says
    /// how far along it is, and the glyph then says the same thing about the
    /// state as it does in every other row.
    var showsPercent = true
    var showsControl = false
    /// When nil the ring is not a control and never renders as a button.
    var toggle: (() -> Void)?

    /// Matches the list's context menu: only these states have a meaningful
    /// pause/resume toggle.
    private var isActionable: Bool {
        guard toggle != nil else { return false }
        switch snapshot.state {
        case .downloading, .seeding, .queued, .paused: return true
        default: return false
        }
    }

    /// Proportions taken from the 27pt popup ring, so every size is the same
    /// drawing scaled rather than a separate set of magic numbers.
    private var stroke: CGFloat { diameter * (2.5 / 27) }
    private var readoutSize: CGFloat { diameter * (9 / 27) }
    private var glyphSize: CGFloat { diameter * (10 / 27) }

    var body: some View {
        if isActionable, let toggle {
            Button(action: toggle) { ring }
                .buttonStyle(.plain)
                .help(snapshot.state == .paused ? "Resume" : "Pause")
        } else {
            ring
        }
    }

    /// Inset by half the stroke so the ring's ink sits inside its frame, which
    /// is what lets a row's padding read as the design's 12pt.
    private var ring: some View {
        ZStack {
            Circle()
                .inset(by: stroke / 2)
                .stroke(Surface.ringTrack, lineWidth: stroke)
            Circle()
                .inset(by: stroke / 2)
                .trim(from: 0, to: min(1, max(0, ringFraction)))
                .stroke(
                    snapshot.state.tint,
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            glyph
        }
        .frame(width: diameter, height: diameter)
        .contentShape(.circle)
    }

    /// While checking or moving, the ring tracks that job rather than the
    /// download: both can take minutes on a large torrent, and the ring used to
    /// show nothing but the download progress frozen where it stopped.
    private var ringFraction: Double {
        switch snapshot.state {
        case .checking: displayFraction(snapshot.checkProgress, complete: false)
        case .moving: displayFraction(snapshot.moveProgress, complete: false)
        default: displayFraction(snapshot.progress, complete: snapshot.isComplete)
        }
    }

    @ViewBuilder
    private var glyph: some View {
        if showsControl, isActionable {
            Image(systemName: snapshot.state == .paused ? "play.fill" : "pause.fill")
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(snapshot.state.tint)
        } else if showsPercent, snapshot.state == .downloading {
            Text(percent(snapshot))
                .font(.system(size: readoutSize, weight: .semibold))
                .monospacedDigit()
        } else {
            Image(systemName: glyphName)
                .font(.system(size: glyphSize, weight: .medium))
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

// MARK: - Controls

/// The capsule look shared by the labelled controls, so a plain button and a
/// menu are indistinguishable until one is opened.
struct PillLabel: View {
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
            Capsule().fill(Surface.fill)
            if hovering { Capsule().fill(Surface.hover) }
        }
        .contentShape(.capsule)
    }
}

/// A labelled capsule control for primary actions.
struct PillButton: View {
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

/// The Add control. Its two destinations don't fit as separate pills beside
/// "Pause All" in a 320pt popup, so they hang off one menu.
struct PillMenu: View {
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

/// An icon-only round control.
struct CircleButton: View {
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
                        Circle().fill(Surface.prominent)
                    } else {
                        Circle().fill(Surface.fill)
                    }
                    if hovering { Circle().fill(Surface.hover) }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A segmented control in the panel's own vocabulary. `.pickerStyle(.segmented)`
/// draws a system bezel that reads as a foreign object among these fills.
struct PillSegmentedControl<Value: Hashable>: View {
    let options: [Value]
    let title: (Value) -> String
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Surface.corner - 3)
                                    .fill(Surface.hover)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Surface.fill, in: .rect(cornerRadius: Surface.corner - 1))
    }
}

// MARK: - Sections

/// A titled card. This is the app's answer to `Form`'s grouped sections, which
/// draw the system's own material and read as a foreign object on these panels.
/// Separate rows with `SurfaceSeparator()`.
struct SurfaceSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) { content }
                .background(Surface.fill)
                .clipShape(.rect(cornerRadius: Surface.corner))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
    }
}

/// One row of a `SurfaceSection`: a label, an optional explanation under it,
/// and whatever control or readout belongs on the trailing edge.
struct SurfaceRow<Trailing: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 12))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

extension SurfaceRow where Trailing == AnyView {
    /// A read-only row: label on the left, value on the right. Long values wrap
    /// rather than truncate — an info hash is only useful whole — and every
    /// value is selectable so it can be copied out.
    init(_ label: String, _ value: String, detail: String? = nil, monospaced: Bool = false) {
        self.init(label: label, detail: detail) {
            AnyView(
                Text(value)
                    .font(monospaced ? .system(size: 11).monospaced() : .system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                    .textSelection(.enabled)
            )
        }
    }
}

extension View {
    /// Field chrome for text entry on a panel: the system bezel is a bright
    /// rounded well that fights every other fill here.
    func surfaceField(width: CGFloat) -> some View {
        textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 12))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(width: width)
            .background(Surface.hover, in: .rect(cornerRadius: 5))
    }

    /// The iOS-style switch, in the app's blue rather than the system accent.
    func surfaceSwitch() -> some View {
        toggleStyle(.switch)
            .controlSize(.small)
            .tint(Surface.prominent)
            .labelsHidden()
    }
}

/// A small capsule button for use inside a card.
struct SurfaceButton: View {
    let title: String
    var role: ButtonRole?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background {
                    Capsule().fill(Surface.hover)
                    if hovering { Capsule().fill(Surface.hover) }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
        .onHover { hovering = $0 }
    }
}

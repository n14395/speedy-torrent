// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TorrentEngine

/// Identifies the pending add a sheet is showing. The sheet is presented by
/// *id* rather than by value: the record now carries the user's settings, so
/// binding to the value itself would re-present the sheet on every checkbox
/// click.
struct PendingAddID: Identifiable, Equatable {
    let id: PendingTorrentAdd.ID
}

/// Shown when a torrent/magnet is opened, before it is actually added: the
/// same detail view as the inspector, plus Cancel/Add. For magnets the file
/// list and size fill in live as the background metadata prefetch resolves.
struct AddTorrentSheet: View {
    @Environment(SessionStore.self) private var store
    let pendingID: PendingTorrentAdd.ID

    @State private var tab: TorrentDetailTab = .files

    private var pending: PendingTorrentAdd? {
        store.pendingAdd(id: pendingID)
    }

    var body: some View {
        VStack(spacing: 0) {
            TorrentDetailView(subject: .pending(pendingID), tab: $tab)
                .environment(store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            SurfaceSeparator()
            HStack(spacing: 8) {
                Spacer()
                footerButton("Cancel") { store.dismissPendingAdd(id: pendingID) }
                    .keyboardShortcut(.cancelAction)
                footerButton("Add Torrent", prominent: true, enabled: !addDisabled) {
                    store.confirmPendingAdd(id: pendingID)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        // The same panel the inspector paints, because this is the same view:
        // on the sheet's own background it read as a different app.
        .background(Surface.panel)
        // Fixed size: switching between a tall tab (Files) and a short one
        // (Info) must not animate the sheet resizing.
        .frame(width: 620, height: 560)
    }

    private func footerButton(
        _ title: String, prominent: Bool = false, enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    Capsule().fill(prominent ? AnyShapeStyle(Surface.prominent) : AnyShapeStyle(Surface.fill))
                }
                .opacity(enabled ? 1 : 0.4)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Nothing selected means nothing to download; an unresolved magnet is
    /// still addable (it starts fetching and takes every file).
    private var addDisabled: Bool {
        guard let pending else { return true }
        return !pending.files.isEmpty && pending.wantedFiles.isEmpty
    }
}

/// An SF Symbol that rotates steadily, for inline "working…" indicators.
/// Driven by `TimelineView` (not an implicit animation) so it keeps spinning
/// even as the surrounding view re-renders on each metadata poll. Honors
/// Reduce Motion by holding still.
struct SpinningSymbol: View {
    let systemName: String
    /// Seconds per full revolution.
    var period: Double = 1.2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Image(systemName: systemName)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period)
                Image(systemName: systemName)
                    .rotationEffect(.degrees(t / period * 360))
            }
        }
    }
}

// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TorrentEngine

/// Small auxiliary window: aggregate transfer graph plus session and
/// all-time counters (persisted by the engine in stats.json).
struct StatisticsView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SurfaceSection(title: "Transfer") {
                    VStack(spacing: 6) {
                        RateChart(samples: store.totalRateHistory)
                            .frame(height: 110)
                        RateChartLegend(
                            download: store.totalDownloadRate,
                            upload: store.totalUploadRate
                        )
                    }
                    .padding(12)
                }

                if let stats = store.stats {
                    SurfaceSection(title: "This session") {
                        SurfaceRow("Downloaded", formatBytes(stats.sessionDownloaded))
                        SurfaceSeparator()
                        SurfaceRow("Uploaded", formatBytes(stats.sessionUploaded))
                        SurfaceSeparator()
                        SurfaceRow("Ratio", String(format: "%.2f", stats.sessionRatio))
                        SurfaceSeparator()
                        SurfaceRow("Running for", formatDuration(stats.sessionDuration))
                    }
                    SurfaceSection(title: "All time") {
                        SurfaceRow("Downloaded", formatBytes(stats.allTimeDownloaded))
                        SurfaceSeparator()
                        SurfaceRow("Uploaded", formatBytes(stats.allTimeUploaded))
                        SurfaceSeparator()
                        SurfaceRow("Ratio", String(format: "%.2f", stats.allTimeRatio))
                        SurfaceSeparator()
                        SurfaceRow("Time running", formatDuration(stats.allTimeUptime))
                        SurfaceSeparator()
                        SurfaceRow("Launches", "\(stats.launchCount)")
                    }
                } else {
                    SurfaceSection {
                        Text("Statistics appear once the session has started.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
            .padding(14)
        }
        .scrollContentBackground(.hidden)
        .background(Surface.panel)
        .frame(width: 340, height: 560)
    }
}

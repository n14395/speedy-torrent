import SwiftUI
import TorrentEngine

/// Small auxiliary window: aggregate transfer graph plus session and
/// all-time counters (persisted by the engine in stats.json).
struct StatisticsView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        Form {
            Section("Transfer") {
                VStack(spacing: 6) {
                    RateChart(samples: store.totalRateHistory)
                        .frame(height: 110)
                    RateChartLegend(
                        download: store.totalDownloadRate,
                        upload: store.totalUploadRate
                    )
                }
            }
            if let stats = store.stats {
                Section("This Session") {
                    row("Downloaded", formatBytes(stats.sessionDownloaded))
                    row("Uploaded", formatBytes(stats.sessionUploaded))
                    row("Ratio", String(format: "%.2f", stats.sessionRatio))
                    row("Running for", formatDuration(stats.sessionDuration))
                }
                Section("All Time") {
                    row("Downloaded", formatBytes(stats.allTimeDownloaded))
                    row("Uploaded", formatBytes(stats.allTimeUploaded))
                    row("Ratio", String(format: "%.2f", stats.allTimeRatio))
                    row("Time running", formatDuration(stats.allTimeUptime))
                    row("Launches", "\(stats.launchCount)")
                }
            } else {
                Section {
                    Text("Statistics appear once the session has started.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 340, height: 660)
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

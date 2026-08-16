import Charts
import SwiftUI

/// Rolling transfer-rate graph: filled download area plus an upload line,
/// over the last few minutes of 1 Hz samples.
struct RateChart: View {
    let samples: [RateSample]

    private var yCeiling: Double {
        let peak = samples.reduce(0.0) { max($0, max($1.download, $1.upload)) }
        return max(20 * 1024, peak * 1.15)
    }

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                AreaMark(
                    x: .value("Time", sample.time),
                    y: .value("Rate", sample.download),
                    series: .value("Direction", "Download")
                )
                .foregroundStyle(.blue.opacity(0.18))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("Time", sample.time),
                    y: .value("Rate", sample.download),
                    series: .value("Direction", "Download")
                )
                .foregroundStyle(.blue)
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("Time", sample.time),
                    y: .value("Rate", sample.upload),
                    series: .value("Direction", "Upload")
                )
                .foregroundStyle(.green)
                .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...yCeiling)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let rate = value.as(Double.self) {
                        Text(axisRate(rate))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    /// Short axis label like "1.5M" (implicitly per second).
    private func axisRate(_ rate: Double) -> String {
        if rate >= 1024 * 1024 {
            let mib = rate / (1024 * 1024)
            return String(format: mib < 10 ? "%.1fM" : "%.0fM", mib)
        }
        return String(format: "%.0fK", rate / 1024)
    }
}

/// A caption-sized legend to pair with `RateChart`.
struct RateChartLegend: View {
    let download: Double
    let upload: Double

    var body: some View {
        HStack(spacing: 12) {
            Label(formatRate(download), systemImage: "arrow.down")
                .foregroundStyle(.blue)
            Label(formatRate(upload), systemImage: "arrow.up")
                .foregroundStyle(.green)
            Spacer()
            Text("last 3 min")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .monospacedDigit()
    }
}

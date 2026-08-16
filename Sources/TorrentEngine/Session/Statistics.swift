import Foundation

/// Aggregate transfer statistics: the running session plus all-time counters
/// persisted across launches (`stats.json` in the state directory).
public struct SessionStatistics: Sendable {
    public var sessionDownloaded: Int64
    public var sessionUploaded: Int64
    public var sessionDuration: TimeInterval
    public var allTimeDownloaded: Int64
    public var allTimeUploaded: Int64
    /// Cumulative time sessions have been running, across all launches.
    public var allTimeUptime: TimeInterval
    /// How many sessions have been started against this state directory.
    public var launchCount: Int

    public var sessionRatio: Double {
        sessionDownloaded > 0 ? Double(sessionUploaded) / Double(sessionDownloaded) : 0
    }

    public var allTimeRatio: Double {
        allTimeDownloaded > 0 ? Double(allTimeUploaded) / Double(allTimeDownloaded) : 0
    }
}

/// On-disk all-time counters. While a session runs, the file is periodically
/// rewritten as (value loaded at launch) + (session so far), which makes
/// repeated saves idempotent and crash-safe to within the save interval.
struct StatsFile: Codable, Sendable {
    var version = 1
    var downloaded: Int64 = 0
    var uploaded: Int64 = 0
    var uptime: TimeInterval = 0
    var launches: Int = 0
}

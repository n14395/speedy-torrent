import Foundation

/// Saved per-torrent state for fast resume across launches.
struct ResumeData: Codable, Sendable {
    var version = 1
    var infoHashHex: String
    var bitfieldBase64: String
    var downloadDirectory: String
    var uploaded: Int64
    var downloaded: Int64
    var paused: Bool
    /// Per-torrent sequential-order override (absent in pre-v0.2 files).
    var sequential: Bool?
    /// File indices excluded from download (absent/nil = everything wanted).
    var unwantedFiles: [Int]?
    var addedAt: Double
    /// Relative path → modification time at last save; a mismatch on load
    /// forces a full hash re-check instead of trusting the bitfield.
    var fileStamps: [String: Double]
}

/// A magnet whose metadata hasn't arrived yet. Saved so torrents still
/// "Fetching metadata" survive a relaunch instead of vanishing; replaced by
/// `meta.torrent` + `resume.json` once the info dictionary is verified.
struct MagnetRecord: Codable, Sendable {
    var version = 1
    var infoHashHex: String
    var displayName: String?
    var trackers: [String]
    var downloadDirectory: String
    var sequential: Bool
    var addedAt: Double
}

/// One restored item, in queue order.
enum RestoreEntry: Sendable {
    case torrent(data: Data, resume: ResumeData?)
    case magnet(MagnetRecord)
}

/// On-disk layout: `<base>/<infohash>/meta.torrent` + `resume.json`, or
/// `magnet.json` while a magnet is still resolving.
/// All operations are synchronous and cheap; call from the session actor.
struct PersistenceStore: Sendable {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    private func directory(for infoHash: InfoHash) -> URL {
        baseURL.appendingPathComponent(infoHash.hexString, isDirectory: true)
    }

    func saveTorrentData(_ data: Data, for infoHash: InfoHash) {
        let dir = directory(for: infoHash)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("meta.torrent"))
    }

    func saveResume(_ resume: ResumeData, for infoHash: InfoHash) {
        let dir = directory(for: infoHash)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(resume) {
            try? encoded.write(to: dir.appendingPathComponent("resume.json"))
        }
    }

    func remove(for infoHash: InfoHash) {
        try? FileManager.default.removeItem(at: directory(for: infoHash))
    }

    func saveMagnet(_ record: MagnetRecord, for infoHash: InfoHash) {
        let dir = directory(for: infoHash)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(record) {
            try? encoded.write(to: dir.appendingPathComponent("magnet.json"))
        }
    }

    /// Drops just the pending-magnet marker, keeping the torrent state that
    /// replaces it.
    func removeMagnet(for infoHash: InfoHash) {
        try? FileManager.default.removeItem(
            at: directory(for: infoHash).appendingPathComponent("magnet.json")
        )
    }

    func saveStats(_ stats: StatsFile) {
        if let encoded = try? JSONEncoder().encode(stats) {
            try? encoded.write(to: baseURL.appendingPathComponent("stats.json"))
        }
    }

    func loadStats() -> StatsFile {
        (try? Data(contentsOf: baseURL.appendingPathComponent("stats.json")))
            .flatMap { try? JSONDecoder().decode(StatsFile.self, from: $0) } ?? StatsFile()
    }

    /// Persists the list order (= queue priority) as hex hashes.
    func saveQueueOrder(_ hexHashes: [String]) {
        if let encoded = try? JSONEncoder().encode(hexHashes) {
            try? encoded.write(to: baseURL.appendingPathComponent("queue.json"))
        }
    }

    func loadQueueOrder() -> [String] {
        (try? Data(contentsOf: baseURL.appendingPathComponent("queue.json")))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    /// Torrents and pending magnets, ordered by the saved queue order;
    /// unknown ones follow by added-date.
    func loadEntries() -> [RestoreEntry] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: nil
        ) else { return [] }
        let queueIndex = Dictionary(
            uniqueKeysWithValues: loadQueueOrder().enumerated().map { ($1, $0) }
        )
        var results: [(RestoreEntry, Int, Double)] = []
        for entry in entries where entry.hasDirectoryPath {
            let position = queueIndex[entry.lastPathComponent] ?? .max
            if let torrentData = try? Data(contentsOf: entry.appendingPathComponent("meta.torrent")) {
                let resume = (try? Data(contentsOf: entry.appendingPathComponent("resume.json")))
                    .flatMap { try? JSONDecoder().decode(ResumeData.self, from: $0) }
                results.append((.torrent(data: torrentData, resume: resume), position, resume?.addedAt ?? 0))
            } else if let magnetData = try? Data(contentsOf: entry.appendingPathComponent("magnet.json")),
                      let record = try? JSONDecoder().decode(MagnetRecord.self, from: magnetData) {
                results.append((.magnet(record), position, record.addedAt))
            }
        }
        return results
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .map(\.0)
    }

    /// Resolved torrents only (magnets excluded).
    func loadAll() -> [(torrentData: Data, resume: ResumeData?)] {
        loadEntries().compactMap { entry in
            guard case .torrent(let data, let resume) = entry else { return nil }
            return (torrentData: data, resume: resume)
        }
    }
}

extension TorrentMetaInfo {
    /// Reassembles .torrent bytes from a raw info dictionary and tracker
    /// tiers (used to persist magnet-added torrents once metadata arrives).
    static func assembleTorrentData(infoDictData: Data, announceTiers: [[String]]) -> Data {
        var pairs: [(String, BValue)] = []
        if let first = announceTiers.first?.first {
            pairs.append(("announce", .string(first)))
        }
        if !announceTiers.isEmpty {
            pairs.append(("announce-list", .list(announceTiers.map { tier in
                BValue.list(tier.map { BValue.string($0) })
            })))
        }
        // Splice the raw info bytes in verbatim to preserve the info-hash.
        var data = Data([UInt8(ascii: "d")])
        data.append(Bencode.encode(.dictionary(pairs)).dropFirst().dropLast())
        data.append(Data("4:info".utf8))
        data.append(infoDictData)
        data.append(UInt8(ascii: "e"))
        return data
    }
}

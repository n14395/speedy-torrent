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

/// On-disk layout: `<base>/<infohash>/meta.torrent` + `resume.json`.
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

    /// Entries ordered by the saved queue order; unknown ones follow by
    /// added-date.
    func loadAll() -> [(torrentData: Data, resume: ResumeData?)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: nil
        ) else { return [] }
        let queueIndex = Dictionary(
            uniqueKeysWithValues: loadQueueOrder().enumerated().map { ($1, $0) }
        )
        var results: [(Data, ResumeData?, Int, Double)] = []
        for entry in entries where entry.hasDirectoryPath {
            guard let torrentData = try? Data(contentsOf: entry.appendingPathComponent("meta.torrent")) else {
                continue
            }
            let resume = (try? Data(contentsOf: entry.appendingPathComponent("resume.json")))
                .flatMap { try? JSONDecoder().decode(ResumeData.self, from: $0) }
            results.append((
                torrentData,
                resume,
                queueIndex[entry.lastPathComponent] ?? .max,
                resume?.addedAt ?? 0
            ))
        }
        return results
            .sorted { ($0.2, $0.3) < ($1.2, $1.3) }
            .map { ($0.0, $0.1) }
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

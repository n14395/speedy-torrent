import Foundation

/// A parsed .torrent file: the info dictionary plus tracker/metadata fields.
public struct TorrentMetaInfo: Sendable {
    public let info: TorrentInfo
    /// BEP 12 tiers; single-announce torrents get one single-entry tier.
    public let announceTiers: [[String]]
    /// BEP 19 web seeds (`url-list`): HTTP mirror URLs.
    public let webSeeds: [String]
    public let comment: String?
    public let creationDate: Date?

    public init(
        info: TorrentInfo,
        announceTiers: [[String]],
        webSeeds: [String] = [],
        comment: String? = nil,
        creationDate: Date? = nil
    ) {
        self.info = info
        self.announceTiers = announceTiers
        self.webSeeds = webSeeds
        self.comment = comment
        self.creationDate = creationDate
    }

    public init(torrentFileData: Data) throws {
        let raw = Data(torrentFileData)
        let decoded = try Bencode.decode(raw)
        guard decoded.dictionaryEntries != nil else { throw MetaInfoError.notADictionary }

        guard let infoEntry = decoded.entry(forKey: "info"), let range = infoEntry.valueRange else {
            throw MetaInfoError.missingField("info")
        }
        self.info = try TorrentInfo(bencodedData: raw.subdata(in: range))

        self.announceTiers = Self.parseAnnounceTiers(from: decoded)
        self.webSeeds = Self.parseWebSeeds(from: decoded)
        self.comment = decoded["comment"]?.stringValue
        self.creationDate = decoded["creation date"]?.integerValue.map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
    }

    static func parseAnnounceTiers(from decoded: BValue) -> [[String]] {
        if let tierList = decoded["announce-list"]?.listValue {
            let tiers = tierList.compactMap { tier -> [String]? in
                guard let urls = tier.listValue else { return nil }
                let valid = urls.compactMap(\.stringValue).filter { !$0.isEmpty }
                return valid.isEmpty ? nil : valid
            }
            if !tiers.isEmpty { return tiers }
        }
        if let announce = decoded["announce"]?.stringValue, !announce.isEmpty {
            return [[announce]]
        }
        return []
    }

    /// `url-list` may be a single string or a list of strings (BEP 19).
    static func parseWebSeeds(from decoded: BValue) -> [String] {
        guard let value = decoded["url-list"] else { return [] }
        if let single = value.stringValue, !single.isEmpty { return [single] }
        if let list = value.listValue {
            return list.compactMap(\.stringValue).filter { !$0.isEmpty }
        }
        return []
    }

    /// All tracker URLs flattened (deduplicated, tier order preserved).
    public var allTrackers: [String] {
        var seen = Set<String>()
        return announceTiers.flatMap { $0 }.filter { seen.insert($0).inserted }
    }
}

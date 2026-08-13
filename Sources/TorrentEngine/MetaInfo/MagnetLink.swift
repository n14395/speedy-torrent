import Foundation

/// A parsed magnet URI (BEP 9): magnet:?xt=urn:btih:<hash>&dn=<name>&tr=<tracker>
public struct MagnetLink: Sendable, Equatable {
    public let infoHash: InfoHash
    public let displayName: String?
    public let trackers: [String]

    public init(infoHash: InfoHash, displayName: String? = nil, trackers: [String] = []) {
        self.infoHash = infoHash
        self.displayName = displayName
        self.trackers = trackers
    }

    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("magnet:?") else { return nil }

        var infoHash: InfoHash?
        var displayName: String?
        var trackers: [String] = []

        for pair in trimmed.dropFirst("magnet:?".count).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            // Parameters may be numbered per the spec, e.g. "xt.1".
            let key = String(parts[0]).lowercased().split(separator: ".").first.map(String.init) ?? ""
            let rawValue = String(parts[1])
            switch key {
            case "xt":
                guard infoHash == nil, let value = rawValue.removingPercentEncoding else { break }
                let urn = value.lowercased()
                if urn.hasPrefix("urn:btih:") {
                    let hash = String(value.dropFirst("urn:btih:".count))
                    infoHash = hash.count == 40 ? InfoHash(hex: hash) : InfoHash(base32: hash)
                }
            case "dn":
                // '+' means space in this (form-encoded) context.
                displayName = rawValue
                    .replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding
            case "tr":
                if let tracker = rawValue.removingPercentEncoding, !tracker.isEmpty {
                    trackers.append(tracker)
                }
            default:
                break
            }
        }

        guard let infoHash else { return nil }
        self.infoHash = infoHash
        self.displayName = displayName
        self.trackers = trackers
    }
}

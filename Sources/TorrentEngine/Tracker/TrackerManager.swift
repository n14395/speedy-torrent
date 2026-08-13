import Foundation

/// Announces to a torrent's trackers with BEP 12 tier semantics: try tiers in
/// order, trackers within a tier in (initially shuffled) order, and move a
/// responding tracker to the front of its tier.
public actor TrackerManager {
    private var tiers: [[String]]
    private let http = HTTPTrackerClient()
    private let udp = UDPTrackerClient()
    /// Last error message per tracker URL (for UI display).
    public private(set) var lastErrors: [String: String] = [:]
    public private(set) var lastSuccess: [String: Date] = [:]

    public init(tiers: [[String]]) {
        self.tiers = tiers.map { $0.shuffled() }
    }

    public var allTrackers: [[String]] { tiers }

    /// Tries trackers per BEP 12 until one responds. Throws the last error if
    /// every tracker fails.
    public func announce(_ request: AnnounceRequest) async throws -> AnnounceResponse {
        var lastError: Error = TrackerError.unsupportedURL("no trackers")
        for tierIndex in tiers.indices {
            for urlIndex in tiers[tierIndex].indices {
                let url = tiers[tierIndex][urlIndex]
                do {
                    let response = try await announce(to: url, request: request)
                    // Promote the responder to the front of its tier.
                    tiers[tierIndex].remove(at: urlIndex)
                    tiers[tierIndex].insert(url, at: 0)
                    lastErrors[url] = nil
                    lastSuccess[url] = Date()
                    return response
                } catch {
                    lastError = error
                    lastErrors[url] = String(describing: error)
                }
            }
        }
        throw lastError
    }

    public func announce(to url: String, request: AnnounceRequest) async throws -> AnnounceResponse {
        let scheme = url.prefix(while: { $0 != ":" }).lowercased()
        switch scheme {
        case "http", "https":
            return try await http.announce(urlString: url, request: request)
        case "udp":
            return try await udp.announce(urlString: url, request: request)
        default:
            throw TrackerError.unsupportedURL(url)
        }
    }

    /// Best-effort announce to every tracker (used for stopped/completed events).
    public func announceAll(_ request: AnnounceRequest) async {
        for tier in tiers {
            for url in tier {
                _ = try? await announce(to: url, request: request)
            }
        }
    }
}

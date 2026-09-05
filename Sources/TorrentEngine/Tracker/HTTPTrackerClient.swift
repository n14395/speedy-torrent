import Foundation

/// HTTP(S) tracker announces per BEP 3, with compact peer lists (BEP 23) and
/// IPv6 extensions (BEP 7).
public struct HTTPTrackerClient: Sendable {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "SpeedyTorrent/\(TorrentEngineInfo.version)"
        ]
        session = URLSession(configuration: config)
    }

    public func announce(urlString: String, request: AnnounceRequest) async throws -> AnnounceResponse {
        guard let url = Self.buildURL(base: urlString, request: request) else {
            throw TrackerError.unsupportedURL(urlString)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw Self.translate(error)
        }
        // A tracker may bencode its "failure reason" alongside a 4xx/5xx, and
        // its own wording beats a bare status code — so only fall back to the
        // status when the body isn't a usable announce.
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            if let reason = Self.failureReason(data) {
                throw TrackerError.failure(reason)
            }
            throw TrackerError.failure("HTTP \(http.statusCode)")
        }
        return try Self.parseResponse(data)
    }

    /// Extracts a bencoded `failure reason`, if the body carries one.
    static func failureReason(_ data: Data) -> String? {
        guard let decoded = try? Bencode.decode(data) else { return nil }
        return decoded["failure reason"]?.stringValue
    }

    /// Turns URLSession's errors into the engine's vocabulary. Without this a
    /// raw `localizedDescription` ends up in the tracker list.
    static func translate(_ error: Error) -> TrackerError {
        guard let urlError = error as? URLError else {
            if error is CancellationError { return .network("Cancelled") }
            return .network((error as NSError).localizedDescription)
        }
        switch urlError.code {
        case .timedOut:
            return .timeout
        case .cannotFindHost, .dnsLookupFailed:
            return .network("Host not found")
        case .cannotConnectToHost:
            return .network("Connection refused")
        case .networkConnectionLost:
            return .network("Connection lost")
        case .notConnectedToInternet:
            return .network("No internet connection")
        case .secureConnectionFailed:
            return .network("Secure connection failed")
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return .network("Untrusted certificate")
        case .httpTooManyRedirects:
            return .network("Too many redirects")
        case .cancelled:
            return .network("Cancelled")
        case .badURL, .unsupportedURL:
            return .unsupportedURL(urlError.failingURL?.absoluteString ?? "")
        default:
            return .network(urlError.localizedDescription)
        }
    }

    static func buildURL(base: String, request: AnnounceRequest) -> URL? {
        guard let baseURL = URL(string: base),
              let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        var params: [(String, String)] = [
            ("info_hash", percentEncode(request.infoHash.data)),
            ("peer_id", percentEncode(request.peerID)),
            ("port", "\(request.port)"),
            ("uploaded", "\(request.uploaded)"),
            ("downloaded", "\(request.downloaded)"),
            ("left", "\(request.left)"),
            ("compact", "1"),
            ("numwant", "\(request.numWant)"),
            ("key", String(format: "%08x", request.key)),
        ]
        if let event = request.event.queryValue {
            params.append(("event", event))
        }
        let query = params.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let separator = base.contains("?") ? "&" : "?"
        return URL(string: base + separator + query)
    }

    /// Percent-encodes raw bytes for a query value: RFC 3986 unreserved
    /// characters pass through, everything else becomes %XX.
    static func percentEncode(_ data: Data) -> String {
        var out = ""
        for byte in data {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"),
                 UInt8(ascii: "."), UInt8(ascii: "~"):
                out.append(Character(UnicodeScalar(byte)))
            default:
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }

    static func parseResponse(_ data: Data) throws -> AnnounceResponse {
        let decoded: BValue
        do {
            decoded = try Bencode.decode(data)
        } catch {
            throw TrackerError.badResponse
        }
        if let failure = decoded["failure reason"]?.stringValue {
            throw TrackerError.failure(failure)
        }

        var peers: [PeerAddress] = []
        switch decoded["peers"] {
        case .some(.string(let compact)):
            peers += CompactPeers.parseIPv4(compact)
        case .some(.list(let entries)):
            // Non-compact dictionary form.
            for entry in entries {
                guard let host = entry["ip"]?.stringValue,
                      let port = entry["port"]?.integerValue,
                      let port16 = UInt16(exactly: port), port16 > 0
                else { continue }
                peers.append(PeerAddress(host: host, port: port16))
            }
        default:
            break
        }
        if let compact6 = decoded["peers6"]?.stringData {
            peers += CompactPeers.parseIPv6(compact6)
        }

        return AnnounceResponse(
            interval: decoded["interval"]?.integerValue ?? 1800,
            minInterval: decoded["min interval"]?.integerValue,
            peers: peers,
            seeders: decoded["complete"]?.integerValue,
            leechers: decoded["incomplete"]?.integerValue,
            warning: decoded["warning message"]?.stringValue
        )
    }
}

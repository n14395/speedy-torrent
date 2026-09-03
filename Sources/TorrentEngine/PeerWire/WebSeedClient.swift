import Foundation

/// GetRight-style web seeding (BEP 19): fetches whole pieces over HTTP using
/// Range requests, mapping each piece to one or more file byte-ranges.
struct WebSeedClient {
    let info: TorrentInfo
    let session: URLSession

    enum WebSeedError: Error {
        case badURL
        case httpStatus(Int)
        case shortResponse
        /// The server answered without a usable byte range — it ignored Range,
        /// or declared a body that isn't the slice we asked for.
        case rangeNotHonoured
    }

    init(info: TorrentInfo, session: URLSession = .shared) {
        self.info = info
        self.session = session
    }

    /// Fetches and concatenates the raw bytes of `pieceIndex` from `base`.
    ///
    /// The limiters are charged for every byte that actually crossed the wire,
    /// in the same order the peer wire uses them (the torrent's own bucket
    /// first, the contended session one last). Because a range arrives in one
    /// piece and the wait lands afterwards, enforcement here is average-rate:
    /// expect range-sized bursts rather than a smooth trickle. Only the
    /// download side is metered — a Range request's own headers are a rounding
    /// error next to its response.
    func fetchPiece(
        _ pieceIndex: Int,
        from base: String,
        torrentLimiter: RateLimiter? = nil,
        sessionLimiter: RateLimiter? = nil
    ) async throws -> Data {
        var assembled = Data(capacity: info.pieceSize(at: pieceIndex))
        for range in fileRanges(for: pieceIndex) {
            guard let url = Self.fileURL(base: base, info: info, fileIndex: range.fileIndex) else {
                throw WebSeedError.badURL
            }
            assembled.append(try await fetch(
                url, offset: range.offset, length: range.length,
                torrentLimiter: torrentLimiter, sessionLimiter: sessionLimiter
            ))
        }
        return assembled
    }

    /// The (file, offset, length) spans a piece occupies across files.
    func fileRanges(for pieceIndex: Int) -> [(fileIndex: Int, offset: Int64, length: Int)] {
        let pieceStart = Int64(pieceIndex) * Int64(info.pieceLength)
        let pieceEnd = pieceStart + Int64(info.pieceSize(at: pieceIndex))
        var result: [(Int, Int64, Int)] = []
        var fileStart: Int64 = 0
        for (index, file) in info.files.enumerated() {
            let fileEnd = fileStart + file.length
            let lo = max(pieceStart, fileStart)
            let hi = min(pieceEnd, fileEnd)
            if hi > lo {
                result.append((index, lo - fileStart, Int(hi - lo)))
            }
            fileStart = fileEnd
        }
        return result
    }

    private func fetch(
        _ url: URL,
        offset: Int64,
        length: Int,
        torrentLimiter: RateLimiter?,
        sessionLimiter: RateLimiter?
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        // Charged before the response is even inspected, and on what arrived
        // rather than what we keep: bytes that crossed the link are real
        // whether or not we end up using them.
        await torrentLimiter?.acquire(data.count)
        await sessionLimiter?.acquire(data.count)
        guard let http = response as? HTTPURLResponse else { throw WebSeedError.shortResponse }
        guard http.statusCode == 206 else {
            // A 200 means the server ignored Range and sent the whole file.
            // We used to slice our part out of it — but `data(for:)` has
            // already buffered the entire body by then, so a 4 GB file in the
            // torrent was a 4 GB allocation, retried in a loop. A mirror that
            // won't do ranges is not a usable web seed; rotate to the next one.
            throw http.statusCode == 200
                ? WebSeedError.rangeNotHonoured
                : WebSeedError.httpStatus(http.statusCode)
        }
        // A single-range 206 must carry Content-Length (RFC 7233), and
        // URLSession bounds the body by it — so agreeing here also bounds what
        // could have been buffered. A 206 sent chunked with no length is the
        // one case left unbounded; it is non-conformant and rare.
        guard http.expectedContentLength == Int64(length) else {
            throw WebSeedError.rangeNotHonoured
        }
        guard data.count == length else { throw WebSeedError.shortResponse }
        return data
    }

    /// Builds the URL for a file under a web-seed base (BEP 19).
    static func fileURL(base: String, info: TorrentInfo, fileIndex: Int) -> URL? {
        func encode(_ component: String) -> String {
            component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
        }
        if info.isDirectory {
            // Multi-file: base + name + file path.
            var string = base.hasSuffix("/") ? base : base + "/"
            string += encode(info.name) + "/"
            string += info.files[fileIndex].path.map(encode).joined(separator: "/")
            return URL(string: string)
        }
        // Single-file: a trailing slash means "directory, append the name".
        if base.hasSuffix("/") {
            return URL(string: base + encode(info.name))
        }
        return URL(string: base)
    }
}

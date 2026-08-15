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
    }

    init(info: TorrentInfo, session: URLSession = .shared) {
        self.info = info
        self.session = session
    }

    /// Fetches and concatenates the raw bytes of `pieceIndex` from `base`.
    func fetchPiece(_ pieceIndex: Int, from base: String) async throws -> Data {
        var assembled = Data(capacity: info.pieceSize(at: pieceIndex))
        for range in fileRanges(for: pieceIndex) {
            guard let url = Self.fileURL(base: base, info: info, fileIndex: range.fileIndex) else {
                throw WebSeedError.badURL
            }
            assembled.append(try await fetch(url, offset: range.offset, length: range.length))
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

    private func fetch(_ url: URL, offset: Int64, length: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebSeedError.shortResponse }
        switch http.statusCode {
        case 206:
            guard data.count == length else { throw WebSeedError.shortResponse }
            return data
        case 200:
            // Server ignored Range and sent the whole file; slice our part out.
            let start = Int(offset)
            guard data.count >= start + length else { throw WebSeedError.shortResponse }
            return data.subdata(in: start..<start + length)
        default:
            throw WebSeedError.httpStatus(http.statusCode)
        }
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

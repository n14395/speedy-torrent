import Foundation
import CryptoKit

/// Creates .torrent data from files on disk (used by tests, the loopback E2E
/// harness, and `storrent create`).
public enum TorrentBuilder {
    public enum BuilderError: Error {
        case emptyContent
        case notFound(String)
    }

    public static func makeTorrentData(
        contentsOf url: URL,
        pieceLength: Int = 256 * 1024,
        announceTiers: [[String]] = [],
        isPrivate: Bool = false
    ) throws -> Data {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw BuilderError.notFound(url.path)
        }

        let name = url.lastPathComponent
        var fileURLs: [(components: [String], url: URL)] = []
        if isDirectory.boolValue {
            let keys: [URLResourceKey] = [.isRegularFileKey]
            guard let enumerator = fileManager.enumerator(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { throw BuilderError.notFound(url.path) }
            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }
                let components = fileURL.standardizedFileURL.pathComponents
                    .dropFirst(url.standardizedFileURL.pathComponents.count)
                fileURLs.append((Array(components), fileURL))
            }
            // Deterministic order so identical content always yields the same info-hash.
            fileURLs.sort { $0.components.joined(separator: "/") < $1.components.joined(separator: "/") }
        } else {
            fileURLs = [([name], url)]
        }
        guard !fileURLs.isEmpty else { throw BuilderError.emptyContent }

        // Hash pieces across the concatenation of all files.
        var pieces = Data()
        var pieceBuffer = Data()
        var totalLength: Int64 = 0
        var entries: [(components: [String], length: Int64)] = []
        for file in fileURLs {
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            var fileLength: Int64 = 0
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                fileLength += Int64(chunk.count)
                pieceBuffer.append(chunk)
                while pieceBuffer.count >= pieceLength {
                    pieces.append(Data(Insecure.SHA1.hash(data: pieceBuffer.prefix(pieceLength))))
                    pieceBuffer = Data(pieceBuffer.dropFirst(pieceLength))
                }
            }
            totalLength += fileLength
            entries.append((file.components, fileLength))
        }
        if !pieceBuffer.isEmpty {
            pieces.append(Data(Insecure.SHA1.hash(data: pieceBuffer)))
        }
        guard totalLength > 0 else { throw BuilderError.emptyContent }

        var infoPairs: [(String, BValue)] = [
            ("name", .string(name)),
            ("piece length", .integer(pieceLength)),
            ("pieces", .string(pieces)),
        ]
        if isDirectory.boolValue {
            let fileValues = entries.map { entry in
                BValue.dictionary([
                    ("length", .integer(Int(entry.length))),
                    ("path", .list(entry.components.map { BValue.string($0) })),
                ])
            }
            infoPairs.append(("files", .list(fileValues)))
        } else {
            infoPairs.append(("length", .integer(Int(totalLength))))
        }
        if isPrivate {
            infoPairs.append(("private", .integer(1)))
        }

        var topPairs: [(String, BValue)] = []
        if let first = announceTiers.first?.first {
            topPairs.append(("announce", .string(first)))
        }
        if !announceTiers.isEmpty {
            let tierValues = announceTiers.map { tier in
                BValue.list(tier.map { BValue.string($0) })
            }
            topPairs.append(("announce-list", .list(tierValues)))
        }
        topPairs.append(("info", .dictionary(infoPairs)))

        return Bencode.encode(.dictionary(topPairs))
    }
}

// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum MetaInfoError: Error, Equatable, Sendable {
    case notADictionary
    case missingField(String)
    case invalidField(String)
    case unsafePath(String)
}

public struct FileEntry: Sendable, Equatable {
    /// Sanitized path components relative to the torrent's root directory.
    public let path: [String]
    public let length: Int64

    public init(path: [String], length: Int64) {
        self.path = path
        self.length = length
    }
}

/// Parsed from the raw bencoded info dictionary (BEP 3). This is all a peer
/// needs to download/verify data, whether it came from a .torrent file or a
/// magnet metadata exchange.
public struct TorrentInfo: Sendable {
    public let infoHash: InfoHash
    public let name: String
    public let pieceLength: Int
    public let pieceHashes: [Data]
    /// Always non-empty; single-file torrents have one entry with path [name].
    public let files: [FileEntry]
    public let totalLength: Int64
    public let isPrivate: Bool
    /// The exact bencoded bytes this was parsed from (persisted, and served
    /// to peers via ut_metadata).
    public let rawData: Data

    /// True when the data occupies a directory named `name` (multi-file mode).
    public let isDirectory: Bool

    public var pieceCount: Int { pieceHashes.count }

    public func pieceSize(at index: Int) -> Int {
        precondition(index >= 0 && index < pieceCount)
        if index == pieceCount - 1 {
            let remainder = Int(totalLength % Int64(pieceLength))
            return remainder == 0 ? pieceLength : remainder
        }
        return pieceLength
    }

    public init(bencodedData: Data) throws {
        let raw = Data(bencodedData)
        let value = try Bencode.decode(raw)
        try self.init(decoded: value, rawData: raw)
    }

    init(decoded: BValue, rawData: Data) throws {
        guard decoded.dictionaryEntries != nil else { throw MetaInfoError.notADictionary }

        guard let nameData = decoded["name"]?.stringData else {
            throw MetaInfoError.missingField("name")
        }
        let name = try Self.sanitizeComponent(String(decoding: nameData, as: UTF8.self))

        guard let pieceLength = decoded["piece length"]?.integerValue else {
            throw MetaInfoError.missingField("piece length")
        }
        guard pieceLength > 0, pieceLength <= 512 * 1024 * 1024 else {
            throw MetaInfoError.invalidField("piece length")
        }

        guard let piecesData = decoded["pieces"]?.stringData else {
            throw MetaInfoError.missingField("pieces")
        }
        guard !piecesData.isEmpty, piecesData.count % InfoHash.byteCount == 0 else {
            throw MetaInfoError.invalidField("pieces")
        }
        var pieceHashes: [Data] = []
        pieceHashes.reserveCapacity(piecesData.count / InfoHash.byteCount)
        var cursor = piecesData.startIndex
        while cursor < piecesData.endIndex {
            let next = piecesData.index(cursor, offsetBy: InfoHash.byteCount)
            pieceHashes.append(Data(piecesData[cursor..<next]))
            cursor = next
        }

        let files: [FileEntry]
        let isDirectory: Bool
        switch (decoded["length"], decoded["files"]) {
        case (.some(let lengthValue), nil):
            guard let length = lengthValue.integerValue, length >= 0 else {
                throw MetaInfoError.invalidField("length")
            }
            files = [FileEntry(path: [name], length: Int64(length))]
            isDirectory = false
        case (nil, .some(let filesValue)):
            guard let fileList = filesValue.listValue, !fileList.isEmpty else {
                throw MetaInfoError.invalidField("files")
            }
            files = try fileList.map { fileValue in
                guard let length = fileValue["length"]?.integerValue, length >= 0 else {
                    throw MetaInfoError.invalidField("files.length")
                }
                guard let pathList = fileValue["path"]?.listValue, !pathList.isEmpty else {
                    throw MetaInfoError.invalidField("files.path")
                }
                let components = try pathList.map { component -> String in
                    guard let data = component.stringData else {
                        throw MetaInfoError.invalidField("files.path")
                    }
                    return try Self.sanitizeComponent(String(decoding: data, as: UTF8.self))
                }
                return FileEntry(path: components, length: Int64(length))
            }
            isDirectory = true
        default:
            throw MetaInfoError.invalidField("exactly one of length/files required")
        }

        // Two entries with the same path map to one file on disk, so both would
        // write to it at different global offsets and silently corrupt each
        // other. (Distinct raw paths can also collide here: decoding invalid
        // UTF-8 replaces bad bytes with U+FFFD, which can merge two names.)
        var seenPaths = Set<String>()
        for file in files where !seenPaths.insert(file.path.joined(separator: "/")).inserted {
            throw MetaInfoError.invalidField("duplicate file path")
        }

        let totalLength = files.reduce(Int64(0)) { $0 + $1.length }
        guard totalLength > 0 else { throw MetaInfoError.invalidField("total length") }

        let expectedPieces = Int((totalLength + Int64(pieceLength) - 1) / Int64(pieceLength))
        guard expectedPieces == pieceHashes.count else {
            throw MetaInfoError.invalidField("piece count mismatch")
        }

        self.infoHash = InfoHash(hashing: rawData)
        self.name = name
        self.pieceLength = pieceLength
        self.pieceHashes = pieceHashes
        self.files = files
        self.totalLength = totalLength
        self.isPrivate = decoded["private"]?.integerValue == 1
        self.rawData = rawData
        self.isDirectory = isDirectory
    }

    /// Rejects path components that could escape the download directory.
    static func sanitizeComponent(_ raw: String) throws -> String {
        let component = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !component.isEmpty, component != ".", component != "..",
              !component.contains("/"), !component.contains("\0")
        else { throw MetaInfoError.unsafePath(raw) }
        return component
    }
}

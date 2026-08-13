import Foundation

/// BEP 10 extension handshake (extended message id 0) and BEP 9 ut_metadata.
enum ExtensionHandshake {
    /// Our local message ID for ut_metadata, advertised in the handshake.
    static let utMetadataID: UInt8 = 3

    static func encode(metadataSize: Int?, listenPort: UInt16?) -> Data {
        var pairs: [(String, BValue)] = [
            ("m", .dictionary([("ut_metadata", .integer(Int(utMetadataID)))])),
            ("v", .string("SpeedyTorrent \(TorrentEngineInfo.version)")),
        ]
        if let metadataSize {
            pairs.append(("metadata_size", .integer(metadataSize)))
        }
        if let listenPort, listenPort > 0 {
            pairs.append(("p", .integer(Int(listenPort))))
        }
        return Bencode.encode(.dictionary(pairs))
    }

    struct Parsed {
        let utMetadataID: UInt8?
        let metadataSize: Int?
    }

    static func parse(_ payload: Data) -> Parsed? {
        guard let value = try? Bencode.decode(payload) else { return nil }
        let utID = value["m"]?["ut_metadata"]?.integerValue
            .flatMap { UInt8(exactly: $0) }
        let size = value["metadata_size"]?.integerValue
        return Parsed(utMetadataID: utID.flatMap { $0 == 0 ? nil : $0 }, metadataSize: size)
    }
}

/// BEP 9 metadata exchange messages: a bencoded header optionally followed by
/// a raw 16 KiB metadata chunk.
enum UTMetadata {
    static let pieceSize = 16 * 1024
    /// Sanity cap — real info dictionaries are far smaller.
    static let maxMetadataSize = 8 * 1024 * 1024

    enum MessageType: Int {
        case request = 0
        case data = 1
        case reject = 2
    }

    static func request(piece: Int) -> Data {
        Bencode.encode(.dictionary([
            ("msg_type", .integer(MessageType.request.rawValue)),
            ("piece", .integer(piece)),
        ]))
    }

    static func data(piece: Int, totalSize: Int, chunk: Data) -> Data {
        var out = Bencode.encode(.dictionary([
            ("msg_type", .integer(MessageType.data.rawValue)),
            ("piece", .integer(piece)),
            ("total_size", .integer(totalSize)),
        ]))
        out.append(chunk)
        return out
    }

    static func reject(piece: Int) -> Data {
        Bencode.encode(.dictionary([
            ("msg_type", .integer(MessageType.reject.rawValue)),
            ("piece", .integer(piece)),
        ]))
    }

    struct Parsed {
        let type: MessageType
        let piece: Int
        let totalSize: Int?
        let trailing: Data
    }

    static func parse(_ payload: Data) -> Parsed? {
        guard let (header, consumed) = try? Bencode.decodePrefix(payload),
              let rawType = header["msg_type"]?.integerValue,
              let type = MessageType(rawValue: rawType),
              let piece = header["piece"]?.integerValue, piece >= 0
        else { return nil }
        return Parsed(
            type: type,
            piece: piece,
            totalSize: header["total_size"]?.integerValue,
            trailing: payload.readData(at: consumed, count: payload.count - consumed) ?? Data()
        )
    }
}

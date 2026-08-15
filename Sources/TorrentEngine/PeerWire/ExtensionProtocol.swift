import Foundation

/// BEP 10 extension handshake (extended message id 0), BEP 9 ut_metadata, and
/// BEP 11 ut_pex.
enum ExtensionHandshake {
    /// Our local message IDs, advertised in the handshake `m` dictionary.
    static let utMetadataID: UInt8 = 3
    static let utPexID: UInt8 = 1

    /// `pexID` is nil for private torrents and magnet metadata fetches, which
    /// must not advertise peer exchange.
    static func encode(metadataSize: Int?, listenPort: UInt16?, pexID: UInt8? = nil) -> Data {
        var m: [(String, BValue)] = [("ut_metadata", .integer(Int(utMetadataID)))]
        if let pexID {
            m.append(("ut_pex", .integer(Int(pexID))))
        }
        var pairs: [(String, BValue)] = [
            ("m", .dictionary(m)),
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
        let utPexID: UInt8?
        let metadataSize: Int?
        /// The peer's own TCP listen port (`p`), used to gossip a reachable
        /// endpoint for peers that connected to us.
        let listenPort: UInt16?
        /// The peer's client name/version (`v`), for the inspector.
        let client: String?
    }

    static func parse(_ payload: Data) -> Parsed? {
        guard let value = try? Bencode.decode(payload) else { return nil }
        let utID = value["m"]?["ut_metadata"]?.integerValue.flatMap { UInt8(exactly: $0) }
        let pexID = value["m"]?["ut_pex"]?.integerValue.flatMap { UInt8(exactly: $0) }
        return Parsed(
            utMetadataID: utID.flatMap { $0 == 0 ? nil : $0 },
            utPexID: pexID.flatMap { $0 == 0 ? nil : $0 },
            metadataSize: value["metadata_size"]?.integerValue,
            listenPort: value["p"]?.integerValue.flatMap { UInt16(exactly: $0) },
            client: value["v"]?.stringValue
        )
    }
}

/// BEP 11 peer exchange (ut_pex): periodic added/dropped peer deltas. We send
/// IPv4 peers and ingest both IPv4 (`added`) and IPv6 (`added6`).
enum UTPex {
    /// Never advertise more than this many peers in one message (BEP 11).
    static let maxPerMessage = 50
    /// Ignore absurdly large added lists from a misbehaving peer.
    static let maxIngest = 200

    static func encode(added: [PeerAddress], dropped: [PeerAddress]) -> Data {
        let addedData = CompactPeers.encodeIPv4(added)
        return Bencode.encode(.dictionary([
            ("added", .string(addedData)),
            // One flags byte per added peer; 0 = no advertised capabilities.
            ("added.f", .string(Data(repeating: 0, count: addedData.count / 6))),
            ("dropped", .string(CompactPeers.encodeIPv4(dropped))),
        ]))
    }

    /// The peers a received message advertises as newly added (IPv4 + IPv6).
    static func parseAdded(_ payload: Data) -> [PeerAddress] {
        guard let value = try? Bencode.decode(payload) else { return [] }
        var peers: [PeerAddress] = []
        if let v4 = value["added"]?.stringData {
            peers += CompactPeers.parseIPv4(v4)
        }
        if let v6 = value["added6"]?.stringData {
            peers += CompactPeers.parseIPv6(v6)
        }
        return Array(peers.prefix(maxIngest))
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

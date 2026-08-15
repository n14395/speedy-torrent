import Foundation

/// A peer endpoint as discovered from trackers, DHT, or incoming connections.
public struct PeerAddress: Sendable, Hashable, CustomStringConvertible {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

public enum CompactPeers {
    /// BEP 23: concatenated 6-byte entries (4-byte IPv4 + 2-byte port).
    public static func parseIPv4(_ data: Data) -> [PeerAddress] {
        parse(data, addressBytes: 4) { bytes in
            bytes.map(String.init).joined(separator: ".")
        }
    }

    /// BEP 7: concatenated 18-byte entries (16-byte IPv6 + 2-byte port).
    public static func parseIPv6(_ data: Data) -> [PeerAddress] {
        parse(data, addressBytes: 16) { bytes in
            stride(from: 0, to: 16, by: 2)
                .map { String(format: "%x", Int(bytes[$0]) << 8 | Int(bytes[$0 + 1])) }
                .joined(separator: ":")
        }
    }

    /// BEP 23: encode peers with dotted-quad IPv4 hosts into 6-byte entries.
    /// Non-IPv4 hosts (e.g. IPv6) are skipped — callers advertise those via a
    /// separate `added6` field if at all.
    public static func encodeIPv4(_ peers: [PeerAddress]) -> Data {
        var out = Data(capacity: peers.count * 6)
        for peer in peers {
            let parts = peer.host.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4, peer.port > 0 else { continue }
            let octets = parts.compactMap { UInt8($0) }
            guard octets.count == 4 else { continue }
            out.append(contentsOf: octets)
            out.appendUInt16(peer.port)
        }
        return out
    }

    private static func parse(
        _ data: Data, addressBytes: Int, format: ([UInt8]) -> String
    ) -> [PeerAddress] {
        let entrySize = addressBytes + 2
        guard data.count % entrySize == 0 else { return [] }
        var peers: [PeerAddress] = []
        peers.reserveCapacity(data.count / entrySize)
        var offset = 0
        while offset < data.count {
            guard let address = data.readData(at: offset, count: addressBytes),
                  let port = data.readUInt16(at: offset + addressBytes)
            else { break }
            if port > 0 {
                peers.append(PeerAddress(host: format([UInt8](address)), port: port))
            }
            offset += entrySize
        }
        return peers
    }
}

public enum PeerID {
    /// BEP 20 Azureus-style: 8-byte client prefix + 12 random bytes.
    public static func generate() -> Data {
        var data = Data(TorrentEngineInfo.peerIDPrefix.utf8)
        let alphabet = [UInt8]("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        for _ in 0..<12 {
            data.append(alphabet.randomElement()!)
        }
        return data
    }
}

/// Best-effort client identification for the inspector.
public enum PeerClient {
    /// Prefers the BEP 10 `v` string; falls back to decoding the BEP 20 peer ID.
    public static func describe(peerID: Data, version: String?) -> String {
        if let version, !version.isEmpty { return version }
        return fromPeerID(peerID)
    }

    private static let names: [String: String] = [
        "AZ": "Azureus", "qB": "qBittorrent", "UT": "µTorrent", "UM": "µTorrent",
        "UW": "µTorrent Web", "TR": "Transmission", "DE": "Deluge", "LT": "libtorrent",
        "lt": "libtorrent", "BT": "BitTorrent", "BW": "BitTorrent", "ST": "SpeedyTorrent",
        "TX": "Tixati", "FD": "Free Download Manager", "WD": "WebTorrent",
    ]

    private static func fromPeerID(_ peerID: Data) -> String {
        let bytes = [UInt8](peerID)
        guard bytes.count >= 8,
              bytes[0] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-")
        else { return "unknown" }
        let code = String(decoding: bytes[1...2], as: UTF8.self)
        let name = names[code] ?? code
        let digits = bytes[3..<7].map { Character(UnicodeScalar($0)) }
        let version = digits.allSatisfy(\.isNumber)
            ? digits.map(String.init).joined(separator: ".")
            : String(digits)
        return version.isEmpty ? name : "\(name) \(version)"
    }
}

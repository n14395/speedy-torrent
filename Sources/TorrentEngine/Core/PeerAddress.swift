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

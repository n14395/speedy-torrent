import Foundation

/// KRPC message codec for BEP 5 — bencoded dictionaries over UDP.
enum KRPC {
    struct NodeInfo: Hashable, Sendable {
        let id: Data // 20 bytes
        let address: PeerAddress
    }

    enum Message: Sendable {
        case query(transaction: Data, method: String, arguments: BValue)
        case response(transaction: Data, body: BValue)
        case error(transaction: Data, code: Int, message: String)
    }

    static func decode(_ data: Data) -> Message? {
        guard let value = try? Bencode.decode(data),
              let transaction = value["t"]?.stringData,
              let type = value["y"]?.stringValue
        else { return nil }
        switch type {
        case "q":
            guard let method = value["q"]?.stringValue,
                  let arguments = value["a"], arguments.dictionaryEntries != nil
            else { return nil }
            return .query(transaction: transaction, method: method, arguments: arguments)
        case "r":
            guard let body = value["r"], body.dictionaryEntries != nil else { return nil }
            return .response(transaction: transaction, body: body)
        case "e":
            let list = value["e"]?.listValue
            return .error(
                transaction: transaction,
                code: list?.first?.integerValue ?? 0,
                message: list?.dropFirst().first?.stringValue ?? ""
            )
        default:
            return nil
        }
    }

    static func encodeQuery(transaction: Data, method: String, arguments: [(String, BValue)]) -> Data {
        Bencode.encode(.dictionary([
            ("a", .dictionary(arguments)),
            ("q", .string(method)),
            ("t", .string(transaction)),
            ("y", .string("q")),
        ]))
    }

    static func encodeResponse(transaction: Data, body: [(String, BValue)]) -> Data {
        Bencode.encode(.dictionary([
            ("r", .dictionary(body)),
            ("t", .string(transaction)),
            ("y", .string("r")),
        ]))
    }

    static func encodeError(transaction: Data, code: Int, message: String) -> Data {
        Bencode.encode(.dictionary([
            ("e", .list([.integer(code), .string(message)])),
            ("t", .string(transaction)),
            ("y", .string("e")),
        ]))
    }

    /// 26-byte compact node entries: 20-byte ID + 4-byte IPv4 + 2-byte port.
    static func parseCompactNodes(_ data: Data) -> [NodeInfo] {
        guard data.count % 26 == 0 else { return [] }
        var nodes: [NodeInfo] = []
        var offset = 0
        while offset < data.count {
            guard let id = data.readData(at: offset, count: 20),
                  let addressData = data.readData(at: offset + 20, count: 6),
                  let peer = CompactPeers.parseIPv4(addressData).first
            else { break }
            nodes.append(NodeInfo(id: id, address: peer))
            offset += 26
        }
        return nodes
    }

    static func encodeCompactNodes(_ nodes: [NodeInfo]) -> Data {
        var out = Data(capacity: nodes.count * 26)
        for node in nodes {
            out.append(node.id)
            out.append(encodeCompactPeer(node.address) ?? Data(count: 6))
        }
        return out
    }

    static func encodeCompactPeer(_ address: PeerAddress) -> Data? {
        let parts = address.host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        var out = Data(parts)
        out.appendUInt16(address.port)
        return out
    }
}

/// XOR metric helpers over 20-byte IDs.
enum NodeID {
    static func random() -> Data {
        Data((0..<20).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func distance(_ a: Data, _ b: Data) -> Data {
        precondition(a.count == 20 && b.count == 20)
        return Data(zip(a, b).map(^))
    }

    static func isCloser(_ a: Data, than b: Data, to target: Data) -> Bool {
        distance(a, target).lexicographicallyPrecedes(distance(b, target))
    }

    /// Length of the common prefix (in bits) between two IDs — the bucket index.
    static func commonPrefixBits(_ a: Data, _ b: Data) -> Int {
        for (index, pair) in zip(a, b).enumerated() {
            let xor = pair.0 ^ pair.1
            if xor != 0 {
                return index * 8 + xor.leadingZeroBitCount
            }
        }
        return 160
    }
}

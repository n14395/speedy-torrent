import Foundation

public enum PeerWireError: Error, Equatable {
    case connectionClosed
    case handshakeFailed(String)
    case oversizedMessage(Int)
    case malformedMessage
    case timeout
    case network(String)
}

/// BEP 3 peer wire messages, plus BEP 10 extension messages.
public enum PeerMessage: Sendable, Equatable {
    case keepAlive
    case choke
    case unchoke
    case interested
    case notInterested
    case have(UInt32)
    case bitfield(Data)
    case request(index: UInt32, begin: UInt32, length: UInt32)
    case piece(index: UInt32, begin: UInt32, block: Data)
    case cancel(index: UInt32, begin: UInt32, length: UInt32)
    case port(UInt16)
    case extended(id: UInt8, payload: Data)

    /// Anything larger is treated as a protocol violation (the largest legal
    /// messages are 16 KiB piece blocks and metadata pieces, plus bitfields
    /// for very large torrents).
    public static let maxPayloadLength = 4 * 1024 * 1024

    public func encoded() -> Data {
        var payload = Data()
        switch self {
        case .keepAlive:
            break
        case .choke: payload.appendUInt8(0)
        case .unchoke: payload.appendUInt8(1)
        case .interested: payload.appendUInt8(2)
        case .notInterested: payload.appendUInt8(3)
        case .have(let index):
            payload.appendUInt8(4)
            payload.appendUInt32(index)
        case .bitfield(let bits):
            payload.appendUInt8(5)
            payload.append(bits)
        case .request(let index, let begin, let length):
            payload.appendUInt8(6)
            payload.appendUInt32(index)
            payload.appendUInt32(begin)
            payload.appendUInt32(length)
        case .piece(let index, let begin, let block):
            payload.appendUInt8(7)
            payload.appendUInt32(index)
            payload.appendUInt32(begin)
            payload.append(block)
        case .cancel(let index, let begin, let length):
            payload.appendUInt8(8)
            payload.appendUInt32(index)
            payload.appendUInt32(begin)
            payload.appendUInt32(length)
        case .port(let port):
            payload.appendUInt8(9)
            payload.appendUInt16(port)
        case .extended(let id, let body):
            payload.appendUInt8(20)
            payload.appendUInt8(id)
            payload.append(body)
        }
        var out = Data(capacity: payload.count + 4)
        out.appendUInt32(UInt32(payload.count))
        out.append(payload)
        return out
    }

    /// Decodes a message payload (without the 4-byte length prefix).
    public static func decode(payload: Data) throws -> PeerMessage {
        guard !payload.isEmpty else { return .keepAlive }
        guard let id = payload.readUInt8(at: 0) else { throw PeerWireError.malformedMessage }
        let body = payload.count - 1
        switch id {
        case 0: return .choke
        case 1: return .unchoke
        case 2: return .interested
        case 3: return .notInterested
        case 4:
            guard body == 4, let index = payload.readUInt32(at: 1) else {
                throw PeerWireError.malformedMessage
            }
            return .have(index)
        case 5:
            guard let bits = payload.readData(at: 1, count: body) else {
                throw PeerWireError.malformedMessage
            }
            return .bitfield(bits)
        case 6, 8:
            guard body == 12,
                  let index = payload.readUInt32(at: 1),
                  let begin = payload.readUInt32(at: 5),
                  let length = payload.readUInt32(at: 9)
            else { throw PeerWireError.malformedMessage }
            return id == 6
                ? .request(index: index, begin: begin, length: length)
                : .cancel(index: index, begin: begin, length: length)
        case 7:
            guard body >= 8,
                  let index = payload.readUInt32(at: 1),
                  let begin = payload.readUInt32(at: 5),
                  let block = payload.readData(at: 9, count: body - 8)
            else { throw PeerWireError.malformedMessage }
            return .piece(index: index, begin: begin, block: block)
        case 9:
            guard body == 2, let port = payload.readUInt16(at: 1) else {
                throw PeerWireError.malformedMessage
            }
            return .port(port)
        case 20:
            guard body >= 1, let extID = payload.readUInt8(at: 1),
                  let extPayload = payload.readData(at: 2, count: body - 1)
            else { throw PeerWireError.malformedMessage }
            return .extended(id: extID, payload: extPayload)
        default:
            throw PeerWireError.malformedMessage
        }
    }
}

/// The 68-byte BEP 3 handshake.
public struct Handshake: Sendable, Equatable {
    public static let length = 68
    static let protocolString = "BitTorrent protocol"

    public let infoHash: InfoHash
    public let peerID: Data
    public let supportsExtensions: Bool // BEP 10, reserved byte 5 bit 0x10
    public let supportsDHT: Bool        // BEP 5, reserved byte 7 bit 0x01

    public init(infoHash: InfoHash, peerID: Data, supportsExtensions: Bool = true, supportsDHT: Bool = true) {
        self.infoHash = infoHash
        self.peerID = peerID
        self.supportsExtensions = supportsExtensions
        self.supportsDHT = supportsDHT
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.length)
        data.appendUInt8(19)
        data.append(contentsOf: Array(Self.protocolString.utf8))
        var reserved = [UInt8](repeating: 0, count: 8)
        if supportsExtensions { reserved[5] |= 0x10 }
        if supportsDHT { reserved[7] |= 0x01 }
        data.append(contentsOf: reserved)
        data.append(infoHash.data)
        data.append(peerID)
        return data
    }

    public static func decode(_ data: Data) throws -> Handshake {
        guard data.count == length,
              data.readUInt8(at: 0) == 19,
              data.readData(at: 1, count: 19) == Data(protocolString.utf8),
              let reserved = data.readData(at: 20, count: 8),
              let hashData = data.readData(at: 28, count: 20),
              let infoHash = InfoHash(data: hashData),
              let peerID = data.readData(at: 48, count: 20)
        else { throw PeerWireError.handshakeFailed("malformed handshake") }
        return Handshake(
            infoHash: infoHash,
            peerID: peerID,
            supportsExtensions: reserved[reserved.startIndex + 5] & 0x10 != 0,
            supportsDHT: reserved[reserved.startIndex + 7] & 0x01 != 0
        )
    }
}

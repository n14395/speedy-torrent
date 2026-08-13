import Foundation

public enum BencodeError: Error, Equatable, Sendable {
    case truncated
    case invalidInteger
    case invalidStringLength
    case unexpectedToken(offset: Int)
    case nonStringDictionaryKey
    case depthLimitExceeded
    case trailingData(offset: Int)
}

public enum Bencode {
    /// Recursion cap so malicious input can't blow the stack.
    static let maxDepth = 64

    /// Decodes a single value; the input must be fully consumed.
    public static func decode(_ data: Data) throws -> BValue {
        var parser = Parser(bytes: [UInt8](data))
        let value = try parser.parseValue(depth: 0)
        guard parser.offset == parser.bytes.count else {
            throw BencodeError.trailingData(offset: parser.offset)
        }
        return value
    }

    /// Decodes a single value from the front of the buffer, returning how
    /// many bytes it consumed (for stream contexts).
    public static func decodePrefix(_ data: Data) throws -> (value: BValue, consumed: Int) {
        var parser = Parser(bytes: [UInt8](data))
        let value = try parser.parseValue(depth: 0)
        return (value, parser.offset)
    }

    /// Canonical encoding: dictionary entries sorted by raw key bytes.
    public static func encode(_ value: BValue) -> Data {
        var out = Data()
        append(value, to: &out)
        return out
    }

    private static func append(_ value: BValue, to out: inout Data) {
        switch value {
        case .string(let data):
            out.append(contentsOf: Array("\(data.count):".utf8))
            out.append(data)
        case .integer(let number):
            out.append(contentsOf: Array("i\(number)e".utf8))
        case .list(let items):
            out.append(UInt8(ascii: "l"))
            for item in items { append(item, to: &out) }
            out.append(UInt8(ascii: "e"))
        case .dictionary(let entries):
            out.append(UInt8(ascii: "d"))
            let sorted = entries.sorted { $0.key.lexicographicallyPrecedes($1.key) }
            for entry in sorted {
                append(.string(entry.key), to: &out)
                append(entry.value, to: &out)
            }
            out.append(UInt8(ascii: "e"))
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        private static let zero = UInt8(ascii: "0")
        private static let nine = UInt8(ascii: "9")

        mutating func parseValue(depth: Int) throws -> BValue {
            guard depth < Bencode.maxDepth else { throw BencodeError.depthLimitExceeded }
            guard offset < bytes.count else { throw BencodeError.truncated }
            switch bytes[offset] {
            case UInt8(ascii: "i"):
                return .integer(try parseInteger())
            case Self.zero...Self.nine:
                return .string(try parseString())
            case UInt8(ascii: "l"):
                offset += 1
                var items: [BValue] = []
                while true {
                    guard offset < bytes.count else { throw BencodeError.truncated }
                    if bytes[offset] == UInt8(ascii: "e") {
                        offset += 1
                        return .list(items)
                    }
                    items.append(try parseValue(depth: depth + 1))
                }
            case UInt8(ascii: "d"):
                offset += 1
                var entries: [BDictEntry] = []
                while true {
                    guard offset < bytes.count else { throw BencodeError.truncated }
                    if bytes[offset] == UInt8(ascii: "e") {
                        offset += 1
                        return .dictionary(entries)
                    }
                    guard bytes[offset] >= Self.zero, bytes[offset] <= Self.nine else {
                        throw BencodeError.nonStringDictionaryKey
                    }
                    let key = try parseString()
                    let valueStart = offset
                    let value = try parseValue(depth: depth + 1)
                    entries.append(BDictEntry(key: key, value: value, valueRange: valueStart..<offset))
                }
            default:
                throw BencodeError.unexpectedToken(offset: offset)
            }
        }

        mutating func parseInteger() throws -> Int {
            offset += 1 // consume 'i'
            let start = offset
            while offset < bytes.count, bytes[offset] != UInt8(ascii: "e") {
                offset += 1
            }
            guard offset < bytes.count else { throw BencodeError.truncated }
            let digits = bytes[start..<offset]
            offset += 1 // consume 'e'

            var body = digits[...]
            var negative = false
            if body.first == UInt8(ascii: "-") {
                negative = true
                body = body.dropFirst()
            }
            guard !body.isEmpty, body.count <= 19,
                  body.allSatisfy({ $0 >= Self.zero && $0 <= Self.nine })
            else { throw BencodeError.invalidInteger }
            if body.first == Self.zero, body.count > 1 { throw BencodeError.invalidInteger }
            if negative, body.first == Self.zero { throw BencodeError.invalidInteger }
            guard let value = Int(String(decoding: digits, as: UTF8.self)) else {
                throw BencodeError.invalidInteger
            }
            return value
        }

        mutating func parseString() throws -> Data {
            let start = offset
            while offset < bytes.count, bytes[offset] != UInt8(ascii: ":") {
                guard bytes[offset] >= Self.zero, bytes[offset] <= Self.nine else {
                    throw BencodeError.invalidStringLength
                }
                offset += 1
            }
            guard offset < bytes.count else { throw BencodeError.truncated }
            let lengthDigits = bytes[start..<offset]
            offset += 1 // consume ':'

            guard !lengthDigits.isEmpty, lengthDigits.count <= 10 else {
                throw BencodeError.invalidStringLength
            }
            if lengthDigits.first == Self.zero, lengthDigits.count > 1 {
                throw BencodeError.invalidStringLength
            }
            guard let length = Int(String(decoding: lengthDigits, as: UTF8.self)) else {
                throw BencodeError.invalidStringLength
            }
            guard bytes.count - offset >= length else { throw BencodeError.truncated }
            let data = Data(bytes[offset..<offset + length])
            offset += length
            return data
        }
    }
}

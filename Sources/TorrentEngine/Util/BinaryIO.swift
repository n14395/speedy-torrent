// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Big-endian binary helpers used by the peer wire, UDP tracker, and DHT
/// codecs. Readers are bounds-checked and slice-safe (offsets are relative to
/// the data's start regardless of its underlying startIndex).
extension Data {
    mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }

    mutating func appendUInt16(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func readUInt8(at offset: Int) -> UInt8? {
        guard offset >= 0, count - offset >= 1 else { return nil }
        return self[startIndex + offset]
    }

    func readUInt16(at offset: Int) -> UInt16? {
        guard let bytes = readBytes(at: offset, count: 2) else { return nil }
        return bytes.reduce(UInt16(0)) { $0 << 8 | UInt16($1) }
    }

    func readUInt32(at offset: Int) -> UInt32? {
        guard let bytes = readBytes(at: offset, count: 4) else { return nil }
        return bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    func readUInt64(at offset: Int) -> UInt64? {
        guard let bytes = readBytes(at: offset, count: 8) else { return nil }
        return bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    func readData(at offset: Int, count: Int) -> Data? {
        guard offset >= 0, count >= 0, self.count - offset >= count else { return nil }
        let start = startIndex + offset
        return Data(self[start..<start + count])
    }

    private func readBytes(at offset: Int, count: Int) -> [UInt8]? {
        guard offset >= 0, self.count - offset >= count else { return nil }
        let start = startIndex + offset
        return [UInt8](self[start..<start + count])
    }
}

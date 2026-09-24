// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A fixed-size bitfield in BEP 3 wire order: bit 0 is the high bit of byte 0.
public struct Bitfield: Sendable, Equatable {
    public private(set) var bytes: [UInt8]
    public let count: Int
    public private(set) var setCount: Int

    public init(count: Int) {
        self.count = count
        self.bytes = [UInt8](repeating: 0, count: (count + 7) / 8)
        self.setCount = 0
    }

    /// Parses a received bitfield message; the byte length must match and any
    /// spare bits in the final byte must be zero.
    public init?(data: Data, count: Int) {
        guard data.count == (count + 7) / 8 else { return nil }
        let bytes = [UInt8](data)
        if count % 8 != 0, let last = bytes.last {
            let spareMask = UInt8(0xFF) >> (count % 8)
            guard last & spareMask == 0 else { return nil }
        }
        self.count = count
        self.bytes = bytes
        self.setCount = bytes.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    public subscript(index: Int) -> Bool {
        get {
            guard index >= 0, index < count else { return false }
            return bytes[index / 8] & (0x80 >> (index % 8)) != 0
        }
        set {
            guard index >= 0, index < count else { return }
            let mask: UInt8 = 0x80 >> (index % 8)
            let wasSet = bytes[index / 8] & mask != 0
            if newValue, !wasSet {
                bytes[index / 8] |= mask
                setCount += 1
            } else if !newValue, wasSet {
                bytes[index / 8] &= ~mask
                setCount -= 1
            }
        }
    }

    public var isFull: Bool { setCount == count }
    public var isEmpty: Bool { setCount == 0 }
    public var data: Data { Data(bytes) }

    /// True if this bitfield has any piece the `other` (typically ours) lacks.
    public func hasAnyPieceMissing(from other: Bitfield) -> Bool {
        for index in 0..<min(bytes.count, other.bytes.count)
        where bytes[index] & ~other.bytes[index] != 0 {
            return true
        }
        return false
    }
}

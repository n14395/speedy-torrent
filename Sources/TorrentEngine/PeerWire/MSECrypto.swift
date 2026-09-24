// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// RC4 stream cipher (ARC4), used by MSE/PE. Not secure on its own — MSE uses
/// it only for light obfuscation to defeat protocol-based throttling.
struct RC4 {
    private var s: [UInt8]
    private var i = 0
    private var j = 0

    init(key: [UInt8]) {
        s = Array(0...255)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % key.count])) & 0xFF
            s.swapAt(i, j)
        }
    }

    mutating func keystreamByte() -> UInt8 {
        i = (i + 1) & 0xFF
        j = (j + Int(s[i])) & 0xFF
        s.swapAt(i, j)
        return s[(Int(s[i]) + Int(s[j])) & 0xFF]
    }

    mutating func process(_ data: [UInt8]) -> [UInt8] {
        data.map { $0 ^ keystreamByte() }
    }

    mutating func process(_ data: Data) -> Data {
        Data(data.map { $0 ^ keystreamByte() })
    }

    /// MSE discards the first 1024 keystream bytes.
    mutating func discard(_ count: Int) {
        for _ in 0..<count { _ = keystreamByte() }
    }
}

/// Minimal unsigned big integer (little-endian 32-bit limbs) supporting the
/// modular exponentiation MSE's Diffie-Hellman needs. Not constant-time.
struct BigUInt: Equatable {
    /// Little-endian limbs with no trailing zero limb; value 0 is `[]`.
    private var limbs: [UInt32]

    init() { limbs = [] }

    init(bigEndianBytes bytes: [UInt8]) {
        var limbs: [UInt32] = []
        var acc: UInt32 = 0
        var shift: UInt32 = 0
        for byte in bytes.reversed() {
            acc |= UInt32(byte) << shift
            shift += 8
            if shift == 32 {
                limbs.append(acc)
                acc = 0
                shift = 0
            }
        }
        if shift > 0 { limbs.append(acc) }
        self.limbs = Self.trimmed(limbs)
    }

    /// Big-endian bytes, left-zero-padded to `count`.
    func bigEndianBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var index = count - 1
        for limb in limbs {
            var value = limb
            for _ in 0..<4 {
                guard index >= 0 else { break }
                bytes[index] = UInt8(value & 0xFF)
                value >>= 8
                index -= 1
            }
        }
        return bytes
    }

    var isZero: Bool { limbs.isEmpty }

    private static func trimmed(_ limbs: [UInt32]) -> [UInt32] {
        var limbs = limbs
        while limbs.last == 0 { limbs.removeLast() }
        return limbs
    }

    private static func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] {
            return a[i] < b[i] ? -1 : 1
        }
        return 0
    }

    private static func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var result = [UInt32](repeating: 0, count: a.count + b.count)
        for i in 0..<a.count {
            var carry: UInt64 = 0
            let ai = UInt64(a[i])
            for j in 0..<b.count {
                let cur = UInt64(result[i + j]) + ai * UInt64(b[j]) + carry
                result[i + j] = UInt32(truncatingIfNeeded: cur)
                carry = cur >> 32
            }
            var k = i + b.count
            while carry > 0 {
                let cur = UInt64(result[k]) + carry
                result[k] = UInt32(truncatingIfNeeded: cur)
                carry = cur >> 32
                k += 1
            }
        }
        return trimmed(result)
    }

    /// Assumes a >= b.
    private static func subtract(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var result = a
        var borrow: Int64 = 0
        for i in 0..<a.count {
            let bv = i < b.count ? Int64(b[i]) : 0
            var cur = Int64(a[i]) - bv - borrow
            if cur < 0 { cur += 0x1_0000_0000; borrow = 1 } else { borrow = 0 }
            result[i] = UInt32(cur)
        }
        return trimmed(result)
    }

    private static func shiftLeftOne(_ a: [UInt32]) -> [UInt32] {
        guard !a.isEmpty else { return [] }
        var result = [UInt32](repeating: 0, count: a.count + 1)
        var carry: UInt32 = 0
        for i in 0..<a.count {
            result[i] = (a[i] << 1) | carry
            carry = a[i] >> 31
        }
        result[a.count] = carry
        return trimmed(result)
    }

    /// a mod m via binary long division.
    private static func mod(_ a: [UInt32], _ m: [UInt32]) -> [UInt32] {
        if compare(a, m) < 0 { return trimmed(a) }
        var rem: [UInt32] = []
        for bit in stride(from: a.count * 32 - 1, through: 0, by: -1) {
            rem = shiftLeftOne(rem)
            let limb = bit / 32
            let offset = UInt32(bit % 32)
            if (a[limb] >> offset) & 1 == 1 {
                if rem.isEmpty { rem = [1] } else { rem[0] |= 1 }
            }
            if compare(rem, m) >= 0 { rem = subtract(rem, m) }
        }
        return trimmed(rem)
    }

    /// self^exponent mod modulus (square-and-multiply).
    func modExp(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        var result: [UInt32] = [1]
        var base = Self.mod(limbs, modulus.limbs)
        let bits = exponent.limbs.count * 32
        for bit in 0..<bits {
            let limb = bit / 32
            let offset = UInt32(bit % 32)
            if (exponent.limbs[limb] >> offset) & 1 == 1 {
                result = Self.mod(Self.multiply(result, base), modulus.limbs)
            }
            base = Self.mod(Self.multiply(base, base), modulus.limbs)
        }
        var out = BigUInt()
        out.limbs = Self.trimmed(result)
        return out
    }
}

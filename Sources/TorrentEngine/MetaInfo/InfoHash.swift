// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit

/// A BitTorrent v1 info-hash: SHA-1 over the raw bencoded info dictionary.
public struct InfoHash: Sendable, Hashable, CustomStringConvertible {
    public static let byteCount = 20

    public let data: Data

    public init?(data: Data) {
        guard data.count == Self.byteCount else { return nil }
        self.data = Data(data)
    }

    public init?(hex: String) {
        guard hex.count == Self.byteCount * 2, let data = Data(hexString: hex) else { return nil }
        self.data = data
    }

    public init?(base32: String) {
        guard base32.count == 32, let data = Data(base32String: base32),
              data.count == Self.byteCount
        else { return nil }
        self.data = data
    }

    public init(hashing infoDictData: Data) {
        self.data = Data(Insecure.SHA1.hash(data: infoDictData))
    }

    public var hexString: String { data.hexString }
    public var description: String { hexString }
}

extension Data {
    public init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let high = chars[i].hexNibble, let low = chars[i + 1].hexNibble else {
                return nil
            }
            bytes.append(high << 4 | low)
        }
        self.init(bytes)
    }

    /// RFC 4648 base32, case-insensitive, optional '=' padding.
    public init?(base32String: String) {
        var bits = 0
        var accumulator = 0
        var bytes = [UInt8]()
        for char in base32String.uppercased().utf8 {
            if char == UInt8(ascii: "=") { break }
            let value: Int
            switch char {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                value = Int(char - UInt8(ascii: "A"))
            case UInt8(ascii: "2")...UInt8(ascii: "7"):
                value = Int(char - UInt8(ascii: "2")) + 26
            default:
                return nil
            }
            accumulator = accumulator << 5 | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8(truncatingIfNeeded: accumulator >> bits))
            }
        }
        self.init(bytes)
    }

    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension UInt8 {
    fileprivate var hexNibble: UInt8? {
        switch self {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): self - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): self - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): self - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

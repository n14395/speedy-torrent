// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit

/// Message Stream Encryption / Protocol Encryption (MSE/PE) constants and
/// key-derivation helpers. MSE obfuscates the peer connection to defeat
/// protocol-based ISP throttling and to reach peers that require encryption.
/// Not a strong security boundary — RC4 with a DH-derived key.
enum MSEHandshake {
    /// The 768-bit MSE Diffie–Hellman prime (RFC 2409 Oakley group 1), G = 2.
    static let primeBytes: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xC9, 0x0F, 0xDA, 0xA2, 0x21, 0x68, 0xC2, 0x34,
        0xC4, 0xC6, 0x62, 0x8B, 0x80, 0xDC, 0x1C, 0xD1, 0x29, 0x02, 0x4E, 0x08, 0x8A, 0x67, 0xCC, 0x74,
        0x02, 0x0B, 0xBE, 0xA6, 0x3B, 0x13, 0x9B, 0x22, 0x51, 0x4A, 0x08, 0x79, 0x8E, 0x34, 0x04, 0xDD,
        0xEF, 0x95, 0x19, 0xB3, 0xCD, 0x3A, 0x43, 0x1B, 0x30, 0x2B, 0x0A, 0x6D, 0xF2, 0x5F, 0x14, 0x37,
        0x4F, 0xE1, 0x35, 0x6D, 0x6D, 0x51, 0xC2, 0x45, 0xE4, 0x85, 0xB5, 0x76, 0x62, 0x5E, 0x7E, 0xC6,
        0xF4, 0x4C, 0x42, 0xE9, 0xA6, 0x3A, 0x36, 0x20, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    ]

    static let keyLength = 96          // 768-bit DH values
    static let vc: [UInt8] = Array(repeating: 0, count: 8)  // verification constant
    static let cryptoPlaintext: UInt32 = 0x01
    static let cryptoRC4: UInt32 = 0x02
    static let keystreamDiscard = 1024
    /// Upper bound on random padding (PadA/B/C/D) per the spec.
    static let maxPad = 512

    private static var prime: BigUInt { BigUInt(bigEndianBytes: primeBytes) }
    private static var generator: BigUInt { BigUInt(bigEndianBytes: [2]) }
    private static var one: BigUInt { BigUInt(bigEndianBytes: [1]) }

    /// P − 1. The prime's low byte is 0xFF, so this borrows nothing.
    private static var primeMinusOne: BigUInt {
        var bytes = primeBytes
        bytes[bytes.count - 1] -= 1
        return BigUInt(bigEndianBytes: bytes)
    }

    // MARK: - Diffie–Hellman

    /// A random 160-bit private exponent (sufficient and fast).
    static func randomPrivateKey() -> BigUInt {
        BigUInt(bigEndianBytes: (0..<20).map { _ in UInt8.random(in: 0...255) })
    }

    /// Our DH public key Y = G^x mod P, as 96 big-endian bytes.
    static func publicKey(privateKey: BigUInt) -> [UInt8] {
        generator.modExp(privateKey, modulus: prime).bigEndianBytes(count: keyLength)
    }

    /// The shared secret S = Y_peer^x mod P, as 96 big-endian bytes.
    ///
    /// Returns nil for the degenerate public keys 0, 1 and P−1, each of which
    /// collapses the secret to a value the peer can predict without knowing our
    /// private exponent. MSE is obfuscation rather than a security boundary, so
    /// this costs little and closes the one case where it claims to be more.
    static func sharedSecret(peerPublicKey: [UInt8], privateKey: BigUInt) -> [UInt8]? {
        let peer = BigUInt(bigEndianBytes: peerPublicKey)
        guard !peer.isZero, peer != one, peer != primeMinusOne else { return nil }
        return peer.modExp(privateKey, modulus: prime).bigEndianBytes(count: keyLength)
    }

    // MARK: - Derived values

    static func sha1(_ parts: [UInt8]...) -> [UInt8] {
        var hasher = Insecure.SHA1()
        for part in parts { hasher.update(data: Data(part)) }
        return Array(hasher.finalize())
    }

    static func req1(secret: [UInt8]) -> [UInt8] { sha1(Array("req1".utf8), secret) }
    static func req2(skey: [UInt8]) -> [UInt8] { sha1(Array("req2".utf8), skey) }
    static func req3(secret: [UInt8]) -> [UInt8] { sha1(Array("req3".utf8), secret) }

    /// The obfuscated SKEY marker A sends: HASH('req2', SKEY) xor HASH('req3', S).
    static func req2XorReq3(skey: [UInt8], secret: [UInt8]) -> [UInt8] {
        zip(req2(skey: skey), req3(secret: secret)).map(^)
    }

    /// RC4 key for a direction: HASH('keyA'|'keyB', S, SKEY).
    static func rc4Cipher(label: String, secret: [UInt8], skey: [UInt8]) -> RC4 {
        var cipher = RC4(key: sha1(Array(label.utf8), secret, skey))
        cipher.discard(keystreamDiscard)
        return cipher
    }
}

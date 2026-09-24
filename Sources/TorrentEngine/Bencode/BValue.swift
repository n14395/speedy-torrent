// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A decoded bencode value (BEP 3).
public indirect enum BValue: Sendable, Equatable {
    case string(Data)
    case integer(Int)
    case list([BValue])
    case dictionary([BDictEntry])
}

/// A dictionary entry. `valueRange` is the byte range of the encoded value in
/// the buffer it was decoded from (nil for programmatically built values) —
/// needed to hash the info dictionary over its *original* bytes.
public struct BDictEntry: Sendable {
    public let key: Data
    public let value: BValue
    public let valueRange: Range<Int>?

    public init(key: Data, value: BValue, valueRange: Range<Int>? = nil) {
        self.key = key
        self.value = value
        self.valueRange = valueRange
    }
}

extension BDictEntry: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.value == rhs.value
    }
}

extension BValue {
    public static func string(_ string: String) -> BValue {
        .string(Data(string.utf8))
    }

    /// Builds a dictionary value from string keys, preserving the given order
    /// (the encoder sorts canonically regardless).
    public static func dictionary(_ pairs: [(String, BValue)]) -> BValue {
        .dictionary(pairs.map { BDictEntry(key: Data($0.0.utf8), value: $0.1) })
    }

    public var stringData: Data? {
        if case .string(let data) = self { return data }
        return nil
    }

    public var stringValue: String? {
        stringData.flatMap { String(data: $0, encoding: .utf8) }
    }

    public var integerValue: Int? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var listValue: [BValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    public var dictionaryEntries: [BDictEntry]? {
        if case .dictionary(let entries) = self { return entries }
        return nil
    }

    /// First entry with the given key (bencode dictionaries with duplicate
    /// keys are malformed; we tolerate them by using the first occurrence).
    public func entry(forKey key: String) -> BDictEntry? {
        let keyData = Data(key.utf8)
        return dictionaryEntries?.first { $0.key == keyData }
    }

    public subscript(key: String) -> BValue? {
        entry(forKey: key)?.value
    }
}

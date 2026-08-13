import Foundation
import Testing
@testable import TorrentEngine

@Suite struct BencodeDecodingTests {
    @Test func decodesScalars() throws {
        #expect(try Bencode.decode(Data("i42e".utf8)) == .integer(42))
        #expect(try Bencode.decode(Data("i-7e".utf8)) == .integer(-7))
        #expect(try Bencode.decode(Data("i0e".utf8)) == .integer(0))
        #expect(try Bencode.decode(Data("4:spam".utf8)) == .string(Data("spam".utf8)))
        #expect(try Bencode.decode(Data("0:".utf8)) == .string(Data()))
    }

    @Test func decodesContainers() throws {
        let list = try Bencode.decode(Data("l4:spami42ee".utf8))
        #expect(list == .list([.string(Data("spam".utf8)), .integer(42)]))

        let dict = try Bencode.decode(Data("d3:bar4:spam3:fooi42ee".utf8))
        #expect(dict["bar"]?.stringValue == "spam")
        #expect(dict["foo"]?.integerValue == 42)
        #expect(dict["missing"] == nil)
    }

    @Test func recordsDictionaryValueRanges() throws {
        let input = Data("d4:spami42ee".utf8)
        let decoded = try Bencode.decode(input)
        let range = try #require(decoded.entry(forKey: "spam")?.valueRange)
        #expect(range == 7..<11)
        #expect(Data(input[range]) == Data("i42e".utf8))
    }

    @Test(arguments: [
        "ie", "i-0e", "i01e", "i--1e", "i1x2e", "i12", // bad integers
        "5:abc", "01:a", ":", "1x:a",                  // bad strings
        "l4:spam", "d3:foo", "d3:fooi1e",              // truncated containers
        "di1e4:spame",                                 // non-string key
        "i1ei2e", "i1ex",                              // trailing data
        "", "x",
    ])
    func rejectsMalformedInput(_ input: String) {
        #expect(throws: BencodeError.self) {
            try Bencode.decode(Data(input.utf8))
        }
    }

    @Test func rejectsDeeplyNestedInput() {
        let bomb = Data(String(repeating: "l", count: 200).utf8)
        #expect(throws: BencodeError.depthLimitExceeded) {
            try Bencode.decode(bomb)
        }
    }

    @Test func decodePrefixReportsConsumedBytes() throws {
        let (value, consumed) = try Bencode.decodePrefix(Data("i42eEXTRA".utf8))
        #expect(value == .integer(42))
        #expect(consumed == 4)
    }
}

@Suite struct BencodeEncodingTests {
    @Test func encodesCanonically() {
        let value = BValue.dictionary([
            ("zebra", .integer(1)),
            ("apple", .string("x")),
        ])
        #expect(Bencode.encode(value) == Data("d5:apple1:x5:zebrai1ee".utf8))
    }

    @Test func sortsKeysByRawBytes() {
        // "piece length" (space, 0x20) sorts before "pieces" ('s', 0x73).
        let value = BValue.dictionary([
            ("pieces", .integer(2)),
            ("piece length", .integer(1)),
        ])
        #expect(Bencode.encode(value) == Data("d12:piece lengthi1e6:piecesi2ee".utf8))
    }

    @Test func roundTripsDecodedValues() throws {
        let inputs = ["d3:bar4:spam3:fooi42ee", "l4:spami-3ele0:e", "i0e", "3:abc"]
        for input in inputs {
            let data = Data(input.utf8)
            #expect(Bencode.encode(try Bencode.decode(data)) == data)
        }
    }
}

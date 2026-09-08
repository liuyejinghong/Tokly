import Foundation

@main
struct Checks {
    static func main() throws {
        let encoder = JSONEncoder()
        let expected = PrepSnapshot(tokens: 160, updatedAt: Date(timeIntervalSince1970: 0), revision: 1)
        let actual = try PrepStore.decode(encoder.encode(expected))
        precondition(actual.schemaVersion == 1 && actual.tokens == 160 && actual.revision == 1)
        var wrong = expected
        wrong.schemaVersion = 2
        do {
            _ = try PrepStore.decode(encoder.encode(wrong))
            fatalError("Unknown schema was accepted")
        } catch PrepStoreError.schemaMismatch(2) {}
        wrong = expected
        wrong.tokens = -1
        do {
            _ = try PrepStore.decode(encoder.encode(wrong))
            fatalError("Negative token count was accepted")
        } catch PrepStoreError.negativeTokens {}
        do {
            _ = try PrepStore.decode(Data("{\"schemaVersion\":".utf8))
            fatalError("Truncated JSON was accepted")
        } catch is DecodingError {}
        let large = PrepSnapshot(tokens: 9_007_199_254_740_993, updatedAt: expected.updatedAt, revision: 2)
        let decoded = try PrepStore.decode(encoder.encode(large))
        precondition(decoded.tokens == large.tokens, "64-bit token precision lost")
        print("PASS: roundtrip, schema, negative tokens, truncated JSON, Int64 precision")
    }
}

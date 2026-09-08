import Foundation

/// Collector → macOS scan snapshot protocol v1: validated Codable types.
///
/// Single validated entrypoint: `ScanSnapshot.decodeValidated(from:)`.
/// Decoding rejects: unsupported schemaVersion, malformed dates / hours /
/// ranges, negative tokens, non-finite or negative costs, unknown source
/// status, unknown timezones, and inconsistent envelopes
/// (range vs hourlyDate, buckets outside range, cost/token mismatch).
/// All token quantities keep Int64 precision; totals use saturating addition.

public enum SnapshotError: Error, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case malformedDate(String)
    case malformedHour(Int)
    case invalidRange(String, String)
    case inconsistentEnvelope(String)
    case negativeTokens(String)
    case invalidCost(String)
    case duplicateEntry(String)
    case malformedTimezone(String)
    case malformedTimestamp(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let v): return "unsupported schemaVersion: \(v)"
        case .malformedDate(let s): return "malformed date: \(s)"
        case .malformedHour(let h): return "malformed hour: \(h)"
        case .invalidRange(let a, let b): return "invalid range: \(a) .. \(b)"
        case .inconsistentEnvelope(let s): return "inconsistent envelope: \(s)"
        case .negativeTokens(let s): return "negative tokens: \(s)"
        case .invalidCost(let s): return "invalid cost: \(s)"
        case .duplicateEntry(let s): return "duplicate entry: \(s)"
        case .malformedTimezone(let s): return "malformed timezone: \(s)"
        case .malformedTimestamp(let s): return "malformed timestamp: \(s)"
        case .decoding(let s): return "decoding failed: \(s)"
        }
    }
}

/// Saturating Int64 addition shared by every aggregation path.
@inline(__always)
public func saturatedAdd(_ a: Int64, _ b: Int64) -> Int64 {
    let (result, overflow) = a.addingReportingOverflow(b)
    if !overflow { return result }
    if a >= 0 && b >= 0 { return Int64.max }
    if a <= 0 && b <= 0 { return Int64.min }
    return result
}

// MARK: - Strict calendar-day strings (YYYY-MM-DD)

public enum SnapshotDate {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()

    public static func isValid(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count == 10, u[4] == 45, u[7] == 45 else { return false }
        for (i, c) in u.enumerated() {
            if i == 4 || i == 7 { continue }
            guard c >= 48 && c <= 57 else { return false }
        }
        guard let d = formatter.date(from: s) else { return false }
        return formatter.string(from: d) == s
    }

    public static func parse(_ s: String) -> Date? {
        guard isValid(s) else { return nil }
        return formatter.date(from: s)
    }

    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}

// MARK: - RFC3339 timestamps

public enum SnapshotTime {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let output: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func parseRFC3339(_ s: String) -> Date? {
        withFraction.date(from: s) ?? plain.date(from: s)
    }

    public static func formatRFC3339(_ d: Date) -> String {
        output.string(from: d)
    }
}

// MARK: - Token quantities

public struct TokenCounts: Encodable, Equatable {
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64
    public var reasoning: Int64

    public init(input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, reasoning: Int64) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    public static var zero: TokenCounts {
        TokenCounts(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0)
    }

    /// Sum of the five categories via saturating addition, never via Double.
    public var total: Int64 {
        saturatedAdd(saturatedAdd(saturatedAdd(saturatedAdd(input, output), cacheRead), cacheWrite), reasoning)
    }

    public func adding(_ other: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: saturatedAdd(input, other.input),
            output: saturatedAdd(output, other.output),
            cacheRead: saturatedAdd(cacheRead, other.cacheRead),
            cacheWrite: saturatedAdd(cacheWrite, other.cacheWrite),
            reasoning: saturatedAdd(reasoning, other.reasoning)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case input, output, cacheRead, cacheWrite, reasoning
    }
}

extension TokenCounts: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let input = try c.decode(Int64.self, forKey: .input)
        let output = try c.decode(Int64.self, forKey: .output)
        let cacheRead = try c.decode(Int64.self, forKey: .cacheRead)
        let cacheWrite = try c.decode(Int64.self, forKey: .cacheWrite)
        let reasoning = try c.decode(Int64.self, forKey: .reasoning)
        for (name, v) in [("input", input), ("output", output), ("cacheRead", cacheRead), ("cacheWrite", cacheWrite), ("reasoning", reasoning)] {
            if v < 0 { throw SnapshotError.negativeTokens("\(name)=\(v)") }
        }
        self.init(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, reasoning: reasoning)
    }
}

// MARK: - Cost semantics (protocol v1, section "费用语义")

public struct EstimatedCost: Encodable, Equatable {
    /// Sum of fully-priced events only; nil when every event with volume is
    /// unpriced. Finite, non-negative. Explicit 0 is a legitimate free price.
    public var amountUsd: Double?
    /// Whether every event carrying tokens was fully priced.
    public var complete: Bool
    /// Token volume of events that could not be fully priced (saturating).
    public var unpricedTokens: Int64

    public init(amountUsd: Double?, complete: Bool, unpricedTokens: Int64) {
        self.amountUsd = amountUsd
        self.complete = complete
        self.unpricedTokens = unpricedTokens
    }

    /// Legitimate zero: no volume at all.
    public static var legitimateZero: EstimatedCost {
        EstimatedCost(amountUsd: 0, complete: true, unpricedTokens: 0)
    }

    private enum CodingKeys: String, CodingKey {
        case amountUsd, complete, unpricedTokens
    }
}

extension EstimatedCost: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let amount = try c.decodeIfPresent(Double.self, forKey: .amountUsd)
        let complete = try c.decode(Bool.self, forKey: .complete)
        let unpriced = try c.decode(Int64.self, forKey: .unpricedTokens)
        if let a = amount {
            guard a.isFinite && a >= 0 else {
                throw SnapshotError.invalidCost("amountUsd must be finite and non-negative")
            }
        }
        if unpriced < 0 { throw SnapshotError.invalidCost("unpricedTokens must be non-negative") }
        self.init(amountUsd: amount, complete: complete, unpricedTokens: unpriced)
    }
}

// MARK: - Usage tree: client is the parent, models are children

public struct ModelUsage: Encodable, Equatable {
    /// Upstream canonical_model_id; key is clientId + modelId, so the same
    /// model under different clients stays separate.
    public var modelId: String
    public var tokens: TokenCounts
    public var estimatedCost: EstimatedCost

    public init(modelId: String, tokens: TokenCounts, estimatedCost: EstimatedCost) {
        self.modelId = modelId
        self.tokens = tokens
        self.estimatedCost = estimatedCost
    }

    private enum CodingKeys: String, CodingKey {
        case modelId, tokens, estimatedCost
    }
}

extension ModelUsage: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let modelId = try c.decode(String.self, forKey: .modelId)
        let tokens = try c.decode(TokenCounts.self, forKey: .tokens)
        let cost = try c.decode(EstimatedCost.self, forKey: .estimatedCost)
        try SnapshotValidation.checkCost(tokens: tokens, cost: cost, context: "model \(modelId)")
        self.init(modelId: modelId, tokens: tokens, estimatedCost: cost)
    }
}

public struct ClientUsage: Encodable, Equatable {
    public var clientId: String
    public var models: [ModelUsage]

    public init(clientId: String, models: [ModelUsage]) {
        self.clientId = clientId
        self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case clientId, models
    }
}

extension ClientUsage: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let clientId = try c.decode(String.self, forKey: .clientId)
        let models = try c.decode([ModelUsage].self, forKey: .models)
        var seen = Set<String>()
        for m in models {
            if !seen.insert(m.modelId).inserted {
                throw SnapshotError.duplicateEntry("client \(clientId) model \(m.modelId)")
            }
        }
        self.init(clientId: clientId, models: models)
    }
}

public struct DayBucket: Encodable, Equatable {
    public var date: String
    public var clients: [ClientUsage]

    public init(date: String, clients: [ClientUsage]) {
        self.date = date
        self.clients = clients
    }

    private enum CodingKeys: String, CodingKey {
        case date, clients
    }
}

extension DayBucket: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let date = try c.decode(String.self, forKey: .date)
        guard SnapshotDate.isValid(date) else { throw SnapshotError.malformedDate(date) }
        let clients = try c.decode([ClientUsage].self, forKey: .clients)
        var seen = Set<String>()
        for cl in clients {
            if !seen.insert(cl.clientId).inserted {
                throw SnapshotError.duplicateEntry("day \(date) client \(cl.clientId)")
            }
        }
        self.init(date: date, clients: clients)
    }
}

public struct HourBucket: Encodable, Equatable {
    /// Local clock hour 0–23. A repeated DST clock hour arrives already
    /// merged under one label by the collector; duplicates are rejected.
    public var hour: Int
    public var clients: [ClientUsage]

    public init(hour: Int, clients: [ClientUsage]) {
        self.hour = hour
        self.clients = clients
    }

    private enum CodingKeys: String, CodingKey {
        case hour, clients
    }
}

extension HourBucket: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let hour = try c.decode(Int.self, forKey: .hour)
        guard hour >= 0 && hour <= 23 else { throw SnapshotError.malformedHour(hour) }
        let clients = try c.decode([ClientUsage].self, forKey: .clients)
        var seen = Set<String>()
        for cl in clients {
            if !seen.insert(cl.clientId).inserted {
                throw SnapshotError.duplicateEntry("hour \(hour) client \(cl.clientId)")
            }
        }
        self.init(hour: hour, clients: clients)
    }
}

// MARK: - Envelope

public struct ScanRange: Encodable, Equatable {
    public var since: String
    public var until: String

    public init(since: String, until: String) {
        self.since = since
        self.until = until
    }

    private enum CodingKeys: String, CodingKey {
        case since, until
    }
}

extension ScanRange: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let since = try c.decode(String.self, forKey: .since)
        let until = try c.decode(String.self, forKey: .until)
        guard SnapshotDate.isValid(since) else { throw SnapshotError.malformedDate(since) }
        guard SnapshotDate.isValid(until) else { throw SnapshotError.malformedDate(until) }
        guard since <= until else { throw SnapshotError.invalidRange(since, until) }
        self.init(since: since, until: until)
    }
}

public enum SourceState: String, Codable {
    case found
    case notFound
}

public struct SourceStatus: Encodable, Equatable {
    public var clientId: String
    public var status: SourceState
    public var sourceCount: Int

    public init(clientId: String, status: SourceState, sourceCount: Int) {
        self.clientId = clientId
        self.status = status
        self.sourceCount = sourceCount
    }

    private enum CodingKeys: String, CodingKey {
        case clientId, status, sourceCount
    }
}

extension SourceStatus: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let clientId = try c.decode(String.self, forKey: .clientId)
        let status = try c.decode(SourceState.self, forKey: .status)
        let count = try c.decode(Int.self, forKey: .sourceCount)
        guard count >= 0 else { throw SnapshotError.decoding("sourceCount must be non-negative") }
        self.init(clientId: clientId, status: status, sourceCount: count)
    }
}

public struct SnapshotWarning: Encodable, Equatable {
    public var code: String
    public var clientId: String?
    public var message: String

    public init(code: String, clientId: String?, message: String) {
        self.code = code
        self.clientId = clientId
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case code, clientId, message
    }
}

extension SnapshotWarning: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let code = try c.decode(String.self, forKey: .code)
        guard !code.isEmpty else { throw SnapshotError.decoding("warning code must be non-empty") }
        let clientId = try c.decodeIfPresent(String.self, forKey: .clientId)
        let message = try c.decode(String.self, forKey: .message)
        self.init(code: code, clientId: clientId, message: message)
    }
}

// MARK: - Cost/token envelope consistency

public enum SnapshotValidation {
    /// Enforces protocol cost semantics at decode time.
    public static func checkCost(tokens: TokenCounts, cost: EstimatedCost, context: String) throws {
        let volume = tokens.total
        if volume == 0 {
            // No tokens: exactly legitimate zero, never a carried subtotal.
            guard cost.amountUsd == 0, cost.complete, cost.unpricedTokens == 0 else {
                throw SnapshotError.inconsistentEnvelope("\(context): zero volume must be 0/true/0")
            }
            return
        }
        if cost.complete {
            guard cost.amountUsd != nil else {
                throw SnapshotError.inconsistentEnvelope("\(context): complete cost requires a known amount")
            }
            guard cost.unpricedTokens == 0 else {
                throw SnapshotError.inconsistentEnvelope("\(context): complete cost requires zero unpriced tokens")
            }
        } else {
            guard cost.unpricedTokens > 0 else {
                throw SnapshotError.inconsistentEnvelope("\(context): incomplete cost requires positive unpriced tokens")
            }
        }
    }
}

// MARK: - Root snapshot

public struct ScanSnapshot: Encodable, Equatable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var timezone: String
    public var range: ScanRange
    public var hourlyDate: String
    public var pricingAsOf: Date?
    public var daily: [DayBucket]
    public var hourly: [HourBucket]
    public var sources: [SourceStatus]
    public var warnings: [SnapshotWarning]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, timezone, range, hourlyDate
        case pricingAsOf, daily, hourly, sources, warnings
    }

    /// Owned encode API: timestamps use the same RFC3339 strings the
    /// validated decoder expects, so encode/decode round-trips.
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(SnapshotTime.formatRFC3339(generatedAt), forKey: .generatedAt)
        try c.encode(timezone, forKey: .timezone)
        try c.encode(range, forKey: .range)
        try c.encode(hourlyDate, forKey: .hourlyDate)
        try c.encode(pricingAsOf.map(SnapshotTime.formatRFC3339), forKey: .pricingAsOf)
        try c.encode(daily, forKey: .daily)
        try c.encode(hourly, forKey: .hourly)
        try c.encode(sources, forKey: .sources)
        try c.encode(warnings, forKey: .warnings)
    }

    /// Validated entrypoint. Price-refresh reports must never be routed here.
    public static func decodeValidated(from data: Data) throws -> ScanSnapshot {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(ScanSnapshot.self, from: data)
        } catch let e as SnapshotError {
            throw e
        } catch let e as DecodingError {
            throw SnapshotError.decoding(String(describing: e))
        }
    }
}

extension ScanSnapshot: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw SnapshotError.unsupportedSchemaVersion(version) }

        let generatedRaw = try c.decode(String.self, forKey: .generatedAt)
        guard let generatedAt = SnapshotTime.parseRFC3339(generatedRaw) else {
            throw SnapshotError.malformedTimestamp(generatedRaw)
        }
        let timezone = try c.decode(String.self, forKey: .timezone)
        guard TimeZone(identifier: timezone) != nil else {
            throw SnapshotError.malformedTimezone(timezone)
        }
        let range = try c.decode(ScanRange.self, forKey: .range)
        let hourlyDate = try c.decode(String.self, forKey: .hourlyDate)
        guard SnapshotDate.isValid(hourlyDate) else { throw SnapshotError.malformedDate(hourlyDate) }
        guard range.since <= hourlyDate && hourlyDate <= range.until else {
            throw SnapshotError.inconsistentEnvelope("hourlyDate \(hourlyDate) outside range \(range.since)..\(range.until)")
        }
        var pricingAsOf: Date?
        if let pricingRaw = try c.decodeIfPresent(String.self, forKey: .pricingAsOf) {
            guard let d = SnapshotTime.parseRFC3339(pricingRaw) else {
                throw SnapshotError.malformedTimestamp(pricingRaw)
            }
            pricingAsOf = d
        }

        let daily = try c.decode([DayBucket].self, forKey: .daily)
        var lastDate: String?
        var seenDates = Set<String>()
        for bucket in daily {
            guard bucket.date >= range.since && bucket.date <= range.until else {
                throw SnapshotError.inconsistentEnvelope("day \(bucket.date) outside range \(range.since)..\(range.until)")
            }
            if !seenDates.insert(bucket.date).inserted {
                throw SnapshotError.duplicateEntry("day \(bucket.date)")
            }
            if let prev = lastDate, bucket.date <= prev {
                throw SnapshotError.inconsistentEnvelope("daily buckets must be ascending")
            }
            lastDate = bucket.date
        }

        // Duplicate hour labels are corrupt input, like duplicate days: the
        // collector already merges repeated DST clock hours before emitting.
        let hourly = try c.decode([HourBucket].self, forKey: .hourly)
        var lastHour: Int?
        var seenHours = Set<Int>()
        for bucket in hourly {
            if !seenHours.insert(bucket.hour).inserted {
                throw SnapshotError.duplicateEntry("hour \(bucket.hour)")
            }
            if let prev = lastHour, bucket.hour <= prev {
                throw SnapshotError.inconsistentEnvelope("hourly buckets must be ascending")
            }
            lastHour = bucket.hour
        }

        let sources = try c.decode([SourceStatus].self, forKey: .sources)
        var seenSources = Set<String>()
        for s in sources {
            if !seenSources.insert(s.clientId).inserted {
                throw SnapshotError.duplicateEntry("source \(s.clientId)")
            }
        }
        let warnings = try c.decode([SnapshotWarning].self, forKey: .warnings)

        self.schemaVersion = version
        self.generatedAt = generatedAt
        self.timezone = timezone
        self.range = range
        self.hourlyDate = hourlyDate
        self.pricingAsOf = pricingAsOf
        self.daily = daily
        self.hourly = hourly
        self.sources = sources
        self.warnings = warnings
    }
}

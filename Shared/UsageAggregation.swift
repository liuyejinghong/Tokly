import Foundation

/// Single aggregation path for every view (day / hour / client / widget).
///
/// All totals flow through `Aggregation.aggregate(_:)`; views must never
/// reimplement their own addition. Day and hourly buckets are two
/// projections of the same usage and must never be added together.
/// Client filters apply to the main window only; menu-bar and Widget
/// "today" totals always use every enabled source (nil filter).
///
/// Calendar helpers take caller-explicit `now` / `timeZone` so tests are
/// deterministic and production never depends on implicit system time.
/// Missing or failed snapshots (nil) are never zero-filled; only past days
/// covered by a successful snapshot may fill 0. Future values are nil.

public struct AggregatedUsage: Equatable {
    public var tokens: TokenCounts
    public var cost: EstimatedCost

    public init(tokens: TokenCounts, cost: EstimatedCost) {
        self.tokens = tokens
        self.cost = cost
    }

    public static var zero: AggregatedUsage {
        AggregatedUsage(tokens: .zero, cost: .legitimateZero)
    }
}

/// Missing vs partial vs all-unpriced vs legitimate-zero, per protocol.
public enum CostState: Equatable {
    /// No volume: amount 0, complete, zero unpriced.
    case legitimateZero
    /// Every event with volume priced.
    case fullyPriced(amountUsd: Double)
    /// Known events summed; some events unpriced.
    case partialKnown(amountUsd: Double, unpricedTokens: Int64)
    /// Every event with volume unpriced: amount unknown.
    case allUnpriced(unpricedTokens: Int64)
}

public struct DayPoint: Equatable {
    public var date: String
    public var isFuture: Bool
    /// nil = future, or unknown (snapshot missing / date uncovered).
    /// Non-nil zero = successful covered empty past bucket.
    public var usage: AggregatedUsage?

    public init(date: String, isFuture: Bool, usage: AggregatedUsage?) {
        self.date = date
        self.isFuture = isFuture
        self.usage = usage
    }
}

public struct HourPoint: Equatable {
    public var hour: Int
    public var isFuture: Bool
    public var usage: AggregatedUsage?

    public init(hour: Int, isFuture: Bool, usage: AggregatedUsage?) {
        self.hour = hour
        self.isFuture = isFuture
        self.usage = usage
    }
}

/// Monday–Sunday segment clipped to the month (4–6 per month).
public struct WeekSegment: Equatable {
    public var start: String
    public var end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }
}

public struct WeeklyPoint: Equatable {
    public var segment: WeekSegment
    /// Last covered day for the in-progress week; nil for future segments.
    public var cutoff: String?
    /// nil = future segment or fully uncovered; zero = covered but empty.
    public var usage: AggregatedUsage?

    public init(segment: WeekSegment, cutoff: String?, usage: AggregatedUsage?) {
        self.segment = segment
        self.cutoff = cutoff
        self.usage = usage
    }
}

public enum Aggregation {
    // MARK: - Single token + cost path

    /// The one aggregation every view uses. Zero-volume entries are dropped
    /// at the seam so filled empty days can never fabricate a known subtotal;
    /// all-zero input yields a legitimate zero.
    public static func aggregate(_ entries: [(tokens: TokenCounts, cost: EstimatedCost)]) -> AggregatedUsage {
        var tokens = TokenCounts.zero
        var costs: [EstimatedCost] = []
        costs.reserveCapacity(entries.count)
        for e in entries {
            tokens = tokens.adding(e.tokens)
            if e.tokens.total > 0 {
                costs.append(e.cost)
            }
        }
        return AggregatedUsage(tokens: tokens, cost: mergeCosts(costs, totalTokens: tokens.total))
    }

    public static func mergeCosts(_ costs: [EstimatedCost], totalTokens: Int64) -> EstimatedCost {
        if totalTokens == 0 {
            return .legitimateZero
        }
        var sum = 0.0
        var hasPriced = false
        var complete = true
        var unpriced: Int64 = 0
        for c in costs {
            if let a = c.amountUsd {
                sum += a
                hasPriced = true
            }
            complete = complete && c.complete
            unpriced = saturatedAdd(unpriced, c.unpricedTokens)
        }
        if !hasPriced || !sum.isFinite {
            return EstimatedCost(amountUsd: nil, complete: false, unpricedTokens: unpriced)
        }
        return EstimatedCost(amountUsd: sum, complete: complete, unpricedTokens: unpriced)
    }

    public static func aggregateModels(_ models: [ModelUsage]) -> AggregatedUsage {
        aggregate(models.map { ($0.tokens, $0.estimatedCost) })
    }

    /// Parent client total == sum of its model children (conservation).
    public static func aggregateClient(_ client: ClientUsage) -> AggregatedUsage {
        aggregateModels(client.models)
    }

    public static func aggregateDay(_ day: DayBucket) -> AggregatedUsage {
        aggregate(day.clients.flatMap { $0.models.map { ($0.tokens, $0.estimatedCost) } })
    }

    public static func aggregateHour(_ hour: HourBucket) -> AggregatedUsage {
        aggregate(hour.clients.flatMap { $0.models.map { ($0.tokens, $0.estimatedCost) } })
    }

    public static func aggregateDays(_ days: [DayBucket]) -> AggregatedUsage {
        aggregate(days.flatMap { $0.clients.flatMap { $0.models.map { ($0.tokens, $0.estimatedCost) } } })
    }

    public static func classify(tokensTotal: Int64, cost: EstimatedCost) -> CostState {
        if tokensTotal == 0 { return .legitimateZero }
        if let amount = cost.amountUsd {
            if cost.complete { return .fullyPriced(amountUsd: amount) }
            return .partialKnown(amountUsd: amount, unpricedTokens: cost.unpricedTokens)
        }
        return .allUnpriced(unpricedTokens: cost.unpricedTokens)
    }

    // MARK: - Day/hour projection consistency

    /// Daily and hourly buckets project the same events. Compares per
    /// client+model identity: tokens, complete flag, and unpriced exact;
    /// amounts with an explicit small tolerance since regrouped Double sums
    /// can associate differently. Never sum both projections regardless.
    public static func verifyDayHourConsistency(_ snapshot: ScanSnapshot) -> Bool {
        guard let day = snapshot.daily.first(where: { $0.date == snapshot.hourlyDate }) else {
            return snapshot.hourly.isEmpty
        }
        return keyedUsageEqual(keyedUsage(day.clients), keyedHourlyUsage(snapshot.hourly))
    }

    static func keyedUsage(_ clients: [ClientUsage]) -> [String: (TokenCounts, EstimatedCost)] {
        var out: [String: (TokenCounts, EstimatedCost)] = [:]
        for client in clients {
            for m in client.models {
                let key = client.clientId + "\u{0}" + m.modelId
                if let prev = out[key] {
                    out[key] = combineIdentical(prev, (m.tokens, m.estimatedCost))
                } else {
                    out[key] = (m.tokens, m.estimatedCost)
                }
            }
        }
        return out
    }

    static func keyedHourlyUsage(_ hours: [HourBucket]) -> [String: (TokenCounts, EstimatedCost)] {
        keyedUsage(hours.flatMap { $0.clients })
    }

    /// Volume-aware seam shared by every same-identity merge.
    static func combineIdentical(
        _ left: (TokenCounts, EstimatedCost),
        _ right: (TokenCounts, EstimatedCost)
    ) -> (TokenCounts, EstimatedCost) {
        let tokens = left.0.adding(right.0)
        var costs: [EstimatedCost] = []
        if left.0.total > 0 { costs.append(left.1) }
        if right.0.total > 0 { costs.append(right.1) }
        return (tokens, mergeCosts(costs, totalTokens: tokens.total))
    }

    static func keyedUsageEqual(
        _ a: [String: (TokenCounts, EstimatedCost)],
        _ b: [String: (TokenCounts, EstimatedCost)]
    ) -> Bool {
        guard Set(a.keys) == Set(b.keys) else { return false }
        for key in a.keys {
            let (ta, ca) = a[key]!
            let (tb, cb) = b[key]!
            guard ta == tb, ca.complete == cb.complete,
                  ca.unpricedTokens == cb.unpricedTokens,
                  amountsClose(ca.amountUsd, cb.amountUsd)
            else { return false }
        }
        return true
    }

    /// Explicit tolerance for regrouped floating-point sums.
    static func amountsClose(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (x?, y?):
            let tol = max(1e-9, 1e-9 * max(abs(x), abs(y)))
            return abs(x - y) <= tol
        default:
            return false
        }
    }

    // MARK: - Client filtering (main window only)

    public static func filterClients(_ clients: [ClientUsage], to ids: Set<String>?) -> [ClientUsage] {
        guard let ids else { return clients }
        return clients.filter { ids.contains($0.clientId) }
    }

    public static func filteredDay(_ day: DayBucket, clientIds: Set<String>?) -> DayBucket {
        DayBucket(date: day.date, clients: filterClients(day.clients, to: clientIds))
    }

    /// Today total for the main window (pass a filter) or for menu-bar /
    /// Widget (pass nil to keep every enabled source). Returns nil when the
    /// snapshot does not cover today; returns legitimate zero when today is
    /// covered but has no bucket.
    public static func todayUsage(_ snapshot: ScanSnapshot?, today: String, clientIds: Set<String>?) -> AggregatedUsage? {
        guard let snapshot else { return nil }
        guard snapshot.range.since <= today && today <= snapshot.range.until else { return nil }
        guard let bucket = snapshot.daily.first(where: { $0.date == today }) else {
            return .zero
        }
        return aggregateDay(filteredDay(bucket, clientIds: clientIds))
    }

    // MARK: - Explicit calendar helpers

    public static func calendar(in timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    public static func todayString(now: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }

    public static func currentHour(now: Date, timeZone: TimeZone) -> Int {
        calendar(in: timeZone).component(.hour, from: now)
    }

    /// Seven ascending dates ending today, inclusive; crosses months.
    public static func trailing7Days(now: Date, timeZone: TimeZone) -> [String] {
        let cal = calendar(in: timeZone)
        let startOfToday = cal.startOfDay(for: now)
        return (-6...0).compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: offset, to: startOfToday) else { return nil }
            return todayString(now: d, timeZone: timeZone)
        }
    }

    public static func monthStartString(containing ymd: String) -> String {
        String(ymd.prefix(8)) + "01"
    }

    /// Scan `since` is the earlier of month-start and the trailing-7 head.
    public static func requestSince(monthStart: String, trailingFirst: String) -> String {
        min(monthStart, trailingFirst)
    }

    /// Single-day range used when menu-bar / Widget opens detail: always today.
    public static func singleDayRange(_ today: String) -> (since: String, until: String) {
        (today, today)
    }

    public static func datesBetween(since: String, until: String) -> [String] {
        guard SnapshotDate.isValid(since), SnapshotDate.isValid(until), since <= until else { return [] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let start = SnapshotDate.parse(since), let end = SnapshotDate.parse(until) else { return [] }
        var out: [String] = []
        var cursor = start
        while cursor <= end {
            out.append(SnapshotDate.string(from: cursor))
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }

    // MARK: - Daily series (natural month default)

    /// Daily values for [since, until]. Future dates are nil; nil snapshots
    /// or uncovered dates are nil (unknown, never zero); covered empty past
    /// days fill legitimate zero.
    public static func dailySeries(snapshot: ScanSnapshot?, since: String, until: String, today: String) -> [DayPoint] {
        datesBetween(since: since, until: until).map { date in
            if date > today { return DayPoint(date: date, isFuture: true, usage: nil) }
            guard let snapshot else { return DayPoint(date: date, isFuture: false, usage: nil) }
            guard date >= snapshot.range.since && date <= snapshot.range.until else {
                return DayPoint(date: date, isFuture: false, usage: nil)
            }
            if let bucket = snapshot.daily.first(where: { $0.date == date }) {
                return DayPoint(date: date, isFuture: false, usage: aggregateDay(bucket))
            }
            return DayPoint(date: date, isFuture: false, usage: .zero)
        }
    }

    // MARK: - Hourly series (today, local hours)

    /// Hourly values for one date. Only `hourlyDate` carries hourly data;
    /// past days without hourly coverage stay unknown (never derived from
    /// daily totals, which are a different projection). Future hours are nil.
    public static func hourlySeries(snapshot: ScanSnapshot?, date: String, now: Date, timeZone: TimeZone) -> [HourPoint] {
        let today = todayString(now: now, timeZone: timeZone)
        let nowHour = currentHour(now: now, timeZone: timeZone)
        return (0..<24).map { hour in
            let future = date > today || (date == today && hour > nowHour)
            if future { return HourPoint(hour: hour, isFuture: true, usage: nil) }
            guard let snapshot, snapshot.hourlyDate == date else {
                return HourPoint(hour: hour, isFuture: false, usage: nil)
            }
            if let bucket = snapshot.hourly.first(where: { $0.hour == hour }) {
                return HourPoint(hour: hour, isFuture: false, usage: aggregateHour(bucket))
            }
            return HourPoint(hour: hour, isFuture: false, usage: .zero)
        }
    }

    // MARK: - Week segments (Monday–Sunday, clipped to month)

    /// Monday–Sunday groups clipped to the month; yields 4–6 segments.
    public static func weekSegments(year: Int, month: Int, timeZone: TimeZone) -> [WeekSegment] {
        let cal = calendar(in: timeZone)
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let first = cal.date(from: comps),
              let count = cal.range(of: .day, in: .month, for: first)?.count,
              let last = cal.date(byAdding: .day, value: count - 1, to: first)
        else { return [] }
        let weekday = cal.component(.weekday, from: first) // Sunday=1
        let backToMonday = (weekday + 5) % 7
        guard var cursor = cal.date(byAdding: .day, value: -backToMonday, to: first) else { return [] }
        var out: [WeekSegment] = []
        while cursor <= last {
            guard let segEnd = cal.date(byAdding: .day, value: 6, to: cursor) else { break }
            let start = max(todayString(now: cursor, timeZone: timeZone), todayString(now: first, timeZone: timeZone))
            let end = min(todayString(now: segEnd, timeZone: timeZone), todayString(now: last, timeZone: timeZone))
            out.append(WeekSegment(start: start, end: end))
            guard let next = cal.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }
        return out
    }

    /// Weekly totals over segments. The in-progress week cuts off at today;
    /// future segments are nil; segments with no covered days are nil
    /// (unknown, not zero); covered empty days contribute zero.
    public static func weeklyTotals(snapshot: ScanSnapshot?, segments: [WeekSegment], today: String) -> [WeeklyPoint] {
        segments.map { seg in
            if seg.start > today {
                return WeeklyPoint(segment: seg, cutoff: nil, usage: nil)
            }
            let cutoff = min(seg.end, today)
            guard let snapshot else {
                return WeeklyPoint(segment: seg, cutoff: cutoff, usage: nil)
            }
            // A segment is reported only when every requested past day is
            // covered; partially covered weeks stay nil (unknown, not zero).
            let days = datesBetween(since: seg.start, until: cutoff)
            guard days.allSatisfy({ $0 >= snapshot.range.since && $0 <= snapshot.range.until }) else {
                return WeeklyPoint(segment: seg, cutoff: cutoff, usage: nil)
            }
            let byDate = Dictionary(uniqueKeysWithValues: snapshot.daily.map { ($0.date, $0) })
            let entries = days.flatMap { date -> [(TokenCounts, EstimatedCost)] in
                guard let bucket = byDate[date] else {
                    return [(TokenCounts.zero, EstimatedCost.legitimateZero)]
                }
                return bucket.clients.flatMap { $0.models.map { ($0.tokens, $0.estimatedCost) } }
            }
            return WeeklyPoint(segment: seg, cutoff: cutoff, usage: aggregate(entries))
        }
    }
}

public enum TokenFormat {
    public static func compact(_ value: Int64) -> String {
        for (threshold, suffix) in [(Int64(1_000_000_000), "B"), (Int64(1_000_000), "M")] {
            if value >= threshold {
                return String(format: "%.2f", Double(value) / Double(threshold))
                    .replacingOccurrences(of: ".00", with: "") + suffix
            }
        }
        if value >= 1_000 {
            if value % 1_000 == 0 { return "\(value / 1_000)K" }
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

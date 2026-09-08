import Foundation

// Production projection checks: exercise RangeProjection (the seam every
// view uses) against the approved sample plus synthetic snapshots.
// Compiled with the three Shared files; sample path arrives as argv[1].
@main
struct ProjectionChecks {
    static var passes = 0
    static var failures = 0

    static func check(_ cond: Bool, _ msg: String) {
        if cond {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(msg)")
        }
    }

    static func tz(_ id: String) -> TimeZone {
        guard let z = TimeZone(identifier: id) else { fatalError("bad tz \(id)") }
        return z
    }

    static func pricedModel(_ id: String, input: Int64, amount: Double?) -> ModelUsage {
        let cost: EstimatedCost
        if input == 0 {
            cost = .legitimateZero
        } else if let amount {
            cost = EstimatedCost(amountUsd: amount, complete: true, unpricedTokens: 0)
        } else {
            cost = EstimatedCost(amountUsd: nil, complete: false, unpricedTokens: input)
        }
        return ModelUsage(
            modelId: id,
            tokens: TokenCounts(input: input, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0),
            estimatedCost: cost)
    }

    static func pricedDay(_ date: String, _ entries: [(client: String, model: String, input: Int64, amount: Double?)]) -> DayBucket {
        var byClient: [String: [ModelUsage]] = [:]
        for e in entries {
            byClient[e.client, default: []].append(pricedModel(e.model, input: e.input, amount: e.amount))
        }
        return DayBucket(
            date: date,
            clients: byClient.keys.sorted().map { ClientUsage(clientId: $0, models: byClient[$0]!) })
    }

    static func snapshot(
        since: String, until: String, hourlyDate: String,
        daily: [DayBucket], sources: [String], timezone: String = "Asia/Shanghai"
    ) -> ScanSnapshot {
        ScanSnapshot(
            schemaVersion: 1, generatedAt: Date(), timezone: timezone,
            range: ScanRange(since: since, until: until),
            hourlyDate: hourlyDate, pricingAsOf: nil, daily: daily,
            hourly: [], sources: sources.map { SourceStatus(clientId: $0, status: .found, sourceCount: 1) },
            warnings: [])
    }

    static func main() {
        guard CommandLine.arguments.count > 1 else {
            print("FAIL: sample snapshot path required as first argument")
            exit(1)
        }
        let samplePath = CommandLine.arguments[1]
        guard let sampleData = FileManager.default.contents(atPath: samplePath) else {
            print("FAIL: cannot read sample snapshot at \(samplePath)")
            exit(1)
        }
        let shanghai = tz("Asia/Shanghai")
        _ = shanghai

        // 1. Approved sample: selected range total and derived config.
        do {
            let snap = try ScanSnapshot.decodeValidated(from: sampleData)
            let days = ["2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04",
                        "2026-09-05", "2026-09-06", "2026-09-07", "2026-09-08"]
            let total = RangeProjection.rangeTotal(
                snapshot: snap, days: days, today: "2026-09-08",
                enabled: ["codex"], filter: nil)
            check(total?.tokens.total == 160, "sample range total is 160 tokens")
            check(total?.cost.amountUsd == 0.000202, "sample range cost preserved")
            check(Set(snap.sources.map { $0.clientId }) == ["codex"], "config derived from snapshot sources")
            check(snap.timezone == "Asia/Shanghai", "config derived from snapshot timezone")
            let narrow = RangeProjection.rangeTotal(
                snapshot: snap, days: ["2026-09-08"], today: "2026-09-08",
                enabled: ["codex"], filter: nil)
            check(narrow?.tokens.total == 160, "single covered day keeps value")
        } catch {
            check(false, "sample decodes: \(error)")
        }

        // 2. Fully covered empty range is zero, not unknown.
        do {
            let snap = snapshot(
                since: "2026-09-01", until: "2026-09-08", hourlyDate: "2026-09-08",
                daily: [], sources: ["codex"])
            let days = (1...8).map { "2026-09-0\($0)" }
            let total = RangeProjection.rangeTotal(
                snapshot: snap, days: days, today: "2026-09-08",
                enabled: ["codex"], filter: nil)
            check(total == .zero, "fully covered empty range is legitimate zero")
        }

        // 3. Missing or partly uncovered past days are nil, never zero.
        do {
            let snap = snapshot(
                since: "2026-09-05", until: "2026-09-08", hourlyDate: "2026-09-08",
                daily: [pricedDay("2026-09-08", [(client: "codex", model: "m", input: 10, amount: 0.001)])],
                sources: ["codex"])
            let partial = RangeProjection.rangeTotal(
                snapshot: snap, days: ["2026-09-01", "2026-09-08"], today: "2026-09-08",
                enabled: ["codex"], filter: nil)
            check(partial == nil, "partly uncovered past range is nil")
            let before = RangeProjection.rangeTotal(
                snapshot: snap, days: ["2026-08-30"], today: "2026-09-08",
                enabled: ["codex"], filter: nil)
            check(before == nil, "wholly uncovered past day is nil")
            let future = RangeProjection.rangeTotal(
                snapshot: snap, days: ["2026-09-08", "2026-09-09", "2026-09-10"], today: "2026-09-08",
                enabled: ["codex"], filter: nil)
            check(future?.tokens.input == 10, "future days do not force nil")
        }

        // 4. Selected range / client / model conservation and filtering.
        do {
            let snap = snapshot(
                since: "2026-09-07", until: "2026-09-08", hourlyDate: "2026-09-08",
                daily: [
                    pricedDay("2026-09-07", [
                        (client: "codex", model: "m", input: 5, amount: 0.001),
                        (client: "codex", model: "n", input: 7, amount: 0.002),
                        (client: "claude", model: "m", input: 11, amount: 0.003),
                    ]),
                    pricedDay("2026-09-08", [
                        (client: "codex", model: "m", input: 3, amount: 0.001),
                    ]),
                ],
                sources: ["codex", "claude"])
            let days = ["2026-09-07", "2026-09-08"]
            let all = RangeProjection.rangeTotal(
                snapshot: snap, days: days, today: "2026-09-08",
                enabled: ["codex", "claude"], filter: nil)
            check(all?.tokens.input == 26, "range total sums every client and model")
            let entries = RangeProjection.clients(
                snapshot: snap, days: Set(days),
                enabled: ["codex", "claude"], filter: nil)
            let clientSum = entries.map { $0.total.tokens.input }.reduce(0, +)
            let modelSum = entries.flatMap { $0.models }.map { $0.usage.tokens.input }.reduce(0, +)
            check(clientSum == 26 && modelSum == 26, "parent clients equal children models equal range")
            for entry in entries {
                let kids = entry.models.map { $0.usage.tokens.input }.reduce(0, +)
                check(kids == entry.total.tokens.input, "client \(entry.clientId) conserves children")
            }
            let codexOnly = RangeProjection.rangeTotal(
                snapshot: snap, days: days, today: "2026-09-08",
                enabled: ["codex", "claude"], filter: ["codex"])
            check(codexOnly?.tokens.input == 15, "client filter narrows to codex")
            let disabled = RangeProjection.rangeTotal(
                snapshot: snap, days: days, today: "2026-09-08",
                enabled: ["codex"], filter: nil)
            check(disabled?.tokens.input == 15, "disabled client excluded")
            let ghost = RangeProjection.rangeTotal(
                snapshot: snap, days: days, today: "2026-09-08",
                enabled: ["codex", "claude"], filter: ["ghost"])
            check(ghost == .zero, "covered filter with no data is zero")
            let weekOnly = RangeProjection.rangeTotal(
                snapshot: snap, days: ["2026-09-07"], today: "2026-09-08",
                enabled: ["codex", "claude"], filter: nil)
            check(weekOnly?.tokens.input == 23, "selected day subset sums")
        }

        // 5. Partial pricing flows through the projection unchanged.
        do {
            let snap = snapshot(
                since: "2026-09-08", until: "2026-09-08", hourlyDate: "2026-09-08",
                daily: [pricedDay("2026-09-08", [
                    (client: "codex", model: "p", input: 10, amount: 0.5),
                    (client: "codex", model: "u", input: 7, amount: nil),
                ])],
                sources: ["codex"])
            let total = RangeProjection.rangeTotal(
                snapshot: snap, days: ["2026-09-08"], today: "2026-09-08",
                enabled: ["codex"], filter: nil)
            if case .partialKnown(let amount, let unpriced) =
                Aggregation.classify(tokensTotal: total?.tokens.total ?? 0, cost: total?.cost ?? .legitimateZero) {
                check(amount == 0.5 && unpriced == 7, "partial pricing preserved")
            } else {
                check(false, "partial pricing preserved")
            }
        }

        check(TokenFormat.compact(1_000_000_000) == "1B", "billion threshold")
        check(TokenFormat.compact(3_670_880_000) == "3.67B", "monthly billion format")
        check(TokenFormat.compact(294_990_000) == "294.99M", "millions unchanged")
        let menu = snapshot(since: "2026-09-07", until: "2026-09-08", hourlyDate: "2026-09-08", daily: [
            pricedDay("2026-09-07", [(client: "codex", model: "shared", input: 40, amount: 1)]),
            pricedDay("2026-09-08", [(client: "claude", model: "shared", input: 60, amount: 1),
                                   (client: "codex", model: "shared", input: 30, amount: 1)])
        ], sources: ["codex", "claude"])
        let modelRows = RangeProjection.menuRows(snapshot: menu, days: ["2026-09-07", "2026-09-08"], enabled: ["codex", "claude"], grouping: .model)
        check(modelRows.map { $0.tokens } == [70, 60], "models aggregate range and sort descending")
        check(Set(modelRows.map { $0.id }).count == 2, "same model preserves client identity")
        let todayRows = RangeProjection.menuRows(snapshot: menu, days: ["2026-09-08"], enabled: ["codex", "claude"], grouping: .client)
        check(todayRows.map { $0.tokens } == [60, 30], "today/client switch uses same range")

        print("PASS \(passes) projection checks, FAIL \(failures)")
        if failures > 0 { exit(1) }
    }
}

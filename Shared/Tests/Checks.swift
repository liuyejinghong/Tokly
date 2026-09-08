import Foundation

/// Foundation-only executable assertions for the P2 shared layer.
/// The sample snapshot path arrives as the first CLI argument.
/// All dates are deterministic and caller-explicit; no real logs, no network.
@main
struct Checks {
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

    static func expectThrow(_ msg: String, _ body: () throws -> Void) {
        do {
            try body()
            check(false, "expected throw: \(msg)")
        } catch {
            check(true, "rejects \(msg)")
        }
    }

    static func tz(_ id: String) -> TimeZone {
        guard let z = TimeZone(identifier: id) else { fatalError("bad tz \(id)") }
        return z
    }

    static func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ zone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        var c = DateComponents()
        c.year = y
        c.month = m
        c.day = d
        c.hour = h
        c.minute = min
        guard let dt = cal.date(from: c) else { fatalError("bad test date") }
        return dt
    }

    static func pricedModel(_ id: String, input: Int64, output: Int64 = 0, amount: Double) -> ModelUsage {
        ModelUsage(
            modelId: id,
            tokens: TokenCounts(input: input, output: output, cacheRead: 0, cacheWrite: 0, reasoning: 0),
            estimatedCost: EstimatedCost(amountUsd: amount, complete: true, unpricedTokens: 0)
        )
    }

    static func pricedDay(_ date: String, _ client: String, _ model: String, input: Int64, amount: Double) -> DayBucket {
        DayBucket(date: date, clients: [ClientUsage(clientId: client, models: [pricedModel(model, input: input, amount: amount)])])
    }

    static func envelope(
        since: String, until: String, hourlyDate: String,
        daily: String, hourly: String, timezone: String = "Asia/Shanghai"
    ) -> Data {
        let s = "{\"schemaVersion\":1,\"generatedAt\":\"2026-09-08T00:01:00Z\",\"timezone\":\"\(timezone)\",\"range\":{\"since\":\"\(since)\",\"until\":\"\(until)\"},\"hourlyDate\":\"\(hourlyDate)\",\"pricingAsOf\":null,\"daily\":[\(daily)],\"hourly\":[\(hourly)],\"sources\":[{\"clientId\":\"codex\",\"status\":\"found\",\"sourceCount\":1}],\"warnings\":[]}"
        return Data(s.utf8)
    }

    static func main() {
        guard CommandLine.arguments.count > 1 else {
            print("FAIL: sample snapshot path required as first argument")
            exit(1)
        }
        let samplePath = CommandLine.arguments[1]
        guard let sampleData = FileManager.default.contents(atPath: samplePath),
              let sampleJSON = String(data: sampleData, encoding: .utf8)
        else {
            print("FAIL: cannot read sample snapshot at \(samplePath)")
            exit(1)
        }
        let shanghai = tz("Asia/Shanghai")

        // MARK: - 1. Sample snapshot decodes through the validated entrypoint
        do {
            let snap = try ScanSnapshot.decodeValidated(from: sampleData)
            check(snap.schemaVersion == 1, "sample schema version")
            check(snap.range.since == "2026-09-01" && snap.range.until == "2026-09-08", "sample range")
            check(snap.hourlyDate == "2026-09-08", "sample hourly date")
            let day = Aggregation.aggregateDay(snap.daily[0])
            check(day.tokens.input == 80 && day.tokens.output == 50 && day.tokens.cacheRead == 20
                && day.tokens.cacheWrite == 0 && day.tokens.reasoning == 10, "sample token fields")
            check(day.tokens.total == 160, "sample token total")
            check(day.cost.amountUsd == 0.000202 && day.cost.complete, "sample cost")
            // Parent conservation: client total == sum of model children.
            let client = snap.daily[0].clients[0]
            check(Aggregation.aggregateClient(client) == Aggregation.aggregateModels(client.models), "sample parent conservation")
            // Day/hour are one usage in two projections and agree here.
            check(Aggregation.verifyDayHourConsistency(snap), "sample day/hour consistency")
            if case .fullyPriced(let a) = Aggregation.classify(tokensTotal: day.tokens.total, cost: day.cost) {
                check(a == 0.000202, "sample fully priced")
            } else {
                check(false, "sample fully priced")
            }
            let today = Aggregation.todayUsage(snap, today: "2026-09-08", clientIds: nil)
            check(today == day, "sample unfiltered today")
        } catch {
            check(false, "sample decodes: \(error)")
        }

        // MARK: - 2. Validation rejects malformed envelopes
        func mutated(_ from: String, _ old: String, _ new: String) -> Data {
            Data(sampleJSON.replacingOccurrences(of: old, with: new).utf8)
        }
        expectThrow("schema 2") {
            _ = try ScanSnapshot.decodeValidated(from: mutated(sampleJSON, "\"schemaVersion\": 1", "\"schemaVersion\": 2"))
        }
        expectThrow("malformed date") {
            _ = try ScanSnapshot.decodeValidated(from: mutated(sampleJSON, "2026-09-01", "2026-13-40"))
        }
        expectThrow("hour 24") {
            _ = try ScanSnapshot.decodeValidated(from: mutated(sampleJSON, "\"hour\": 8", "\"hour\": 24"))
        }
        expectThrow("negative tokens") {
            _ = try ScanSnapshot.decodeValidated(from: mutated(sampleJSON, "\"input\": 80", "\"input\": -1"))
        }
        expectThrow("negative cost") {
            _ = try ScanSnapshot.decodeValidated(from: mutated(sampleJSON, "\"amountUsd\": 0.000202", "\"amountUsd\": -1"))
        }
        expectThrow("complete without amount") {
            _ = try ScanSnapshot.decodeValidated(from: mutated(sampleJSON, "\"amountUsd\": 0.000202", "\"amountUsd\": null"))
        }
        expectThrow("incomplete with zero unpriced") {
            _ = try ScanSnapshot.decodeValidated(from: mutated(sampleJSON, "\"complete\": true", "\"complete\": false"))
        }
        expectThrow("hourlyDate outside range") {
            _ = try ScanSnapshot.decodeValidated(from: mutated(sampleJSON, "\"hourlyDate\": \"2026-09-08\"", "\"hourlyDate\": \"2026-09-20\""))
        }
        expectThrow("unknown source status") {
            _ = try ScanSnapshot.decodeValidated(from: mutated(sampleJSON, "\"status\": \"found\"", "\"status\": \"maybe\""))
        }
        expectThrow("unknown timezone") {
            _ = try ScanSnapshot.decodeValidated(from: mutated(sampleJSON, "Asia/Shanghai", "Not/AZone"))
        }
        expectThrow("zero volume carrying a subtotal") {
            var s = sampleJSON
            s = s.replacingOccurrences(of: "\"input\": 80", with: "\"input\": 0")
            s = s.replacingOccurrences(of: "\"output\": 50", with: "\"output\": 0")
            s = s.replacingOccurrences(of: "\"cacheRead\": 20", with: "\"cacheRead\": 0")
            s = s.replacingOccurrences(of: "\"reasoning\": 10", with: "\"reasoning\": 0")
            _ = try ScanSnapshot.decodeValidated(from: Data(s.utf8))
        }

        // MARK: - 3. Int64 precision and saturation
        do {
            let big = TokenCounts(input: Int64.max, output: 1, cacheRead: 0, cacheWrite: 0, reasoning: 0)
            check(big.total == Int64.max, "saturating total")
            let a = pricedModel("m", input: Int64.max, amount: 1.0)
            let b = pricedModel("m", input: 5, amount: 2.0)
            let merged = Aggregation.aggregateModels([a, b])
            check(merged.tokens.input == Int64.max, "saturating aggregate input")
            let u1 = EstimatedCost(amountUsd: nil, complete: false, unpricedTokens: Int64.max)
            let u2 = EstimatedCost(amountUsd: nil, complete: false, unpricedTokens: 7)
            let um = Aggregation.mergeCosts([u1, u2], totalTokens: 9)
            check(um.unpricedTokens == Int64.max && um.amountUsd == nil && !um.complete, "saturating unpriced")
            let bigJSON = envelope(
                since: "2026-09-08", until: "2026-09-08", hourlyDate: "2026-09-08",
                daily: "{\"date\":\"2026-09-08\",\"clients\":[{\"clientId\":\"codex\",\"models\":[{\"modelId\":\"m\",\"tokens\":{\"input\":9223372036854775807,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"reasoning\":0},\"estimatedCost\":{\"amountUsd\":1.5,\"complete\":true,\"unpricedTokens\":0}}]}]}",
                hourly: ""
            )
            let snap = try ScanSnapshot.decodeValidated(from: bigJSON)
            check(Aggregation.aggregateDay(snap.daily[0]).tokens.total == Int64.max, "Int64 JSON precision")
        } catch {
            check(false, "Int64 path: \(error)")
        }

        // MARK: - 4. Trailing 7 days across a month boundary + leap month
        do {
            let now = at(2026, 3, 3, 12, 0, shanghai)
            let t7 = Aggregation.trailing7Days(now: now, timeZone: shanghai)
            check(t7 == ["2026-02-25", "2026-02-26", "2026-02-27", "2026-02-28", "2026-03-01", "2026-03-02", "2026-03-03"], "early-month trailing 7 crosses month")
            check(Aggregation.monthStartString(containing: "2026-03-03") == "2026-03-01", "month start")
            check(Aggregation.requestSince(monthStart: "2026-03-01", trailingFirst: t7.first!) == "2026-02-25", "request since is earlier head")
            let feb = Aggregation.datesBetween(since: "2024-02-01", until: "2024-02-29")
            check(feb.count == 29 && feb.last == "2024-02-29", "leap month has 29 days")
        }

        // MARK: - 5. Week segments: 4 / 5 / 6 groups, clipped, contiguous
        do {
            let s4 = Aggregation.weekSegments(year: 2021, month: 2, timeZone: shanghai)
            let s5 = Aggregation.weekSegments(year: 2024, month: 2, timeZone: shanghai)
            let s6 = Aggregation.weekSegments(year: 2026, month: 8, timeZone: shanghai)
            check(s4.count == 4, "Feb 2021 has 4 segments (got \(s4.count))")
            check(s5.count == 5, "Feb 2024 has 5 segments (got \(s5.count))")
            check(s6.count == 6, "Aug 2026 has 6 segments (got \(s6.count))")
            for (segs, first, last) in [(s4, "2021-02-01", "2021-02-28"), (s5, "2024-02-01", "2024-02-29"), (s6, "2026-08-01", "2026-08-31")] {
                let covered = segs.flatMap { Aggregation.datesBetween(since: $0.start, until: $0.end) }
                check(covered == Aggregation.datesBetween(since: first, until: last), "segments tile \(first.prefix(7)) exactly once")
                for s in segs {
                    let wd = weekday(of: s.start, in: shanghai)
                    let isFirst = s.start == first
                    check(isFirst || wd == 2, "segment starts Monday or month head (\(s.start))")
                }
            }
        }

        // MARK: - 6. Weekly totals: partial current-week cutoff, future nil
        do {
            var daily: [DayBucket] = []
            for d in 1...8 {
                daily.append(pricedDay("2026-09-\(String(format: "%02d", d))", "codex", "m", input: 10, amount: 0.001))
            }
            let snap = ScanSnapshot(
                schemaVersion: 1, generatedAt: Date(), timezone: "Asia/Shanghai",
                range: ScanRange(since: "2026-09-01", until: "2026-09-08"),
                hourlyDate: "2026-09-08", pricingAsOf: nil, daily: daily,
                hourly: [], sources: [], warnings: []
            )
            let segs = Aggregation.weekSegments(year: 2026, month: 9, timeZone: shanghai)
            check(segs.count == 5, "Sep 2026 has 5 segments")
            let points = Aggregation.weeklyTotals(snapshot: snap, segments: segs, today: "2026-09-08")
            check(points[0].usage?.tokens.input == 60, "first partial week sums 6 covered days")
            check(points[1].cutoff == "2026-09-08", "current week cut off at today")
            check(points[1].usage?.tokens.input == 20, "current week sums only days through today, not future")
            check(points[2].usage == nil && points[2].cutoff == nil, "future week is nil")
            check(points[3].usage == nil && points[4].usage == nil, "later future weeks are nil")
            // Missing snapshot is never zero-filled.
            let missing = Aggregation.weeklyTotals(snapshot: nil, segments: segs, today: "2026-09-08")
            check(missing.allSatisfy { $0.usage == nil }, "missing snapshot yields no zeros")
            // Partially covered weeks stay nil instead of summing a subset.
            let partialSnap = ScanSnapshot(
                schemaVersion: 1, generatedAt: Date(), timezone: "Asia/Shanghai",
                range: ScanRange(since: "2026-09-05", until: "2026-09-08"),
                hourlyDate: "2026-09-08", pricingAsOf: nil,
                daily: [pricedDay("2026-09-05", "codex", "m", input: 10, amount: 0.001),
                        pricedDay("2026-09-06", "codex", "m", input: 10, amount: 0.001),
                        pricedDay("2026-09-07", "codex", "m", input: 10, amount: 0.001),
                        pricedDay("2026-09-08", "codex", "m", input: 10, amount: 0.001)],
                hourly: [], sources: [], warnings: []
            )
            let partial = Aggregation.weeklyTotals(snapshot: partialSnap, segments: segs, today: "2026-09-08")
            check(partial[0].usage == nil, "partially covered week is nil, not a subset sum")
            check(partial[1].usage?.tokens.input == 20, "fully covered current week still sums")
        }

        // MARK: - 7. Daily series: covered-empty fills zero, future/uncovered nil
        do {
            let snap = ScanSnapshot(
                schemaVersion: 1, generatedAt: Date(), timezone: "Asia/Shanghai",
                range: ScanRange(since: "2026-09-01", until: "2026-09-08"),
                hourlyDate: "2026-09-08", pricingAsOf: nil,
                daily: [pricedDay("2026-09-07", "codex", "m", input: 10, amount: 0.001),
                        pricedDay("2026-09-08", "codex", "m", input: 20, amount: 0.002)],
                hourly: [], sources: [], warnings: []
            )
            let series = Aggregation.dailySeries(snapshot: snap, since: "2026-08-30", until: "2026-09-10", today: "2026-09-08")
            let byDate = Dictionary(uniqueKeysWithValues: series.map { ($0.date, $0) })
            check(byDate["2026-08-30"]!.usage == nil && byDate["2026-08-31"]!.usage == nil, "uncovered past stays unknown, not zero")
            check(byDate["2026-09-01"]!.usage == .zero, "covered empty past fills legitimate zero")
            check(byDate["2026-09-07"]!.usage?.tokens.input == 10, "known day keeps value")
            check(byDate["2026-09-09"]!.usage == nil && byDate["2026-09-09"]!.isFuture, "future day is nil")
            check(byDate["2026-09-10"]!.usage == nil && byDate["2026-09-10"]!.isFuture, "further future is nil")
            let missing = Aggregation.dailySeries(snapshot: nil, since: "2026-09-01", until: "2026-09-08", today: "2026-09-08")
            check(missing.allSatisfy { $0.usage == nil }, "failed snapshot never fills zero")
        }

        // MARK: - 8. Hourly series: today only, future nil, no daily backfill
        do {
            let hourBucket = HourBucket(hour: 8, clients: [ClientUsage(clientId: "codex", models: [pricedModel("m", input: 80, amount: 0.001)])])
            let snap = ScanSnapshot(
                schemaVersion: 1, generatedAt: Date(), timezone: "Asia/Shanghai",
                range: ScanRange(since: "2026-09-01", until: "2026-09-08"),
                hourlyDate: "2026-09-08", pricingAsOf: nil,
                daily: [pricedDay("2026-09-08", "codex", "m", input: 80, amount: 0.001)],
                hourly: [hourBucket], sources: [], warnings: []
            )
            let now = at(2026, 9, 8, 10, 0, shanghai)
            let hours = Aggregation.hourlySeries(snapshot: snap, date: "2026-09-08", now: now, timeZone: shanghai)
            check(hours[8].usage?.tokens.input == 80, "known hour keeps value")
            check(hours[9].usage == .zero && !hours[9].isFuture, "covered empty past hour fills zero")
            check(hours[11].usage == nil && hours[11].isFuture, "future hour is nil")
            let other = Aggregation.hourlySeries(snapshot: snap, date: "2026-09-07", now: now, timeZone: shanghai)
            check(other.allSatisfy { $0.usage == nil }, "past day without hourly coverage stays unknown")
        }

        // MARK: - 9. DST repeated clock hour arrives already merged (single label)
        do {
            let merged = envelope(
                since: "2025-11-01", until: "2025-11-03", hourlyDate: "2025-11-02",
                daily: "{\"date\":\"2025-11-02\",\"clients\":[{\"clientId\":\"codex\",\"models\":[{\"modelId\":\"m\",\"tokens\":{\"input\":20,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"reasoning\":0},\"estimatedCost\":{\"amountUsd\":0.002,\"complete\":true,\"unpricedTokens\":0}}]}]}",
                hourly: "{\"hour\":1,\"clients\":[{\"clientId\":\"codex\",\"models\":[{\"modelId\":\"m\",\"tokens\":{\"input\":20,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"reasoning\":0},\"estimatedCost\":{\"amountUsd\":0.002,\"complete\":true,\"unpricedTokens\":0}}]}]}",
                timezone: "America/New_York"
            )
            let snap = try ScanSnapshot.decodeValidated(from: merged)
            check(snap.hourly.filter { $0.hour == 1 }.count == 1, "merged DST hour decodes as one label")
            check(Aggregation.verifyDayHourConsistency(snap), "merged day/hour agree")
            let duplicated = envelope(
                since: "2025-11-01", until: "2025-11-03", hourlyDate: "2025-11-02",
                daily: "{\"date\":\"2025-11-02\",\"clients\":[{\"clientId\":\"codex\",\"models\":[{\"modelId\":\"m\",\"tokens\":{\"input\":20,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"reasoning\":0},\"estimatedCost\":{\"amountUsd\":0.002,\"complete\":true,\"unpricedTokens\":0}}]}]}",
                hourly: "{\"hour\":1,\"clients\":[]},{\"hour\":1,\"clients\":[]}",
                timezone: "America/New_York"
            )
            expectThrow("duplicate hour labels") {
                _ = try ScanSnapshot.decodeValidated(from: duplicated)
            }
            let unordered = envelope(
                since: "2025-11-01", until: "2025-11-03", hourlyDate: "2025-11-02",
                daily: "{\"date\":\"2025-11-02\",\"clients\":[{\"clientId\":\"codex\",\"models\":[{\"modelId\":\"m\",\"tokens\":{\"input\":20,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"reasoning\":0},\"estimatedCost\":{\"amountUsd\":0.002,\"complete\":true,\"unpricedTokens\":0}}]}]}",
                hourly: "{\"hour\":9,\"clients\":[]},{\"hour\":8,\"clients\":[]}",
                timezone: "America/New_York"
            )
            expectThrow("unordered hourly buckets") {
                _ = try ScanSnapshot.decodeValidated(from: unordered)
            }
        } catch {
            check(false, "DST merge: \(error)")
        }

        // MARK: - 10. Cost states: missing vs partial vs all-unpriced vs free
        do {
            // Zero-volume contributors drop out at the seam: a filled empty
            // day next to one unpriced token must stay unknown, not Some(0).
            let seam = Aggregation.aggregate([
                (.zero, EstimatedCost.legitimateZero),
                (TokenCounts(input: 1, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0),
                 EstimatedCost(amountUsd: nil, complete: false, unpricedTokens: 1)),
            ])
            check(seam.cost.amountUsd == nil && !seam.cost.complete && seam.cost.unpricedTokens == 1, "zero-volume seam keeps amount unknown")
            let zeroEntry = ModelUsage(modelId: "z", tokens: .zero, estimatedCost: .legitimateZero)
            let freeEntry = ModelUsage(modelId: "f", tokens: TokenCounts(input: 5, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0), estimatedCost: EstimatedCost(amountUsd: 0, complete: true, unpricedTokens: 0))
            let pricedEntry = pricedModel("p", input: 10, amount: 0.5)
            let unpricedEntry = ModelUsage(modelId: "u", tokens: TokenCounts(input: 7, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0), estimatedCost: EstimatedCost(amountUsd: nil, complete: false, unpricedTokens: 7))
            let zeroAgg = Aggregation.aggregateModels([zeroEntry])
            check(zeroAgg.cost.amountUsd == 0 && zeroAgg.cost.complete, "zero volume never fabricates a subtotal")
            check(Aggregation.classify(tokensTotal: 0, cost: zeroAgg.cost) == .legitimateZero, "legitimate zero classified")
            check(Aggregation.classify(tokensTotal: 5, cost: freeEntry.estimatedCost) == .fullyPriced(amountUsd: 0), "known free stays fully priced, distinct from unknown")
            let partial = Aggregation.aggregateModels([pricedEntry, unpricedEntry])
            if case .partialKnown(let a, let u) = Aggregation.classify(tokensTotal: partial.tokens.total, cost: partial.cost) {
                check(a == 0.5 && u == 7, "partial keeps known sum plus unpriced volume")
            } else {
                check(false, "partial classified")
            }
            let all = Aggregation.aggregateModels([unpricedEntry])
            if case .allUnpriced(let u) = Aggregation.classify(tokensTotal: all.tokens.total, cost: all.cost) {
                check(all.cost.amountUsd == nil && u == 7, "all unpriced keeps amount unknown")
            } else {
                check(false, "all-unpriced classified")
            }
        }

        // MARK: - 11. Cross-client identity + main-window-only filtering
        do {
            let day = DayBucket(date: "2026-09-08", clients: [
                ClientUsage(clientId: "codex", models: [pricedModel("m", input: 5, amount: 0.001)]),
                ClientUsage(clientId: "claude", models: [pricedModel("m", input: 7, amount: 0.002)]),
            ])
            let snap = ScanSnapshot(
                schemaVersion: 1, generatedAt: Date(), timezone: "Asia/Shanghai",
                range: ScanRange(since: "2026-09-08", until: "2026-09-08"),
                hourlyDate: "2026-09-08", pricingAsOf: nil, daily: [day],
                hourly: [], sources: [], warnings: []
            )
            check(Aggregation.aggregateDay(day).tokens.input == 12, "same model across clients sums at day level")
            check(Aggregation.aggregateClient(day.clients[0]).tokens.input == 5
                && Aggregation.aggregateClient(day.clients[1]).tokens.input == 7, "clients retain separate identity")
            let main = Aggregation.todayUsage(snap, today: "2026-09-08", clientIds: ["codex"])
            let all = Aggregation.todayUsage(snap, today: "2026-09-08", clientIds: nil)
            check(main?.tokens.input == 5, "main-window filter narrows to selected clients")
            check(all?.tokens.input == 12, "menu-bar/Widget today keeps every enabled source")
            check(Aggregation.todayUsage(snap, today: "2026-09-09", clientIds: nil) == nil, "uncovered today is nil, not zero")
            check(Aggregation.todayUsage(nil, today: "2026-09-08", clientIds: nil) == nil, "missing snapshot is nil, not zero")
            check(Aggregation.singleDayRange("2026-09-08").since == "2026-09-08", "detail reopens on today")
        }

        // MARK: - 12. Widget snapshot: minimal, expiry retains date
        do {
            let snap = ScanSnapshot(
                schemaVersion: 1, generatedAt: Date(), timezone: "Asia/Shanghai",
                range: ScanRange(since: "2026-09-01", until: "2026-09-08"),
                hourlyDate: "2026-09-08", pricingAsOf: nil,
                daily: [pricedDay("2026-09-08", "codex", "m", input: 80, amount: 0.001)],
                hourly: [], sources: [], warnings: []
            )
            let prefs = WidgetPreferences(showCost: true)
            let widget = WidgetSnapshotBuilder.make(from: snap, today: "2026-09-08", preferences: prefs)
            check(widget.updatedAt == snap.generatedAt, "widget stamps scan time")
            check(widget.date == "2026-09-08" && !widget.isExpired(today: "2026-09-08"), "fresh widget current")
            check(widget.totals.input == 80 && widget.clients.count == 1, "widget carries current-day totals")
            check(widget.isExpired(today: "2026-09-09"), "yesterday snapshot marks expired")
            check(widget.date == "2026-09-08", "expired snapshot retains its date")
            let stale = WidgetSnapshotBuilder.make(from: snap, today: "2026-09-09", preferences: prefs)
            check(stale.date == "2026-09-08" && stale.isExpired(today: "2026-09-09"), "stale build retains old date, never rewrites as today")
            check(stale.totals.input == 80, "stale build keeps old values, never zero-fills as today")
            check(stale.updatedAt == snap.generatedAt, "stale build keeps scan time, never stamps now")
            let encoded = try JSONEncoder().encode(widget)
            let text = String(data: encoded, encoding: .utf8) ?? ""
            check(!text.contains("hourly") && !text.contains("daily") && !text.contains("sourceCount") && !text.contains("pricingAsOf"), "widget carries no history or source paths")
            let roundTrip = try JSONDecoder().decode(WidgetSnapshot.self, from: encoded)
            check(roundTrip == widget, "widget codable round-trip")
        } catch {
            check(false, "widget path: \(error)")
        }

        // MARK: - 13. Range totals never mix projections
        do {
            let snap = try ScanSnapshot.decodeValidated(from: sampleData)
            let rangeTotal = Aggregation.aggregateDays(snap.daily)
            check(rangeTotal.tokens.total == 160, "range total comes from daily only")
            check(Aggregation.verifyDayHourConsistency(snap), "projections agree without being added together")
            let empty = Aggregation.aggregateDays([])
            check(empty == .zero, "empty range is legitimate zero")
            let roundTripped = try ScanSnapshot.decodeValidated(from: try snap.encoded())
            check(roundTripped == snap, "owned encode round-trips through validated decode")
        } catch {
            check(false, "range totals: \(error)")
        }

        // MARK: - 14. Consistency tolerates regrouped sums, rejects real drift
        do {
            func regrouped(amount: Double, swapped: Bool) -> ScanSnapshot {
                let dayClients = swapped
                    ? [ClientUsage(clientId: "codex", models: [pricedModel("m", input: 10, amount: 0.1)]),
                       ClientUsage(clientId: "claude", models: [pricedModel("m", input: 20, amount: 0.2)])]
                    : [ClientUsage(clientId: "codex", models: [pricedModel("m", input: 30, amount: amount)])]
                let hourClients = swapped
                    ? [ClientUsage(clientId: "codex", models: [pricedModel("m", input: 10, amount: 0.2)]),
                       ClientUsage(clientId: "claude", models: [pricedModel("m", input: 20, amount: 0.1)])]
                    : [ClientUsage(clientId: "codex", models: [pricedModel("m", input: 10, amount: 0.1)]),
                       ClientUsage(clientId: "codex", models: [pricedModel("m", input: 20, amount: 0.2)])]
                return ScanSnapshot(
                    schemaVersion: 1, generatedAt: Date(), timezone: "Asia/Shanghai",
                    range: ScanRange(since: "2026-09-08", until: "2026-09-08"),
                    hourlyDate: "2026-09-08", pricingAsOf: nil,
                    daily: [DayBucket(date: "2026-09-08", clients: dayClients)],
                    hourly: [HourBucket(hour: 8, clients: [hourClients[0]]),
                             HourBucket(hour: 9, clients: Array(hourClients.dropFirst()))],
                    sources: [], warnings: []
                )
            }
            // 0.1 + 0.2 regroups to 0.30000000000000004 vs daily 0.3.
            check(Aggregation.verifyDayHourConsistency(regrouped(amount: 0.3, swapped: false)), "regrouped .1/.2/.3 passes")
            check(!Aggregation.verifyDayHourConsistency(regrouped(amount: 0.5, swapped: false)), "genuinely different amount rejected")
            check(!Aggregation.verifyDayHourConsistency(regrouped(amount: 0.3, swapped: true)), "swapped client amounts rejected")
        }

        print("PASS \(passes) checks, FAIL \(failures)")
        if failures > 0 { exit(1) }
    }

    /// Monday=2 in the Gregorian calendar.
    static func weekday(of ymd: String, in timeZone: TimeZone) -> Int {
        guard let d = SnapshotDate.parse(ymd) else { return 0 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.component(.weekday, from: d)
    }
}

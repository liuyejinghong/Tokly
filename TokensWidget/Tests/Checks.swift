import Foundation

/// Foundation-only P4 widget checks.
///
/// Compiled with the three Shared sources + `TokensWidget/WidgetData.swift`
/// via `bash scripts/check-widget.sh`. First CLI argument is the approved
/// scan sample (`Shared/sample-snapshot.json`). Only temporary synthetic
/// files are read/written; no real App Group, no app/extension launch, no
/// network, no signing.
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

    static func pricedModel(_ id: String, input: Int64, output: Int64 = 0, amount: Double?) -> ModelUsage {
        let cost: EstimatedCost
        if let amount {
            cost = EstimatedCost(amountUsd: amount, complete: true, unpricedTokens: 0)
        } else {
            cost = EstimatedCost(amountUsd: nil, complete: false, unpricedTokens: input + output)
        }
        return ModelUsage(
            modelId: id,
            tokens: TokenCounts(input: input, output: output, cacheRead: 0, cacheWrite: 0, reasoning: 0),
            estimatedCost: cost)
    }

    static func pricedDay(_ date: String, _ client: String, _ model: String, input: Int64, amount: Double?) -> DayBucket {
        DayBucket(date: date, clients: [ClientUsage(clientId: client, models: [pricedModel(model, input: input, amount: amount)])])
    }

    static func scanFor(day: DayBucket, date: String, zone: String = "Asia/Shanghai") -> ScanSnapshot {
        ScanSnapshot(
            schemaVersion: 1,
            generatedAt: SnapshotTime.parseRFC3339("2026-09-08T00:01:00Z")!,
            timezone: zone,
            range: ScanRange(since: date, until: date),
            hourlyDate: date,
            pricingAsOf: nil,
            daily: [day],
            hourly: [],
            sources: [SourceStatus(clientId: "codex", status: .found, sourceCount: 1)],
            warnings: [])
    }

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("widget-check-\(UUID().uuidString).json")
    }

    static func write(_ snapshot: WidgetSnapshot) -> URL {
        let url = tempURL()
        do {
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        } catch {
            fatalError("cannot write temp snapshot: \(error)")
        }
        return url
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
        let newYork = tz("America/New_York")

        // MARK: - 1. Approved sample -> main builder -> encode -> read (current)
        do {
            let snap = try ScanSnapshot.decodeValidated(from: sampleData)
            let prefs = WidgetPreferences(showCost: true)
            let widget = WidgetSnapshotBuilder.make(from: snap, today: "2026-09-08", preferences: prefs)
            check(widget.timezone == "Asia/Shanghai", "builder inherits scan timezone")
            check(widget.updatedAt == snap.generatedAt, "builder keeps scan time")
            check(widget.date == "2026-09-08", "builder date is today")
            let url = write(widget)
            defer { try? FileManager.default.removeItem(at: url) }
            let now = at(2026, 9, 8, 12, 0, shanghai)
            let read = WidgetReader.read(at: url, now: now)
            check(read == .current(widget), "sample round-trips to current")
            check(read.snapshot?.totals.total == 160, "sample totals preserved")
            check(read.snapshot?.totalCost.amountUsd == 0.000202, "sample cost preserved")
            check(!read.isPlaceholder, "current is not placeholder")
            // Small/medium display states follow showCost.
            check(WidgetReader.primaryText(for: widget) == "$0.00", "cost primary shows amount")
            check(WidgetReader.secondaryText(for: widget) == "160 Token", "cost secondary shows tokens")
            let tokensPrefs = WidgetSnapshot(
                date: widget.date, timezone: widget.timezone, updatedAt: widget.updatedAt,
                totals: widget.totals, totalCost: widget.totalCost,
                clients: widget.clients, preferences: WidgetPreferences(showCost: false))
            check(WidgetReader.primaryText(for: tokensPrefs) == "160", "tokens primary shows compact")
            check(!WidgetReader.topClients(for: widget).isEmpty, "medium has client summaries")
        } catch {
            check(false, "sample builder round-trip: \(error)")
        }

        // MARK: - 2. Missing file -> placeholder, never stale fallback
        do {
            let absent = FileManager.default.temporaryDirectory
                .appendingPathComponent("widget-missing-\(UUID().uuidString).json")
            let now = at(2026, 9, 8, 12, 0, shanghai)
            check(WidgetReader.read(at: absent, now: now) == .missing, "absent file is missing")
            check(WidgetReader.read(at: nil, now: now) == .missing, "nil URL is missing")
            check(WidgetReader.read(at: absent, now: now).isPlaceholder, "missing is placeholder")
            // Removal after a user config change invalidates instead of restoring.
            let snap = try ScanSnapshot.decodeValidated(from: sampleData)
            let widget = WidgetSnapshotBuilder.make(from: snap, today: "2026-09-08", preferences: WidgetPreferences(showCost: true))
            let url = write(widget)
            check(WidgetReader.read(at: url, now: now) == .current(widget), "present file current before removal")
            try FileManager.default.removeItem(at: url)
            check(WidgetReader.read(at: url, now: now) == .missing, "removed file is missing, not stale cache")
        } catch {
            check(false, "missing path: \(error)")
        }

        // MARK: - 3. Corrupt / failure payloads -> invalid, never pseudo-zero
        do {
            let now = at(2026, 9, 8, 12, 0, shanghai)
            let bad = tempURL()
            defer { try? FileManager.default.removeItem(at: bad) }
            try Data("not json".utf8).write(to: bad)
            if case .invalid = WidgetReader.read(at: bad, now: now) {
                check(true, "corrupt is invalid")
            } else {
                check(false, "corrupt is invalid")
            }
            check(WidgetReader.read(at: bad, now: now).snapshot == nil, "invalid carries no values")
            check(WidgetReader.read(at: bad, now: now).isPlaceholder, "invalid is placeholder")
            // Truncated JSON.
            try Data("{\"date\":".utf8).write(to: bad)
            if case .invalid = WidgetReader.read(at: bad, now: now) {
                check(true, "truncated is invalid")
            } else {
                check(false, "truncated is invalid")
            }
        } catch {
            check(false, "corrupt path: \(error)")
        }

        // MARK: - 4. Strict payload validation
        do {
            let snap = try ScanSnapshot.decodeValidated(from: sampleData)
            let base = WidgetSnapshotBuilder.make(from: snap, today: "2026-09-08", preferences: WidgetPreferences(showCost: true))
            let now = at(2026, 9, 8, 12, 0, shanghai)
            func expectInvalid(_ s: WidgetSnapshot, _ msg: String) {
                let url = write(s)
                defer { try? FileManager.default.removeItem(at: url) }
                if case .invalid = WidgetReader.read(at: url, now: now) {
                    check(true, msg)
                } else {
                    check(false, msg)
                }
            }
            var bad = base; bad.date = "2026-13-40"
            expectInvalid(bad, "rejects malformed date")
            var badTZ = base; badTZ.timezone = "Not/AZone"
            expectInvalid(badTZ, "rejects unknown timezone")
            var neg = base; neg.totals = TokenCounts(input: -1, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0)
            expectInvalid(neg, "rejects negative tokens")
            var negCost = base; negCost.totalCost = EstimatedCost(amountUsd: -1, complete: true, unpricedTokens: 0)
            expectInvalid(negCost, "rejects negative cost")
            // Non-finite amounts cannot be JSON-encoded, so validate directly.
            var infCost = base; infCost.totalCost = EstimatedCost(amountUsd: Double.infinity, complete: true, unpricedTokens: 0)
            check(WidgetReader.validationError(for: infCost) != nil, "rejects non-finite cost")
            var noAmount = base; noAmount.totalCost = EstimatedCost(amountUsd: nil, complete: true, unpricedTokens: 0)
            expectInvalid(noAmount, "rejects complete without amount")
            var zeroCarry = base
            zeroCarry.totals = .zero
            zeroCarry.totalCost = EstimatedCost(amountUsd: 0.5, complete: true, unpricedTokens: 0)
            expectInvalid(zeroCarry, "rejects zero volume carrying a subtotal")
            var negClient = base
            negClient.clients = [WidgetClientSummary(clientId: "codex", totalTokens: -3, amountUsd: 0.1, complete: true)]
            expectInvalid(negClient, "rejects negative client tokens")
            var badClientCost = base
            badClientCost.clients = [WidgetClientSummary(clientId: "codex", totalTokens: 5, amountUsd: nil, complete: true)]
            expectInvalid(badClientCost, "rejects complete client without amount")
        } catch {
            check(false, "validation path: \(error)")
        }

        // MARK: - 5. Expired keeps original date/values/time
        do {
            let snap = try ScanSnapshot.decodeValidated(from: sampleData)
            let prefs = WidgetPreferences(showCost: true)
            let stale = WidgetSnapshotBuilder.make(from: snap, today: "2026-09-09", preferences: prefs)
            check(stale.date == "2026-09-08", "stale build retains old date")
            check(stale.updatedAt == snap.generatedAt, "stale build keeps scan time")
            let url = write(stale)
            defer { try? FileManager.default.removeItem(at: url) }
            let nextDay = at(2026, 9, 9, 9, 0, shanghai)
            let read = WidgetReader.read(at: url, now: nextDay)
            check(read == .expired(stale), "old snapshot reads expired")
            check(read.snapshot?.date == "2026-09-08", "expired retains date")
            check(read.snapshot?.totals.total == 160, "expired retains values")
            check(read.snapshot?.updatedAt == snap.generatedAt, "expired retains scan time")
            check(!read.isPlaceholder, "expired is not placeholder")
            check(WidgetReader.expiredLabel(date: "2026-09-08") == "9/8的数据 · 今日暂无覆盖", "expired label keeps original date")
        } catch {
            check(false, "expiry path: \(error)")
        }

        // MARK: - 6. Non-system timezone midnight (payload zone wins)
        do {
            // 2026-09-08 00:30 in Shanghai is still 2026-09-07 in New York.
            // The payload timezone (Shanghai) must decide current/expired.
            let day = pricedDay("2026-09-08", "codex", "m", input: 10, amount: 0.001)
            let snap = scanFor(day: day, date: "2026-09-08", zone: "Asia/Shanghai")
            let widget = WidgetSnapshotBuilder.make(from: snap, today: "2026-09-08", preferences: WidgetPreferences(showCost: false))
            let url = write(widget)
            defer { try? FileManager.default.removeItem(at: url) }
            let shanghaiEarly = at(2026, 9, 8, 0, 30, shanghai)
            // Sanity: the same instant is a different calendar day in New York.
            check(WidgetReader.todayString(now: shanghaiEarly, timeZone: shanghai) == "2026-09-08", "payload zone says 09-08")
            check(WidgetReader.todayString(now: shanghaiEarly, timeZone: newYork) == "2026-09-07", "system-like zone would say 09-07")
            check(WidgetReader.read(at: url, now: shanghaiEarly) == .current(widget), "reader uses payload zone, not system zone")
            // Midnight boundary in the payload zone.
            let before = at(2026, 9, 8, 23, 50, shanghai)
            let after = at(2026, 9, 9, 0, 10, shanghai)
            check(WidgetReader.read(at: url, now: before) == .current(widget), "before payload midnight is current")
            check(WidgetReader.read(at: url, now: after) == .expired(widget), "after payload midnight is expired")
            if let midnight = WidgetReader.midnightAfter(before, in: shanghai) {
                check(WidgetReader.todayString(now: midnight, timeZone: shanghai) == "2026-09-09", "midnight edge advances payload day")
                check(midnight > before && midnight <= after.addingTimeInterval(3600), "midnight edge is the coming boundary")
            } else {
                check(false, "midnight edge computes")
            }
        }

        // MARK: - 7. Empty / true-free / partial / all-unpriced
        do {
            let now = at(2026, 9, 8, 12, 0, shanghai)
            func roundTrip(_ s: WidgetSnapshot) -> WidgetReadResult {
                let url = write(s)
                defer { try? FileManager.default.removeItem(at: url) }
                return WidgetReader.read(at: url, now: now)
            }
            // Empty: legitimate zero, not unknown.
            let empty = WidgetSnapshot(
                date: "2026-09-08", timezone: "Asia/Shanghai",
                updatedAt: SnapshotTime.parseRFC3339("2026-09-08T00:01:00Z")!,
                totals: .zero, totalCost: .legitimateZero, clients: [],
                preferences: WidgetPreferences(showCost: true))
            check(roundTrip(empty) == .current(empty), "empty reads current")
            check(WidgetReader.primaryText(for: empty) == "$0.00", "empty cost primary is zero, not unavailable")
            // True free: priced at explicit 0 stays fully priced.
            let freeTotals = TokenCounts(input: 5, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0)
            let free = WidgetSnapshot(
                date: "2026-09-08", timezone: "Asia/Shanghai",
                updatedAt: empty.updatedAt, totals: freeTotals,
                totalCost: EstimatedCost(amountUsd: 0, complete: true, unpricedTokens: 0),
                clients: [WidgetClientSummary(clientId: "codex", totalTokens: 5, amountUsd: 0, complete: true)],
                preferences: WidgetPreferences(showCost: true))
            check(roundTrip(free) == .current(free), "free reads current")
            check(WidgetReader.primaryText(for: free) == "$0.00", "known free is $0.00, distinct from unknown")
            // Partial: known sum plus unpriced volume.
            let partialTotals = TokenCounts(input: 17, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0)
            let partial = WidgetSnapshot(
                date: "2026-09-08", timezone: "Asia/Shanghai",
                updatedAt: empty.updatedAt, totals: partialTotals,
                totalCost: EstimatedCost(amountUsd: 0.5, complete: false, unpricedTokens: 7),
                clients: [
                    WidgetClientSummary(clientId: "claude", totalTokens: 10, amountUsd: 0.5, complete: true),
                    WidgetClientSummary(clientId: "codex", totalTokens: 7, amountUsd: nil, complete: false),
                ],
                preferences: WidgetPreferences(showCost: true))
            check(roundTrip(partial) == .current(partial), "partial reads current")
            check(WidgetReader.primaryText(for: partial) == "$0.50 *", "partial keeps known sum with marker")
            // All-unpriced: unavailable, never free.
            let unpricedTotals = TokenCounts(input: 7, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0)
            let unknown = WidgetSnapshot(
                date: "2026-09-08", timezone: "Asia/Shanghai",
                updatedAt: empty.updatedAt, totals: unpricedTotals,
                totalCost: EstimatedCost(amountUsd: nil, complete: false, unpricedTokens: 7),
                clients: [WidgetClientSummary(clientId: "opencode", totalTokens: 7, amountUsd: nil, complete: false)],
                preferences: WidgetPreferences(showCost: true))
            check(roundTrip(unknown) == .current(unknown), "all-unpriced reads current")
            check(WidgetReader.primaryText(for: unknown) == "—", "unknown cost is unavailable, not free")
            let unknownTokens = WidgetSnapshot(
                date: unknown.date, timezone: unknown.timezone, updatedAt: unknown.updatedAt,
                totals: unknown.totals, totalCost: unknown.totalCost,
                clients: unknown.clients, preferences: WidgetPreferences(showCost: false))
            check(WidgetReader.primaryText(for: unknownTokens) == "7", "tokens primary still shows volume when price unknown")
        }

        // MARK: - 8. Medium client ordering + deep link + file name
        do {
            let snap = try ScanSnapshot.decodeValidated(from: sampleData)
            let base = WidgetSnapshotBuilder.make(from: snap, today: "2026-09-08", preferences: WidgetPreferences(showCost: false))
            var multi = base
            multi.clients = [
                WidgetClientSummary(clientId: "codex", totalTokens: 100, amountUsd: 0.1, complete: true),
                WidgetClientSummary(clientId: "claude", totalTokens: 300, amountUsd: 0.3, complete: true),
                WidgetClientSummary(clientId: "opencode", totalTokens: 200, amountUsd: nil, complete: false),
            ]
            let top = WidgetReader.topClients(for: multi)
            check(top.map { $0.clientId } == ["claude", "opencode", "codex"], "medium orders clients by volume")
            check(WidgetReader.deepLink == "tokensmacos://today", "tap opens today overview")
            check(WidgetReader.fileName == "widget-snapshot.json", "group file name matches publication contract")
            check(WidgetReader.groupID == "team.tokensmacos.app", "group matches publication contract")
            let container = FileManager.default.temporaryDirectory
            check(WidgetReader.fileURL(in: container).lastPathComponent == "widget-snapshot.json", "file URL helper appends snapshot name")
        } catch {
            check(false, "medium ordering: \(error)")
        }

        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("snapshot.json")
            try Data("{}".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
                try? FileManager.default.removeItem(at: dir)
            }
            if (try? Data(contentsOf: file)) == nil {
                if case .invalid = WidgetReader.read(at: file, now: Date()) {
                    check(true, "denied parent directory is invalid, not missing")
                } else { check(false, "denied parent directory misclassified") }
            }
        } catch { check(false, "permission fixture: \(error)") }

        print("PASS \(passes) checks, FAIL \(failures)")
        if failures > 0 { exit(1) }
    }
}

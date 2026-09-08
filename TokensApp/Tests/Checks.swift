import Foundation

/// Synthetic deterministic scheduling checks for P3.
///
/// Compiled Foundation-only with `TokensApp/ScanScheduler.swift` via
/// `bash scripts/check-app.sh`. No real processes, no real HOME, no
/// network, no Shared import. All dates are caller-explicit.
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

    static func range(_ since: String, _ until: String, _ hourly: String) -> ScanRangeRequest {
        ScanRangeRequest(since: since, until: until, hourlyDate: hourly)
    }

    static func main() {
        let shanghai = tz("Asia/Shanghai")

        // 1. Coalescing: unique running scan, one pending, quit cancels.
        do {
            let c = ScanCoalescer()
            check(c.requestScan() == .start, "idle request starts")
            check(c.isRunning && !c.hasPending, "running without pending")
            check(c.requestScan() == .queued, "concurrent request queues")
            check(c.requestScan() == .queued, "repeat concurrent still queues")
            check(c.hasPending, "single pending recorded")
            check(c.finishScan() == true, "finish starts pending")
            check(c.isRunning && !c.hasPending, "pending now running")
            check(c.finishScan() == false, "no further pending stays idle")
            check(!c.isRunning, "idle after drain")
            // Quit cancellation drops pending.
            _ = c.requestScan()
            _ = c.requestScan()
            c.cancelAll()
            check(!c.isRunning && !c.hasPending, "quit cancels running+pending")
            check(c.finishScan() == false, "finish after cancel stays idle")
        }

        // 2. Stale-result protection across source-selection changes.
        do {
            let c = ScanCoalescer()
            _ = c.requestScan()
            let tag = c.generation
            check(!c.isStale(tag: tag), "current tag fresh")
            c.noteSourcesChanged()
            check(c.isStale(tag: tag), "old tag stale after selection change")
            check(!c.isStale(tag: c.generation), "new tag fresh")
        }

        // 3. Cadence: interval due, wake single catch-up, day change once.
        do {
            let now = at(2026, 9, 8, 14, 0, shanghai)
            check(ScanScheduler.isDue(last: nil, interval: 600, now: now), "never scanned is due")
            check(!ScanScheduler.isDue(last: now, interval: 600, now: now), "just scanned not due")
            let nineAgo = now.addingTimeInterval(-9 * 60)
            check(!ScanScheduler.isDue(last: nineAgo, interval: 600, now: now), "9min not due on 10min cadence")
            let elevenAgo = now.addingTimeInterval(-11 * 60)
            check(ScanScheduler.isDue(last: elevenAgo, interval: 600, now: now), "11min due on 10min cadence")
            // Wake: elapsed interval -> exactly one scan decision (boolean, never a replay count).
            check(ScanScheduler.shouldScanOnWake(lastSuccess: elevenAgo, now: now, interval: 600), "wake after gap scans once")
            check(!ScanScheduler.shouldScanOnWake(lastSuccess: nineAgo, now: now, interval: 600), "wake within interval skips")
            // Three days of missed cycles still yield a single boolean, not a replay list.
            let threeDaysAgo = now.addingTimeInterval(-3 * 86400)
            check(ScanScheduler.shouldScanOnWake(lastSuccess: threeDaysAgo, now: now, interval: 600), "long gap still single catch-up")
            // Day change.
            check(ScanScheduler.shouldScanOnDayChange(lastCoveredDate: nil, today: "2026-09-08"), "no coverage scans")
            check(ScanScheduler.shouldScanOnDayChange(lastCoveredDate: "2026-09-07", today: "2026-09-08"), "cross-day scans once")
            check(!ScanScheduler.shouldScanOnDayChange(lastCoveredDate: "2026-09-08", today: "2026-09-08"), "same day skips")
            // 5-minute option respected.
            check(!ScanScheduler.isDue(last: nineAgo, interval: 300, now: now) == false, "5min cadence due after 9min")
            check(ScanScheduler.defaultInterval == 600 && ScanScheduler.fastInterval == 300, "10min default, 5min option")
        }

        // 4. Price refresh: daily, independent, at most once per day.
        do {
            let morning = at(2026, 9, 8, 9, 0, shanghai)
            let evening = at(2026, 9, 8, 21, 0, shanghai)
            let nextMorning = at(2026, 9, 9, 9, 0, shanghai)
            check(ScanScheduler.isPriceRefreshDue(lastRefresh: nil, now: morning, timeZone: shanghai), "never refreshed due")
            check(!ScanScheduler.isPriceRefreshDue(lastRefresh: morning, now: evening, timeZone: shanghai), "same day not due again")
            check(ScanScheduler.isPriceRefreshDue(lastRefresh: morning, now: nextMorning, timeZone: shanghai), "next day due")
            check(!ScanScheduler.isPriceRefreshDue(lastRefresh: evening, now: morning, timeZone: shanghai), "future last refresh not due")
        }

        // 5. Scan window: earlier of month-start and trailing-7 head.
        do {
            let now = at(2026, 9, 8, 12, 0, shanghai)
            let r = ScanScheduler.scanRange(now: now, timeZone: shanghai)
            check(r.until == "2026-09-08" && r.hourlyDate == "2026-09-08", "until/hourly are today")
            check(r.since == "2026-09-01", "september since is month start (earlier than trailing head 09-02)")
            let early = at(2026, 3, 3, 12, 0, shanghai)
            let re = ScanScheduler.scanRange(now: early, timeZone: shanghai)
            check(re.since == "2026-02-25", "early-month since crosses into prior month")
            check(re.until == "2026-03-03" && re.hourlyDate == "2026-03-03", "early-month until/hourly today")
            let t7 = ScanScheduler.trailing7Days(now: early, timeZone: shanghai)
            check(t7 == ["2026-02-25", "2026-02-26", "2026-02-27", "2026-02-28", "2026-03-01", "2026-03-02", "2026-03-03"], "trailing 7 crosses month")
        }

        // 6. Explicit argv: arrays only, absolute paths, no empty-clients-as-all.
        do {
            let args = try! ScanScheduler.buildScanArguments(
                home: "/Users/test", configDir: "/Users/test/.config/tokens",
                timeZoneID: "Asia/Shanghai",
                range: range("2026-09-01", "2026-09-08", "2026-09-08"),
                clients: ["codex", "claude"]
            )
            check(args == ["scan", "--home", "/Users/test", "--config-dir", "/Users/test/.config/tokens",
                           "--timezone", "Asia/Shanghai", "--since", "2026-09-01",
                           "--until", "2026-09-08", "--hourly-date", "2026-09-08",
                           "--clients", "claude,codex"], "explicit scan argv sorted, no shell")
            check(!args.joined(separator: " ").contains(";") && !args.contains("&&"), "no shell metachars")
            // Nil clients = full registry (flag omitted); empty = throw, never "all".
            let full = try! ScanScheduler.buildScanArguments(
                home: "/h", configDir: "/c", timeZoneID: "Asia/Shanghai",
                range: range("2026-09-08", "2026-09-08", "2026-09-08"), clients: nil)
            check(!full.contains("--clients"), "nil selection omits flag (full registry)")
            expectThrow("empty clients") {
                _ = try ScanScheduler.buildScanArguments(
                    home: "/h", configDir: "/c", timeZoneID: "Asia/Shanghai",
                    range: range("2026-09-08", "2026-09-08", "2026-09-08"), clients: [])
            }
            expectThrow("relative home") {
                _ = try ScanScheduler.buildScanArguments(
                    home: "relative/path", configDir: "/c", timeZoneID: "Asia/Shanghai",
                    range: range("2026-09-08", "2026-09-08", "2026-09-08"), clients: nil)
            }
            expectThrow("relative config") {
                _ = try ScanScheduler.buildScanArguments(
                    home: "/h", configDir: "rel", timeZoneID: "Asia/Shanghai",
                    range: range("2026-09-08", "2026-09-08", "2026-09-08"), clients: nil)
            }
            expectThrow("unknown timezone") {
                _ = try ScanScheduler.buildScanArguments(
                    home: "/h", configDir: "/c", timeZoneID: "Not/AZone",
                    range: range("2026-09-08", "2026-09-08", "2026-09-08"), clients: nil)
            }
            expectThrow("since after until") {
                _ = try ScanScheduler.buildScanArguments(
                    home: "/h", configDir: "/c", timeZoneID: "Asia/Shanghai",
                    range: range("2026-09-09", "2026-09-08", "2026-09-08"), clients: nil)
            }
            expectThrow("hourly outside range") {
                _ = try ScanScheduler.buildScanArguments(
                    home: "/h", configDir: "/c", timeZoneID: "Asia/Shanghai",
                    range: range("2026-09-01", "2026-09-08", "2026-09-20"), clients: nil)
            }
            expectThrow("unknown client") {
                _ = try ScanScheduler.buildScanArguments(
                    home: "/h", configDir: "/c", timeZoneID: "Asia/Shanghai",
                    range: range("2026-09-08", "2026-09-08", "2026-09-08"), clients: ["notaclient"])
            }
            // Dedup + case fold.
            let dedup = try! ScanScheduler.buildScanArguments(
                home: "/h", configDir: "/c", timeZoneID: "Asia/Shanghai",
                range: range("2026-09-08", "2026-09-08", "2026-09-08"), clients: ["Codex", "codex", " Claude "])
            check(dedup.last == "claude,codex", "clients deduped, trimmed, sorted")
            // Prices argv.
            let pargs = try! ScanScheduler.buildPricesArguments(configDir: "/c")
            check(pargs == ["prices", "refresh", "--config-dir", "/c"], "explicit prices argv")
            expectThrow("prices relative config") {
                _ = try ScanScheduler.buildPricesArguments(configDir: "rel")
            }
        }

        // 7. Composed trigger: one decision per event, never two requests.
        do {
            let now = at(2026, 9, 8, 14, 0, shanghai)
            let fresh = now.addingTimeInterval(-60)
            check(!ScanScheduler.shouldTrigger(
                lastSuccess: fresh, lastCoveredDate: "2026-09-08",
                today: "2026-09-08", interval: 600, now: now), "fresh + covered stays quiet")
            check(ScanScheduler.shouldTrigger(
                lastSuccess: now.addingTimeInterval(-11 * 60), lastCoveredDate: "2026-09-08",
                today: "2026-09-08", interval: 600, now: now), "due triggers")
            check(ScanScheduler.shouldTrigger(
                lastSuccess: fresh, lastCoveredDate: "2026-09-07",
                today: "2026-09-08", interval: 600, now: now), "day change triggers")
            check(ScanScheduler.shouldTrigger(
                lastSuccess: nil, lastCoveredDate: nil,
                today: "2026-09-08", interval: 600, now: now), "first run triggers once")
        }

        // 8. Display gate: snapshot belongs to its request config.
        do {
            check(ScanScheduler.isDisplayValid(
                snapshotClients: ["codex", "claude"], snapshotTimeZone: "Asia/Shanghai",
                enabledClients: ["codex", "claude"], timeZoneID: "Asia/Shanghai"), "matching config valid")
            check(!ScanScheduler.isDisplayValid(
                snapshotClients: ["codex", "claude"], snapshotTimeZone: "Asia/Shanghai",
                enabledClients: ["codex"], timeZoneID: "Asia/Shanghai"), "narrowed selection invalidates old snapshot")
            check(!ScanScheduler.isDisplayValid(
                snapshotClients: ["codex"], snapshotTimeZone: "Asia/Shanghai",
                enabledClients: ["codex", "opencode"], timeZoneID: "Asia/Shanghai"), "widened selection invalidates old snapshot")
            check(!ScanScheduler.isDisplayValid(
                snapshotClients: ["codex"], snapshotTimeZone: "Asia/Shanghai",
                enabledClients: ["codex"], timeZoneID: "UTC"), "timezone change invalidates old snapshot")
            check(ScanScheduler.isDisplayValid(
                snapshotClients: [], snapshotTimeZone: "Asia/Shanghai",
                enabledClients: [], timeZoneID: "Asia/Shanghai"), "empty matches empty without defaults")
        }

        // 9. Price attempt cap: failures do not retry every scan.
        do {
            let morning = at(2026, 9, 8, 9, 0, shanghai)
            let evening = at(2026, 9, 8, 21, 0, shanghai)
            let nextMorning = at(2026, 9, 9, 9, 0, shanghai)
            check(ScanScheduler.isPriceAttemptDue(lastAttempt: nil, now: morning, timeZone: shanghai), "never attempted due")
            check(!ScanScheduler.isPriceAttemptDue(lastAttempt: morning, now: evening, timeZone: shanghai), "failed attempt not retried same day")
            check(ScanScheduler.isPriceAttemptDue(lastAttempt: morning, now: nextMorning, timeZone: shanghai), "attempt due next day")
            check(!ScanScheduler.isPriceAttemptDue(lastAttempt: evening, now: morning, timeZone: shanghai), "future attempt not due")
        }

        // 10. Response must match the captured request before acceptance.
        do {
            check(ScanScheduler.isResponseMatching(
                requestClients: ["codex", "claude"], requestTimeZone: "Asia/Shanghai",
                responseSources: ["claude", "codex"], responseTimeZone: "Asia/Shanghai"), "matching response accepted")
            check(!ScanScheduler.isResponseMatching(
                requestClients: ["codex"], requestTimeZone: "Asia/Shanghai",
                responseSources: ["codex", "claude"], responseTimeZone: "Asia/Shanghai"), "extra source rejected")
            check(!ScanScheduler.isResponseMatching(
                requestClients: ["codex", "claude"], requestTimeZone: "Asia/Shanghai",
                responseSources: ["codex"], responseTimeZone: "Asia/Shanghai"), "missing source rejected")
            check(!ScanScheduler.isResponseMatching(
                requestClients: ["codex"], requestTimeZone: "Asia/Shanghai",
                responseSources: ["codex"], responseTimeZone: "UTC"), "timezone drift rejected")
        }

        print("PASS \(passes) checks, FAIL \(failures)")
        if failures > 0 { exit(1) }
    }
}

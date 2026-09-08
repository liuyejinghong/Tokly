import Foundation

/// Pure, injected scheduling + argument-building logic for the Tokens app.
///
/// Foundation-only: no SwiftUI/AppKit, no Shared import, no real Process,
/// no UserDefaults, no implicit clock. Every time-dependent helper takes an
/// explicit `now` / `timeZone` so the synthetic checks are deterministic.
/// The real runner (`CollectorRunner`) owns Process lifetime and calls into
/// these pure helpers; `Tests/Checks.swift` covers them without spawning
/// anything.
public enum ScanSchedulerError: Error, Equatable {
    case emptyHome
    case relativeHome
    case emptyConfigDir
    case relativeConfigDir
    case unknownTimezone(String)
    case malformedDate(String)
    case invalidRange(String, String)
    case hourlyDateOutsideRange(String)
    case emptyClientSelection
    case unknownClient(String)
}

public struct ScanRangeRequest: Equatable {
    public var since: String
    public var until: String
    public var hourlyDate: String

    public init(since: String, until: String, hourlyDate: String) {
        self.since = since
        self.until = until
        self.hourlyDate = hourlyDate
    }
}

public enum ScanCoalesceDecision: Equatable {
    /// No scan running: caller should start immediately.
    case start
    /// A scan is running: recorded as the single pending request.
    case queued
}

/// Merges concurrent scan requests: at most one running scan and at most
/// one pending request. `generation` guards source-selection changes: the
/// runner tags each started scan and drops completions whose generation no
/// longer matches (stale-result protection).
public final class ScanCoalescer {
    private(set) var isRunning: Bool = false
    private(set) var hasPending: Bool = false
    private(set) var generation: UInt64 = 0

    public init() {}

    @discardableResult
    public func requestScan() -> ScanCoalesceDecision {
        if isRunning {
            hasPending = true
            return .queued
        }
        isRunning = true
        hasPending = false
        return .start
    }

    /// Marks the running scan finished. Returns true when the single
    /// pending request must start now (caller re-tags with current
    /// generation); false when idle.
    @discardableResult
    public func finishScan() -> Bool {
        isRunning = false
        if hasPending {
            hasPending = false
            isRunning = true
            return true
        }
        return false
    }

    /// Explicit quit: drops the running flag and the pending request.
    /// In-flight Process termination itself is owned by the runner.
    public func cancelAll() {
        isRunning = false
        hasPending = false
    }

    /// Source selection changed: bump the generation so completions tagged
    /// with the old generation are discarded instead of overwriting the
    /// new selection's data. Does not start work by itself.
    public func noteSourcesChanged() {
        generation &+= 1
    }

    public func isStale(tag: UInt64) -> Bool {
        tag != generation
    }
}

public enum ScanScheduler {
    public static let defaultInterval: TimeInterval = 600
    public static let fastInterval: TimeInterval = 300
    public static let priceRefreshInterval: TimeInterval = 86400

    // MARK: - Calendar helpers (caller-explicit now/timeZone)

    public static func ymdString(from date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public static func isValidYMD(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count == 10, u[4] == 45, u[7] == 45 else { return false }
        for (i, c) in u.enumerated() {
            if i == 4 || i == 7 { continue }
            guard c >= 48 && c <= 57 else { return false }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        guard let d = f.date(from: s) else { return false }
        return f.string(from: d) == s
    }

    public static func monthStart(containing ymd: String) -> String {
        String(ymd.prefix(8)) + "01"
    }

    public static func requestSince(monthStart: String, trailingFirst: String) -> String {
        min(monthStart, trailingFirst)
    }

    public static func trailing7Days(now: Date, timeZone: TimeZone) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let startOfToday = cal.startOfDay(for: now)
        return (-6...0).compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: offset, to: startOfToday) else { return nil }
            return ymdString(from: d, timeZone: timeZone)
        }
    }

    /// Protocol scan window: until = today, hourlyDate = today,
    /// since = earlier of month-start and trailing-7 head.
    public static func scanRange(now: Date, timeZone: TimeZone) -> ScanRangeRequest {
        let today = ymdString(from: now, timeZone: timeZone)
        let trailing = trailing7Days(now: now, timeZone: timeZone)
        let since = requestSince(monthStart: monthStart(containing: today), trailingFirst: trailing.first ?? today)
        return ScanRangeRequest(since: since, until: today, hourlyDate: today)
    }

    // MARK: - Cadence decisions (at most one catch-up scan)

    public static func nextDueDate(last: Date?, interval: TimeInterval, now: Date) -> Date {
        guard let last else { return now }
        return last.addingTimeInterval(interval)
    }

    public static func isDue(last: Date?, interval: TimeInterval, now: Date) -> Bool {
        nextDueDate(last: last, interval: interval, now: now) <= now
    }

    /// Wake catch-up: a single scan when the interval elapsed while
    /// asleep. Never replays every missed cycle — one decision only.
    public static func shouldScanOnWake(lastSuccess: Date?, now: Date, interval: TimeInterval) -> Bool {
        isDue(last: lastSuccess, interval: interval, now: now)
    }

    /// Cross-day catch-up: exactly one scan when the covered date changed.
    public static func shouldScanOnDayChange(lastCoveredDate: String?, today: String) -> Bool {
        guard let lastCoveredDate else { return true }
        return lastCoveredDate != today
    }

    /// Single composed trigger decision: due by cadence OR uncovered day.
    /// Callers must evaluate this once per wake/appear/timer event so one
    /// trigger yields at most one scan request (never due + day-change as
    /// two separate requests).
    public static func shouldTrigger(
        lastSuccess: Date?,
        lastCoveredDate: String?,
        today: String,
        interval: TimeInterval,
        now: Date
    ) -> Bool {
        isDue(last: lastSuccess, interval: interval, now: now)
            || shouldScanOnDayChange(lastCoveredDate: lastCoveredDate, today: today)
    }

    /// Display/config gate: a persisted snapshot belongs to the request
    /// config that produced it. It must not be shown, filtered, or shared
    /// under a different enabled set or timezone; the artifact stays on
    /// disk but the projection is invalid until a fresh result arrives.
    public static func isDisplayValid(
        snapshotClients: Set<String>,
        snapshotTimeZone: String,
        enabledClients: Set<String>,
        timeZoneID: String
    ) -> Bool {
        snapshotClients == enabledClients && snapshotTimeZone == timeZoneID
    }

    /// Response check: the returned snapshot must carry exactly the
    /// requested client selection and timezone before it is accepted.
    /// Sources arrive as the collector's explicit per-client list.
    public static func isResponseMatching(
        requestClients: Set<String>,
        requestTimeZone: String,
        responseSources: [String],
        responseTimeZone: String
    ) -> Bool {
        Set(responseSources) == requestClients && responseTimeZone == requestTimeZone
    }

    /// Independent daily price refresh gate. Nil = never refreshed (due).
    /// Otherwise due when the calendar day differs in `timeZone` or a full
    /// 24h elapsed (covers DST edge cases). At most once per day.
    public static func isPriceRefreshDue(lastRefresh: Date?, now: Date, timeZone: TimeZone) -> Bool {
        guard let lastRefresh else { return true }
        if now < lastRefresh { return false }
        let lastDay = ymdString(from: lastRefresh, timeZone: timeZone)
        let today = ymdString(from: now, timeZone: timeZone)
        if lastDay != today { return true }
        return now.timeIntervalSince(lastRefresh) >= priceRefreshInterval
    }

    /// Daily price-attempt cap: gated on the last attempt (success or
    /// failure), so a failed refresh does not retry on every scan. The
    /// token display never waits on this gate.
    public static func isPriceAttemptDue(lastAttempt: Date?, now: Date, timeZone: TimeZone) -> Bool {
        guard let lastAttempt else { return true }
        if now < lastAttempt { return false }
        return ymdString(from: lastAttempt, timeZone: timeZone) != ymdString(from: now, timeZone: timeZone)
    }

    // MARK: - Explicit argv builders (no shell)

    public static func validateClients(_ clients: [String]?) throws -> [String]? {
        guard let clients else { return nil }
        if clients.isEmpty { throw ScanSchedulerError.emptyClientSelection }
        var out: [String] = []
        for raw in clients {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if name.isEmpty { continue }
            guard SourceIDs.isKnown(name) else { throw ScanSchedulerError.unknownClient(raw) }
            if !out.contains(name) { out.append(name) }
        }
        if out.isEmpty { throw ScanSchedulerError.emptyClientSelection }
        return out.sorted()
    }

    /// Explicit scan argv (without the executable): never a shell string.
    /// Empty selection throws: the caller must skip scanning when the user
    /// enabled no sources instead of passing an empty list (which would
    /// mean "all" to the helper).
    public static func buildScanArguments(
        home: String,
        configDir: String,
        timeZoneID: String,
        range: ScanRangeRequest,
        clients: [String]?
    ) throws -> [String] {
        guard !home.isEmpty else { throw ScanSchedulerError.emptyHome }
        guard home.hasPrefix("/") else { throw ScanSchedulerError.relativeHome }
        guard !configDir.isEmpty else { throw ScanSchedulerError.emptyConfigDir }
        guard configDir.hasPrefix("/") else { throw ScanSchedulerError.relativeConfigDir }
        guard TimeZone(identifier: timeZoneID) != nil else { throw ScanSchedulerError.unknownTimezone(timeZoneID) }
        guard isValidYMD(range.since) else { throw ScanSchedulerError.malformedDate(range.since) }
        guard isValidYMD(range.until) else { throw ScanSchedulerError.malformedDate(range.until) }
        guard isValidYMD(range.hourlyDate) else { throw ScanSchedulerError.malformedDate(range.hourlyDate) }
        guard range.since <= range.until else { throw ScanSchedulerError.invalidRange(range.since, range.until) }
        guard range.since <= range.hourlyDate && range.hourlyDate <= range.until else {
            throw ScanSchedulerError.hourlyDateOutsideRange(range.hourlyDate)
        }
        var args = [
            "scan",
            "--home", home,
            "--config-dir", configDir,
            "--timezone", timeZoneID,
            "--since", range.since,
            "--until", range.until,
            "--hourly-date", range.hourlyDate,
        ]
        if let selected = try validateClients(clients) {
            args.append("--clients")
            args.append(selected.joined(separator: ","))
        }
        return args
    }

    /// Explicit prices-refresh argv (without the executable).
    public static func buildPricesArguments(configDir: String) throws -> [String] {
        guard !configDir.isEmpty else { throw ScanSchedulerError.emptyConfigDir }
        guard configDir.hasPrefix("/") else { throw ScanSchedulerError.relativeConfigDir }
        return ["prices", "refresh", "--config-dir", configDir]
    }
}

/// Registry mirror used only for argv validation (display names live in
/// `SourceRegistry`). Kept in sync with the upstream ClientId set plus the
/// collector-accepted `synthetic` / `9router` aliases.
public enum SourceIDs {
    public static let all: [String] = [
        "opencode", "claude", "codex", "cursor", "gemini", "amp", "droid",
        "openclaw", "pi", "kimi", "qwen", "roocode", "kilocode", "mux",
        "kilo", "crush", "hermes", "copilot", "goose", "codebuff",
        "antigravity", "zed", "kiro", "trae", "warp", "cline", "gjc",
        "grok", "jcode", "commandcode", "micode", "antigravity-cli",
        "junie", "zcode", "opencodereview", "codebuddy", "workbuddy",
        "devin-cli", "devin-desktop", "reasonix", "freebuff", "fx",
        "synthetic", "9router",
    ]

    public static func isKnown(_ id: String) -> Bool {
        all.contains(id.lowercased())
    }
}

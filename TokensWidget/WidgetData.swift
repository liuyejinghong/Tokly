import Foundation

/// Foundation-only Widget read + display helpers (P4).
///
/// The extension never launches processes, never touches the network, and
/// never scans logs. It only reads the trimmed `widget-snapshot.json` the
/// main app atomically publishes to the shared App Group. All entrypoints
/// take an explicit file URL and an explicit `now` so synthetic tests are
/// deterministic and production never depends on implicit system time.
///
/// Timezone rule: cross-day judgement and midnight expiry always use the
/// payload `timezone` (the statistics timezone inherited from the scan),
/// never the extension host's system timezone. `updatedAt` is the original
/// scan timestamp and is the only update time ever displayed.
public enum WidgetReadResult: Equatable {
    case missing
    case invalid(reason: String)
    case current(WidgetSnapshot)
    case expired(WidgetSnapshot)

    public var snapshot: WidgetSnapshot? {
        switch self {
        case .current(let s), .expired(let s):
            return s
        case .missing, .invalid:
            return nil
        }
    }

    public var isPlaceholder: Bool {
        switch self {
        case .missing, .invalid:
            return true
        case .current, .expired:
            return false
        }
    }
}

public enum WidgetReader {
    public static let fileName = "widget-snapshot.json"
    public static let groupID = "team.tokensmacos.app"
    public static let groupDefaultsKey = "TokensAppGroupIdentifier"
    public static var deepLink: String { (Bundle.main.object(forInfoDictionaryKey: "ToklyURLScheme") as? String ?? "tokensmacos") + "://today" }

    /// `widget-snapshot.json` inside a resolved group container.
    public static func fileURL(in container: URL) -> URL {
        container.appendingPathComponent(fileName)
    }

    /// Caller-explicit calendar-day string (YYYY-MM-DD) in `timeZone`.
    public static func todayString(now: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }

    /// Next local midnight after `now` in `timeZone` (timeline expiry edge).
    public static func midnightAfter(_ now: Date, in timeZone: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: now)
        return cal.date(byAdding: .day, value: 1, to: start)
    }

    /// Pure read: nil URL or absent file -> `.missing` (placeholder, never a
    /// stale fallback). Unreadable/corrupt/failed-validation -> `.invalid`.
    /// Otherwise `.current` when payload date == today in the payload
    /// timezone, else `.expired` (original date/values retained).
    public static func read(at fileURL: URL?, now: Date) -> WidgetReadResult {
        guard let fileURL else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError {
                return .missing
            }
            if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
               u.domain == NSPOSIXErrorDomain, u.code == Int(ENOENT) {
                return .missing
            }
            // A missing POSIX path can also surface directly.
            if (ns.domain as String) == NSPOSIXErrorDomain, ns.code == Int(ENOENT) {
                return .missing
            }
            return .invalid(reason: "unreadable: \(error.localizedDescription)")
        }
        let snapshot: WidgetSnapshot
        do {
            snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        } catch {
            return .invalid(reason: "decoding failed: \(error.localizedDescription)")
        }
        if let reason = validationError(for: snapshot) {
            return .invalid(reason: reason)
        }
        guard let payloadZone = TimeZone(identifier: snapshot.timezone) else {
            return .invalid(reason: "unknown timezone: \(snapshot.timezone)")
        }
        let today = todayString(now: now, timeZone: payloadZone)
        if snapshot.date == today {
            return .current(snapshot)
        }
        return .expired(snapshot)
    }

    /// Strict payload validation: date / timezone / non-negative finite
    /// tokens and amounts / cost invariants. Returns nil when valid, else a
    /// short reason. Corrupt payloads never render as pseudo-zero.
    public static func validationError(for snapshot: WidgetSnapshot) -> String? {
        guard SnapshotDate.isValid(snapshot.date) else {
            return "malformed date: \(snapshot.date)"
        }
        guard TimeZone(identifier: snapshot.timezone) != nil else {
            return "malformed timezone: \(snapshot.timezone)"
        }
        let t = snapshot.totals
        if t.input < 0 || t.output < 0 || t.cacheRead < 0 || t.cacheWrite < 0 || t.reasoning < 0 {
            return "negative tokens"
        }
        if let reason = costError(tokensTotal: t.total, amountUsd: snapshot.totalCost.amountUsd, complete: snapshot.totalCost.complete, context: "totals") {
            return reason
        }
        if snapshot.totalCost.unpricedTokens < 0 {
            return "negative unpricedTokens"
        }
        // Totals cost/token envelope consistency (same rule as protocol).
        do {
            try SnapshotValidation.checkCost(tokens: t, cost: snapshot.totalCost, context: "totals")
        } catch {
            return "inconsistent totals cost: \(error.localizedDescription)"
        }
        for client in snapshot.clients {
            if client.clientId.isEmpty {
                return "empty clientId"
            }
            if client.totalTokens < 0 {
                return "negative tokens: client \(client.clientId)"
            }
            if let reason = costError(tokensTotal: client.totalTokens, amountUsd: client.amountUsd, complete: client.complete, context: "client \(client.clientId)") {
                return reason
            }
        }
        return nil
    }

    private static func costError(tokensTotal: Int64, amountUsd: Double?, complete: Bool, context: String) -> String? {
        if let a = amountUsd {
            guard a.isFinite && a >= 0 else {
                return "invalid cost (\(context)): amount must be finite and non-negative"
            }
        }
        if tokensTotal == 0 {
            // No volume: exactly legitimate zero, never a carried subtotal.
            guard amountUsd == 0, complete else {
                return "inconsistent cost (\(context)): zero volume must be 0/true"
            }
            return nil
        }
        if complete, amountUsd == nil {
            return "inconsistent cost (\(context)): complete cost requires a known amount"
        }
        return nil
    }

    // MARK: - Display text (mirrors TokensApp/Format + WidgetsView rules)

    public static func compact(_ value: Int64) -> String {
        TokenFormat.compact(value)
    }

    public static func money(_ v: Double) -> String {
        "$" + String(format: "%.2f", v)
    }

    /// Cost text for a totals/client pair. Unknown (all-unpriced) stays
    /// unavailable and is never rendered as free.
    public static func costText(tokensTotal: Int64, amountUsd: Double?, complete: Bool) -> String {
        if tokensTotal == 0 { return "$0.00" }
        if let a = amountUsd {
            if complete { return money(a) }
            return money(a) + " *"
        }
        return "暂无单价"
    }

    public static func costFootnote(tokensTotal: Int64, amountUsd: Double?, complete: Bool, unpricedTokens: Int64) -> String {
        if tokensTotal == 0 { return "暂无用量" }
        if amountUsd != nil {
            if complete { return "按模型单价估算 · USD" }
            return "部分 Token 暂无单价（\(compact(unpricedTokens)) 未定价）"
        }
        return "\(compact(unpricedTokens)) Token 暂无可用单价"
    }

    /// Primary metric follows the existing app setting: `showCost == true`
    /// shows cost first, otherwise tokens first. Unknown cost renders as
    /// "—" (unavailable), never as free.
    public static func primaryText(for snapshot: WidgetSnapshot) -> String {
        if snapshot.preferences.showCost {
            if snapshot.totals.total > 0, snapshot.totalCost.amountUsd == nil {
                return "—"
            }
            return costText(
                tokensTotal: snapshot.totals.total,
                amountUsd: snapshot.totalCost.amountUsd,
                complete: snapshot.totalCost.complete)
        }
        return compact(snapshot.totals.total)
    }

    public static func secondaryText(for snapshot: WidgetSnapshot) -> String {
        if snapshot.preferences.showCost {
            return "\(compact(snapshot.totals.total)) Token"
        }
        if snapshot.totals.total > 0, snapshot.totalCost.amountUsd == nil {
            return "\(compact(snapshot.totalCost.unpricedTokens)) Token 暂无可用单价"
        }
        if snapshot.totalCost.complete {
            if snapshot.totals.total == 0 { return "暂无用量" }
            return costText(
                tokensTotal: snapshot.totals.total,
                amountUsd: snapshot.totalCost.amountUsd,
                complete: snapshot.totalCost.complete) + " 估算费用"
        }
        return (snapshot.totalCost.amountUsd.map { money($0) + " *" } ?? "暂无单价") + " 估算费用"
    }

    public static func clientPrimaryText(_ client: WidgetClientSummary, showCost: Bool) -> String {
        if showCost {
            if client.totalTokens > 0, client.amountUsd == nil { return "—" }
            return costText(tokensTotal: client.totalTokens, amountUsd: client.amountUsd, complete: client.complete)
        }
        return compact(client.totalTokens)
    }

    /// Medium family shows up to three clients by descending token volume.
    public static func topClients(for snapshot: WidgetSnapshot, limit: Int = 3) -> [WidgetClientSummary] {
        Array(snapshot.clients.sorted { $0.totalTokens > $1.totalTokens }.prefix(limit))
    }

    public static func updatedText(_ date: Date?) -> String {
        guard let date else { return "尚未更新" }
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    public static func dayLabel(_ ymd: String) -> String {
        let parts = ymd.split(separator: "-")
        guard parts.count == 3,
              let m = Int(parts[1]), let d = Int(parts[2]) else { return ymd }
        return "\(m)/\(d)"
    }

    /// Expired entries keep their original date label; never rewritten as today.
    public static func expiredLabel(date: String) -> String {
        "\(dayLabel(date))的数据 · 今日暂无覆盖"
    }
}

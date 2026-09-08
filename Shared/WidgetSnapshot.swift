import Foundation

/// Minimal Widget snapshot: current-day totals, per-client summaries, update
/// metadata, and display preferences only. No history, no source paths, no
/// session or credential material.
///
/// An expired snapshot (e.g. yesterday's, when new data has not arrived)
/// keeps its original date and reports expired via `isExpired(today:)`; the
/// old values are never rewritten as today's.

public struct WidgetClientSummary: Codable, Equatable {
    public var clientId: String
    public var totalTokens: Int64
    public var amountUsd: Double?
    public var complete: Bool

    public init(clientId: String, totalTokens: Int64, amountUsd: Double?, complete: Bool) {
        self.clientId = clientId
        self.totalTokens = totalTokens
        self.amountUsd = amountUsd
        self.complete = complete
    }
}

public struct WidgetPreferences: Codable, Equatable {
    public var showCost: Bool
    /// Nil means all enabled sources.
    public var visibleClientIds: [String]?

    public init(showCost: Bool, visibleClientIds: [String]? = nil) {
        self.showCost = showCost
        self.visibleClientIds = visibleClientIds
    }
}

public struct WidgetSnapshot: Codable, Equatable {
    /// The calendar day these values belong to (YYYY-MM-DD).
    public var date: String
    public var timezone: String
    public var updatedAt: Date
    public var totals: TokenCounts
    public var totalCost: EstimatedCost
    public var clients: [WidgetClientSummary]
    public var preferences: WidgetPreferences

    public init(
        date: String,
        timezone: String,
        updatedAt: Date,
        totals: TokenCounts,
        totalCost: EstimatedCost,
        clients: [WidgetClientSummary],
        preferences: WidgetPreferences
    ) {
        self.date = date
        self.timezone = timezone
        self.updatedAt = updatedAt
        self.totals = totals
        self.totalCost = totalCost
        self.clients = clients
        self.preferences = preferences
    }

    public func isExpired(today: String) -> Bool {
        date != today
    }
}

public enum WidgetSnapshotBuilder {
    /// Builds the Widget snapshot for `today` from every enabled source
    /// (main-window client filters never apply here). When the scan does not
    /// cover today, the snapshot retains the nearest covered date and reads
    /// expired until fresh data arrives. `updatedAt` stays at the scan's
    /// `generatedAt` so stale data is never stamped fresh.
    public static func make(
        from snapshot: ScanSnapshot,
        today: String,
        preferences: WidgetPreferences
    ) -> WidgetSnapshot {
        let effectiveDate: String
        if snapshot.range.since <= today && today <= snapshot.range.until {
            effectiveDate = today
        } else if today < snapshot.range.since {
            effectiveDate = snapshot.range.since
        } else {
            effectiveDate = snapshot.range.until
        }
        let bucket = snapshot.daily.first(where: { $0.date == effectiveDate })
        let usage = bucket.map { Aggregation.aggregateDay($0) } ?? .zero
        let clients = (bucket?.clients ?? [])
            .sorted(by: { $0.clientId < $1.clientId })
            .map { client -> WidgetClientSummary in
                let rollup = Aggregation.aggregateClient(client)
                return WidgetClientSummary(
                    clientId: client.clientId,
                    totalTokens: rollup.tokens.total,
                    amountUsd: rollup.cost.amountUsd,
                    complete: rollup.cost.complete
                )
            }
        return WidgetSnapshot(
            date: effectiveDate,
            timezone: snapshot.timezone,
            updatedAt: snapshot.generatedAt,
            totals: usage.tokens,
            totalCost: usage.cost,
            clients: clients,
            preferences: preferences
        )
    }
}

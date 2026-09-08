import Foundation

public struct RangeModelEntry {
    public var modelId: String
    public var usage: AggregatedUsage
}

public struct RangeClientEntry {
    public var clientId: String
    public var total: AggregatedUsage
    public var models: [RangeModelEntry]
}

public enum RangeProjection {
    public static func filteredSnapshot(
        _ snapshot: ScanSnapshot,
        enabled: Set<String>,
        filter: Set<String>?
    ) -> ScanSnapshot {
        func keep(_ id: String) -> Bool {
            enabled.contains(id) && (filter == nil || filter!.contains(id))
        }
        let daily = snapshot.daily.map { day in
            DayBucket(date: day.date, clients: day.clients.filter { keep($0.clientId) })
        }
        let hourly = snapshot.hourly.map { hour in
            HourBucket(hour: hour.hour, clients: hour.clients.filter { keep($0.clientId) })
        }
        return ScanSnapshot(
            schemaVersion: snapshot.schemaVersion,
            generatedAt: snapshot.generatedAt,
            timezone: snapshot.timezone,
            range: snapshot.range,
            hourlyDate: snapshot.hourlyDate,
            pricingAsOf: snapshot.pricingAsOf,
            daily: daily, hourly: hourly,
            sources: snapshot.sources, warnings: snapshot.warnings)
    }

    public static func clients(
        snapshot: ScanSnapshot,
        days: Set<String>,
        enabled: Set<String>,
        filter: Set<String>?
    ) -> [RangeClientEntry] {
        var acc: [String: [String: [(TokenCounts, EstimatedCost)]]] = [:]
        for day in snapshot.daily where days.contains(day.date) {
            for client in day.clients where enabled.contains(client.clientId) {
                if let filter, !filter.contains(client.clientId) { continue }
                for model in client.models {
                    acc[client.clientId, default: [:]][model.modelId, default: []]
                        .append((model.tokens, model.estimatedCost))
                }
            }
        }
        return acc.keys.sorted().map { cid in
            let models = (acc[cid] ?? [:]).keys.sorted().map { mid in
                RangeModelEntry(modelId: mid, usage: Aggregation.aggregate(acc[cid]![mid]!))
            }
            let total = Aggregation.aggregate(models.map { ($0.usage.tokens, $0.usage.cost) })
            return RangeClientEntry(clientId: cid, total: total, models: models)
        }
    }

    public static func rangeTotal(
        snapshot: ScanSnapshot,
        days: [String],
        today: String,
        enabled: Set<String>,
        filter: Set<String>?
    ) -> AggregatedUsage? {
        for day in days where day <= today {
            guard day >= snapshot.range.since && day <= snapshot.range.until else {
                return nil
            }
        }
        let wanted = Set(days)
        let entries = clients(snapshot: snapshot, days: wanted, enabled: enabled, filter: filter)
            .flatMap { $0.models.map { ($0.usage.tokens, $0.usage.cost) } }
        guard !entries.isEmpty else { return .zero }
        return Aggregation.aggregate(entries)
    }
}

public enum MenuGrouping: String, CaseIterable {
    case model, client
}

public struct MenuUsageRow: Identifiable {
    public var id: String
    public var name: String
    public var clientId: String?
    public var tokens: Int64
}

extension RangeProjection {
    public static func menuRows(snapshot: ScanSnapshot, days: [String], enabled: Set<String>, grouping: MenuGrouping) -> [MenuUsageRow] {
        let groups = clients(snapshot: snapshot, days: Set(days), enabled: enabled, filter: nil)
        let rows: [MenuUsageRow] = groups.flatMap { client in
            if grouping == .client {
                return [MenuUsageRow(id: client.clientId, name: client.clientId, clientId: nil, tokens: client.total.tokens.total)]
            }
            return client.models.map { model in
                MenuUsageRow(id: client.clientId + "\0" + model.modelId, name: model.modelId, clientId: client.clientId, tokens: model.usage.tokens.total)
            }
        }
        return rows.filter { $0.tokens > 0 }.sorted {
            $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens
        }
    }
}

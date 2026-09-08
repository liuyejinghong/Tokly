import SwiftUI

struct ErrorBanner: View {
    var message: String
    var snapshotLabel: String?
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(message).lineLimit(2)
            if let s = snapshotLabel {
                Text(s).foregroundStyle(.secondary)
            }
            Spacer()
            Button("重试", action: onRetry)
        }
        .font(.callout)
        .padding(10)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MetricCards: View {
    var usage: AggregatedUsage?
    var rangeLabel: String

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(rangeLabel) Token").font(.caption).foregroundStyle(.secondary)
                Text(usage.map { Format.compact($0.tokens.total) } ?? "—")
                    .font(.system(size: 34, weight: .medium, design: .default))
                Text("含输入、输出、缓存与推理").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("估算费用").font(.caption).foregroundStyle(.secondary)
                Text(usage.map { Format.costText(tokensTotal: $0.tokens.total, cost: $0.cost) } ?? "—")
                    .font(.system(size: 34, weight: .medium, design: .default))
                Text(usage.map { Format.costFootnote(tokensTotal: $0.tokens.total, cost: $0.cost) } ?? "按模型单价估算 · USD")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct ClientRow: View {
    var clientId: String
    var tokens: Int64
    var shareOfClient: Double? // 0..1 within client (for child rows)
    var total: Int64
    var expanded: Bool
    var childCount: Int
    var onToggle: () -> Void
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(SourceRegistry.displayName(for: clientId)).font(.headline)
                    Spacer()
                    Text(Format.compact(tokens)).monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            Text("\(childCount) 个模型").font(.caption2).foregroundStyle(.secondary)
            GeometryReader { geo in
                Rectangle().fill(Color.accentColor.opacity(0.55))
                    .frame(width: total > 0 ? geo.size.width * CGFloat(min(1, Double(tokens) / Double(total))) : 0, height: 3)
            }
            .frame(height: 3)
            .padding(.top, 4)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct ModelDetailSheet: View {
    @EnvironmentObject var state: AppState
    var clientId: String
    var modelId: String
    var range: RangeKind
    var onDone: () -> Void

    private var detail: (tokens: TokenCounts, cost: EstimatedCost)? {
        guard let snap = state.filteredSnapshot() else { return nil }
        let days: Set<String>
        switch range {
        case .today: days = [state.todayString]
        case .week: days = Set(Aggregation.trailing7Days(now: Date(), timeZone: state.timeZone))
        case .month:
            let today = state.todayString
            days = Set(Aggregation.datesBetween(
                since: Aggregation.monthStartString(containing: today), until: today))
        }
        let entries = snap.daily.filter { days.contains($0.date) }
            .flatMap { $0.clients }.filter { $0.clientId == clientId }
            .flatMap { $0.models }.filter { $0.modelId == modelId }
            .map { ($0.tokens, $0.estimatedCost) }
        guard !entries.isEmpty else { return nil }
        let agg = Aggregation.aggregate(entries)
        return (agg.tokens, agg.cost)
    }

    private var rangeLabel: String {
        switch range {
        case .today: return "今日"
        case .week: return "近7天"
        case .month: return "本月"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(modelId).font(.headline)
                    Text("\(SourceRegistry.displayName(for: clientId)) · \(rangeLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onDone) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            if let detail {
                let tokens = detail.tokens
                let cost = detail.cost
                Text("Token 总量").font(.caption).foregroundStyle(.secondary)
                Text(Format.compact(tokens.total)).font(.system(size: 30, weight: .medium)).monospacedDigit()
                ForEach([("输入", tokens.input), ("输出", tokens.output), ("缓存读取", tokens.cacheRead), ("缓存写入", tokens.cacheWrite), ("推理", tokens.reasoning)], id: \.0) { row in
                    HStack { Text(row.0).foregroundStyle(.secondary); Spacer(); Text(Format.compact(row.1)).monospacedDigit() }
                        .font(.callout)
                    Divider()
                }
                HStack {
                    Text("估算费用")
                    Spacer()
                    Text(Format.costText(tokensTotal: tokens.total, cost: cost))
                        .foregroundStyle(cost.amountUsd == nil && tokens.total > 0 ? .orange : .primary)
                }
                .font(.callout)
                Text(Format.costFootnote(tokensTotal: tokens.total, cost: cost))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("所选范围内暂无该模型数据").foregroundStyle(.secondary).font(.callout)
            }
            HStack { Spacer(); Button("完成", action: onDone).keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 380)
    }
}

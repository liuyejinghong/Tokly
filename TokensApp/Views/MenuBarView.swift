import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var menuRange: RangeKind = .today

    private var days: [String] {
        switch menuRange {
        case .today: return [state.todayString]
        case .week: return Aggregation.trailing7Days(now: Date(), timeZone: state.timeZone)
        case .month:
            return Aggregation.datesBetween(since: Aggregation.monthStartString(containing: state.todayString), until: state.todayString)
        }
    }

    private var usage: AggregatedUsage? {
        guard state.displayValid, let snapshot = state.snapshot else { return nil }
        return RangeProjection.rangeTotal(snapshot: snapshot, days: days, today: state.todayString,
                                          enabled: state.enabledClients, filter: nil)
    }

    private var rows: [MenuUsageRow] {
        guard usage != nil, let snapshot = state.snapshot else { return [] }
        return RangeProjection.menuRows(snapshot: snapshot, days: days, enabled: state.enabledClients,
                                        grouping: state.menuGrouping)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(menuRange.label)用量").font(.headline)
                Spacer()
                Text(dateLabel).font(.caption).foregroundStyle(.secondary)
            }
            Picker("统计范围", selection: $menuRange) {
                ForEach(RangeKind.allCases, id: \.self) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)
            if let usage {
                Text(Format.compact(usage.tokens.total))
                    .font(.system(size: 34, weight: .medium)).monospacedDigit()
                Text(costLine(usage)).font(.callout).foregroundStyle(.secondary)
                Divider()
                if !rows.isEmpty {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(rows) { row in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.clientId == nil ? SourceRegistry.displayName(for: row.name) : row.name)
                                            .lineLimit(1).help(row.name)
                                        if let client = row.clientId {
                                            Text(SourceRegistry.displayName(for: client))
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Text(Format.compact(row.tokens)).monospacedDigit().fixedSize()
                                }
                                .font(.callout)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(rows.count) * (state.menuGrouping == .model ? 43 : 28), 240))
                } else {
                    Text("此范围暂无用量").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("暂无此范围的完整统计").foregroundStyle(.secondary)
            }
            if let error = state.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Divider()
            HStack {
                Button("打开统计窗口") {
                    state.openToday()
                    state.range = menuRange
                    openWindow(id: "tokens-main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button(state.isScanning ? "更新中" : "刷新") { state.requestScan(userInitiated: true) }
                    .disabled(state.isScanning)
            }
            Text("\(Format.updatedText(state.lastSuccessAt)) 更新").font(.caption2).foregroundStyle(.secondary)
            Divider()
            Button("退出 Tokly") { NSApp.terminate(nil) }
                .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
    }

    private var dateLabel: String {
        guard let first = days.first, let last = days.last else { return "" }
        return first == last ? Format.dayLabel(first) : "\(Format.dayLabel(first))–\(Format.dayLabel(last))"
    }

    private func costLine(_ usage: AggregatedUsage) -> String {
        if usage.tokens.total > 0, usage.cost.amountUsd == nil { return "暂无可用单价" }
        return "\(Format.costText(tokensTotal: usage.tokens.total, cost: usage.cost)) 估算费用 · USD"
    }
}

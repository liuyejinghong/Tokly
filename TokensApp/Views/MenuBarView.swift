import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("今日用量").font(.headline)
                Spacer()
                Text(Format.dayLabel(state.todayString)).font(.caption).foregroundStyle(.secondary)
            }
            if let u = state.todayUnfiltered() {
                Text(Format.compact(u.tokens.total)).font(.system(size: 34, weight: .medium)).monospacedDigit()
                Text(costLine(u)).font(.callout).foregroundStyle(.secondary)
                Divider()
                ForEach(clientRows(), id: \.0) { (id, t) in
                    HStack {
                        Text(SourceRegistry.displayName(for: id))
                        Spacer()
                        Text(Format.compact(t)).monospacedDigit()
                    }
                    .font(.callout)
                }
            } else {
                Text("暂无今日统计").foregroundStyle(.secondary)
                if let err = state.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            Divider()
            HStack {
                Button("打开统计窗口") {
                    state.openToday()
                    openWindow(id: "tokens-main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button(state.isScanning ? "更新中" : "刷新") { state.requestScan(userInitiated: true) }
                    .disabled(state.isScanning)
            }
            Text("\(Format.updatedText(state.lastSuccessAt)) 更新").font(.caption2).foregroundStyle(.secondary)
            Divider()
            Button("退出 Tokens") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func costLine(_ u: AggregatedUsage) -> String {
        if u.tokens.total > 0, u.cost.amountUsd == nil { return "暂无可用单价" }
        return "\(Format.costText(tokensTotal: u.tokens.total, cost: u.cost)) 估算费用 · USD"
    }

    private func clientRows() -> [(String, Int64)] {
        guard state.displayValid, let snap = state.snapshot,
              let bucket = snap.daily.first(where: { $0.date == state.todayString }) else { return [] }
        return bucket.clients
            .map { ($0.clientId, Aggregation.aggregateClient($0).tokens.total) }
            .sorted { $0.1 > $1.1 }
    }
}

import SwiftUI

struct WidgetsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("桌面小组件").font(.title2.weight(.medium))
                Text("不打开窗口，也能看到今日用量").font(.callout).foregroundStyle(.secondary)
                previewRow
                HStack {
                    VStack(alignment: .leading) {
                        Text("突出显示").font(.headline)
                        Text("两种尺寸使用相同的主指标").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("主指标", selection: Binding(
                        get: { state.widgetShowCost ? "cost" : "tokens" },
                        set: { state.widgetShowCost = ($0 == "cost") })) {
                        Text("Token").tag("tokens")
                        Text("估算费用").tag("cost")
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 200)
                }
                settingRow(icon: "rectangle.on.rectangle", title: "添加到桌面", sub: "右键桌面 → 编辑小组件 → 搜索 Tokens")
                settingRow(icon: "clock", title: "更新时间", sub: "小组件由 macOS 安排刷新，以卡片上的更新时间为准。")
                if let expired = state.expiredLabel {
                    Text("\(expired)：新数据到达前保留原日期显示。").font(.caption).foregroundStyle(.orange)
                }
                Text("原生小组件扩展在 P4 提供；此处先提供配置与添加指引，数据已按正式快照格式准备。")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Text("更新于 \(Format.updatedText(state.lastSuccessAt))")
                    Spacer()
                    Text("统计保存在本机").foregroundStyle(.secondary)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .navigationTitle("小组件")
    }

    private var previewRow: some View {
        let usage = state.todayUnfiltered()
        return HStack(alignment: .top, spacing: 18) {
            widgetCard(usage: usage, medium: false)
            widgetCard(usage: usage, medium: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor)))
    }

    private func widgetCard(usage: AggregatedUsage?, medium: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tokly").font(.caption.weight(.medium))
                Spacer()
                Text("今日").font(.caption2).foregroundStyle(.secondary)
            }
            if let u = usage {
                Text(mainText(u)).font(.system(size: medium ? 24 : 28, weight: .medium)).monospacedDigit()
                Text(subText(u)).font(.caption2).foregroundStyle(.secondary)
                if medium {
                    Divider()
                    ForEach(topClients(), id: \.0) { (id, t) in
                        HStack {
                            Text(SourceRegistry.displayName(for: id)).font(.caption2)
                            Spacer()
                            Text(Format.compact(t)).font(.caption2).monospacedDigit()
                        }
                    }
                }
            } else {
                Text("暂无数据").font(.headline)
                Text("等待首次采集").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Format.updatedText(state.lastSuccessAt)) 更新").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: medium ? 300 : 160, height: 164)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 21))
        .overlay(RoundedRectangle(cornerRadius: 21).stroke(Color(nsColor: .separatorColor)))
    }

    private func mainText(_ u: AggregatedUsage) -> String {
        if state.widgetShowCost {
            if u.tokens.total > 0, u.cost.amountUsd == nil { return "—" }
            return Format.costText(tokensTotal: u.tokens.total, cost: u.cost)
        }
        return Format.compact(u.tokens.total)
    }

    private func subText(_ u: AggregatedUsage) -> String {
        if state.widgetShowCost { return "\(Format.compact(u.tokens.total)) Token" }
        return Format.costFootnote(tokensTotal: u.tokens.total, cost: u.cost)
    }

    private func topClients() -> [(String, Int64)] {
        guard let snap = state.filteredSnapshot(),
              let bucket = snap.daily.first(where: { $0.date == state.todayString }) else { return [] }
        return bucket.clients
            .map { ($0.clientId, Aggregation.aggregateClient($0).tokens.total) }
            .sorted { $0.1 > $1.1 }.prefix(3).map { $0 }
    }

    private func settingRow(icon: String, title: String, sub: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(title).font(.callout)
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: icon).foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            Divider()
        }
    }
}

import SwiftUI

struct ModelsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("客户端与模型").font(.title2.weight(.medium))
                        Text(rangeDetail).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("客户端", selection: Binding(
                        get: { state.clientFilter ?? "all" },
                        set: { state.clientFilter = ($0 == "all" ? nil : $0) })) {
                        Text("全部客户端").tag("all")
                        ForEach(state.enabledClients.sorted(), id: \.self) { id in
                            Text(SourceRegistry.displayName(for: id)).tag(id)
                        }
                    }
                    .frame(maxWidth: 160)
                    Picker("范围", selection: $state.range) {
                        Text("今日").tag(RangeKind.today)
                        Text("近7天").tag(RangeKind.week)
                        Text("本月").tag(RangeKind.month)
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 260)
                }
                if let err = state.lastError {
                    ErrorBanner(message: err, snapshotLabel: nil, onRetry: { state.retry() })
                }
                Text("\(rows.flatMap { $0.models }.count) 个模型 · \(Format.compact(grandTotal?.tokens.total ?? 0)) Token")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Text("Token").font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                    Text("估算费用").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                    Text("占所选总量").font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                }
                ForEach(rows, id: \.clientId) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(SourceRegistry.displayName(for: group.clientId)).font(.headline)
                            Text("\(group.models.count) 个模型").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.compact(group.total.tokens.total)).monospacedDigit()
                            Text(costCell(group.total)).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                            Text(share(group.total)).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                        }
                        .padding(8)
                        .background(Color(nsColor: .windowBackgroundColor))
                        ForEach(group.models, id: \.modelId) { child in
                            Button {
                                state.selectedModel = .init(id: group.clientId + "\0" + child.modelId, clientId: group.clientId, modelId: child.modelId, range: state.range)
                            } label: {
                                HStack {
                                    Text(child.modelId).lineLimit(1)
                                    Spacer()
                                    Text(Format.compact(child.usage.tokens.total)).monospacedDigit()
                                    Text(costCell(child.usage)).font(.caption).foregroundStyle(costColor(child.usage)).frame(width: 90, alignment: .trailing)
                                    Text(share(child.usage)).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                }
                Text("客户端为父级，模型为子级；子项合计等于客户端总量。")
                    .font(.caption2).foregroundStyle(.secondary)
                footer
            }
            .padding(24)
        }
        .navigationTitle("模型")
    }

    private var rangeDetail: String {
        let days = state.rangeDays()
        guard let first = days.first, let last = days.last else { return "" }
        if first == last { return Format.dayLabel(first) }
        return "\(Format.dayLabel(first)) — \(Format.dayLabel(last))"
    }

    private var rows: [RangeClientEntry] {
        state.rangeClients()
    }

    private var grandTotal: AggregatedUsage? {
        state.rangeTotal()
    }

    private func share(_ u: AggregatedUsage) -> String {
        guard let t = grandTotal?.tokens.total, t > 0 else { return "—" }
        return String(format: "%.1f%%", 100 * Double(u.tokens.total) / Double(t))
    }

    private func costCell(_ u: AggregatedUsage) -> String {
        if u.tokens.total > 0, u.cost.amountUsd == nil { return "暂无单价" }
        return Format.costText(tokensTotal: u.tokens.total, cost: u.cost)
    }

    private func costColor(_ u: AggregatedUsage) -> Color {
        (u.tokens.total > 0 && u.cost.amountUsd == nil) ? .orange : .secondary
    }

    private var footer: some View {
        HStack {
            Text("更新于 \(Format.updatedText(state.lastSuccessAt))")
            Spacer()
            Text("统计保存在本机").foregroundStyle(.secondary)
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

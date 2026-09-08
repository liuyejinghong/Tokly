import SwiftUI
import Charts

struct OverviewView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let error = state.directoryAccessError { Text(error).font(.caption).foregroundStyle(.orange) }
                if let err = state.lastError {
                    ErrorBanner(message: err, snapshotLabel: state.lastSuccessAt.map { "上次成功 " + Format.updatedText($0) }, onRetry: { state.retry() })
                }
                if let stale = state.configStaleNotice {
                    ErrorBanner(message: stale, snapshotLabel: nil, onRetry: { state.requestScan(userInitiated: true) })
                }
                if let storeErr = state.storageError {
                    Text(storeErr).font(.caption).foregroundStyle(.orange)
                }
                if state.rangeTotal() == nil {
                    emptyState
                } else {
                    MetricCards(usage: state.rangeTotal(), rangeLabel: state.range.label)
                    if let expired = state.expiredLabel {
                        Text(expired).font(.caption).foregroundStyle(.orange)
                    }
                    trendCard
                    HStack(alignment: .top, spacing: 24) {
                        clientsCard
                        breakdownCard
                    }
                }
                footer
            }
            .padding(24)
        }
        .navigationTitle("用量总览")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("用量总览").font(.title2.weight(.medium))
                Text(rangeDetail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("客户端", selection: Binding(
                get: { state.clientFilter ?? "all" },
                set: { state.clientFilter = ($0 == "all" ? nil : $0) })) {
                Text("全部客户端").tag("all")
                ForEach(enabledClientOptions, id: \.self) { id in
                    Text(SourceRegistry.displayName(for: id)).tag(id)
                }
            }
            .frame(maxWidth: 160)
            Picker("范围", selection: $state.range) {
                Text("今日").tag(RangeKind.today)
                Text("近7天").tag(RangeKind.week)
                Text("本月").tag(RangeKind.month)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            Button(state.isScanning ? "更新中" : "刷新") { state.requestScan(userInitiated: true) }
                .disabled(state.isScanning)
        }
    }

    private var rangeDetail: String {
        let days = state.rangeDays()
        guard let first = days.first, let last = days.last else { return "" }
        if first == last { return Format.dayLabel(first) }
        return "\(Format.dayLabel(first)) — \(Format.dayLabel(last))"
    }

    private var enabledClientOptions: [String] {
        state.enabledClients.sorted()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.column").font(.largeTitle).foregroundStyle(.secondary)
            Text(state.enabledClients.isEmpty ? "尚未启用数据来源" : "还没有用量记录").font(.headline)
            Text(state.enabledClients.isEmpty ? "选择要统计的本机客户端。" : "使用已连接的 AI 工具后，用量会显示在这里。")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Trend (always the filtered projection)

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("用量趋势").font(.headline)
                Spacer()
                if state.range == .month {
                    Picker("月视图", selection: $state.monthView) {
                        Text("日趋势").tag(MonthView.line)
                        Text("周汇总").tag(MonthView.weeks)
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 200)
                }
                Picker("指标", selection: $state.trendMetric) {
                    Text("Token").tag(MenuMetric.tokens)
                    Text("费用").tag(MenuMetric.cost)
                }
                .pickerStyle(.segmented).frame(maxWidth: 160)
            }
            switch state.range {
            case .today: todayChart
            case .week: weekChart
            case .month:
                if state.monthView == .line { monthLineChart } else { monthWeeksChart }
            }
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
    }

    private func value(_ u: AggregatedUsage) -> Double? {
        if state.trendMetric == .tokens { return Double(u.tokens.total) }
        return u.cost.amountUsd
    }

    private var todayChart: some View {
        let pts = Aggregation.hourlySeries(
            snapshot: state.filteredSnapshot(), date: state.todayString,
            now: Date(), timeZone: state.timeZone)
        let rows = pts.compactMap { p -> (Int, Double)? in
            guard let u = p.usage, let v = value(u) else { return nil }
            return (p.hour, v)
        }
        return VStack(alignment: .leading) {
            if rows.isEmpty {
                Text("今日暂无按小时数据").foregroundStyle(.secondary).font(.callout)
            } else {
                Chart(rows, id: \.0) { (h, v) in
                    BarMark(x: .value("小时", h), y: .value("用量", v))
                }
                .frame(height: 180)
                .chartXAxis { AxisMarks(values: [0, 4, 8, 12, 16, 20, 23]) }
            }
            Text("按小时 · 今日").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var weekChart: some View {
        let days = state.rangeDays()
        let vals: [(String, Double?)] = days.map { d in
            (d, dayTotal(d).flatMap { value($0) })
        }
        let rows = vals.enumerated().compactMap { (i, v) -> (Int, String, Double)? in
            guard let amount = v.1 else { return nil }
            return (i, v.0, amount)
        }
        return VStack(alignment: .leading) {
            if rows.isEmpty {
                Text("所选范围暂无数据").foregroundStyle(.secondary).font(.callout)
            } else {
                Chart(rows, id: \.0) { (i, d, v) in
                    BarMark(x: .value("日期", Format.dayLabel(d)), y: .value("用量", v))
                }
                .frame(height: 180)
            }
            Text("按日 · 近7天").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var monthLineChart: some View {
        let today = state.todayString
        let start = Aggregation.monthStartString(containing: today)
        let series = Aggregation.dailySeries(
            snapshot: state.filteredSnapshot(), since: start, until: today, today: today)
        let rows = series.enumerated().compactMap { (i, p) -> (Int, String, Double)? in
            guard let u = p.usage, let v = value(u) else { return nil }
            return (i, p.date, v)
        }
        let sel = state.selectedDayIndex >= 0 && state.selectedDayIndex < series.count ? state.selectedDayIndex : (series.count - 1)
        return VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Text("本月暂无数据").foregroundStyle(.secondary).font(.callout)
            } else {
                Chart(rows, id: \.0) { (i, d, v) in
                    AreaMark(x: .value("日期", i), y: .value("用量", v))
                        .foregroundStyle(Color.accentColor.opacity(0.2))
                    LineMark(x: .value("日期", i), y: .value("用量", v))
                }
                .frame(height: 200)
                .chartXAxis {
                    AxisMarks(values: [0, max(0, rows.count / 3), max(0, 2 * rows.count / 3), max(0, rows.count - 1)]) { v in
                        if let i = v.as(Int.self), i >= 0, i < rows.count {
                            AxisValueLabel(Format.dayLabel(rows[i].1))
                        }
                    }
                }
                if series.indices.contains(sel), let u = series[sel].usage {
                    Text("\(Format.dayLabel(series[sel].date)) · \(state.trendMetric == .tokens ? Format.compact(u.tokens.total) + " Token" : Format.costText(tokensTotal: u.tokens.total, cost: u.cost))")
                        .font(.callout)
                }
                Slider(value: Binding(get: { Double(max(0, sel)) }, set: { state.selectedDayIndex = Int($0) }), in: 0...Double(max(0, series.count - 1)), step: 1) {
                    Text("查看日期")
                }
                .disabled(series.isEmpty)
                Text("自然月 · 每日用量，非累计 · 截至\(Format.dayLabel(today))").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var monthWeeksChart: some View {
        let today = state.todayString
        let comps = Calendar(identifier: .gregorian).dateComponents(in: state.timeZone, from: Date())
        let segs = Aggregation.weekSegments(year: comps.year ?? 2026, month: comps.month ?? 9, timeZone: state.timeZone)
        let points = Aggregation.weeklyTotals(snapshot: state.filteredSnapshot(), segments: segs, today: today)
        let rows = points.enumerated().compactMap { (i, p) -> (Int, String, Double)? in
            guard let u = p.usage, let v = value(u) else { return nil }
            return (i, "周\(i + 1)", v)
        }
        return VStack(alignment: .leading) {
            if rows.isEmpty {
                Text("所选范围暂无数据").foregroundStyle(.secondary).font(.callout)
            } else {
                Chart(rows, id: \.0) { (i, label, v) in
                    BarMark(x: .value("周", label), y: .value("用量", v))
                }
                .frame(height: 180)
            }
            if let cur = points.enumerated().first(where: { $0.element.cutoff == today }) {
                Text("本周进行中 · 截至\(Format.dayLabel(cur.element.cutoff ?? today))").font(.caption2).foregroundStyle(.secondary)
            }
            Text("自然周汇总，月初/月末截于本月；未开始的周不记为零。").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func dayTotal(_ date: String) -> AggregatedUsage? {
        guard let snap = state.filteredSnapshot() else { return nil }
        guard date >= snap.range.since && date <= snap.range.until else { return nil }
        guard let bucket = snap.daily.first(where: { $0.date == date }) else {
            return date <= state.todayString ? .zero : nil
        }
        return Aggregation.aggregateDay(bucket)
    }

    // MARK: - Clients (whole selected range) + breakdown

    private var clientsCard: some View {
        let entries = state.rangeClients()
        let total = state.rangeTotal()
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("客户端用量").font(.headline)
                Spacer()
            }
            ForEach(entries, id: \.clientId) { entry in
                let open = state.expandedClients.contains(entry.clientId)
                ClientRow(clientId: entry.clientId, tokens: entry.total.tokens.total, shareOfClient: nil, total: max(1, total?.tokens.total ?? 1), expanded: open, childCount: entry.models.count, onToggle: {
                    if open { state.expandedClients.remove(entry.clientId) } else { state.expandedClients.insert(entry.clientId) }
                }, onOpen: {})
                if open {
                    ForEach(entry.models.sorted(by: { $0.modelId < $1.modelId }), id: \.modelId) { m in
                        Button {
                            state.selectedModel = .init(id: entry.clientId + "\0" + m.modelId, clientId: entry.clientId, modelId: m.modelId, range: state.range)
                        } label: {
                            HStack {
                                Text(m.modelId).lineLimit(1).font(.callout)
                                Spacer()
                                Text(Format.compact(m.usage.tokens.total)).monospacedDigit().font(.callout)
                                Text(clientShare(m.usage, in: entry.total)).font(.caption2).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 20)
                        .padding(.vertical, 3)
                    }
                }
                Divider()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
    }

    private func clientShare(_ m: AggregatedUsage, in client: AggregatedUsage) -> String {
        guard client.tokens.total > 0 else { return "—" }
        return String(format: "%.0f%%", 100 * Double(m.tokens.total) / Double(client.tokens.total))
    }

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Token 构成").font(.headline)
            if let rows = state.categoryBreakdown() {
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Text(row.0).foregroundStyle(.secondary)
                        Spacer()
                        Text(Format.compact(row.1)).monospacedDigit()
                    }
                    .font(.callout)
                    Divider()
                }
            } else {
                Text("暂无数据").foregroundStyle(.secondary).font(.callout)
            }
        }
        .frame(minWidth: 200)
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("更新于 \(Format.updatedText(state.lastSuccessAt)) · 每\(Int(state.interval / 60))分钟采集")
                Spacer()
                Text("统计保存在本机").foregroundStyle(.secondary)
            }
            if let price = state.priceStatus {
                Text(price).foregroundStyle(.orange)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

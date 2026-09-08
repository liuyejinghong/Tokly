import SwiftUI
import WidgetKit

/// Native small/medium views (P4).
///
/// - Semantic system colors only; appearance follows the system.
/// - `containerBackground(for: .widget)` on every family.
/// - `showCost == true` renders cost as the primary metric, otherwise
///   tokens; consistent with the existing `widgetShowCost` app setting.
/// - Missing/invalid snapshots render placeholder visuals only (no demo
///   usage). Expired snapshots retain their original date and values with
///   an explicit stale label; yesterday is never relabelled as today.
/// - All displayed update times use the payload `updatedAt` (original scan
///   time), never the timeline refresh time.
/// - Tapping opens the today overview via `tokensmacos://today`; it resets
///   to the today range and never inherits month/client filters.
struct TokensWidgetEntryView: View {
    var entry: TokensSnapshotEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            switch entry.result {
            case .missing, .invalid:
                placeholderView
            case .current(let snapshot):
                if family == .systemMedium {
                    mediumView(snapshot: snapshot, expired: false)
                } else {
                    smallView(snapshot: snapshot, expired: false)
                }
            case .expired(let snapshot):
                if family == .systemMedium {
                    mediumView(snapshot: snapshot, expired: true)
                } else {
                    smallView(snapshot: snapshot, expired: true)
                }
            }
        }
        .widgetURL(URL(string: WidgetReader.deepLink))
        .containerBackground(for: .widget) {}
    }

    // MARK: - Small: today primary metric + one summary + update time

    private func smallView(snapshot: WidgetSnapshot, expired: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tokly")
                    .font(.caption.weight(.medium))
                Spacer()
                Text(expired ? WidgetReader.dayLabel(snapshot.date) : "今日")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(expired ? "\(WidgetReader.dayLabel(snapshot.date))数据" : "Tokly 今日")
            Text(WidgetReader.primaryText(for: snapshot))
                .font(.system(size: 28, weight: .medium))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .accessibilityLabel(primaryAccessibility(snapshot: snapshot))
            Text(WidgetReader.secondaryText(for: snapshot))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if expired {
                Text(WidgetReader.expiredLabel(date: snapshot.date))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            Text("\(WidgetReader.updatedText(snapshot.updatedAt)) 更新")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel("更新于 \(WidgetReader.updatedText(snapshot.updatedAt))")
        }
    }

    // MARK: - Medium: small content + client summaries

    private func mediumView(snapshot: WidgetSnapshot, expired: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Tokly")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text(expired ? WidgetReader.dayLabel(snapshot.date) : "今日")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(WidgetReader.primaryText(for: snapshot))
                    .font(.system(size: 24, weight: .medium))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .accessibilityLabel(primaryAccessibility(snapshot: snapshot))
                Text(WidgetReader.secondaryText(for: snapshot))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if expired {
                    Text(WidgetReader.expiredLabel(date: snapshot.date))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                Text("\(WidgetReader.updatedText(snapshot.updatedAt)) 更新")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(WidgetReader.topClients(for: snapshot), id: \.clientId) { client in
                    HStack {
                        Text(displayName(for: client.clientId))
                            .font(.caption2)
                            .lineLimit(1)
                        Spacer()
                        Text(WidgetReader.clientPrimaryText(client, showCost: snapshot.preferences.showCost))
                            .font(.caption2)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(displayName(for: client.clientId)) \(WidgetReader.clientPrimaryText(client, showCost: snapshot.preferences.showCost))")
                }
                if WidgetReader.topClients(for: snapshot).isEmpty {
                    Text("暂无客户端")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 18)
        }
    }

    // MARK: - Placeholder: visuals only, never demo usage

    private var placeholderView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tokly")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("今日")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("暂无数据")
                .font(.headline)
                .accessibilityLabel("暂无数据")
            Text("等待首次采集")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("尚未更新")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("小组件暂无数据，等待首次采集")
    }

    private func primaryAccessibility(snapshot: WidgetSnapshot) -> String {
        if snapshot.preferences.showCost {
            return "估算费用 \(WidgetReader.primaryText(for: snapshot))"
        }
        return "Token \(WidgetReader.primaryText(for: snapshot))"
    }

    private func displayName(for clientId: String) -> String {
        switch clientId {
        case "codex": return "Codex"
        case "claude": return "Claude Code"
        case "opencode": return "OpenCode"
        default: return clientId
        }
    }
}

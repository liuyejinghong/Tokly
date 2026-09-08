import SwiftUI
import WidgetKit

struct PrepEntry: TimelineEntry {
    let date: Date
    let tokens: Int64?
    let revision: Int?
    let updatedAt: Date?
    /// Machine-readable state for the view: "value" | "missing" | "invalid".
    let state: String
    let message: String?
}

struct PrepProvider: TimelineProvider {
    func placeholder(in context: Context) -> PrepEntry {
        PrepEntry(date: Date(), tokens: 160, revision: 1, updatedAt: Date(), state: "value", message: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PrepEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PrepEntry>) -> Void) {
        let entry = currentEntry()
        // Request the next refresh after 5 minutes; the system may repaint later or not at all.
        let next = Date().addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func currentEntry() -> PrepEntry {
        do {
            let snapshot = try PrepStore.read()
            return PrepEntry(
                date: Date(),
                tokens: snapshot.tokens,
                revision: snapshot.revision,
                updatedAt: snapshot.updatedAt,
                state: "value",
                message: nil
            )
        } catch let error as PrepStoreError {
            switch error {
            case .missingSnapshot, .missingGroupIdentifier, .unresolvedGroup:
                // Waiting state: no snapshot available yet (or group not configured).
                return PrepEntry(
                    date: Date(),
                    tokens: nil,
                    revision: nil,
                    updatedAt: nil,
                    state: "missing",
                    message: error.errorDescription
                )
            case .schemaMismatch, .negativeTokens:
                // Bad data: a snapshot exists but failed validation.
                return PrepEntry(
                    date: Date(),
                    tokens: nil,
                    revision: nil,
                    updatedAt: nil,
                    state: "invalid",
                    message: error.errorDescription
                )
            }
        } catch {
            // Decoding errors surface here as bad data (file exists but is unreadable).
            return PrepEntry(
                date: Date(),
                tokens: nil,
                revision: nil,
                updatedAt: nil,
                state: "invalid",
                message: "快照数据异常：解码失败（\(error.localizedDescription)）"
            )
        }
    }
}

struct PrepWidgetView: View {
    let entry: PrepEntry

    private static var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tokens 前置验证")
                .font(.caption)
                .foregroundStyle(.secondary)
            if entry.state == "value", let tokens = entry.tokens, let revision = entry.revision {
                Text("\(tokens)")
                    .font(.title2.bold())
                Text("rev \(revision)")
                    .font(.caption)
                if let updated = entry.updatedAt {
                    Text(Self.timeFormatter.string(from: updated))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("合成数据")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if entry.state == "missing" {
                Text("等待写入")
                    .font(.headline)
                Text(entry.message ?? "尚未写入快照")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("数据异常")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(entry.message ?? "快照数据异常")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "tokensprep://open"))
    }
}

@main
struct PrepWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PrepStore.widgetKind, provider: PrepProvider()) { entry in
            PrepWidgetView(entry: entry)
        }
        .configurationDisplayName("Tokens 前置验证")
        .description("本机共享数据与刷新验证")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

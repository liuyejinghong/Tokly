import SwiftUI
import WidgetKit
import Foundation

struct UsageEntry: TimelineEntry {
    let date: Date
    let tokens: Int64
}
struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: .now, tokens: 0) }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: .now, tokens: 0))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        completion(Timeline(entries: [UsageEntry(date: .now, tokens: 0)], policy: .after(.now.addingTimeInterval(600))))
    }
}
struct UsageWidget: Widget {
    let kind = "TokensUsage"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            Text(entry.tokens.formatted()).containerBackground(.fill.tertiary, for: .widget)
        }.supportedFamilies([.systemSmall, .systemMedium])
    }
}
func sharedSnapshotURL(groupID: String) -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent("usage.json")
}
func requestRefresh() { WidgetCenter.shared.reloadTimelines(ofKind: "TokensUsage") }

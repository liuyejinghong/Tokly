import SwiftUI
import WidgetKit

/// WidgetKit extension (P4): read-only today snapshot, system scheduling.
///
/// No process spawning, no network, no log scanning. The only input is the
/// trimmed `widget-snapshot.json` published by the main app to the shared
/// App Group. Timeline keeps original date values: at the statistics-day
/// boundary a second entry marks the same payload expired. A reasonable
/// refresh is requested without promising exact 5/10-minute timing.
struct TokensSnapshotEntry: TimelineEntry {
    var date: Date
    var result: WidgetReadResult
}

struct TokensProvider: TimelineProvider {
    func placeholder(in context: Context) -> TokensSnapshotEntry {
        TokensSnapshotEntry(date: Date(), result: .missing)
    }

    func getSnapshot(in context: Context, completion: @escaping (TokensSnapshotEntry) -> Void) {
        completion(TokensSnapshotEntry(date: Date(), result: readNow()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TokensSnapshotEntry>) -> Void) {
        let now = Date()
        let result = readNow(at: now)
        switch result {
        case .current(let snapshot):
            // Expire at the next statistics-day boundary in the payload
            // timezone, retaining the original date/values.
            if let zone = TimeZone(identifier: snapshot.timezone),
               let midnight = WidgetReader.midnightAfter(now, in: zone) {
                let current = TokensSnapshotEntry(date: now, result: result)
                let expired = TokensSnapshotEntry(date: midnight, result: .expired(snapshot))
                // Ask for a reasonable refresh after expiry; the system
                // decides the actual cadence (no punctual promise).
                let refresh = midnight.addingTimeInterval(30 * 60)
                completion(Timeline(entries: [current, expired], policy: .after(refresh)))
            } else {
                let entry = TokensSnapshotEntry(date: now, result: result)
                completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(30 * 60))))
            }
        case .expired, .missing, .invalid:
            let entry = TokensSnapshotEntry(date: now, result: result)
            completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(30 * 60))))
        }
    }

    private func readNow(at now: Date = Date()) -> WidgetReadResult {
        guard let url = widgetFileURL() else { return .missing }
        return WidgetReader.read(at: url, now: now)
    }

    private func widgetFileURL() -> URL? {
        let id: String
        if let configured = Bundle.main.object(forInfoDictionaryKey: WidgetReader.groupDefaultsKey) as? String,
           !configured.isEmpty, !configured.contains("$(") {
            id = configured
        } else {
            id = WidgetReader.groupID
        }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) else {
            return nil
        }
        return WidgetReader.fileURL(in: container)
    }
}

struct TokensWidget: Widget {
    let kind: String = "TokensWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TokensProvider()) { entry in
            TokensWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Tokly")
        .description("今日用量")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct TokensWidgetBundle: WidgetBundle {
    var body: some Widget {
        TokensWidget()
    }
}

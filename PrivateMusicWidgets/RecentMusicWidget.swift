import SwiftUI
import WidgetKit

struct RecentMusicProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentMusicEntry {
        RecentMusicEntry(date: Date(), snapshot: RecentWidgetSnapshot(accountID: nil, tracks: []))
    }
    func getSnapshot(in context: Context, completion: @escaping (RecentMusicEntry) -> Void) {
        completion(RecentMusicEntry(date: Date(), snapshot: .read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentMusicEntry>) -> Void) {
        completion(Timeline(entries: [RecentMusicEntry(date: Date(), snapshot: .read())], policy: .never))
    }
}

@main
struct RecentMusicWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: RecentWidgetSnapshot.kind, provider: RecentMusicProvider()) { entry in
            RecentMusicWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget.recent"))
        .description(String(localized: "widget.hint"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

import SwiftUI
import WidgetKit

struct RecentMusicEntry: TimelineEntry {
    let date: Date
    let snapshot: RecentWidgetSnapshot
}

struct RecentMusicWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecentMusicEntry
    var previewFamily: WidgetFamily? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "widget.recent"), systemImage: "waveform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if entry.snapshot.tracks.isEmpty {
                Text(String(localized: "widget.empty"))
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(Array(entry.snapshot.tracks.prefix((previewFamily ?? family) == .systemSmall ? 1 : 3))) { track in
                    Link(destination: entry.snapshot.url(for: track) ?? URL(string: "privatemusic://recent")!) {
                        HStack(spacing: 10) {
                            Group {
                                if let data = track.artwork, let image = UIImage(data: data) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    Image(systemName: "music.note").foregroundStyle(.white)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .background(LinearGradient(colors: [.indigo, .blue],
                                                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                                }
                            }
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .tint(.primary)
                }
            }
            Spacer(minLength: 0)
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(entry.snapshot.tracks.first.flatMap { entry.snapshot.url(for: $0) })
    }
}


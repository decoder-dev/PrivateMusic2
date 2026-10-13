import SwiftUI

/// "Итоги прослушивания": totals, top artists and tracks, and the hours you
/// listen at, from the counters kept on this device.
struct ListeningStatsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scope: Scope = .month
    @State private var chosenMonth: String?
    @State private var chosenYear: Int?
    @State private var showingReset = false

    private enum Scope: CaseIterable, Hashable {
        case month, year, all

        var title: String {
            switch self {
            case .month: L10n.text("stats.period.month")
            case .year: L10n.text("stats.period.year")
            case .all: L10n.text("stats.period.all")
            }
        }
    }

    private var store: ListeningStatsStore { environment.historyStore.stats }
    private var data: ListeningStatsData { store.data }

    private var months: [String] { ListeningSummary.availableMonths(in: data) }
    private var years: [Int] { ListeningSummary.availableYears(in: data) }

    private var period: ListeningSummary.Period {
        switch scope {
        case .month:
            .month(chosenMonth.flatMap { months.contains($0) ? $0 : nil }
                ?? months.first
                ?? ListeningStatsData.monthKey(for: Date(), calendar: .current))
        case .year:
            .year(chosenYear.flatMap { years.contains($0) ? $0 : nil }
                ?? years.first
                ?? Calendar.current.component(.year, from: Date()))
        case .all:
            .allTime
        }
    }

    private var summary: ListeningSummary {
        ListeningSummary.make(from: data, period: period)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BubbleSpacing.section) {
                Picker(L10n.text("stats.period.picker"), selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)

                periodChooser

                if summary.isEmpty {
                    EmptyStateView(
                        title: L10n.text("stats.empty_title"),
                        systemImage: "chart.bar.xaxis",
                        description: L10n.text("stats.empty_detail"),
                        titleIsLocalizedKey: false,
                        descriptionIsLocalizedKey: false
                    )
                } else {
                    totals
                    if !summary.topArtists.isEmpty { topArtists }
                    if !summary.topTracks.isEmpty { topTracks }
                    habits
                }

                Text(L10n.text("stats.privacy_footer"))
                    .font(BubbleType.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !data.isEmpty {
                    Button(role: .destructive) {
                        showingReset = true
                    } label: {
                        Text(L10n.text("stats.reset"))
                            .frame(maxWidth: .infinity, minHeight: PremiumLayout.minimumTapTarget)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, PremiumLayout.screenPadding)
            .padding(.vertical, BubbleSpacing.l)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(ThemeBackground())
        .navigationTitle(L10n.text("stats.title"))
        .navigationBarTitleDisplayMode(.inline)
        .clearsMiniPlayer()
        .confirmationDialog(
            L10n.text("stats.reset_confirm_title"),
            isPresented: $showingReset,
            titleVisibility: .visible
        ) {
            Button(L10n.text("stats.reset"), role: .destructive) {
                store.clear()
            }
            Button(L10n.text("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("stats.reset_confirm_message"))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: scope)
    }

    // MARK: Period

    @ViewBuilder
    private var periodChooser: some View {
        switch scope {
        case .month where months.count > 1:
            Menu {
                ForEach(months, id: \.self) { key in
                    Button(monthTitle(key)) { chosenMonth = key }
                }
            } label: {
                chooserLabel(monthTitle(currentMonthKey))
            }
        case .year where years.count > 1:
            Menu {
                ForEach(years, id: \.self) { year in
                    Button(String(year)) { chosenYear = year }
                }
            } label: {
                chooserLabel(String(currentYear))
            }
        case .month:
            Text(monthTitle(currentMonthKey))
                .font(BubbleType.section)
        case .year:
            Text(String(currentYear))
                .font(BubbleType.section)
        case .all:
            EmptyView()
        }
    }

    private func chooserLabel(_ title: String) -> some View {
        HStack(spacing: BubbleSpacing.xs) {
            Text(title).font(BubbleType.section)
            Image(systemName: "chevron.up.chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: PremiumLayout.minimumTapTarget, alignment: .leading)
    }

    private var currentMonthKey: String {
        if case .month(let key) = period { return key }
        return ""
    }

    private var currentYear: Int {
        if case .year(let year) = period { return year }
        return Calendar.current.component(.year, from: Date())
    }

    private func monthTitle(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]),
              let date = Calendar.current.date(
                from: DateComponents(year: year, month: month, day: 1)
              ) else { return key }
        return date.formatted(.dateTime.month(.wide).year())
    }

    // MARK: Sections

    private var totals: some View {
        VStack(alignment: .leading, spacing: BubbleSpacing.l) {
            VStack(alignment: .leading, spacing: BubbleSpacing.xs) {
                Text(L10n.text("stats.total_time"))
                    .font(BubbleType.metadata)
                    .foregroundStyle(.secondary)
                Text(Self.duration(summary.totalSeconds))
                    .font(BubbleType.hero(40))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            HStack(alignment: .top, spacing: BubbleSpacing.xl) {
                figure(
                    value: summary.plays.formatted(),
                    label: L10n.text("stats.plays")
                )
                figure(
                    value: summary.activeDays.formatted(),
                    label: L10n.text("stats.active_days")
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func figure(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: BubbleSpacing.xs) {
            Text(value).font(BubbleType.hero(28))
            Text(label)
                .font(BubbleType.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var topArtists: some View {
        AppGroupedSection(title: "stats.top_artists") {
            ForEach(Array(summary.topArtists.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().padding(.leading, 54) }
                row(rank: index + 1, entry: entry, showsArtwork: false)
            }
        }
    }

    private var topTracks: some View {
        AppGroupedSection(title: "stats.top_tracks") {
            ForEach(Array(summary.topTracks.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().padding(.leading, 54) }
                row(rank: index + 1, entry: entry, showsArtwork: true)
            }
        }
    }

    private func row(
        rank: Int,
        entry: ListeningSummary.Entry,
        showsArtwork: Bool
    ) -> some View {
        AppGroupedRow {
            HStack(spacing: BubbleSpacing.m) {
                Text("\(rank)")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                if showsArtwork {
                    AsyncArtwork(url: entry.artworkURL, size: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = entry.subtitle {
                        Text(subtitle)
                            .font(BubbleType.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        } trailing: {
            Text("×\(entry.plays)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var habits: some View {
        AppGroupedSection(title: "stats.when") {
            VStack(alignment: .leading, spacing: BubbleSpacing.m) {
                hourChart
                if let hour = summary.peakHour {
                    Label(
                        L10n.format("stats.peak_hour", String(format: "%02d:00", hour)),
                        systemImage: "clock"
                    )
                }
                if let weekday = summary.favouriteWeekday {
                    Label(
                        L10n.format("stats.favorite_weekday", weekdayName(weekday)),
                        systemImage: "calendar"
                    )
                }
                if let day = summary.busiestDay {
                    Label(
                        L10n.format("stats.busiest_day", dayTitle(day.key)),
                        systemImage: "flame"
                    )
                }
            }
            .font(BubbleType.body)
            .padding(BubbleSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hourChart: some View {
        let peak = max(summary.hourSeconds.max() ?? 0, 1)
        return VStack(spacing: BubbleSpacing.xs) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    let share = summary.hourSeconds[hour] / peak
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(hour == summary.peakHour ? Color.accentColor : Color.accentColor.opacity(0.35))
                        .frame(height: max(3, 64 * share))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 64, alignment: .bottom)
            HStack {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(String(format: "%02d", hour))
                    if hour != 18 { Spacer() }
                }
            }
            .font(BubbleType.micro)
            .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }

    // MARK: Formatting

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : ""
    }

    private func dayTitle(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(
                from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
              ) else { return key }
        return date.formatted(.dateTime.day().month(.wide))
    }

    private static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: max(0, seconds)) ?? ""
    }
}

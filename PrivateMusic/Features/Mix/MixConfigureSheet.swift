import SwiftUI

/// Which dial the sheet is tuning. Selena gets the full Yandex-style wave
/// (moodEnergy + diversity + language incl. instrumental). Catalog mixes
/// keep only language + familiarity.
enum MixConfigureScope: Equatable {
    case selena
    case mix
    /// Settings hosts both dials on one page.
    case all
}

/// Bottom-sheet tuner — Selena wave or basic mix filters.
struct MixConfigureSheet: View {
    @Environment(\.dismiss) private var dismiss

    var scope: MixConfigureScope = .selena
    /// When set, the primary button starts playback after applying filters.
    var onStart: (() -> Void)? = nil
    /// Fires after the sheet has dismissed when Start was tapped — keeps
    /// mix launch off the same turn as teardown.
    @State private var pendingStart = false

    var body: some View {
        NavigationStack {
            MixConfigureContent(
                scope: scope,
                showsStartAction: onStart != nil,
                onCancel: { dismiss() },
                onStart: {
                    pendingStart = true
                    dismiss()
                }
            )
            .background(ThemeBackground())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onDisappear {
            guard pendingStart else { return }
            pendingStart = false
            onStart?()
        }
    }

    private var navigationTitle: String {
        switch scope {
        case .selena: L10n.text("configure_selena")
        case .mix: L10n.text("configure_mix")
        case .all: L10n.text("mix_filters")
        }
    }
}

/// Shared chip body used by Explore sheets and the Settings page.
struct MixConfigureContent: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var scope: MixConfigureScope = .selena
    var showsStartAction = false
    var onCancel: (() -> Void)? = nil
    var onStart: (() -> Void)? = nil

    private var increaseContrast: Bool {
        colorSchemeContrast == .increased
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BubbleSpacing.xxl) {
                switch scope {
                case .selena:
                    selenaSections
                case .mix:
                    mixSections
                case .all:
                    selenaSections
                    Divider().opacity(0.35)
                    mixSections
                }

                if !showsStartAction {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, BubbleSpacing.l)
            .padding(.top, BubbleSpacing.m)
            .padding(.bottom, BubbleSpacing.xxl)
        }
        .toolbar {
            if let onCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("done"), action: onCancel)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(L10n.text("action.reset")) {
                    resetFilters()
                }
                .disabled(!hasActiveFilters)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsStartAction, let onStart {
                VStack(spacing: 0) {
                    Divider().opacity(0.35)
                    Button(action: {
                        Haptics.selection()
                        environment.reapplyMixFiltersToPlayingQueue()
                        onStart()
                    }) {
                        HStack(spacing: BubbleSpacing.s) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 16, weight: .bold))
                            Text(startTitle)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(settings.theme.buttonForeground)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            settings.theme.accent,
                            in: Capsule(style: .continuous)
                        )
                    }
                    .buttonStyle(BubblePressStyle())
                    .accessibilityLabel(startTitle)
                    .padding(.horizontal, BubbleSpacing.l)
                    .padding(.top, BubbleSpacing.m)
                    .padding(.bottom, BubbleSpacing.m)
                }
                .background(.bar)
            }
        }
    }

    @ViewBuilder
    private var selenaSections: some View {
        if scope == .all {
            Text(L10n.text("selena.wave_section"))
                .font(.title3.weight(.semibold))
        }
        moodSection
        diversitySection
        languageSection(cases: MixLanguagePreference.selenaCases)
    }

    @ViewBuilder
    private var mixSections: some View {
        if scope == .all {
            Text(L10n.text("mix.basic_section"))
                .font(.title3.weight(.semibold))
        }
        familiaritySection
        languageSection(cases: MixLanguagePreference.mixCases)
    }

    private var startTitle: String {
        switch scope {
        case .selena: L10n.text("start_selena")
        case .mix, .all: L10n.text("start_your_mix")
        }
    }

    private var footnote: String {
        switch scope {
        case .selena:
            L10n.text("selena.wave_footnote")
        case .mix:
            L10n.text("mix.basic_footnote")
        case .all:
            L10n.text(
                "like_vk_mix_filters_they_apply_to_the_mix_queue_and_to_recommendations_o"
            )
        }
    }

    private var hasActiveFilters: Bool {
        switch scope {
        case .selena:
            return settings.mixMoodPreference != .any
                || settings.selenaDiversityPreference != .default
                || settings.mixLanguagePreference != .any
        case .mix:
            return settings.mixLanguagePreference != .any
                || settings.mixFamiliarityPreference != .any
        case .all:
            return settings.mixMoodPreference != .any
                || settings.selenaDiversityPreference != .default
                || settings.mixLanguagePreference != .any
                || settings.mixFamiliarityPreference != .any
        }
    }

    private var moodSection: some View {
        filterSection(
            title: L10n.text("mood"),
            footnote: L10n.text("selena.mood_live_footnote")
        ) {
            ForEach(MixMoodPreference.allCases.filter { $0 != .any }) { mood in
                MixConfigureChip(
                    title: mood.title,
                    systemImage: mood.chipSymbol,
                    isSelected: settings.mixMoodPreference == mood,
                    increaseContrast: increaseContrast,
                    reduceTransparency: reduceTransparency
                ) {
                    toggleMood(mood)
                }
            }
        }
    }

    private var diversitySection: some View {
        filterSection(
            title: L10n.text("selena.diversity"),
            footnote: settings.selenaDiversityPreference.caption
        ) {
            ForEach(
                SelenaDiversityPreference.allCases.filter { $0 != .default }
            ) { diversity in
                MixConfigureChip(
                    title: diversity.chipTitle,
                    systemImage: diversity.chipSymbol,
                    isSelected: settings.selenaDiversityPreference == diversity,
                    increaseContrast: increaseContrast,
                    reduceTransparency: reduceTransparency
                ) {
                    toggleDiversity(diversity)
                }
            }
        }
    }

    private var familiaritySection: some View {
        filterSection(title: L10n.text("familiarity")) {
            ForEach(
                MixFamiliarityPreference.allCases.filter { $0 != .any }
            ) { familiarity in
                MixConfigureChip(
                    title: familiarity.chipTitle,
                    systemImage: familiarity.chipSymbol,
                    isSelected: settings.mixFamiliarityPreference == familiarity,
                    increaseContrast: increaseContrast,
                    reduceTransparency: reduceTransparency
                ) {
                    toggleFamiliarity(familiarity)
                }
            }
        }
    }

    private func languageSection(
        cases: [MixLanguagePreference]
    ) -> some View {
        filterSection(title: L10n.text("language")) {
            ForEach(cases) { language in
                MixConfigureChip(
                    title: language.title,
                    systemImage: language.chipSymbol,
                    isSelected: settings.mixLanguagePreference == language,
                    increaseContrast: increaseContrast,
                    reduceTransparency: reduceTransparency
                ) {
                    toggleLanguage(language)
                }
            }
        }
    }

    private func filterSection<Content: View>(
        title: String,
        footnote: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: BubbleSpacing.m) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            MixFilterChipFlow(spacing: BubbleSpacing.s) {
                content()
            }
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func resetFilters() {
        Haptics.selection()
        switch scope {
        case .selena:
            settings.mixMoodPreference = .any
            settings.selenaDiversityPreference = .default
            settings.mixLanguagePreference = .any
        case .mix:
            settings.mixLanguagePreference = .any
            settings.mixFamiliarityPreference = .any
        case .all:
            settings.mixMoodPreference = .any
            settings.selenaDiversityPreference = .default
            settings.mixLanguagePreference = .any
            settings.mixFamiliarityPreference = .any
        }
        environment.reapplyMixFiltersToPlayingQueue()
    }

    private func toggleMood(_ mood: MixMoodPreference) {
        Haptics.selection()
        settings.mixMoodPreference =
            settings.mixMoodPreference == mood ? .any : mood
        // Live on Selena — soft moodEnergy reorder of the playing queue.
        environment.reapplyMixFiltersToPlayingQueue()
    }

    private func toggleDiversity(_ diversity: SelenaDiversityPreference) {
        Haptics.selection()
        settings.selenaDiversityPreference =
            settings.selenaDiversityPreference == diversity
            ? .default
            : diversity
        environment.reapplyMixFiltersToPlayingQueue()
    }

    private func toggleFamiliarity(_ familiarity: MixFamiliarityPreference) {
        Haptics.selection()
        settings.mixFamiliarityPreference =
            settings.mixFamiliarityPreference == familiarity
            ? .any
            : familiarity
        environment.reapplyMixFiltersToPlayingQueue()
    }

    private func toggleLanguage(_ language: MixLanguagePreference) {
        Haptics.selection()
        settings.mixLanguagePreference =
            settings.mixLanguagePreference == language ? .any : language
        environment.reapplyMixFiltersToPlayingQueue()
    }
}

// MARK: - Chip

private struct MixConfigureChip: View {
    @Environment(AppSettings.self) private var settings

    let title: String
    let systemImage: String
    let isSelected: Bool
    var increaseContrast = false
    var reduceTransparency = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: BubbleSpacing.s) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                }
            }
            .foregroundStyle(
                isSelected
                    ? settings.theme.buttonForeground
                    : Color.primary
            )
            .padding(.horizontal, BubbleSpacing.m)
            .frame(minHeight: PremiumLayout.minimumTapTarget)
            .background(
                Capsule(style: .continuous)
                    .fill(fillColor)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: strokeWidth)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(BubblePressStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(title)
    }

    private var fillColor: Color {
        if isSelected {
            return settings.theme.accent
        }
        let base = increaseContrast || reduceTransparency ? 0.10 : 0.06
        return Color.primary.opacity(base)
    }

    private var strokeColor: Color {
        if isSelected { return .clear }
        return Color.primary.opacity(
            ContrastPolicy.strokeOpacity(
                increased: increaseContrast,
                reduceTransparency: reduceTransparency,
                base: 0.08
            )
        )
    }

    private var strokeWidth: CGFloat {
        ContrastPolicy.strokeWidth(increased: increaseContrast)
    }
}

// MARK: - Wrapping flow

/// Lays chips into rows that wrap at the container width — Form pickers
/// hide the whole set; a flow keeps every option visible at once.
struct MixFilterChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = arrange(proposal: proposal, subviews: subviews)
        let width = proposal.width
            ?? rows.map(\.width).max()
            ?? 0
        let height = rows.map(\.height).reduce(0, +)
            + CGFloat(max(rows.count - 1, 0)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = arrange(
            proposal: ProposedViewSize(width: bounds.width, height: nil),
            subviews: subviews
        )
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var current = Row()

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = current.indices.isEmpty
                ? size.width
                : current.width + spacing + size.width
            if nextWidth > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.indices.append(index)
            current.width = current.indices.count == 1
                ? size.width
                : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

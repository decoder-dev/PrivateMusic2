import SwiftUI

/// Bottom-sheet tuner for mood / familiarity / language — pick chips,
/// then start a mix. Same knobs as Settings, but scannable like a radio
/// dial instead of three Form pickers.
struct MixConfigureSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// When set, the primary button starts a mix after applying filters.
    var onStart: (() -> Void)? = nil
    /// Fires after the sheet has dismissed when Start was tapped — keeps
    /// mix launch off the same turn as teardown.
    @State private var pendingStart = false

    var body: some View {
        NavigationStack {
            MixConfigureContent(
                showsStartAction: onStart != nil,
                onCancel: { dismiss() },
                onStart: {
                    pendingStart = true
                    dismiss()
                }
            )
            .background(ThemeBackground())
            .navigationTitle(L10n.text("configure_mix"))
            .navigationBarTitleDisplayMode(.inline)
        }
        // Large so mood + familiarity + language + Start fit without
        // burying Language under the fold on a medium detent.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onDisappear {
            guard pendingStart else { return }
            pendingStart = false
            onStart?()
        }
    }
}

/// Shared chip body used by the Explore sheet and the Settings page.
struct MixConfigureContent: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var showsStartAction = false
    var onCancel: (() -> Void)? = nil
    var onStart: (() -> Void)? = nil

    private var increaseContrast: Bool {
        colorSchemeContrast == .increased
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BubbleSpacing.xxl) {
                moodSection
                familiaritySection
                languageSection

                if !showsStartAction {
                    Text(
                        L10n.text(
                            "like_vk_mix_filters_they_apply_to_the_mix_queue_and_to_recommendations_o"
                        )
                    )
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
                // Filters write through immediately — this closes the
                // sheet, it does not discard the dial.
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
                            Text(L10n.text("start_your_mix"))
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
                    .accessibilityLabel(L10n.text("start_your_mix"))
                    .padding(.horizontal, BubbleSpacing.l)
                    .padding(.top, BubbleSpacing.m)
                    .padding(.bottom, BubbleSpacing.m)
                }
                .background(.bar)
            }
        }
    }

    private var hasActiveFilters: Bool {
        settings.mixMoodPreference != .any
            || settings.mixLanguagePreference != .any
            || settings.mixFamiliarityPreference != .any
    }

    private var moodSection: some View {
        filterSection(
            title: L10n.text("mood"),
            footnote: L10n.text("mix_mood_applies_on_start")
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

    private var languageSection: some View {
        filterSection(title: L10n.text("language")) {
            ForEach(
                MixLanguagePreference.allCases.filter { $0 != .any }
            ) { language in
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
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func resetFilters() {
        Haptics.selection()
        settings.mixMoodPreference = .any
        settings.mixLanguagePreference = .any
        settings.mixFamiliarityPreference = .any
        environment.reapplyMixFiltersToPlayingQueue()
    }

    private func toggleMood(_ mood: MixMoodPreference) {
        Haptics.selection()
        // Mood shapes which station Start launches — it is not a live
        // queue filter like language / familiarity.
        settings.mixMoodPreference =
            settings.mixMoodPreference == mood ? .any : mood
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

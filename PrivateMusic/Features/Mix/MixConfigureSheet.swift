import SwiftUI

/// Where the filter chips are shown.
enum MixConfigureScope: Equatable {
    /// Bottom sheet opened from a mix.
    case mix
    /// The Settings page.
    case all
}

/// Bottom-sheet tuner for the basic mix filters (language + familiarity).
struct MixConfigureSheet: View {
    @Environment(\.dismiss) private var dismiss

    var scope: MixConfigureScope = .mix
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

    var scope: MixConfigureScope = .mix
    var showsStartAction = false
    var onCancel: (() -> Void)? = nil
    var onStart: (() -> Void)? = nil

    private var increaseContrast: Bool {
        colorSchemeContrast == .increased
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BubbleSpacing.xxl) {
                mixSections

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
                        .foregroundStyle(settings.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            settings.accent,
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
    private var mixSections: some View {
        familiaritySection
        languageSection(cases: MixLanguagePreference.mixCases)
    }

    private var startTitle: String {
        L10n.text("start_your_mix")
    }

    private var footnote: String {
        switch scope {
        case .mix:
            L10n.text("mix.basic_footnote")
        case .all:
            L10n.text(
                "like_vk_mix_filters_they_apply_to_the_mix_queue_and_to_recommendations_o"
            )
        }
    }

    private var hasActiveFilters: Bool {
        settings.mixLanguagePreference != .any
            || settings.mixFamiliarityPreference != .any
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
        settings.mixLanguagePreference = .any
        settings.mixFamiliarityPreference = .any
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
                    ? settings.onAccent
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
            return settings.accent
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

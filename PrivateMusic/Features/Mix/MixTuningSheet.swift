import SwiftUI

/// VK's own «Настроить микс»: mood, activity and genre chips read from
/// `audio.getStreamMixSettings`, applied to the stream as `mix_options`.
struct MixTuningSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let mix: MusicMix
    /// Receives the tuned mix once the sheet has dismissed.
    let onPlay: (MusicMix) -> Void

    private enum Phase {
        case loading
        case ready(MixTuning)
        case unavailable
    }

    @State private var phase = Phase.loading
    @State private var selection: [String: Set<String>] = [:]
    @State private var pendingMix: MusicMix?

    var body: some View {
        NavigationStack {
            content
                .background(ThemeBackground())
                .navigationTitle(L10n.text("mix.tuning_title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.text("done")) { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(L10n.text("action.reset")) {
                            Haptics.selection()
                            selection = [:]
                        }
                        .disabled(selection.isEmpty)
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await load() }
        .onDisappear {
            guard let pendingMix else { return }
            self.pendingMix = nil
            onPlay(pendingMix)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            VStack(spacing: BubbleSpacing.m) {
                Image(systemName: "slider.horizontal.3")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(L10n.text("mix.tuning_unavailable"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(BubbleSpacing.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .ready(tuning):
            ScrollView {
                VStack(alignment: .leading, spacing: BubbleSpacing.xxl) {
                    ForEach(tuning.categories) { category in
                        categorySection(category)
                    }
                }
                .padding(.horizontal, BubbleSpacing.l)
                .padding(.top, BubbleSpacing.m)
                .padding(.bottom, BubbleSpacing.xxl)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                playBar(tuning: tuning)
            }
        }
    }

    private func categorySection(
        _ category: MixTuningCategory
    ) -> some View {
        VStack(alignment: .leading, spacing: BubbleSpacing.m) {
            if !category.title.isEmpty {
                Text(category.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            MixFilterChipFlow(spacing: BubbleSpacing.s) {
                ForEach(category.options) { option in
                    chip(option, in: category)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(category.title)
    }

    private func chip(
        _ option: MixTuningOption,
        in category: MixTuningCategory
    ) -> some View {
        let isSelected = selection[category.id]?.contains(option.id) == true
        return Button {
            toggle(option, in: category)
        } label: {
            HStack(spacing: BubbleSpacing.xs) {
                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                }
            }
            .foregroundStyle(isSelected ? settings.onAccent : Color.primary)
            .padding(.horizontal, BubbleSpacing.m)
            .frame(minHeight: PremiumLayout.minimumTapTarget)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        isSelected
                            ? settings.accent
                            : Color.primary.opacity(0.07)
                    )
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(BubblePressStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func playBar(tuning: MixTuning) -> some View {
        VStack(spacing: 0) {
            Divider().opacity(0.35)
            Button {
                Haptics.selection()
                pendingMix = tuning.mix(applying: selection, to: mix)
                dismiss()
            } label: {
                HStack(spacing: BubbleSpacing.s) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .bold))
                    Text(L10n.text("start_your_mix"))
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
            .padding(.horizontal, BubbleSpacing.l)
            .padding(.vertical, BubbleSpacing.m)
        }
        .background(.bar)
    }

    private func toggle(
        _ option: MixTuningOption,
        in category: MixTuningCategory
    ) {
        Haptics.selection()
        var picked = selection[category.id] ?? []
        if picked.contains(option.id) {
            picked.remove(option.id)
        } else {
            if !category.allowsMultiple { picked.removeAll() }
            picked.insert(option.id)
        }
        selection[category.id] = picked.isEmpty ? nil : picked
    }

    private func load() async {
        do {
            let tuning = try await environment.withAuthorizedToken { token in
                try await environment.musicService.mixTuning(
                    for: mix,
                    accessToken: token
                )
            }
            guard !tuning.isEmpty else {
                phase = .unavailable
                return
            }
            selection = tuning.initialSelection
            phase = .ready(tuning)
        } catch is CancellationError {
            return
        } catch {
            phase = .unavailable
        }
    }
}

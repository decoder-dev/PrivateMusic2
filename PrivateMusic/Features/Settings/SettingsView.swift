import SwiftUI

/// Lifecycle of the "delete all saved files" control in settings. Internal so
/// tests can drive every state without touching the view.
enum OfflineDeleteAllPhase: Equatable {
    case idle
    case deleting
    case completed
    case incomplete(remainingBytes: Int64, remainingItems: Int)

    var isDeleting: Bool {
        if case .deleting = self { return true }
        return false
    }
}

/// Pure presentation of the delete-all row: title, subtitle, icon, enabled
/// state and spinner flag. Resolving happens in one place so the view stays
/// thin and the states are unit-testable.
struct OfflineDeleteAllPresentation: Equatable {
    let title: String
    let subtitle: String
    let systemImage: String
    let isEnabled: Bool
    let showsProgress: Bool

    /// Normalizes the phase: new content after a completed deletion returns
    /// the row to the active idle state.
    static func resolve(
        phase: OfflineDeleteAllPhase,
        hasContent: Bool,
        downloadedTrackCount: Int,
        totalBytes: Int64,
        formattedBytes: (Int64) -> String
    ) -> OfflineDeleteAllPresentation {
        let effectivePhase: OfflineDeleteAllPhase
        if hasContent, phase == .completed {
            effectivePhase = .idle
        } else {
            effectivePhase = phase
        }
        switch effectivePhase {
        case .idle:
            guard hasContent else {
                return OfflineDeleteAllPresentation(
                    title: L10n.text("all_saved_files_have_been_removed"),
                    subtitle: L10n.text("done"),
                    systemImage: "checkmark.circle.fill",
                    isEnabled: false,
                    showsProgress: false
                )
            }
            return OfflineDeleteAllPresentation(
                title: L10n.text("remove_all_saved_files"),
                subtitle: L10n.format(
                    "d0_files_1",
                    downloadedTrackCount,
                    formattedBytes(totalBytes)
                ),
                systemImage: "trash",
                isEnabled: true,
                showsProgress: false
            )
        case .deleting:
            return OfflineDeleteAllPresentation(
                title: L10n.text("removing_saved_files"),
                subtitle: L10n.text(
                    "stopping_downloads_and_clearing_storage"
                ),
                systemImage: "trash",
                isEnabled: false,
                showsProgress: true
            )
        case .completed:
            return OfflineDeleteAllPresentation(
                title: L10n.text("all_saved_files_have_been_removed"),
                subtitle: L10n.text("done"),
                systemImage: "checkmark.circle.fill",
                isEnabled: false,
                showsProgress: false
            )
        case let .incomplete(remainingBytes, remainingItems):
            return OfflineDeleteAllPresentation(
                title: L10n.text("some_files_could_not_be_removed"),
                subtitle: L10n.format(
                    "remaining_d0_items_1",
                    remainingItems,
                    formattedBytes(remainingBytes)
                ),
                systemImage: "exclamationmark.triangle.fill",
                isEnabled: true,
                showsProgress: false
            )
        }
    }
}

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(AudioPlayer.self) private var player
    @Environment(SessionStore.self) private var sessionStore
    @Environment(NetworkMonitor.self) private var networkMonitor
    @Environment(OfflineTrackStore.self) private var offlineStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BubbleSpacing.section) {
                AppGroupedSection(title: "tab.settings") {
                    settingsDestination(
                        title: "appearance",
                        systemImage: "paintpalette"
                    ) { AppearanceSettingsView() }
                    Divider().padding(.leading, 54)
                    settingsDestination(
                        title: "player_audio",
                        systemImage: "waveform"
                    ) { PlayerAudioSettingsView() }
                    Divider().padding(.leading, 54)
                    settingsDestination(
                        title: "equalizer",
                        systemImage: "slider.horizontal.3"
                    ) { EqualizerSettingsView() }
                    if OfflineDownloadsFeature.showsControls,
                       !environment.isShareSessionActive {
                        Divider().padding(.leading, 54)
                        settingsDestination(
                            title: "offline_storage",
                            systemImage: "externaldrive"
                        ) { OfflineStorageSettingsView() }
                    }
                    Divider().padding(.leading, 54)
                    settingsDestination(
                        title: "sleep_timer",
                        systemImage: "moon.zzz"
                    ) { SleepTimerSettingsView() }
                    Divider().padding(.leading, 54)
                    settingsDestination(
                        title: "connection",
                        systemImage: "network"
                    ) { ConnectionSettingsView() }
                    Divider().padding(.leading, 54)
                    settingsDestination(
                        title: "mix_filters",
                        systemImage: "line.3.horizontal.decrease.circle"
                    ) { MixFiltersSettingsView() }
                    Divider().padding(.leading, 54)
                    settingsDestination(
                        title: "hidden_in_mixes",
                        systemImage: "hand.thumbsdown"
                    ) { MixFeedbackManagerView() }
                }

                AppGroupedSection(title: "about") {
                    labeledValueRow(
                        title: L10n.text("app"),
                        value: L10n.text("private_music")
                    )
                    Divider().padding(.leading, 54)
                    labeledValueRow(title: L10n.text("version"), value: version)
                    Divider().padding(.leading, 54)
                    labeledValueRow(
                        title: L10n.text("developer"),
                        value: "decoder-dev"
                    )
                    Divider().padding(.leading, 54)
                    labeledValueRow(
                        title: L10n.text("analytics"),
                        value: L10n.text("not_used")
                    )
                }
            }
            .padding(.horizontal, PremiumLayout.screenPadding)
            .padding(.vertical, BubbleSpacing.l)
        }
        .background(ThemeBackground())
        .navigationTitle(L10n.text("tab.settings"))
    }

    private var version: String {
        let short = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "—"
        return "\(short) (\(build))"
    }

    private func settingsDestination<Destination: View>(
        title: String,
        systemImage: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            AppGroupedRow {
                Label(L10n.text(title), systemImage: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
            } trailing: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func labeledValueRow(title: String, value: String) -> some View {
        AppGroupedRow {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
        } trailing: {
            Text(value)
                .font(BubbleType.metadata.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section(L10n.text("theme")) {
                themePicker
            }

            // Below iOS 26 everything is already drawn this way, so the
            // switch would be a no-op control — it only shows up where
            // Liquid Glass actually applies.
            if #available(iOS 26.0, *) {
                Section(L10n.text("player_look")) {
                    Toggle(isOn: $settings.classicChrome) {
                        Label(
                            L10n.text("classic_player_look"),
                            systemImage: "rectangle.on.rectangle"
                        )
                    }
                    Text(L10n.text("classic_player_look.footnote"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.text("home_stage.section")) {
                Toggle(isOn: $settings.homeStageEnabled) {
                    Label(
                        L10n.text("home_stage.toggle"),
                        systemImage: "sparkles.rectangle.stack"
                    )
                }
                Text(L10n.text("home_stage.footnote"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.text("text_size")) {
                Picker(
                    L10n.text("text_scale_picker"),
                    selection: $settings.textScale
                ) {
                    ForEach(AppTextScale.allCases) { scale in
                        Text("\(scale.title) · \(scale.subtitle)")
                            .tag(scale)
                    }
                }

                HStack {
                    Text(L10n.text("settings.preview"))
                        .font(.headline)
                    Spacer()
                    Text(settings.textScale.subtitle)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button(L10n.text("reset_appearance")) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        settings.resetAppearance()
                    }
                }
            }

            Section(L10n.text("feedback")) {
                Toggle(
                    isOn: Binding(
                        get: { settings.hapticsEnabled },
                        set: { newValue in
                            withAnimation(
                                .spring(response: 0.3, dampingFraction: 0.8)
                            ) {
                                settings.hapticsEnabled = newValue
                            }
                        }
                    )
                ) {
                    Label(L10n.text("haptic_feedback"),
                        systemImage: "hand.tap"
                    )
                }
                Text(
                    L10n.text("a_light_vibration_when_switching_tracks_acting_on_your_library_and_other")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle(L10n.text("appearance"))
    }

    private var themePicker: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 72), spacing: 12)
            ],
            spacing: 12
        ) {
            ForEach(AppTheme.allCases) { theme in
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        settings.theme = theme
                        settings.appearance =
                            theme == .dark ? .dark : .light
                    }
                } label: {
                    VStack(spacing: 7) {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: theme.colors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)
                            .overlay {
                                if settings.theme == theme {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(theme.accent)
                                }
                            }
                        Text(theme.title)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.title)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Player & Audio

private struct PlayerAudioSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var showRouteHint = false
    @State private var routeHintToken = UUID()

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section(L10n.text("audio_quality")) {
                Toggle(
                    isOn: $settings.preferHighQuality
                ) {
                    Label(L10n.text("high_quality"),
                        systemImage: "waveform"
                    )
                }
                Text(
                    L10n.text("prefers_vk_hq_streams_and_does_not_cap_the_hls_bitrate_turn_it_off_to_sa")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Toggle(
                    isOn: $settings.loudnessNormalization
                ) {
                    Label(L10n.text("volume_normalization"),
                        systemImage: "speaker.wave.2"
                    )
                }
                Text(
                    L10n.text("smooths_volume_jumps_between_tracks_works_on_progressive_streams_on_devi")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Toggle(
                    isOn: $settings.dynamicRangeCompression
                ) {
                    Label(L10n.text("dynamic_range_compression"),
                        systemImage: "waveform.path"
                    )
                }
                Text(
                    L10n.text("makes_quiet_passages_audible_in_noisy_places_headphones_on_the_subway_a_")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    isOn: $settings.resumeOnBluetoothConnection
                ) {
                    Label(L10n.text("resume_on_bluetooth_connection"),
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                }
                Text(
                    L10n.text("if_the_queue_has_a_current_track_playback_resumes_after_compatible_headp")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Toggle(
                    isOn: $settings.pauseAtMinimumVolume
                ) {
                    Label(L10n.text("pause_at_minimum_volume"),
                        systemImage: "speaker.slash"
                    )
                }
                Text(
                    L10n.text("playback_pauses_at_the_current_position_when_system_volume_reaches_zero")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Toggle(
                    isOn: $settings.advanceOnPlaybackError
                ) {
                    Label(L10n.text("skip_unavailable_tracks"),
                        systemImage: "forward.end"
                    )
                }
                Text(
                    L10n.text("after_several_failed_stream_refresh_attempts_the_player_moves_to_the_nex")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section(L10n.text("spatial_audio")) {
                Toggle(
                    isOn: spatialAudioBinding
                ) {
                    Label(L10n.text("expanded_stereo_soundstage"),
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                }

                VStack(spacing: 8) {
                    HStack {
                        Text(L10n.text("settings.intensity"))
                        Spacer()
                        Text(
                            settings.spatialAudioIntensity,
                            format: .percent.precision(.fractionLength(0))
                        )
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $settings.spatialAudioIntensity,
                        in: 0...1,
                        step: 0.05
                    )
                }
                .disabled(!settings.spatialAudioEnabled)

                Text(
                    L10n.text("widens_the_soundstage_on_headphones_in_the_car_and_on_speakers_bass_stay")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle(L10n.text("player_audio"))
        .audioProcessingRouteHintOverlay(isPresented: $showRouteHint)
    }

    private var spatialAudioBinding: Binding<Bool> {
        Binding(
            get: { settings.spatialAudioEnabled },
            set: { newValue in
                let wasEnabled = settings.spatialAudioEnabled
                settings.spatialAudioEnabled = newValue
                if newValue && !wasEnabled {
                    showProcessingRouteHint()
                }
            }
        )
    }

    private func showProcessingRouteHint() {
        let token = UUID()
        routeHintToken = token
        Haptics.open()
        showRouteHint = true
        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard routeHintToken == token else { return }
            showRouteHint = false
        }
    }
}

// MARK: - Equalizer

struct EqualizerSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var showRouteHint = false
    @State private var routeHintToken = UUID()

    private let frequencies = [
        "31", "62", "125", "250", "500",
        "1K", "2K", "4K", "8K", "16K"
    ]

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(L10n.text("audio_processing"),
                    isOn: equalizerEnabledBinding
                )
                Toggle(L10n.text("volume_normalization"),
                    isOn: $settings.loudnessNormalization
                )
                Toggle(L10n.text("dynamic_range_compression"),
                    isOn: $settings.dynamicRangeCompression
                )
            }

            Section(L10n.text("equalizer_preset")) {
                Picker(L10n.text("equalizer_preset"),
                    selection: Binding(
                        get: { settings.equalizerPreset },
                        set: { settings.selectPreset($0) }
                    )
                ) {
                    ForEach(EqualizerPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
            }

            Section(L10n.text("preamp")) {
                VStack(spacing: 5) {
                    HStack {
                        Text(L10n.text("settings.level"))
                        Spacer()
                        Text(
                            settings.equalizerPreamp,
                            format: .number.precision(
                                .fractionLength(1)
                            )
                        )
                        Text(L10n.text("settings.db"))
                    }
                    .font(.subheadline.monospacedDigit())
                    Slider(
                        value: $settings.equalizerPreamp,
                        in: -12...6,
                        step: 0.5
                    )
                }
                .disabled(!settings.equalizerEnabled)
            }

            Section {
                ForEach(frequencies.indices, id: \.self) { index in
                    VStack(spacing: 5) {
                        HStack {
                            Text(
                                L10n.format(
                                    "n_0_hz",
                                    frequencies[index]
                                )
                            )
                            Spacer()
                            Text(
                                settings.equalizerGains[index],
                                format: .number.precision(
                                    .fractionLength(1)
                                )
                            )
                            Text(L10n.text("settings.db"))
                        }
                        .font(.subheadline.monospacedDigit())

                        Slider(
                            value: Binding(
                                get: {
                                    settings.equalizerGains[index]
                                },
                                set: {
                                    settings.setGain($0, at: index)
                                }
                            ),
                            in: -12...12,
                            step: 0.5
                        )
                    }
                    .disabled(!settings.equalizerEnabled)
                }
            } header: {
                Text(L10n.text("settings.eq_bands"))
            } footer: {
                Text(
                    L10n.text("processing_runs_on_device_and_applies_to_headphones_speakers_and_carkit_")
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle(L10n.text("equalizer"))
        .audioProcessingRouteHintOverlay(isPresented: $showRouteHint)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text("done")) { dismiss() }
            }
        }
    }

    private var equalizerEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.equalizerEnabled },
            set: { newValue in
                let wasEnabled = settings.equalizerEnabled
                settings.equalizerEnabled = newValue
                if newValue && !wasEnabled {
                    showProcessingRouteHint()
                }
            }
        )
    }

    private func showProcessingRouteHint() {
        let token = UUID()
        routeHintToken = token
        Haptics.open()
        showRouteHint = true
        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard routeHintToken == token else { return }
            showRouteHint = false
        }
    }
}

// MARK: - Offline & Storage

private struct OfflineStorageSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(OfflineTrackStore.self) private var offlineStore
    private let offlinePlaylists =
        OfflinePlaylistStore.shared
    @State private var deleteAllPhase: OfflineDeleteAllPhase = .idle
    @State private var showsDeleteAllConfirmation = false

    var body: some View {
        @Bindable var settings = settings
        let usage = offlineStore.storageUsage
        Form {
            Section(L10n.text("storage_2")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(L10n.text("used"),
                            systemImage: "externaldrive"
                        )
                        Spacer()
                        Text(
                            L10n.format(
                                "n_0_d1_gb",
                                formattedBytes(usage.totalBytes),
                                settings.offlineStorageLimitGB
                            )
                        )
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    Color.secondary.opacity(0.15)
                                )
                            if usage.totalBytes > 0 {
                                HStack(spacing: 0) {
                                    if usage.manualBytes > 0 {
                                        RoundedRectangle(
                                            cornerRadius: 4
                                        )
                                        .fill(
                                            usageColor(usage: usage)
                                        )
                                        .frame(
                                            width: max(
                                                4,
                                                geo.size.width
                                                    * usage.manualRatio
                                                    * usage.usageRatio
                                            )
                                        )
                                    }
                                    if usage.automaticBytes > 0 {
                                        RoundedRectangle(
                                            cornerRadius: 4
                                        )
                                        .fill(
                                            Color.orange.opacity(0.7)
                                        )
                                        .frame(
                                            width: max(
                                                2,
                                                geo.size.width
                                                    * (1 - usage
                                                        .manualRatio)
                                                    * usage
                                                        .usageRatio
                                            )
                                        )
                                    }
                                }
                                .animation(
                                    .easeInOut(duration: 0.4),
                                    value: usage.totalBytes
                                )
                            }
                        }
                    }
                    .frame(height: 8)

                    HStack(spacing: 16) {
                        if usage.manualCount > 0 {
                            Label {
                                Text(L10n.trackCount(usage.manualCount))
                            } icon: {
                                Circle()
                                    .fill(
                                        usageColor(usage: usage)
                                    )
                                    .frame(width: 8, height: 8)
                            }
                        }
                        if usage.automaticCount > 0 {
                            Label {
                                Text(L10n.trackCount(usage.automaticCount))
                            } icon: {
                                Circle()
                                    .fill(
                                        Color.orange.opacity(0.7)
                                    )
                                    .frame(width: 8, height: 8)
                            }
                        }
                        if usage.totalCount == 0 {
                            Label(L10n.text("empty"),
                                systemImage: "tray"
                            )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(L10n.text("limit"),
                            systemImage: "internaldrive"
                        )
                        Spacer()
                        Text(
                            L10n.format(
                                "d0_gb",
                                settings.offlineStorageLimitGB
                            )
                        )
                        .font(
                            .subheadline.monospacedDigit()
                                .weight(.semibold)
                        )
                        .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: Binding(
                            get: {
                                Double(
                                    settings.offlineStorageLimitGB
                                )
                            },
                            set: {
                                settings.offlineStorageLimitGB =
                                    Int($0)
                            }
                        ),
                        in: Double(
                            AppSettings.minimumOfflineStorageLimitGB
                        )...Double(
                            AppSettings.maximumOfflineStorageLimitGB
                        ),
                        step: Double(
                            AppSettings.offlineStorageLimitStepGB
                        )
                    )
                    .accessibilityValue(
                        L10n.format(
                            "d0_gb",
                            settings.offlineStorageLimitGB
                        )
                    )

                    HStack {
                        Text(
                            L10n.format(
                                "d0_gb",
                                AppSettings
                                    .minimumOfflineStorageLimitGB
                            )
                        )
                        Spacer()
                        Text(
                            L10n.format(
                                "d0_gb",
                                AppSettings
                                    .maximumOfflineStorageLimitGB
                            )
                        )
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
            }

            if !environment.isShareSessionActive {
                Section(L10n.text("automatic_caching")) {
                    Toggle(
                        isOn: $settings.automaticOfflineCacheEnabled
                    ) {
                        Label(L10n.text("automatic_caching"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }

                    Text(
                        L10n.text("played_tracks_are_saved_automatically_for_replay_without_an_internet_con")
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            Section(L10n.text("manage")) {
                if offlineStore.automaticCacheByteCount > 0 {
                    Button(L10n.text("clear_automatic_cache"), role: .destructive) {
                        offlineStore.removeAutomaticCache()
                    }
                }

                let presentation = OfflineDeleteAllPresentation.resolve(
                    phase: deleteAllPhase,
                    hasContent: hasSavedOrActiveContent,
                    downloadedTrackCount: offlineStore.downloadedTrackCount,
                    totalBytes: offlineStore.storageUsage.totalBytes,
                    formattedBytes: formattedBytes
                )
                Button {
                    guard hasSavedOrActiveContent,
                          !deleteAllPhase.isDeleting else {
                        return
                    }
                    showsDeleteAllConfirmation = true
                } label: {
                    HStack(spacing: 12) {
                        Group {
                            if presentation.showsProgress {
                                ProgressView()
                            } else {
                                Image(systemName: presentation.systemImage)
                                    .foregroundStyle(deleteAllIconColor)
                            }
                        }
                        .frame(width: 24)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(presentation.title)
                                .foregroundStyle(deleteAllTitleColor)
                            Text(presentation.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!presentation.isEnabled)
                .accessibilityLabel(presentation.title)
                .accessibilityValue(presentation.subtitle)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle(L10n.text("offline_storage"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            L10n.text("remove_all_saved_files_2"),
            isPresented: $showsDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                L10n.text("delete_all"),
                role: .destructive
            ) {
                Task {
                    await deleteAllSavedContent()
                }
            }
            Button(L10n.text("action.cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.text("current_downloads_will_be_stopped_and_downloaded_tracks_playlists_and_au")
            )
        }
        .onChange(of: deleteAllContentSnapshot) { _ in
            if hasSavedOrActiveContent,
               deleteAllPhase == .completed {
                deleteAllPhase = .idle
            }
        }
    }

    /// Content is defined by audio bytes, physical files, in-flight
    /// downloads and playlist records (including active playlist state).
    private var hasSavedOrActiveContent: Bool {
        let hasActivePlaylist = offlinePlaylists.records.values.contains {
            OfflinePlaylistStatus.status(for: $0).isActive
        }

        return offlineStore.storageUsage.totalBytes > 0
            || offlineStore.downloadedTrackCount > 0
            || !offlineStore.downloadingTrackIDs.isEmpty
            || !offlinePlaylists.records.isEmpty
            || hasActivePlaylist
    }

    /// Stable signature of the storage/playlist state. When content appears
    /// after a completed deletion the row returns to the active idle state.
    private var deleteAllContentSnapshot: String {
        [
            String(offlineStore.storageUsage.totalBytes),
            String(offlineStore.downloadedTrackCount),
            String(offlineStore.downloadingTrackIDs.count),
            String(offlinePlaylists.records.count)
        ].joined(separator: ":")
    }

    @MainActor
    private func deleteAllSavedContent() async {
        deleteAllPhase = .deleting

        // First stop playlist orchestration.
        offlinePlaylists.removeAll()

        // Then cancel/block/wait/delete/unblock the shared queue.
        await offlineStore.removeAll()

        offlineStore.reconcile()
        offlinePlaylists.reconcileDownloads(with: offlineStore)

        let usage = offlineStore.storageUsage
        let remainingItems =
            offlineStore.downloadedTrackCount
            + offlinePlaylists.records.count

        if usage.totalBytes == 0,
           remainingItems == 0,
           offlineStore.downloadingTrackIDs.isEmpty {
            deleteAllPhase = .completed
            Haptics.success()
        } else {
            deleteAllPhase = .incomplete(
                remainingBytes: usage.totalBytes,
                remainingItems: remainingItems
            )
            Haptics.error()
        }
    }

    private var deleteAllIconColor: Color {
        switch deleteAllPhase {
        case .deleting:
            return .secondary
        case .completed:
            return .green
        case .incomplete:
            return .orange
        case .idle:
            return hasSavedOrActiveContent ? Color.red : Color.green
        }
    }

    private var deleteAllTitleColor: Color {
        // Typography stays monochrome in both supported themes. Destructive
        // intent is communicated by the icon, role and confirmation dialog.
        Color.primary
    }

    private func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: value,
            countStyle: .file
        )
    }

    private func usageColor(usage: StorageUsage) -> Color {
        if usage.usageRatio > 0.8 {
            return .red
        } else if usage.usageRatio > 0.5 {
            return .orange
        }
        return .green
    }
}

// MARK: - Sleep Timer

private struct SleepTimerSettingsView: View {
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        Form {
            Section {
                if let mode = player.sleepTimerMode {
                    if let endDate = player.sleepTimerEndDate {
                        LabeledContent(L10n.text("stops_at"),
                            value: endDate.formatted(
                                date: .omitted,
                                time: .shortened
                            )
                        )
                    } else {
                        LabeledContent(L10n.text("stops_at"),
                            value: mode.statusLabel
                        )
                    }
                    Button(L10n.text("cancel_timer"),
                        role: .destructive
                    ) {
                        player.cancelSleepTimer()
                    }
                } else {
                    Menu(L10n.text("stop_playback_in")) {
                        Button(L10n.text("sleep.end_of_track")) {
                            player.scheduleSleepTimer(.endOfTrack)
                        }
                        Button(L10n.text("sleep.end_of_queue")) {
                            player.scheduleSleepTimer(.endOfQueue)
                        }
                        ForEach(
                            [15, 30, 45, 60, 90],
                            id: \.self
                        ) { minutes in
                            Button(L10n.minutes(minutes)) {
                                player.scheduleSleepTimer(
                                    minutes: minutes
                                )
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle(L10n.text("sleep_timer"))
    }
}

// MARK: - Connection

private struct ConnectionSettingsView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(NetworkMonitor.self) private var networkMonitor
    @Environment(AppEnvironment.self) private var environment
    @State private var isRefreshing = false
    @State private var refreshError: String?

    var body: some View {
        Form {
            Section(L10n.text("network")) {
                HStack(spacing: 12) {
                    Text(L10n.text("settings.status"))
                    Spacer(minLength: 16)
                    Label(
                        networkTitle,
                        systemImage: networkIcon
                    )
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(networkTint)
                }
                .padding(.vertical, 2)
            }

            Section(L10n.text("vk_session")) {
                LabeledContent(
                    L10n.text("session_label"),
                    value: sessionTitle
                )
                if let expiresAt = sessionStore.session?
                    .expiresAt {
                    LabeledContent(L10n.text("token_expires"),
                        value: expiresAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                }
                Button {
                    refreshSession()
                } label: {
                    HStack {
                        Label(L10n.text("action.refresh"),
                            systemImage: "arrow.clockwise"
                        )
                        if isRefreshing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isRefreshing)
                if let refreshError {
                    Text(refreshError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Text(
                    L10n.text("the_saved_session_remains_in_the_system_keychain_during_temporary_outage")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle(L10n.text("connection"))
    }

    private func refreshSession() {
        guard !isRefreshing,
              sessionStore.session?.canRefresh == true else { return }
        isRefreshing = true
        refreshError = nil
        Task {
            do {
                _ = try await environment.recoverSession()
                refreshError = nil
            } catch {
                refreshError = error.localizedDescription
            }
            isRefreshing = false
        }
    }

    private var networkTitle: String {
        guard networkMonitor.state != .offline else {
            return L10n.text("offline")
        }
        switch networkMonitor.transport {
        case .wifi:
            return L10n.text("connected_via_wi_fi")
        case .cellular:
            return L10n.text("connected_via_cellular")
        case .wired:
            return L10n.text("connected_via_ethernet")
        case .other:
            return L10n.text("connected")
        case .unavailable:
            return L10n.text("offline")
        }
    }

    private var networkIcon: String {
        guard networkMonitor.state != .offline else {
            return "wifi.slash"
        }
        switch networkMonitor.transport {
        case .wifi:
            return "wifi"
        case .cellular:
            return "cellularbars"
        case .wired:
            return "network"
        case .other:
            return "network"
        case .unavailable:
            return "wifi.slash"
        }
    }

    private var networkTint: Color {
        networkMonitor.state == .offline ? .orange : .green
    }

    private var sessionTitle: String {
        guard let session = sessionStore.session else {
            return L10n.text("not_connected")
        }
        if session.needsRefresh {
            return session.canRefresh
                ? L10n.text(
                    "automatic_refresh_available"
                )
                : L10n.text(
                    "sign_in_required_to_refresh"
                )
        }
        return session.canRefresh
            ? L10n.text(
                "connected_automatic_refresh_available"
            )
            : L10n.text("connected_2")
    }
}

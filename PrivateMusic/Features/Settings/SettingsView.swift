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
                    title: L10n.text("Все сохранённые файлы удалены"),
                    subtitle: L10n.text("Готово"),
                    systemImage: "checkmark.circle.fill",
                    isEnabled: false,
                    showsProgress: false
                )
            }
            return OfflineDeleteAllPresentation(
                title: L10n.text("Удалить все сохранённые"),
                subtitle: L10n.format(
                    "%d файлов · %@",
                    downloadedTrackCount,
                    formattedBytes(totalBytes)
                ),
                systemImage: "trash",
                isEnabled: true,
                showsProgress: false
            )
        case .deleting:
            return OfflineDeleteAllPresentation(
                title: L10n.text("Удаляем сохранённые файлы…"),
                subtitle: L10n.text(
                    "Останавливаем загрузки и очищаем хранилище."
                ),
                systemImage: "trash",
                isEnabled: false,
                showsProgress: true
            )
        case .completed:
            return OfflineDeleteAllPresentation(
                title: L10n.text("Все сохранённые файлы удалены"),
                subtitle: L10n.text("Готово"),
                systemImage: "checkmark.circle.fill",
                isEnabled: false,
                showsProgress: false
            )
        case let .incomplete(remainingBytes, remainingItems):
            return OfflineDeleteAllPresentation(
                title: L10n.text("Удалено не всё"),
                subtitle: L10n.format(
                    "Осталось: %d объектов · %@",
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
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var offlineStore: OfflineTrackStore

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    Label(
                        "Оформление",
                        systemImage: "paintpalette"
                    )
                }

                NavigationLink {
                    PlayerAudioSettingsView()
                } label: {
                    Label(
                        "Плеер и аудио",
                        systemImage: "waveform"
                    )
                }

                NavigationLink {
                    EqualizerSettingsView()
                } label: {
                    Label(
                        "Эквалайзер",
                        systemImage: "slider.horizontal.3"
                    )
                }

                if OfflineDownloadsFeature.showsControls,
                   !environment.isShareSessionActive {
                    NavigationLink {
                        OfflineStorageSettingsView()
                    } label: {
                        Label(
                            "Офлайн и хранилище",
                            systemImage: "externaldrive"
                        )
                    }
                }

                NavigationLink {
                    SleepTimerSettingsView()
                } label: {
                    Label(
                        "Таймер сна",
                        systemImage: "moon.zzz"
                    )
                }

                NavigationLink {
                    ConnectionSettingsView()
                } label: {
                    Label(
                        "Подключение",
                        systemImage: "network"
                    )
                }
            }

            Section("О приложении") {
                LabeledContent("Приложение", value: "Private Music")
                LabeledContent("Версия", value: version)
                LabeledContent("Разработчик", value: "decoder-dev")
                LabeledContent(
                    "Аналитика",
                    value: L10n.text("Не используется")
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle("Настройки")
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
}

// MARK: - Appearance

private struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Тема") {
                themePicker
            }

            Section("Масштаб текста") {
                Picker(
                    "Масштаб",
                    selection: $settings.textScale
                ) {
                    ForEach(AppTextScale.allCases) { scale in
                        Text("\(scale.title) · \(scale.subtitle)")
                            .tag(scale)
                    }
                }

                HStack {
                    Text("Пример")
                        .font(.headline)
                    Spacer()
                    Text(settings.textScale.subtitle)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button("Сбросить оформление") {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        settings.resetAppearance()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle("Оформление")
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
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(
                    isOn: $settings.resumeOnBluetoothConnection
                ) {
                    Label(
                        "Продолжать при подключении Bluetooth",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                }
                Text(
                    L10n.text(
                        "Если в очереди есть текущий трек, приложение "
                            + "возобновит воспроизведение после подключения "
                            + "совместимых наушников или колонки."
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Toggle(
                    isOn: $settings.pauseAtMinimumVolume
                ) {
                    Label(
                        "Пауза при минимальной громкости",
                        systemImage: "speaker.slash"
                    )
                }
                Text(
                    L10n.text(
                        "При снижении системной громкости до нуля "
                            + "воспроизведение приостанавливается на текущей "
                            + "позиции."
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Toggle(
                    isOn: $settings.advanceOnPlaybackError
                ) {
                    Label(
                        "Пропускать недоступный трек",
                        systemImage: "forward.end"
                    )
                }
                Text(
                    L10n.text(
                        "Если VK не смог обновить аудиопоток, плеер продолжит "
                            + "очередь со следующей песни."
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Пространственный звук") {
                Toggle(
                    isOn: $settings.spatialAudioEnabled
                ) {
                    Label(
                        "Расширенная стереосцена",
                        systemImage: "airpodspro"
                    )
                }

                VStack(spacing: 8) {
                    HStack {
                        Text("Интенсивность")
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
                    L10n.text(
                        "Расширяет стереосцену обычных треков. "
                            + "Эффект лучше всего слышен в наушниках."
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle("Плеер и аудио")
    }
}

// MARK: - Equalizer

private struct EqualizerSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    private let frequencies = [
        "31", "62", "125", "250", "500",
        "1K", "2K", "4K", "8K", "16K"
    ]

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Обработка звука",
                    isOn: $settings.equalizerEnabled
                )
            }

            Section("Профиль") {
                Picker(
                    "Профиль",
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

            Section("Предусилитель") {
                VStack(spacing: 5) {
                    HStack {
                        Text("Уровень")
                        Spacer()
                        Text(
                            settings.equalizerPreamp,
                            format: .number.precision(
                                .fractionLength(1)
                            )
                        )
                        Text("дБ")
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

            Section("Полосы частот") {
                ForEach(frequencies.indices, id: \.self) { index in
                    VStack(spacing: 5) {
                        HStack {
                            Text(
                                L10n.format(
                                    "%@ Гц",
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
                            Text("дБ")
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
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle("Эквалайзер")
    }
}

// MARK: - Offline & Storage

private struct OfflineStorageSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var offlineStore: OfflineTrackStore
    @ObservedObject private var offlinePlaylists =
        OfflinePlaylistStore.shared
    @State private var deleteAllPhase: OfflineDeleteAllPhase = .idle
    @State private var showsDeleteAllConfirmation = false

    var body: some View {
        let usage = offlineStore.storageUsage
        Form {
            Section("Хранилище") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(
                            "Использовано",
                            systemImage: "externaldrive"
                        )
                        Spacer()
                        Text(
                            L10n.format(
                                "%@ / %d ГБ",
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
                            Label(
                                "Пусто",
                                systemImage: "tray"
                            )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(
                            "Лимит",
                            systemImage: "internaldrive"
                        )
                        Spacer()
                        Text(
                            L10n.format(
                                "%d ГБ",
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
                            "%d ГБ",
                            settings.offlineStorageLimitGB
                        )
                    )

                    HStack {
                        Text(
                            L10n.format(
                                "%d ГБ",
                                AppSettings
                                    .minimumOfflineStorageLimitGB
                            )
                        )
                        Spacer()
                        Text(
                            L10n.format(
                                "%d ГБ",
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
                Section("Автокэширование") {
                    Toggle(
                        isOn: $settings.automaticOfflineCacheEnabled
                    ) {
                        Label(
                            "Автокэширование",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }

                    Text(
                        L10n.text(
                            "Прослушанные треки автоматически "
                                + "сохраняются для повторного "
                                + "воспроизведения без интернета. "
                                + "При заполнении хранилища старый "
                                + "автокэш очищается первым; ручные "
                                + "загрузки сохраняются."
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Управление") {
                if offlineStore.automaticCacheByteCount > 0 {
                    Button("Очистить автокэш", role: .destructive) {
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
        .navigationTitle("Офлайн и хранилище")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            L10n.text("Удалить все сохранённые файлы?"),
            isPresented: $showsDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                L10n.text("Удалить всё"),
                role: .destructive
            ) {
                Task {
                    await deleteAllSavedContent()
                }
            }
            Button(L10n.text("Отмена"), role: .cancel) {}
        } message: {
            Text(
                L10n.text(
                    "Будут остановлены текущие загрузки и удалены "
                        + "скачанные треки, плейлисты и автокэш. "
                        + "Музыка в VK не изменится."
                )
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
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        Form {
            Section {
                if let endDate = player.sleepTimerEndDate {
                    LabeledContent(
                        "Остановка",
                        value: endDate.formatted(
                            date: .omitted,
                            time: .shortened
                        )
                    )
                    Button(
                        "Отключить таймер",
                        role: .destructive
                    ) {
                        player.cancelSleepTimer()
                    }
                } else {
                    Menu("Остановить воспроизведение через…") {
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
        .navigationTitle("Таймер сна")
    }
}

// MARK: - Connection

private struct ConnectionSettingsView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var environment: AppEnvironment
    @State private var isRefreshing = false
    @State private var refreshError: String?

    var body: some View {
        Form {
            Section("Сеть") {
                HStack(spacing: 12) {
                    Text("Статус")
                    Spacer(minLength: 16)
                    Label(
                        networkTitle,
                        systemImage: networkIcon
                    )
                    .lineLimit(1)
                    .foregroundStyle(networkTint)
                }
                .padding(.vertical, 2)
            }

            Section("Сессия VK") {
                LabeledContent(
                    "Сессия",
                    value: sessionTitle
                )
                if let expiresAt = sessionStore.session?
                    .expiresAt {
                    LabeledContent(
                        "Срок действия токена",
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
                        Label(
                            "Обновить",
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
                    L10n.text(
                        "При временном обрыве сети сохранённая "
                            + "сессия остаётся в системном Keychain. "
                            + "Если VK принимает данные веб-сессии, "
                            + "приложение попробует обновить "
                            + "подключение автоматически."
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle("Подключение")
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
            return L10n.text("Нет подключения")
        }
        switch networkMonitor.transport {
        case .wifi:
            return L10n.text("Wi‑Fi доступен")
        case .cellular:
            return L10n.text("Мобильная сеть")
        case .wired:
            return L10n.text("Проводная сеть")
        case .other:
            return L10n.text("Сеть доступна")
        case .unavailable:
            return L10n.text("Нет подключения")
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
            return L10n.text("Не подключена")
        }
        if session.needsRefresh {
            return session.canRefresh
                ? L10n.text(
                    "Доступно автоматическое обновление"
                )
                : L10n.text(
                    "Для обновления потребуется повторный вход"
                )
        }
        return session.canRefresh
            ? L10n.text(
                "Подключена · доступно автообновление"
            )
            : L10n.text("Подключена")
    }
}

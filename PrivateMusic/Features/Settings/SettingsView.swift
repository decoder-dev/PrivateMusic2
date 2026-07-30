import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor

    private let frequencies = [
        "31", "62", "125", "250", "500",
        "1K", "2K", "4K", "8K", "16K"
    ]

    var body: some View {
        Form {
            Section("Оформление") {
                themePicker

                Picker("Масштаб текста", selection: $settings.textScale) {
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

            Section("Плеер и аудио") {
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

            Section("Эквалайзер") {
                Toggle(
                    "Обработка звука",
                    isOn: $settings.equalizerEnabled
                )

                Picker(
                    "Профиль эквалайзера",
                    selection: Binding(
                        get: { settings.equalizerPreset },
                        set: { settings.selectPreset($0) }
                    )
                ) {
                    ForEach(EqualizerPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }

                VStack(spacing: 5) {
                    HStack {
                        Text("Предусилитель")
                        Spacer()
                        Text(
                            settings.equalizerPreamp,
                            format: .number.precision(.fractionLength(1))
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

            Section("Таймер сна") {
                if let endDate = player.sleepTimerEndDate {
                    LabeledContent(
                        "Остановка",
                        value: endDate.formatted(
                            date: .omitted,
                            time: .shortened
                        )
                    )
                    Button("Отключить таймер", role: .destructive) {
                        player.cancelSleepTimer()
                    }
                } else {
                    Menu("Остановить воспроизведение через…") {
                        ForEach([15, 30, 45, 60, 90], id: \.self) {
                            minutes in
                            Button(L10n.minutes(minutes)) {
                                player.scheduleSleepTimer(
                                    minutes: minutes
                                )
                            }
                        }
                    }
                }
            }

            Section("Подключение") {
                HStack(spacing: 12) {
                    Text("Сеть")
                    Spacer(minLength: 16)
                    Label(
                        networkTitle,
                        systemImage: networkIcon
                    )
                    .lineLimit(1)
                    .foregroundStyle(networkTint)
                }
                .padding(.vertical, 2)
                LabeledContent("Сессия VK", value: sessionTitle)
                if let expiresAt = sessionStore.session?.expiresAt {
                    LabeledContent(
                        "Срок действия токена",
                        value: expiresAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                }
                Text(
                    L10n.text(
                        "При временном обрыве сети сохранённая сессия остаётся "
                            + "в системном Keychain. Если VK принимает данные "
                            + "веб-сессии, приложение попробует обновить "
                            + "подключение автоматически."
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                ? L10n.text("Доступно автоматическое обновление")
                : L10n.text("Для обновления потребуется повторный вход")
        }
        return session.canRefresh
            ? L10n.text("Подключена · доступно автообновление")
            : L10n.text("Подключена")
    }

    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Тема")
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
                                            .font(.headline)
                                            .foregroundStyle(
                                                theme.buttonForeground
                                            )
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
        }
        .padding(.vertical, 4)
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

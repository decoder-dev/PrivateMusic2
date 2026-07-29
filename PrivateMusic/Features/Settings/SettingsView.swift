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

                Toggle(
                    "Liquid Glass",
                    isOn: $settings.liquidGlassEnabled
                )
                Text(
                    "На iOS 26 используется системное интерактивное стекло. "
                    + "На iOS 16–25 — совместимый material-эффект."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Button("Сбросить оформление") {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        settings.resetAppearance()
                    }
                }
            }

            Section("Эквалайзер") {
                Toggle(
                    "Обработка звука",
                    isOn: $settings.equalizerEnabled
                )

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
                            Text("\(frequencies[index]) Гц")
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
                            Button("\(minutes) мин") {
                                player.scheduleSleepTimer(
                                    minutes: minutes
                                )
                            }
                        }
                    }
                }
            }

            Section("Подключение") {
                LabeledContent("Сеть") {
                    Label(
                        networkTitle,
                        systemImage: networkIcon
                    )
                    .foregroundStyle(networkTint)
                }
                LabeledContent("Сессия VK", value: sessionTitle)
                if let expiresAt = sessionStore.session?.expiresAt {
                    LabeledContent(
                        "Обновление до",
                        value: expiresAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                }
                Text(
                    "При обрыве сети сессия не удаляется. "
                        + "Подключение восстанавливается автоматически, "
                        + "а данные входа остаются в системном Keychain."
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
                    value: "Отключена"
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle("Настройки")
    }

    private var networkTitle: String {
        switch networkMonitor.state {
        case .online:
            return "Доступна"
        case .constrained:
            return "Мобильная или ограниченная"
        case .offline:
            return "Нет подключения"
        }
    }

    private var networkIcon: String {
        networkMonitor.state == .offline ? "wifi.slash" : "wifi"
    }

    private var networkTint: Color {
        networkMonitor.state == .offline ? .orange : .green
    }

    private var sessionTitle: String {
        guard let session = sessionStore.session else {
            return "Не подключена"
        }
        if session.needsRefresh {
            return session.canRefresh
                ? "Автовосстановление включено"
                : "Требуется повторный вход"
        }
        return session.canRefresh
            ? "Подключена · автообновление"
            : "Подключена"
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

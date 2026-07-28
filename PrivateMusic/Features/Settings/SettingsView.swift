import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer

    private let frequencies = ["60", "230", "910", "4K", "14K"]

    var body: some View {
        Form {
            Section("Оформление") {
                themePicker

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

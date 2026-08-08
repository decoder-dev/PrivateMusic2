import SwiftUI

struct MixFiltersSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker(
                    L10n.text("Настроение"),
                    selection: $settings.mixMoodPreference
                ) {
                    ForEach(MixMoodPreference.allCases) { mood in
                        Text(mood.title).tag(mood)
                    }
                }
                Picker(
                    L10n.text("Язык"),
                    selection: $settings.mixLanguagePreference
                ) {
                    ForEach(MixLanguagePreference.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                Picker(
                    L10n.text("Узнаваемость"),
                    selection: $settings.mixFamiliarityPreference
                ) {
                    ForEach(MixFamiliarityPreference.allCases) { familiarity in
                        Text(familiarity.title).tag(familiarity)
                    }
                }
            } footer: {
                Text(
                    L10n.text(
                        "Как фильтры VK Микса: применяются к очереди микса "
                            + "и рекомендациям на устройстве. Серверные "
                            + "параметры VK для этого не задокументированы."
                    )
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle(L10n.text("Фильтры микса"))
    }
}

import SwiftUI

struct MixFiltersSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker(
                    L10n.text("mood"),
                    selection: $settings.mixMoodPreference
                ) {
                    ForEach(MixMoodPreference.allCases) { mood in
                        Text(mood.title).tag(mood)
                    }
                }
                Picker(
                    L10n.text("language"),
                    selection: $settings.mixLanguagePreference
                ) {
                    ForEach(MixLanguagePreference.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                Picker(
                    L10n.text("familiarity"),
                    selection: $settings.mixFamiliarityPreference
                ) {
                    ForEach(MixFamiliarityPreference.allCases) { familiarity in
                        Text(familiarity.title).tag(familiarity)
                    }
                }
            } footer: {
                Text(
                    L10n.text("like_vk_mix_filters_they_apply_to_the_mix_queue_and_to_recommendations_o")
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle(L10n.text("mix_filters"))
    }
}

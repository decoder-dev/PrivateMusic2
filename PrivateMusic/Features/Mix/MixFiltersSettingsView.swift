import SwiftUI

/// Settings destination — language and familiarity filters for VK mixes.
struct MixFiltersSettingsView: View {
    var body: some View {
        MixConfigureContent(scope: .all, showsStartAction: false)
            .background(ThemeBackground())
            .navigationTitle(L10n.text("mix_filters"))
            .navigationBarTitleDisplayMode(.inline)
    }
}

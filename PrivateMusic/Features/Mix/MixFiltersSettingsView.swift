import SwiftUI

/// Settings destination — Selena wave dial + basic catalog-mix filters.
struct MixFiltersSettingsView: View {
    var body: some View {
        MixConfigureContent(scope: .all, showsStartAction: false)
            .background(ThemeBackground())
            .navigationTitle(L10n.text("mix_filters"))
            .navigationBarTitleDisplayMode(.inline)
    }
}

import SwiftUI

/// Settings destination for mix filters — same chip dial as the Explore
/// sheet, pushed in the settings stack (no nested NavigationStack, no
/// "start mix" CTA).
struct MixFiltersSettingsView: View {
    var body: some View {
        MixConfigureContent(showsStartAction: false)
            .background(ThemeBackground())
            .navigationTitle(L10n.text("mix_filters"))
            .navigationBarTitleDisplayMode(.inline)
    }
}

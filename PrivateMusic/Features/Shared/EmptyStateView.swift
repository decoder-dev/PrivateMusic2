import SwiftUI

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String
    var titleIsLocalizedKey = true
    var descriptionIsLocalizedKey = true

    var body: some View {
        AppStatusPanel(
            title: title,
            systemImage: systemImage,
            description: description,
            titleIsLocalizedKey: titleIsLocalizedKey,
            descriptionIsLocalizedKey: descriptionIsLocalizedKey
        )
        .accessibilityElement(children: .combine)
    }
}

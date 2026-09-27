import SwiftUI

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String
    var titleIsLocalizedKey = true
    var descriptionIsLocalizedKey = true
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        AppStatusPanel(
            title: title,
            systemImage: systemImage,
            description: description,
            titleIsLocalizedKey: titleIsLocalizedKey,
            descriptionIsLocalizedKey: descriptionIsLocalizedKey,
            actionTitle: actionTitle,
            action: action
        )
        .accessibilityElement(children: .contain)
    }
}

import SwiftUI

/// Keep category names inside the viewport. Intrinsic label sizes decide
/// between one row, two columns and a stack; no horizontal clipping or
/// shrinking of text is needed. Accessibility sizes use the native menu.
struct AdaptiveCategoryPicker<Value: Hashable>: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let items: [Value]
    let title: (Value) -> String
    let label: String
    @Binding var selection: Value

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker(label, selection: $selection) {
                ForEach(items, id: \.self) { item in
                    Text(title(item)).tag(item)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, minHeight: PremiumLayout.minimumTapTarget, alignment: .leading)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.self) { button($0) }
                }
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { index in
                        GridRow {
                            button(items[index])
                            if index + 1 < items.count { button(items[index + 1]) }
                        }
                    }
                }
                VStack(spacing: 8) {
                    ForEach(items, id: \.self) { button($0) }
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
        }
    }

    private func button(_ item: Value) -> some View {
        Button { selection = item } label: {
            Text(title(item))
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: true, vertical: true)
                .foregroundStyle(selection == item ? settings.onAccent : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: PremiumLayout.minimumTapTarget)
                .background(selection == item ? settings.accent : Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(PremiumPressStyle())
        .accessibilityAddTraits(selection == item ? .isSelected : [])
    }
}

import SwiftUI

/// Shared single-row navigation. Full labels either fit together or move
/// into a compact menu; categories never wrap into a second row.
struct AdaptiveCategoryPicker<Value: Hashable>: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let items: [Value]
    let title: (Value) -> String
    let label: String
    @Binding var selection: Value

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                categoryMenu
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        ForEach(items, id: \.self) { button($0) }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    categoryMenu
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var categoryMenu: some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach(items, id: \.self) { item in
                    Text(title(item)).tag(item)
                }
            }
        } label: {
            HStack(spacing: BubbleSpacing.s) {
                Text(title(selection))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: BubbleSpacing.s)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, BubbleSpacing.m)
            .padding(.vertical, BubbleSpacing.s)
            .frame(maxWidth: .infinity, minHeight: PremiumLayout.minimumTapTarget)
            .background(Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: PremiumLayout.controlRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(PremiumPressStyle())
        .accessibilityLabel(label)
        .accessibilityValue(title(selection))
    }

    private func button(_ item: Value) -> some View {
        Button { selection = item } label: {
            Text(title(item))
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: true, vertical: true)
                .foregroundStyle(selection == item ? settings.accent : .secondary)
                .padding(.horizontal, BubbleSpacing.s)
                .frame(minWidth: PremiumLayout.minimumTapTarget, minHeight: PremiumLayout.minimumTapTarget)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(selection == item ? settings.accent : .clear)
                        .frame(height: 2)
                        .padding(.horizontal, BubbleSpacing.s)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PremiumPressStyle())
        .accessibilityAddTraits(selection == item ? .isSelected : [])
    }
}

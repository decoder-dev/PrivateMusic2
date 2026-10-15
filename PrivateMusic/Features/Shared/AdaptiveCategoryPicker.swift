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
            CategoryGridLayout {
                ForEach(items, id: \.self) { button($0) }
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

/// Measure the actual localized labels before assigning equal-width cells.
/// A flexible container alone can report a fitting width while its text
/// still overflows; require the full intrinsic width of every button.
private struct CategoryGridLayout: Layout {
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let plan = metrics(width: proposal.width, subviews: subviews)
        return CGSize(width: plan.width, height: plan.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = metrics(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index % plan.columns) * (plan.cellWidth + spacing),
                                     y: bounds.minY + CGFloat(index / plan.columns) * (plan.cellHeight + spacing)),
                          anchor: .topLeading, proposal: ProposedViewSize(width: plan.cellWidth, height: plan.cellHeight))
        }
    }

    private func metrics(width proposed: CGFloat?, subviews: Subviews) ->
        (width: CGFloat, height: CGFloat, columns: Int, cellWidth: CGFloat, cellHeight: CGFloat) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let minimumWidth = ideal.map(\.width).max() ?? 0
        let naturalWidth = CGFloat(subviews.count) * minimumWidth + CGFloat(max(0, subviews.count - 1)) * spacing
        let width = proposed.flatMap { $0.isFinite ? max(0, $0) : nil } ?? naturalWidth
        var columns = 1
        for candidate in [4, 2] where candidate <= subviews.count {
            let contentWidth = CGFloat(candidate) * minimumWidth
            let gapWidth = CGFloat(candidate - 1) * spacing
            if contentWidth + gapWidth <= width {
                columns = candidate
                break
            }
        }
        let cellWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let cellHeight = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height
        }.max() ?? 0
        let rows = (subviews.count + columns - 1) / columns
        return (width, CGFloat(rows) * cellHeight + CGFloat(max(0, rows - 1)) * spacing,
                columns, cellWidth, cellHeight)
    }
}

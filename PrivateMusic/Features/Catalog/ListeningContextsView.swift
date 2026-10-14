import SwiftUI

struct ListeningContextsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(HomeCatalogStore.self) private var catalog
    @Environment(SessionStore.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let tuning: MixTuning?
    @State private var starting: ListeningContext?
    @State private var launchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: BubbleSpacing.m) {
            Text(L10n.text("context.title")).font(BubbleType.section)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 260 : 140))],
                      alignment: .leading, spacing: BubbleSpacing.m) {
                ForEach(ListeningContext.allCases) { context in
                    let selection = context.selection(tuning: tuning, mixes: catalog.mixes)
                    Button { start(context, selection: selection) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: context.symbol).font(.title3).foregroundStyle(settings.accent)
                                Spacer()
                                if starting == context { ProgressView().controlSize(.small) }
                            }
                            Text(context.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(selection.detail).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(BubbleSpacing.m)
                        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PremiumPressStyle())
                    .disabled(starting != nil)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .onChange(of: session.resolvedOfflineAccountID) { _, _ in
            launchTask?.cancel(); starting = nil
        }
    }

    private func start(_ context: ListeningContext, selection: ListeningContextSelection) {
        guard starting == nil else { return }
        starting = context
        launchTask = Task {
            switch selection {
            case .tuned(let mix), .catalog(let mix): await environment.startCatalogMix(mix)
            case .mood(let mood): await environment.startMoodStation(mood, in: catalog.mixes)
            }
            if !Task.isCancelled { starting = nil }
        }
    }
}

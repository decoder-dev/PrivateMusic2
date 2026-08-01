import SwiftUI
import UIKit

@MainActor
final class TrackShareViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing(TrackExportProgress)
        case ready(TrackSharePayload)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var task: Task<Void, Never>?
    private var payload: TrackSharePayload?
    private var generation = UUID()

    var isWorking: Bool {
        if case .preparing = state { return true }
        return false
    }

    func start(
        track: Track,
        environment: any TrackSharePreparing
    ) {
        generation = UUID()
        let operationID = generation
        task?.cancel()
        cleanupPayload(using: environment)
        state = .preparing(.resolvingSource)

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let prepared = try await environment.prepareSharePayload(
                    for: track
                ) { [weak self] progress in
                    guard let self,
                          self.generation == operationID else {
                        return
                    }
                    self.state = .preparing(progress)
                }

                guard !Task.isCancelled,
                      generation == operationID else {
                    await environment.removeSharePayload(prepared)
                    return
                }

                payload = prepared
                state = .ready(prepared)
            } catch is CancellationError {
                guard generation == operationID else { return }
                state = .idle
            } catch {
                guard generation == operationID else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel(environment: any TrackSharePreparing) {
        generation = UUID()
        task?.cancel()
        task = nil
        cleanupPayload(using: environment)
        state = .idle
    }

    func activityFinished(
        environment: any TrackSharePreparing
    ) {
        generation = UUID()
        task?.cancel()
        task = nil
        cleanupPayload(using: environment)
        state = .idle
    }

    func retry(
        track: Track,
        environment: any TrackSharePreparing
    ) {
        start(track: track, environment: environment)
    }

    /// Test seam: resolves when the current operation settles, so tests can
    /// assert state after a stale completion is ignored.
    func waitForCurrentOperation() async {
        await task?.value
    }

    private func cleanupPayload(
        using environment: any TrackSharePreparing
    ) {
        guard let payload else { return }
        self.payload = nil
        Task {
            await environment.removeSharePayload(payload)
        }
    }
}

// MARK: - Display helpers

extension TrackExportProgress {
    var fraction: Double? {
        switch self {
        case let .downloadingSegments(completed, total):
            guard total > 0 else { return nil }
            return min(max(Double(completed) / Double(total), 0), 1)
        default:
            return nil
        }
    }

    var title: String {
        switch self {
        case .resolvingSource:
            return L10n.text("Проверяем аудиофайл…")
        case .copyingLocalFile:
            return L10n.text("Подготавливаем сохранённый файл…")
        case .downloadingDirectFile:
            return L10n.text("Скачиваем аудиофайл…")
        case .downloadingSegments:
            return L10n.text("Собираем аудиопоток…")
        case .convertingToM4A:
            return L10n.text("Создаём файл M4A…")
        }
    }

    var detail: String? {
        switch self {
        case let .downloadingSegments(completed, total):
            return L10n.format("%d из %d частей", completed, total)
        default:
            return nil
        }
    }
}

// MARK: - Flow view

struct TrackShareFlowView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let track: Track
    @StateObject private var model = TrackShareViewModel()

    var body: some View {
        Group {
            switch model.state {
            case let .ready(payload):
                ActivityViewController(
                    activityItems: [payload.fileURL]
                ) { _ in
                    model.activityFinished(environment: environment)
                    dismiss()
                }
                .ignoresSafeArea()

            case let .preparing(progress):
                statusScreen(progress: progress)
                    .interactiveDismissDisabled()

            case let .failed(message):
                failureScreen(message: message)

            case .idle:
                statusScreen(progress: .resolvingSource)
            }
        }
        .task(id: track.id) {
            model.start(track: track, environment: environment)
        }
        .onDisappear {
            model.cancel(environment: environment)
        }
    }

    private func statusScreen(
        progress: TrackExportProgress
    ) -> some View {
        NavigationStack {
            VStack(spacing: 22) {
                AsyncArtwork(url: track.artworkURL, size: 112)

                VStack(spacing: 5) {
                    Text(track.title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(spacing: 10) {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                            .frame(maxWidth: 240)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                    }

                    Text(progress.title)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)

                    if let detail = progress.detail {
                        Text(detail)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Text(
                    L10n.text(
                        "После подготовки откроется стандартное меню iPhone. "
                            + "Выберите «Сохранить в Файлы», AirDrop, мессенджер "
                            + "или другое приложение."
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

                Button(role: .cancel) {
                    model.cancel(environment: environment)
                    dismiss()
                } label: {
                    Text(L10n.text("Отменить"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .navigationTitle(L10n.text("Поделиться файлом"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func failureScreen(message: String) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                EmptyStateView(
                    title: "Не удалось подготовить файл",
                    systemImage: "exclamationmark.triangle",
                    description: message
                )

                Button(L10n.text("Повторить")) {
                    model.retry(track: track, environment: environment)
                }
                .buttonStyle(.borderedProminent)

                Button(L10n.text("Закрыть"), role: .cancel) {
                    model.cancel(environment: environment)
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .navigationTitle(L10n.text("Поделиться файлом"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

// MARK: - System share sheet

struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    let completion: @MainActor (Bool) -> Void

    final class Coordinator: NSObject {
        let completion: @MainActor (Bool) -> Void
        var didFinish = false

        init(completion: @escaping @MainActor (Bool) -> Void) {
            self.completion = completion
        }

        func finish(_ completed: Bool) {
            guard !didFinish else { return }
            didFinish = true
            Task { @MainActor in
                completion(completed)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = {
            _, completed, _, _ in
            context.coordinator.finish(completed)
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

// MARK: - Modifier

private struct TrackShareSheetModifier: ViewModifier {
    @Binding var track: Track?

    func body(content: Content) -> some View {
        content.sheet(item: $track) { selectedTrack in
            TrackShareFlowView(track: selectedTrack)
        }
    }
}

extension View {
    func trackShareSheet(track: Binding<Track?>) -> some View {
        modifier(TrackShareSheetModifier(track: track))
    }
}

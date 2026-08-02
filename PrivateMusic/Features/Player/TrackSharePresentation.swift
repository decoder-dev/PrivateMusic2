import SwiftUI
import UIKit

struct TrackShareFailure: Equatable, Sendable {
    let title: String
    let message: String
    let diagnosticCode: String?
}

@MainActor
final class TrackShareViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing(TrackExportProgress)
        case ready(TrackSharePayload)
        case failed(TrackShareFailure)
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
                state = .failed(Self.failure(from: error))
            }
        }
    }

    private static func failure(from error: Error) -> TrackShareFailure {
        let baseTitle = L10n.text("Не удалось подготовить аудиофайл.")
        let nsError = error as NSError

        let baseMessage: String
        let code: String?

        switch error {
        case let diagnostic as HLSDiagnosticError:
            baseMessage = diagnostic.errorDescription
                ?? L10n.text("Не удалось подготовить аудиофайл.")
            code = diagnostic.publicCode
        case let exporterError as HLSExportError:
            baseMessage = exporterError.errorDescription
                ?? L10n.text("Не удалось подготовить аудиофайл.")
            code = nil
        case let apiError as APIError:
            baseMessage = apiError.errorDescription
                ?? L10n.text("Не удалось подготовить аудиофайл.")
            if apiError == .timedOut {
                code = "PM-NSURLErrorDomain--1001"
            } else {
                code = "VK-\(nsError.code)"
            }
        case let urlError as URLError where urlError.code == .timedOut:
            baseMessage = APIError.timedOut.errorDescription
                ?? L10n.text("Не удалось подготовить аудиофайл.")
            code = "PM-\(NSURLErrorDomain)-\(URLError.timedOut.rawValue)"
        default:
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorTimedOut {
                baseMessage = APIError.timedOut.errorDescription
                    ?? L10n.text("Не удалось подготовить аудиофайл.")
                code = "PM-\(nsError.domain)-\(nsError.code)"
            } else {
                baseMessage = L10n.text("Не удалось подготовить аудиофайл.")
                code = "PM-\(nsError.domain)-\(nsError.code)"
            }
        }

        return TrackShareFailure(
            title: baseTitle,
            message: baseMessage,
            diagnosticCode: code
        )
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
                // Keep a normal SwiftUI sheet host and present
                // UIActivityViewController from it. Embedding the activity
                // controller as the sheet root crashes on some iOS versions
                // (missing popover source / nested presentation).
                readyScreen(payload: payload)
                    .interactiveDismissDisabled()

            case let .preparing(progress):
                statusScreen(progress: progress)
                    .interactiveDismissDisabled()

            case let .failed(failure):
                failureScreen(failure: failure)

            case .idle:
                statusScreen(progress: .resolvingSource)
            }
        }
        .onAppear {
            environment.beginShareSession()
        }
        .task(id: track.id) {
            model.start(track: track, environment: environment)
        }
        .onDisappear {
            model.cancel(environment: environment)
            environment.endShareSession()
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

    private func readyScreen(payload: TrackSharePayload) -> some View {
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

                ProgressView()
                    .controlSize(.large)

                Text(L10n.text("Открываем меню «Поделиться»…"))
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)

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
            .background {
                ActivityViewController(activityItems: [payload.fileURL]) { _ in
                    model.activityFinished(environment: environment)
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func failureScreen(failure: TrackShareFailure) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                EmptyStateView(
                    title: failure.title,
                    systemImage: "exclamationmark.triangle",
                    description: failure.message
                )

                if let code = failure.diagnosticCode {
                    Button {
                        UIPasteboard.general.string = Self.errorReport(code: code)
                    } label: {
                        Label(
                            L10n.text("Скопировать код ошибки"),
                            systemImage: "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                }

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

    private static func errorReport(code: String) -> String {
        let marketing = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "unknown"
        return "Private Music \(marketing) (\(build))\n\(code)"
    }
}

// MARK: - System share sheet

/// Host that presents `UIActivityViewController` once. Using the activity
/// controller itself as a `UIViewControllerRepresentable` root inside a
/// SwiftUI `.sheet` is undefined on iPad (popover source) and has crashed
/// when SwiftUI swaps preparing → ready content.
struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    let completion: @MainActor (Bool) -> Void

    final class Coordinator: NSObject {
        let completion: @MainActor (Bool) -> Void
        var didPresent = false
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

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        return host
    }

    func updateUIViewController(
        _ uiViewController: UIViewController,
        context: Context
    ) {
        let coordinator = context.coordinator
        guard !coordinator.didPresent,
              uiViewController.presentedViewController == nil,
              uiViewController.view.window != nil
                || uiViewController.isViewLoaded else {
            return
        }

        let present = { [activityItems] in
            guard !coordinator.didPresent,
                  uiViewController.presentedViewController == nil else {
                return
            }
            coordinator.didPresent = true

            let activity = UIActivityViewController(
                activityItems: activityItems,
                applicationActivities: nil
            )
            activity.completionWithItemsHandler = {
                _, completed, _, _ in
                coordinator.finish(completed)
            }
            if let popover = activity.popoverPresentationController {
                let view = uiViewController.view!
                popover.sourceView = view
                popover.sourceRect = CGRect(
                    x: view.bounds.midX,
                    y: view.bounds.midY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
            uiViewController.present(activity, animated: true)
        }

        if uiViewController.view.window != nil {
            DispatchQueue.main.async(execute: present)
        } else {
            DispatchQueue.main.async {
                DispatchQueue.main.async(execute: present)
            }
        }
    }
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

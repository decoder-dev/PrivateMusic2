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

    /// Transfers ownership of the prepared file out of the view model so the
    /// preparing sheet can dismiss without deleting it. The caller must
    /// remove the payload after the system share sheet finishes.
    func takePayloadForSystemShare() -> TrackSharePayload? {
        let value = payload
        payload = nil
        generation = UUID()
        task?.cancel()
        task = nil
        state = .idle
        return value
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
    /// Clears the parent `.sheet(item:)` binding after a successful hand-off.
    var onHandedOff: (() -> Void)? = nil

    @StateObject private var model = TrackShareViewModel()
    @State private var didHandOffToSystemShare = false

    var body: some View {
        Group {
            switch model.state {
            case .ready:
                // Brief placeholder while we dismiss this sheet and present
                // UIActivityViewController from the UIKit root.
                statusScreen(progress: .convertingToM4A)
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
        .onChange(of: model.state) { newState in
            guard case .ready = newState else { return }
            handOffToSystemShare()
        }
        .onDisappear {
            if !didHandOffToSystemShare {
                model.cancel(environment: environment)
            }
            environment.endShareSession()
        }
    }

    private func handOffToSystemShare() {
        guard !didHandOffToSystemShare else { return }
        guard let payload = model.takePayloadForSystemShare() else { return }
        didHandOffToSystemShare = true

        SystemSharePresenter.dismissPresentedThenShare(
            fileURL: payload.fileURL,
            onPreparationDismissed: {
                onHandedOff?()
            },
            completion: { _ in
                Task {
                    await environment.removeSharePayload(payload)
                }
            }
        )
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

// MARK: - UIKit system share

/// Presents `UIActivityViewController` from the real UIKit presenter after
/// dismissing any preparation sheet. Embedding the activity controller inside
/// a SwiftUI `.sheet` (as root or via `.background`) has crashed on device.
enum SystemSharePresenter {
    @MainActor
    static func dismissPresentedThenShare(
        fileURL: URL,
        onPreparationDismissed: (() -> Void)? = nil,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let top = topViewController() else {
            onPreparationDismissed?()
            completion(false)
            return
        }

        if let presenter = top.presentingViewController {
            presenter.dismiss(animated: true) {
                onPreparationDismissed?()
                presentActivity(
                    from: presenter,
                    fileURL: fileURL,
                    completion: completion
                )
            }
            return
        }

        // No UIKit presenter relationship (unusual SwiftUI hosting). Clear
        // the sheet binding and wait for tear-down before presenting.
        onPreparationDismissed?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            let host = topViewController() ?? top
            presentActivity(
                from: host,
                fileURL: fileURL,
                completion: completion
            )
        }
    }

    @MainActor
    private static func presentActivity(
        from presenter: UIViewController,
        fileURL: URL,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        // If something is still presented (SwiftUI tear-down lag), wait one
        // run-loop turn and try the current top-most controller instead.
        if presenter.presentedViewController != nil {
            DispatchQueue.main.async {
                let host = topViewController() ?? presenter
                if host.presentedViewController != nil {
                    host.dismiss(animated: true) {
                        presentActivityNow(
                            from: host,
                            fileURL: fileURL,
                            completion: completion
                        )
                    }
                } else {
                    presentActivityNow(
                        from: host,
                        fileURL: fileURL,
                        completion: completion
                    )
                }
            }
            return
        }

        presentActivityNow(
            from: presenter,
            fileURL: fileURL,
            completion: completion
        )
    }

    @MainActor
    private static func presentActivityNow(
        from presenter: UIViewController,
        fileURL: URL,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let activity = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
        activity.completionWithItemsHandler = { _, completed, _, _ in
            Task { @MainActor in
                completion(completed)
            }
        }

        if let popover = activity.popoverPresentationController {
            let view = presenter.view
            popover.sourceView = view
            popover.sourceRect = CGRect(
                x: view.bounds.midX,
                y: view.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }

        presenter.present(activity, animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        let window = windows.first(where: \.isKeyWindow) ?? windows.first
        guard let root = window?.rootViewController else { return nil }

        var top = root
        while true {
            if let presented = top.presentedViewController {
                top = presented
                continue
            }
            if let nav = top as? UINavigationController,
               let visible = nav.visibleViewController {
                top = visible
                continue
            }
            if let tab = top as? UITabBarController,
               let selected = tab.selectedViewController {
                top = selected
                continue
            }
            break
        }
        return top
    }
}

// MARK: - Modifier

private struct TrackShareSheetModifier: ViewModifier {
    @Binding var track: Track?

    func body(content: Content) -> some View {
        content.sheet(item: $track) { selectedTrack in
            TrackShareFlowView(track: selectedTrack) {
                track = nil
            }
        }
    }
}

extension View {
    func trackShareSheet(track: Binding<Track?>) -> some View {
        modifier(TrackShareSheetModifier(track: track))
    }
}

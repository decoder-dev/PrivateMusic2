import SwiftUI
import UIKit

struct TrackShareFailure: Equatable, Sendable {
    let title: String
    let message: String
    let diagnosticCode: String?
}

@MainActor
@Observable
final class TrackShareViewModel {
    enum State: Equatable {
        case idle
        case preparing(TrackExportProgress)
        case ready(TrackSharePayload)
        case failed(TrackShareFailure)
    }

    private(set) var state: State = .idle

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
        let baseTitle = L10n.text("could_not_prepare_the_audio_file")
        let nsError = error as NSError

        let baseMessage: String
        let code: String?

        switch error {
        case let diagnostic as HLSDiagnosticError:
            baseMessage = diagnostic.errorDescription
                ?? L10n.text("could_not_prepare_the_audio_file")
            code = diagnostic.publicCode
        case let exporterError as HLSExportError:
            baseMessage = exporterError.errorDescription
                ?? L10n.text("could_not_prepare_the_audio_file")
            code = nil
        case let apiError as APIError:
            baseMessage = apiError.errorDescription
                ?? L10n.text("could_not_prepare_the_audio_file")
            if apiError == .timedOut {
                code = "PM-NSURLErrorDomain--1001"
            } else {
                code = "VK-\(nsError.code)"
            }
        case let urlError as URLError where urlError.code == .timedOut:
            baseMessage = APIError.timedOut.errorDescription
                ?? L10n.text("could_not_prepare_the_audio_file")
            code = "PM-\(NSURLErrorDomain)-\(URLError.timedOut.rawValue)"
        default:
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorTimedOut {
                baseMessage = APIError.timedOut.errorDescription
                    ?? L10n.text("could_not_prepare_the_audio_file")
                code = "PM-\(nsError.domain)-\(nsError.code)"
            } else {
                baseMessage = L10n.text("could_not_prepare_the_audio_file")
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
            return L10n.text("checking_audio_file")
        case .copyingLocalFile:
            return L10n.text("preparing_saved_file")
        case .downloadingDirectFile:
            return L10n.text("downloading_audio_file")
        case .downloadingSegments:
            return L10n.text("assembling_audio_stream")
        case .convertingToM4A:
            return L10n.text("creating_m4a_file")
        }
    }

    var detail: String? {
        switch self {
        case let .downloadingSegments(completed, total):
            return L10n.format("d0_of_d1_parts", completed, total)
        default:
            return nil
        }
    }
}

// MARK: - Flow view

struct TrackShareFlowView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let track: Track

    @State private var model = TrackShareViewModel()

    var body: some View {
        Group {
            switch model.state {
            case let .ready(payload):
                readyScreen(payload: payload)

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

    private func readyScreen(payload: TrackSharePayload) -> some View {
        NavigationStack {
            VStack(spacing: 22) {
                AsyncArtwork(url: track.artworkURL, size: 112)

                VStack(spacing: 5) {
                    Text(track.title)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(L10n.text("the_file_is_ready_tap_the_button_below"))
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)

                // Let SwiftUI own the activity-controller lifecycle. Every
                // previous crash happened in custom programmatic UIKit
                // presentation while another sheet was transitioning.
                ShareLink(item: payload.fileURL) {
                    Label(
                        L10n.text("share"),
                        systemImage: "square.and.arrow.up"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(L10n.text("action.close"), role: .cancel) {
                    model.cancel(environment: environment)
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .navigationTitle(L10n.text("share_file"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
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
                        .fixedSize(horizontal: false, vertical: true)
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
                    L10n.text("when_the_file_is_ready_the_standard_iphone_menu_will_open_choose_save_to")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

                Button(role: .cancel) {
                    model.cancel(environment: environment)
                    dismiss()
                } label: {
                    Text(L10n.text("cancel"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .navigationTitle(L10n.text("share_file"))
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
                            L10n.text("copy_error_code"),
                            systemImage: "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                }

                Button(L10n.text("action.retry")) {
                    model.retry(track: track, environment: environment)
                }
                .buttonStyle(.borderedProminent)

                Button(L10n.text("action.close"), role: .cancel) {
                    model.cancel(environment: environment)
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .navigationTitle(L10n.text("share_file"))
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

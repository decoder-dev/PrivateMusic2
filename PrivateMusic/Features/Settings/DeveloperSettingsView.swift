import SwiftUI

enum DeveloperLogExportPhase: Equatable {
    case idle
    case preparing
    case ready
    case failed(String)
}

struct DeveloperSettingsView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(NetworkMonitor.self) private var networkMonitor
    @Environment(AudioPlayer.self) private var player

    @State private var exportPhase: DeveloperLogExportPhase = .idle
    @State private var archiveURL: URL?
    @State private var fileLoggingEnabled = AppLog.shared.isFileLoggingEnabled

    var body: some View {
        Form {
            Section(L10n.text("developer.diagnostics")) {
                LabeledContent(L10n.text("version"), value: versionLabel)
                LabeledContent(
                    L10n.text("developer.bundle_id"),
                    value: Bundle.main.bundleIdentifier ?? "—"
                )
                LabeledContent(
                    L10n.text("network"),
                    value: networkTitle
                )
                LabeledContent(
                    L10n.text("session_label"),
                    value: sessionTitle
                )
                if let expiresAt = sessionStore.session?.expiresAt {
                    LabeledContent(
                        L10n.text("token_expires"),
                        value: expiresAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                }
                if let track = player.currentTrack?.title, !track.isEmpty {
                    LabeledContent(
                        L10n.text("current_track"),
                        value: track
                    )
                }
            }

            Section {
                Toggle(
                    L10n.text("developer.file_logging"),
                    isOn: $fileLoggingEnabled
                )
                .onChange(of: fileLoggingEnabled) { _, enabled in
                    AppLog.shared.setFileLoggingEnabled(enabled)
                    AppLog.shared.info(
                        .app,
                        "File logging \(enabled ? "enabled" : "disabled")"
                    )
                }

                exportControls

                Button(L10n.text("developer.clear_logs"), role: .destructive) {
                    clearLogs()
                }
                .disabled(exportPhase == .preparing)
            } header: {
                Text(L10n.text("developer.logging"))
            } footer: {
                Text(L10n.text("developer.logging_footer"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackground())
        .navigationTitle(L10n.text("developer.menu"))
        .onDisappear {
            cleanupArchive()
        }
    }

    @ViewBuilder
    private var exportControls: some View {
        switch exportPhase {
        case .preparing:
            HStack(spacing: 12) {
                ProgressView()
                Text(L10n.text("developer.building_log_archive"))
                    .foregroundStyle(.secondary)
            }
        case .ready:
            if let archiveURL {
                ShareLink(item: archiveURL) {
                    Label(
                        L10n.text("developer.save_log_archive"),
                        systemImage: "square.and.arrow.up"
                    )
                }
            }
            Button(L10n.text("developer.build_log_archive_again")) {
                buildArchive()
            }
        case let .failed(message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(BubbleGamut.destructive.color)
            Button(L10n.text("developer.build_log_archive")) {
                buildArchive()
            }
        case .idle:
            Button(L10n.text("developer.build_log_archive")) {
                buildArchive()
            }
        }
    }

    private var versionLabel: String {
        let short = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "—"
        return "\(short) (\(build))"
    }

    private var networkTitle: String {
        guard networkMonitor.state != .offline else {
            return L10n.text("offline")
        }
        switch networkMonitor.transport {
        case .wifi:
            return L10n.text("connected_via_wi_fi")
        case .cellular:
            return L10n.text("connected_via_cellular")
        case .wired:
            return L10n.text("connected_via_ethernet")
        case .other:
            return L10n.text("connected")
        case .unavailable:
            return L10n.text("offline")
        }
    }

    private var sessionTitle: String {
        guard sessionStore.session != nil else {
            return L10n.text("not_connected")
        }
        return L10n.text("connected_2")
    }

    private func buildArchive() {
        guard exportPhase != .preparing else { return }
        cleanupArchive()
        exportPhase = .preparing
        let diagnostics = DeveloperDiagnosticsBuilder.make(
            networkStatus: networkTitle,
            sessionActive: sessionStore.session != nil,
            sessionExpiresAt: sessionStore.session?.expiresAt,
            currentTrackTitle: player.currentTrack?.title,
            isPlaying: player.isPlaying,
            fileLogCount: AppLog.shared.listLogFiles().count,
            totalLogBytes: AppLog.shared.totalLogBytes(),
            developerMenuUnlocked: DeveloperFeature.isUnlocked,
            fileLoggingEnabled: AppLog.shared.isFileLoggingEnabled
        )
        Task {
            do {
                let url = try await LogArchiveService.shared.buildArchive(
                    diagnostics: diagnostics
                )
                await MainActor.run {
                    archiveURL = url
                    exportPhase = .ready
                }
            } catch {
                await MainActor.run {
                    exportPhase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func clearLogs() {
        do {
            try AppLog.shared.clearLogFiles()
            cleanupArchive()
            exportPhase = .idle
        } catch {
            exportPhase = .failed(error.localizedDescription)
        }
    }

    private func cleanupArchive() {
        if let archiveURL {
            Task {
                await LogArchiveService.shared.removeArchive(at: archiveURL)
            }
        }
        archiveURL = nil
        if case .ready = exportPhase {
            exportPhase = .idle
        }
    }
}

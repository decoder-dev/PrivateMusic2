import SwiftUI

struct LibraryDownloadView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var wifiOnly = true
    @State private var confirmsCancel = false

    var body: some View {
        let job = environment.libraryDownloadJob
        Form {
            Section {
                Text(L10n.text("features.download.explanation"))
                Toggle(L10n.text("features.download.wifi"), isOn: $wifiOnly).disabled(job.running)
            }
            if job.hasJob {
                Section {
                    if job.snapshot.finished {
                        Label(L10n.text("features.download.done"), systemImage: "checkmark.circle")
                    } else {
                        ProgressView(value: Double(job.snapshot.completed),
                            total: Double(max(1, job.snapshot.total, job.snapshot.completed)))
                    }
                    Text(L10n.format("features.download.progress", job.snapshot.completed, job.snapshot.total))
                        .monospacedDigit()
                    if let error = job.error { Text(error).foregroundStyle(.secondary) }
                }
            }
            Section {
                if job.running {
                    Button(L10n.text("features.download.pause")) { job.pause() }
                } else {
                    Button(L10n.text(job.hasJob && !job.snapshot.finished ? "features.download.resume" : "features.download.start")) {
                        job.start(environment: environment, wifiOnly: wifiOnly)
                    }
                }
                if job.hasJob && !job.snapshot.finished {
                    Button(L10n.text("features.download.cancel"), role: .destructive) { confirmsCancel = true }
                }
                NavigationLink { OfflineDownloadsView() } label: { Text(L10n.text("downloads")) }
            }
        }
        .navigationTitle(L10n.text("features.download.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { wifiOnly = job.snapshot.wifiOnly }
        .confirmationDialog(L10n.text("features.download.cancel_hint"), isPresented: $confirmsCancel) {
            Button(L10n.text("features.download.cancel"), role: .destructive) { job.cancel() }
        }
    }
}

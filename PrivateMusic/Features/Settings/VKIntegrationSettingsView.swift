import SwiftUI

struct VKIntegrationSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(L10n.text("features.vk.broadcast"), isOn: $settings.vkBroadcastEnabled)
                Toggle(L10n.text("features.vk.reporting"), isOn: $settings.vkReportingEnabled)
            } footer: {
                Text(L10n.text("features.vk.consent"))
            }
            if let error = environment.vkIntegration.broadcastError {
                Section(L10n.text("features.vk.broadcast")) { Text(error).foregroundStyle(.secondary) }
            }
            if let error = environment.vkIntegration.reportingError {
                Section(L10n.text("features.vk.reporting")) { Text(error).foregroundStyle(.secondary) }
            }
            if environment.vkIntegration.broadcastError != nil || environment.vkIntegration.reportingError != nil {
                Button(L10n.text("action.retry")) { environment.vkIntegration.retry(environment: environment) }
            }
        }
        .navigationTitle(L10n.text("features.vk.settings"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

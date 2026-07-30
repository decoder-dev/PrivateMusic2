import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(\.openURL) private var openURL
    @State private var showingLogoutConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                profileCard
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Настройки", systemImage: "gearshape.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .premiumCard(interactive: true)
                }
                .buttonStyle(.plain)
                linksCard

                Button(role: .destructive) {
                    showingLogoutConfirmation = true
                } label: {
                    Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .premiumCard(interactive: true)
                }

                VStack(spacing: 8) {
                    Image("AppIconPreview")
                        .resizable()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    Text("Private Music \(version)")
                        .foregroundStyle(.secondary)
                    Text("decoder-dev")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 28)
            }
            .padding()
        }
        .background(ThemeBackground())
        .navigationTitle("Профиль")
        .confirmationDialog(
            "Выйти из Private Music?",
            isPresented: $showingLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Выйти", role: .destructive) {
                sessionStore.logout()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(
                L10n.text(
                    "После выхода сохранённая сессия будет удалена с этого "
                        + "устройства. Для подключения потребуется снова "
                        + "войти в VK."
                )
            )
        }
    }

    private var version: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
    }

    private var profileCard: some View {
        HStack(spacing: 16) {
            AsyncArtwork(url: sessionStore.profile?.photoURL, size: 76)
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    sessionStore.profile?.displayName
                        ?? L10n.text("Слушатель")
                )
                    .font(.title3.bold())
                Text("Private Music")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .premiumCard()
    }

    private var linksCard: some View {
        VStack(spacing: 0) {
            linkButton(
                title: "Группа Private Music",
                subtitle: "Новости и обновления",
                icon: "paperplane.fill",
                url: environment.configuration.telegramGroupURL
            )
            Divider().padding(.leading, 54)
            linkButton(
                title: "VPN",
                subtitle: "Открыть Telegram-бота",
                icon: "lock.fill",
                url: environment.configuration.telegramVPNURL
            )
        }
        .padding(.horizontal)
        .premiumCard()
    }

    private func linkButton(
        title: String,
        subtitle: String,
        icon: String,
        url: URL
    ) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: 28)
                    .foregroundStyle(Brand.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(title))
                        .foregroundStyle(.primary)
                    Text(L10n.text(subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 15)
        }
        .buttonStyle(.plain)
    }
}

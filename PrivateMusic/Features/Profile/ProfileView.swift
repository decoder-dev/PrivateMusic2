import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                profileCard
                linksCard

                Button(role: .destructive) {
                    sessionStore.logout()
                } label: {
                    Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Brand.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }

                VStack(spacing: 8) {
                    Image("AppIconPreview")
                        .resizable()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    Text("Private Music 2.0")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 28)
            }
            .padding()
        }
        .background(Brand.background)
        .navigationTitle("Профиль")
    }

    private var profileCard: some View {
        HStack(spacing: 16) {
            AsyncArtwork(url: sessionStore.profile?.photoURL, size: 76)
            VStack(alignment: .leading, spacing: 4) {
                Text(sessionStore.profile?.displayName ?? "Слушатель")
                    .font(.title3.bold())
                Text("Private Music")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Brand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22))
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
                title: "Быстрый VPN",
                subtitle: "Стабильное подключение",
                icon: "lock.fill",
                url: environment.configuration.telegramVPNURL
            )
        }
        .padding(.horizontal)
        .background(Brand.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22))
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
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
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


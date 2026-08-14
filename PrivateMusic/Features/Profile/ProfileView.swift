import SwiftUI

struct ProfileView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(MainTabScrollCoordinator.self) private var scrollCoordinator
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingLogoutConfirmation = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 22) {
                    profileCard
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label(L10n.text("tab.settings"), systemImage: "gearshape.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .premiumCard(interactive: true)
                    }
                    .buttonStyle(.plain)
                    linksCard

                    Button(role: .destructive) {
                        showingLogoutConfirmation = true
                    } label: {
                        Label(L10n.text("sign_out"), systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .premiumCard(interactive: true)
                    }

                    VStack(spacing: 8) {
                        Image("AppIconPreview")
                            .resizable()
                            .frame(width: 60, height: 60)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: PremiumLayout.controlRadius,
                                    style: .continuous
                                )
                            )
                        Text("Private Music \(version)")
                            .foregroundStyle(.secondary)
                        Text("decoder-dev")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 28)
                }
                .id(MainTabScrollDestination.profile)
                .padding()
            }
            .onChange(of: scrollCoordinator.request) { _, request in
                guard request?.destination == .profile else { return }
                if reduceMotion {
                    proxy.scrollTo(MainTabScrollDestination.profile, anchor: .top)
                } else {
                    withAnimation(.easeOut(duration: 0.28)) {
                        proxy.scrollTo(
                            MainTabScrollDestination.profile,
                            anchor: .top
                        )
                    }
                }
            }
        }
        .background(ThemeBackground())
        .navigationTitle(L10n.text("tab.profile"))
        .confirmationDialog(L10n.text("sign_out_of_private_music"),
            isPresented: $showingLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("sign_out"), role: .destructive) {
                sessionStore.logout()
            }
            Button(L10n.text("action.cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.text("signing_out_removes_the_saved_session_from_this_device_you_will_need_to_")
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
                        ?? L10n.text("listener")
                )
                    .font(.title3.bold())
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("private_music"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .padding()
        .premiumCard()
    }

    private var linksCard: some View {
        VStack(spacing: 0) {
            linkButton(
                title: "private_music_group",
                subtitle: "news_and_updates",
                icon: "paperplane.fill",
                url: environment.configuration.telegramGroupURL
            )
            Divider().padding(.leading, 54)
            linkButton(
                title: "vpn",
                subtitle: "open_telegram_bot",
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
                    .foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(title))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text(subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
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

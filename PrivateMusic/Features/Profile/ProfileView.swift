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
                VStack(spacing: 24) {
                    identityHeader
                    groupedActions
                    logoutRow
                    footer
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

    /// Identity dominates the surface it sits on rather than the other
    /// way around — no card, no shadow, just the avatar and the name on
    /// the same background everything else already reads from.
    private var identityHeader: some View {
        HStack(spacing: 16) {
            AsyncArtwork(url: sessionStore.profile?.photoURL, size: 64)
                .clipShape(Circle())
                .overlay { Circle().stroke(.primary.opacity(0.1)) }
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    sessionStore.profile?.displayName
                        ?? L10n.text("listener")
                )
                .font(.system(size: 21, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("private_music"))
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    /// One grouped surface, three rows — Settings used to be its own
    /// full-width card floating between the identity and the links card,
    /// which is what made the screen read as a stack of separate panels
    /// rather than one settings-style list.
    private var groupedActions: some View {
        VStack(spacing: 0) {
            NavigationLink {
                SettingsView()
            } label: {
                groupedRow(
                    title: L10n.text("tab.settings"),
                    subtitle: nil,
                    systemImage: "gearshape.fill",
                    trailing: "chevron.right"
                )
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 54)

            Button {
                openURL(environment.configuration.telegramGroupURL)
            } label: {
                groupedRow(
                    title: L10n.text("private_music_group"),
                    subtitle: L10n.text("news_and_updates"),
                    systemImage: "paperplane.fill",
                    trailing: "arrow.up.right"
                )
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 54)

            Button {
                openURL(environment.configuration.telegramVPNURL)
            } label: {
                groupedRow(
                    title: L10n.text("vpn"),
                    subtitle: L10n.text("open_telegram_bot"),
                    systemImage: "lock.fill",
                    trailing: "arrow.up.right"
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .premiumCard()
    }

    /// Shared row so Settings and both external links carry identical
    /// height, typography and trailing-indicator placement — a chevron
    /// for the in-app destination, an external-link glyph for the two
    /// that leave the app.
    private func groupedRow(
        title: String,
        subtitle: String?,
        systemImage: String,
        trailing: String
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: trailing)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    /// Destructive, but one row — not a second full-width billboard
    /// beneath the settings list.
    private var logoutRow: some View {
        Button(role: .destructive) {
            showingLogoutConfirmation = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 28)
                Text(L10n.text("sign_out"))
                    .font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 8)
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 12)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .premiumCard(interactive: true)
    }

    /// Tertiary information stays tertiary: a 60pt icon and two full-size
    /// text lines competed with the identity above them for attention.
    private var footer: some View {
        VStack(spacing: 4) {
            Image("AppIconPreview")
                .resizable()
                .frame(width: 36, height: 36)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: PremiumLayout.controlRadius,
                        style: .continuous
                    )
                )
            Text("Private Music \(version)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("decoder-dev")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 8)
    }
}

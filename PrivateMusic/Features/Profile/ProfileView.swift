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
                VStack(spacing: BubbleSpacing.section) {
                    identityHeader
                    accountSection
                    supportSection
                    sessionSection
                    footer
                }
                .id(MainTabScrollDestination.profile)
                .padding(.horizontal, PremiumLayout.screenPadding)
                .padding(.vertical, BubbleSpacing.l)
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

    private var accountSection: some View {
        AppGroupedSection(title: "account") {
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
        }
    }

    private var supportSection: some View {
        AppGroupedSection(title: "support") {
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
    }

    private var sessionSection: some View {
        AppGroupedSection(title: "session") {
            Button(role: .destructive) {
                showingLogoutConfirmation = true
            } label: {
                groupedRow(
                    title: L10n.text("sign_out"),
                    subtitle: nil,
                    systemImage: "rectangle.portrait.and.arrow.right",
                    trailing: nil,
                    foregroundStyle: .red,
                    isDestructive: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func groupedRow(
        title: String,
        subtitle: String?,
        systemImage: String,
        trailing: String?,
        foregroundStyle: Color = .primary,
        isDestructive: Bool = false
    ) -> some View {
        AppGroupedRow {
            HStack(spacing: BubbleSpacing.m) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(foregroundStyle)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(foregroundStyle)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(BubbleType.metadata)
                            .foregroundStyle(
                                isDestructive ? .red.opacity(0.82) : .secondary
                            )
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } trailing: {
            if let trailing {
                Image(systemName: trailing)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
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

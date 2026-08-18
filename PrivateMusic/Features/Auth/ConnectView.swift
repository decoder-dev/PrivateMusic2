import SwiftUI

struct ConnectView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AppSettings.self) private var settings
    @State private var token = ""
    @State private var userAgent = ""
    @State private var isConnecting = false
    @State private var isWebLoginPresented = false
    @State private var showsManualImport = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            ThemeBackground()

            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 28)
                    brandHeader
                    loginCard
                    privacyNote
                    manualImport
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
            }
        }
        .alert(L10n.text("could_not_connect"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(L10n.text("action.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $isWebLoginPresented) {
            VKWebLoginView { result in
                Task { await connectWebSession(result) }
            }
        }
    }

    private var brandHeader: some View {
        VStack(spacing: 14) {
            Image("AppIconPreview")
                .resizable()
                .scaledToFit()
                .frame(width: 92, height: 92)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: PremiumLayout.cardRadius,
                        style: .continuous
                    )
                )
                .shadow(color: .black.opacity(0.12), radius: 20, y: 10)

            VStack(spacing: 5) {
                Text(L10n.text("private_music"))
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(L10n.text("music_from_your_vk_library_in_a_single_player"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var loginCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("connect_vk"))
                    .font(.title3.bold())
                Text(L10n.text("sign_in_opens_on_the_official_vk_page")
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                benefit("phone.fill", "sign_in_with_your_phone_number")
                benefit("lock.shield.fill", "your_password_stays_with_vk")
                benefit(
                    "key.fill",
                    "session_data_is_stored_in_the_system_keychain"
                )
            }

            Button {
                isWebLoginPresented = true
            } label: {
                HStack {
                    if isConnecting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                    Text(
                        L10n.text(
                            isConnecting
                                ? "connecting_account"
                                : "continue_with_vk"
                        )
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isConnecting)
        }
        .padding(20)
        .premiumCard(interactive: true)
    }

    private func benefit(_ icon: String, _ title: String) -> some View {
        Label {
            Text(L10n.text(title))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(settings.theme.accent)
                .frame(width: 22)
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.green)
            Text(
                L10n.text("private_music_does_not_read_sign_in_fields_or_send_your_password_or_veri")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
    }

    private var manualImport: some View {
        DisclosureGroup(L10n.text("have_an_existing_session"),
            isExpanded: $showsManualImport
        ) {
            VStack(spacing: 12) {
                SecureField("VK access token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .padding()
                    .background(
                        Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(
                            cornerRadius: PremiumLayout.controlRadius,
                            style: .continuous
                        )
                    )

                TextField(L10n.text("user_agent_from_vkpymusic"), text: $userAgent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding()
                    .background(
                        Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(
                            cornerRadius: PremiumLayout.controlRadius,
                            style: .continuous
                        )
                    )

                Button {
                    Task { await connectImportedSession() }
                } label: {
                    Label(L10n.text("import"),
                        systemImage: "square.and.arrow.down"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(
                    isConnecting
                        || token.count < 16
                        || userAgent.count < 12
                )
            }
            .padding(.top, 14)
        }
        .font(.subheadline)
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(
                cornerRadius: PremiumLayout.compactRadius,
                style: .continuous
            )
        )
    }

    @MainActor
    private func connectImportedSession() async {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedUserAgent = userAgent.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard cleaned.count >= 16, cleanedUserAgent.count >= 12 else {
            errorMessage = APIError.unauthorized.localizedDescription
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        do {
            await environment.musicService.configure(
                userAgent: cleanedUserAgent
            )
            environment.player.configureNetwork(
                userAgent: cleanedUserAgent
            )
            let profile = try await environment.musicService.profile(
                accessToken: cleaned
            )
            try sessionStore.connect(
                accessToken: cleaned,
                userAgent: cleanedUserAgent,
                profile: profile
            )
            token = ""
            userAgent = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func connectWebSession(_ result: VKWebAuthResult) async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            await environment.musicService.configure(
                userAgent: result.apiUserAgent
            )
            environment.player.configureNetwork(
                userAgent: result.apiUserAgent
            )
            let profile = try await environment.musicService.profile(
                accessToken: result.accessToken
            )
            try sessionStore.updateWebSession(
                result,
                profile: profile
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

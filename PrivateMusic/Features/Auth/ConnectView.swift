import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: AppSettings
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
        .alert(
            "Не удалось подключить",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("ОК", role: .cancel) {}
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
                Text("Private Music")
                    .font(.system(size: 34, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("Музыка из вашей медиатеки VK в одном плеере")
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
                Text("Подключите VK")
                    .font(.title3.bold())
                Text(
                    "Вход откроется на официальной странице VK."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                benefit("phone.fill", "Вход по номеру телефона")
                benefit("lock.shield.fill", "Пароль остаётся на стороне VK")
                benefit(
                    "key.fill",
                    "Данные сессии хранятся в системном Keychain"
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
                                ? "Подключаем аккаунт…"
                                : "Продолжить с VK"
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
                L10n.text(
                    "Private Music не читает поля формы входа и не отправляет "
                        + "пароль или код подтверждения на собственный сервер. "
                        + "Полученные данные сессии сохраняются в системном "
                        + "Keychain этого устройства."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
    }

    private var manualImport: some View {
        DisclosureGroup(
            "Есть готовая сессия?",
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

                TextField("User-Agent из VKpyMusic", text: $userAgent)
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
                    Label(
                        "Импортировать",
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

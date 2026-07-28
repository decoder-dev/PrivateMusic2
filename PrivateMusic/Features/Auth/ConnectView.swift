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
                VStack(spacing: 28) {
                    Spacer(minLength: 48)

                    Image("AppIconPreview")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 132, height: 132)
                        .clipShape(RoundedRectangle(cornerRadius: 30))
                        .shadow(
                            color: settings.theme.accent.opacity(0.35),
                            radius: 28
                        )

                    VStack(spacing: 8) {
                        Text("Private Music")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                        Text("Музыка без лишнего шума")
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 14) {
                        Button {
                            isWebLoginPresented = true
                        } label: {
                            HStack {
                                if isConnecting {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "phone.fill")
                                }
                                Text(
                                    isConnecting
                                        ? "Проверяем сессию…"
                                        : "Войти по номеру телефона"
                                )
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isConnecting)

                        DisclosureGroup(
                            "Импортировать готовую сессию",
                            isExpanded: $showsManualImport
                        ) {
                            VStack(spacing: 12) {
                                SecureField("VK access token", text: $token)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .textContentType(.password)
                                    .padding()
                                    .adaptiveGlass(
                                        in: RoundedRectangle(cornerRadius: 14)
                                    )

                                TextField(
                                    "User-Agent из VKpyMusic",
                                    text: $userAgent
                                )
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding()
                                .adaptiveGlass(
                                    in: RoundedRectangle(cornerRadius: 14)
                                )

                                Button {
                                    Task { await connectImportedSession() }
                                } label: {
                                    Label(
                                        "Подключить готовую сессию",
                                        systemImage: "key.fill"
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
                    }
                    .padding(.horizontal, 24)

                    Text(
                        "Авторизация открывается на защищённой странице VK. "
                        + "Private Music не видит и не сохраняет пароль, "
                        + "код подтверждения или cookies. После проверки "
                        + "в Keychain сохраняется только временный токен."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                }
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
            let profile = try await environment.musicService.profile(
                accessToken: result.accessToken
            )
            try sessionStore.connect(
                accessToken: result.accessToken,
                userAgent: result.apiUserAgent,
                expiresAt: result.expiresAt,
                profile: profile
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

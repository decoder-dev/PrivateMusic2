import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @State private var token = ""
    @State private var isConnecting = false
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
                        SecureField("VK access token", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.password)
                            .padding()
                            .adaptiveGlass(
                                in: RoundedRectangle(cornerRadius: 14)
                            )

                        Button {
                            Task { await connect() }
                        } label: {
                            HStack {
                                if isConnecting {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "link")
                                }
                                Text(
                                    isConnecting
                                        ? "Проверяем сессию…"
                                        : "Подключить VK"
                                )
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isConnecting || token.count < 16)
                    }
                    .padding(.horizontal, 24)

                    Text(
                        "Токен проверяется запросом к VK и хранится только "
                        + "в системном Keychain. Пароль и коды подтверждения "
                        + "Private Music не запрашивает."
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
    }

    @MainActor
    private func connect() async {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 16 else {
            errorMessage = APIError.unauthorized.localizedDescription
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        do {
            let profile = try await environment.musicService.profile(
                accessToken: cleaned
            )
            try sessionStore.connect(
                accessToken: cleaned,
                profile: profile
            )
            token = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

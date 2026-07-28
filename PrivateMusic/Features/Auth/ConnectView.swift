import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var token = ""
    @State private var showingAdvanced = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 48)

                    Image("AppIconPreview")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 132, height: 132)
                        .clipShape(RoundedRectangle(cornerRadius: 30))
                        .shadow(color: Brand.accent.opacity(0.35), radius: 28)

                    VStack(spacing: 8) {
                        Text("Private Music")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                        Text("Музыка без лишнего шума")
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 14) {
                        Button {
                            environment.useDemoMode()
                            sessionStore.enterDemoMode()
                        } label: {
                            Label("Открыть демо", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())

                        DisclosureGroup(
                            "Подключить существующую VK-сессию",
                            isExpanded: $showingAdvanced
                        ) {
                            VStack(spacing: 12) {
                                SecureField("Access token", text: $token)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding()
                                    .background(Brand.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))

                                Button("Сохранить в Keychain") {
                                    connect()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(.top, 12)
                        }
                        .tint(.secondary)
                    }
                    .padding(.horizontal, 24)

                    Text(
                        "Пароль и коды подтверждения приложение не запрашивает. "
                        + "Официальную авторизацию VK ID можно подключить отдельным модулем."
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

    private func connect() {
        do {
            environment.useLiveMode()
            try sessionStore.connect(accessToken: token)
            token = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

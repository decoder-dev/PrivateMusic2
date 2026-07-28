import SwiftUI
import WebKit

struct VKWebLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = VKWebLoginModel()
    @State private var isCompleting = false
    @State private var errorMessage: String?

    let onAuthenticated: @MainActor (VKWebAuthResult) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                VKWebView(webView: model.webView)

                if model.isLoading {
                    ProgressView()
                        .padding(16)
                        .adaptiveGlass(in: Circle())
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        Task { await completeLogin() }
                    } label: {
                        HStack {
                            if isCompleting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "checkmark.shield.fill")
                            }
                            Text(
                                isCompleting
                                    ? "Проверяем сессию…"
                                    : "Я вошёл — продолжить"
                            )
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isCompleting || model.isLoading)

                    Text(
                        "Телефон, пароль и код вводятся только на странице VK."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        Task {
                            await model.clearWebData()
                            dismiss()
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isCompleting)
        .alert(
            "Не удалось войти",
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
    private func completeLogin() async {
        isCompleting = true
        defer { isCompleting = false }
        do {
            let result = try await model.exchangeSession()
            onAuthenticated(result)
            await model.clearWebData()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct VKWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
private final class VKWebLoginModel: NSObject, ObservableObject {
    @Published private(set) var isLoading = true
    @Published private(set) var title = "Вход через VK"

    let webView: WKWebView
    private let authService = VKWebAuthService()

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self

        if let url = URL(string: "https://vk.ru/") {
            webView.load(
                URLRequest(
                    url: url,
                    cachePolicy: .reloadIgnoringLocalCacheData,
                    timeoutInterval: 30
                )
            )
        }
    }

    func exchangeSession() async throws -> VKWebAuthResult {
        let cookies = await allCookies()
        let vkCookies = cookies
            .filter { cookie in
                let domain = cookie.domain.lowercased()
                return domain == "vk.ru"
                    || domain.hasSuffix(".vk.ru")
            }
            .sorted { $0.name < $1.name }
        guard !vkCookies.isEmpty else {
            throw VKWebAuthError.noSession
        }

        let header = vkCookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        let userAgent = try await currentUserAgent()
        return try await authService.exchange(
            cookieHeader: header,
            webUserAgent: userAgent
        )
    }

    func clearWebData() async {
        webView.stopLoading()
        let store = webView.configuration.websiteDataStore
        let cookies = await allCookies()
        for cookie in cookies {
            await withCheckedContinuation { continuation in
                store.httpCookieStore.delete(cookie) {
                    continuation.resume()
                }
            }
        }

        let records = await withCheckedContinuation { continuation in
            store.fetchDataRecords(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()
            ) { continuation.resume(returning: $0) }
        }
        await withCheckedContinuation { continuation in
            store.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                for: records
            ) {
                continuation.resume()
            }
        }
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore
                .getAllCookies {
                    continuation.resume(returning: $0)
                }
        }
    }

    private func currentUserAgent() async throws -> String {
        let value = try await webView.evaluateJavaScript(
            "navigator.userAgent"
        )
        guard let userAgent = value as? String, userAgent.count >= 12 else {
            throw VKWebAuthError.invalidResponse
        }
        return userAgent
    }
}

extension VKWebLoginModel: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation?
    ) {
        isLoading = true
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation?
    ) {
        isLoading = false
        title = webView.title?.isEmpty == false
            ? webView.title ?? "Вход через VK"
            : "Вход через VK"
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        isLoading = false
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        isLoading = false
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              Self.isAllowedVKHost(host) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private static func isAllowedVKHost(_ host: String) -> Bool {
        host == "vk.ru"
            || host.hasSuffix(".vk.ru")
            || host == "vk.com"
            || host.hasSuffix(".vk.com")
    }
}

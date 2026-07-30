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
            VStack(spacing: 0) {
                securityBanner

                ZStack {
                    VKWebView(webView: model.webView)

                    if model.isLoading {
                        Color(uiColor: .systemBackground)
                            .opacity(0.82)
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Открываем страницу VK…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if let loadError = model.loadError {
                        VStack(spacing: 14) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 42))
                                .foregroundStyle(.secondary)
                            Text("Страница не загрузилась")
                                .font(.headline)
                            Text(loadError)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Повторить") {
                                model.reload()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(24)
                    }
                }

                browserBar
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Вход в VK")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Task {
                            await model.clearWebData()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Закрыть")
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isCompleting)
        .onChange(of: model.sessionRevision) { _ in
            guard model.sessionRevision > 0, !isCompleting else { return }
            Task { await completeLogin(automatic: true) }
        }
        .alert(
            "Не удалось завершить вход",
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

    private var securityBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 34, height: 34)
                .background(.green.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    L10n.text(
                        isCompleting
                            ? "Подтверждаем вход…"
                            : "Официальная страница VK"
                    )
                )
                .font(.subheadline.weight(.semibold))
                Text(
                    L10n.text(
                        isCompleting
                            ? "Проверяем данные сессии"
                            : "Private Music не получает пароль и код "
                                + "подтверждения"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isCompleting {
                ProgressView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var browserBar: some View {
        HStack(spacing: 8) {
            browserButton("chevron.backward", label: "Назад") {
                model.goBack()
            }
            .disabled(!model.canGoBack || isCompleting)

            browserButton("arrow.clockwise", label: "Обновить") {
                model.reload()
            }
            .disabled(isCompleting)

            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text(model.displayHost)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            Button {
                Task { await completeLogin(automatic: false) }
            } label: {
                if isCompleting {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.headline)
                        .frame(width: 32, height: 32)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCompleting || model.isLoading)
            .accessibilityLabel("Завершить вход")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func browserButton(
        _ image: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text(label))
    }

    @MainActor
    private func completeLogin(automatic: Bool) async {
        guard !isCompleting else { return }
        isCompleting = true
        defer { isCompleting = false }
        do {
            let result = try await model.exchangeSession()
            onAuthenticated(result)
            await model.clearWebData()
            dismiss()
        } catch {
            if !automatic {
                errorMessage = error.localizedDescription
            }
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
    @Published private(set) var loadError: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var displayHost = "vk.ru"
    @Published private(set) var sessionRevision = 0

    let webView: WKWebView
    private let authService = VKWebAuthService()
    private var lastSessionFingerprint: String?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        loadLoginPage()
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func reload() {
        loadError = nil
        if webView.url == nil {
            loadLoginPage()
        } else {
            webView.reload()
        }
    }

    func exchangeSession() async throws -> VKWebAuthResult {
        let vkCookies = await sessionCookies()
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

    private func loadLoginPage() {
        guard let url = URL(string: "https://vk.ru/login") else { return }
        webView.load(
            URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 30
            )
        )
    }

    private func setLoadError(_ error: Error) {
        if let urlError = error as? URLError,
           urlError.code == .cancelled {
            return
        }
        isLoading = false
        loadError = error.localizedDescription
    }

    private func inspectSession() async {
        let cookies = await sessionCookies()
        let likelySessionNames = [
            "remixsid",
            "remixsid6",
            "remixnsid"
        ]
        let authenticated = cookies.contains {
            likelySessionNames.contains($0.name.lowercased())
                && !$0.value.isEmpty
        }
        guard authenticated else { return }
        let fingerprint = cookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: ";")
        guard fingerprint != lastSessionFingerprint else { return }
        lastSessionFingerprint = fingerprint
        sessionRevision += 1
    }

    private func sessionCookies() async -> [HTTPCookie] {
        await allCookies()
            .filter { cookie in
                let domain = cookie.domain.lowercased()
                return domain == "vk.ru"
                    || domain.hasSuffix(".vk.ru")
            }
            .sorted { $0.name < $1.name }
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

    private static func isAllowedVKHost(_ host: String) -> Bool {
        host == "vk.ru"
            || host.hasSuffix(".vk.ru")
            || host == "vk.com"
            || host.hasSuffix(".vk.com")
    }
}

extension VKWebLoginModel: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation?
    ) {
        isLoading = true
        loadError = nil
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation?
    ) {
        isLoading = false
        canGoBack = webView.canGoBack
        displayHost = webView.url?.host ?? "vk.ru"
        Task { await inspectSession() }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        setLoadError(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        setLoadError(error)
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
}

extension VKWebLoginModel: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url,
           let host = url.host?.lowercased(),
           Self.isAllowedVKHost(host) {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

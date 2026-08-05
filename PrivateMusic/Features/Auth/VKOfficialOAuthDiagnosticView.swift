import SwiftUI
import WebKit

/// Diagnostic-only screen for `experiment/vk-official-oauth`.
///
/// Checks whether a *user-registered* VK app (as opposed to the
/// grandfathered first-party/legacy client IDs `VKWebAuthService` borrows
/// today) is actually granted the `audio` scope. Uses VK's Implicit Flow
/// (`response_type=token`) with the `offline` scope, which VK returns as a
/// non-expiring token — no confidential app secret is ever needed in the
/// app, on this branch or in a real rollout, since there is no
/// code-exchange step.
///
/// This view never persists anything to Keychain/SessionStore: it is a
/// standalone probe, not a login path wired into the rest of the app.
struct VKOfficialOAuthDiagnosticView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = VKOfficialOAuthDiagnosticModel()

    var body: some View {
        NavigationStack {
            Group {
                if let result = model.result {
                    resultView(result)
                } else if let errorMessage = model.errorMessage {
                    errorView(errorMessage)
                } else {
                    ZStack {
                        VKOAuthWebView(webView: model.webView)
                        if model.isLoading {
                            Color(uiColor: .systemBackground).opacity(0.82)
                            ProgressView()
                        }
                    }
                }
            }
            .navigationTitle("Проверка audio-доступа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func resultView(_ result: VKOAuthDiagnosticResult) -> some View {
        List {
            Section {
                HStack {
                    Image(
                        systemName: result.hasAudioScope
                            ? "checkmark.circle.fill"
                            : "xmark.circle.fill"
                    )
                    .font(.title2)
                    .foregroundStyle(
                        result.hasAudioScope ? .green : .red
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            result.hasAudioScope
                                ? "audio выдан"
                                : "audio НЕ выдан"
                        )
                        .font(.headline)
                        Text(
                            result.hasAudioScope
                                ? "Официальный API можно использовать "
                                    + "для audio-методов этого приложения."
                                : "VK не включил audio в granted scope — "
                                    + "текущая приватная архитектура "
                                    + "остаётся единственным рабочим "
                                    + "вариантом."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Что реально вернул VK") {
                LabeledContent("scope", value: result.rawScope)
                LabeledContent(
                    "access_token",
                    value: result.hasToken ? "получен" : "отсутствует"
                )
                LabeledContent(
                    "не истекает (offline)",
                    value: result.expiresIn == 0 ? "да" : "нет"
                )
                if let userID = result.userID {
                    LabeledContent("user_id", value: String(userID))
                }
            }
            Section("Реальный вызов audio.get") {
                switch model.apiTestOutcome {
                case .none:
                    HStack {
                        ProgressView()
                        Text("Проверяем этим токеном…")
                            .foregroundStyle(.secondary)
                    }
                case let .some(.success(count)):
                    Label(
                        "Получено треков: \(count)",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                case let .some(.failure(message)):
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            "VK отклонил вызов",
                            systemImage: "xmark.circle.fill"
                        )
                        .foregroundStyle(.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Результат")
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Повторить") { model.reload() }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct VKOAuthDiagnosticResult {
    let rawScope: String
    let hasToken: Bool
    let expiresIn: Int
    let userID: Int?

    var hasAudioScope: Bool {
        rawScope
            .lowercased()
            .split(separator: ",")
            .contains("audio")
    }
}

private struct VKOAuthWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

enum VKOAuthAPITestOutcome {
    case success(trackCount: Int)
    case failure(message: String)
}

@MainActor
private final class VKOfficialOAuthDiagnosticModel: NSObject, ObservableObject {
    @Published private(set) var isLoading = true
    @Published private(set) var result: VKOAuthDiagnosticResult?
    @Published private(set) var errorMessage: String?
    @Published private(set) var apiTestOutcome: VKOAuthAPITestOutcome?

    let webView: WKWebView

    // Provided for this diagnostic run only. Implicit Flow never needs a
    // confidential app secret — do not add one here even for a
    // "complete" test.
    private let clientID = "54707652"
    private let redirectHost = "oauth.vk.com"
    private let redirectPath = "/blank.html"

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        load()
    }

    func reload() {
        errorMessage = nil
        result = nil
        apiTestOutcome = nil
        load()
    }

    private func load() {
        var components = URLComponents(
            string: "https://oauth.vk.com/authorize"
        )!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "display", value: "mobile"),
            URLQueryItem(
                name: "redirect_uri",
                value: "https://\(redirectHost)\(redirectPath)"
            ),
            URLQueryItem(name: "scope", value: "audio,offline"),
            URLQueryItem(name: "response_type", value: "token"),
            URLQueryItem(name: "v", value: "5.199")
        ]
        guard let url = components.url else {
            errorMessage = L10n.text("Не удалось собрать ссылку авторизации.")
            return
        }
        isLoading = true
        webView.load(URLRequest(url: url))
    }

    fileprivate func handleRedirect(_ url: URL) {
        // VK returns the payload as a URL *fragment*
        // (#access_token=...&expires_in=...&scope=...), not query items.
        let fragment = url.fragment ?? ""
        let pairs = fragment
            .split(separator: "&")
            .reduce(into: [String: String]()) { result, pair in
                let parts = pair.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                guard parts.count == 2 else { return }
                result[String(parts[0])] =
                    String(parts[1]).removingPercentEncoding ?? String(parts[1])
            }

        if let error = pairs["error"] {
            errorMessage = L10n.format(
                "VK отклонил запрос: %@",
                pairs["error_description"] ?? error
            )
            isLoading = false
            return
        }

        let scope = pairs["scope"] ?? ""
        let accessToken = pairs["access_token"] ?? ""
        let expiresIn = Int(pairs["expires_in"] ?? "") ?? -1
        let userID = Int(pairs["user_id"] ?? "")

        guard !accessToken.isEmpty else {
            errorMessage = L10n.text(
                "VK не вернул access_token в ответе."
            )
            isLoading = false
            return
        }

        result = VKOAuthDiagnosticResult(
            rawScope: scope.isEmpty ? "(пусто)" : scope,
            hasToken: true,
            expiresIn: expiresIn,
            userID: userID
        )
        isLoading = false
        Task { await runAPITest(accessToken: accessToken) }
    }

    /// The real test: not just whether "audio" shows up in the granted
    /// `scope` string, but whether VK actually serves audio.get with this
    /// token. Reuses the app's own VKMusicService unchanged — every method
    /// there takes the access token as a call parameter rather than
    /// storing one internally, so no new service implementation is needed
    /// to try it against an officially-obtained token.
    private func runAPITest(accessToken: String) async {
        guard let baseURL = URL(string: "https://api.vk.ru") else { return }
        let client = APIClient(baseURL: baseURL, userAgent: nil)
        let service = VKMusicService(client: client, apiVersion: "5.199")
        do {
            let page = try await service.library(
                accessToken: accessToken,
                offset: 0,
                count: 5
            )
            apiTestOutcome = .success(trackCount: page.items.count)
        } catch {
            apiTestOutcome = .failure(message: error.localizedDescription)
        }
    }
}

extension VKOfficialOAuthDiagnosticModel: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation?
    ) {
        isLoading = false
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        isLoading = false
        errorMessage = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        isLoading = false
        errorMessage = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.host == redirectHost, url.path == redirectPath {
            decisionHandler(.cancel)
            handleRedirect(url)
            return
        }
        decisionHandler(.allow)
    }
}

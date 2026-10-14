import Foundation
import UIKit
import WebKit

/// Loads Genius through WebKit and shares its session with the visible lyrics
/// browser. An interactive challenge cannot be completed by this hidden view.
@MainActor
final class GeniusWebFetcher: NSObject, WKNavigationDelegate {
    enum Kind: Sendable {
        case json
        case html
    }

    static let store = WKWebsiteDataStore.nonPersistent()
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1"

    private var webView: WKWebView?
    private var didFinish = false
    private var failure: Error?

    static func fetch(_ url: URL, kind: Kind) async throws -> Data {
        try Task.checkCancellation()
        let fetcher = GeniusWebFetcher()
        return try await fetcher.load(url, kind: kind)
    }

    private func load(_ url: URL, kind: Kind) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw APIError.invalidRequest }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.store
        let view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: configuration
        )
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = self
        // A web view that belongs to no window gets its timers and scripts
        // throttled, which is enough to stall a Cloudflare challenge. Keep
        // it in the hierarchy, invisible and untouchable, for the load.
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .insertSubview(view, at: 0)
        webView = view
        defer {
            view.stopLoading()
            view.navigationDelegate = nil
            view.removeFromSuperview()
            webView = nil
        }
        view.load(URLRequest(url: url))

        let script = kind == .json
            ? "document.body ? document.body.innerText : ''"
            : "document.documentElement.outerHTML"
        // The challenge page reloads itself into the real one, so keep
        // polling until the content stops looking like a challenge.
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(400))
            try Task.checkCancellation()
            if let failure { throw failure }
            guard didFinish else { continue }
            let value = try? await view.evaluateJavaScript(script)
            guard let text = value as? String,
                  GeniusResponsePolicy.isUsable(text, kind: kind) else {
                continue
            }
            AppLog.shared.info(
                .network,
                "genius web load ok host=\(url.host ?? "-") bytes=\(text.utf8.count)"
            )
            return Data(text.utf8)
        }
        // Say what the page was when we gave up (title and address only),
        // so the next log shows whether it is a challenge or an error page.
        let state = (try? await view.evaluateJavaScript(
            "document.title + ' | ' + location.host + location.pathname"
        )) as? String
        AppLog.shared.error(
            .network,
            "genius web load gave up finished=\(didFinish) page=\(state ?? "unavailable")"
        )
        throw GeniusLookupError.accessRestricted
    }

    func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        // A challenge redirect starts a new navigation; wait for that one.
        didFinish = false
        failure = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish = true
    }

    /// The page and the Cloudflare challenge in front of it are all https.
    /// A redirect to `http:`, `file:` or an app scheme is not part of either
    /// and is refused instead of being opened inside a script-enabled view.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        decisionHandler(scheme == "https" || scheme == "about" ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failure = APIError.invalidResponse
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        // Challenge pages cancel their own navigation while redirecting.
        if (error as NSError).code == NSURLErrorCancelled { return }
        failure = error
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        // Challenge pages cancel their own navigation while redirecting.
        if (error as NSError).code == NSURLErrorCancelled { return }
        failure = error
    }
}

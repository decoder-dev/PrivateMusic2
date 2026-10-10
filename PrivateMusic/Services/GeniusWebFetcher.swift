import Foundation
import WebKit

/// Loads a Genius URL in a real WebKit engine. Genius sits behind a
/// Cloudflare check that rejects plain `URLSession` requests with 403, while
/// a browser engine clears the check on its own. The data store is shared for
/// the app run so the clearance cookie is reused by later requests.
@MainActor
final class GeniusWebFetcher: NSObject, WKNavigationDelegate {
    enum Kind: Sendable {
        case json
        case html
    }

    private static let store = WKWebsiteDataStore.nonPersistent()
    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1"

    private var webView: WKWebView?
    private var didFinish = false
    private var failure: Error?

    static func fetch(_ url: URL, kind: Kind) async throws -> Data {
        let fetcher = GeniusWebFetcher()
        return try await fetcher.load(url, kind: kind)
    }

    private func load(_ url: URL, kind: Kind) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.store
        let view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: configuration
        )
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = self
        webView = view
        defer {
            view.stopLoading()
            view.navigationDelegate = nil
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
                  Self.isUsable(text, kind: kind) else {
                continue
            }
            return Data(text.utf8)
        }
        throw APIError.invalidResponse
    }

    private static func isUsable(_ text: String, kind: Kind) -> Bool {
        switch kind {
        case .json:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix(String(UnicodeScalar(123)))
        case .html:
            let lower = text.lowercased()
            return !lower.contains("cloudflare_error.challenge")
                && !lower.contains("just a moment")
                && !lower.contains("challenge-platform")
                && lower.contains("lyrics")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish = true
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        failure = error
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failure = error
    }
}

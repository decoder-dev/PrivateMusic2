import SwiftUI
import WebKit

/// A visible recovery path for Genius pages that require browser interaction.
/// Only text from an actual Genius song URL is returned to the player.
struct GeniusLyricsBrowser: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let onLyrics: (Lyrics) -> Void

    var body: some View {
        NavigationStack {
            GeniusLyricsWebView(url: url) { lyrics in
                onLyrics(lyrics)
                dismiss()
            }
            .navigationTitle("Genius")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("done")) { dismiss() }
                }
            }
        }
    }
}

private struct GeniusLyricsWebView: UIViewRepresentable {
    let url: URL
    let onLyrics: (Lyrics) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLyrics: onLyrics) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = GeniusWebFetcher.store
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = GeniusWebFetcher.userAgent
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.extraction?.cancel()
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onLyrics: (Lyrics) -> Void
        var extraction: Task<Void, Never>?
        private var delivered = false

        init(onLyrics: @escaping (Lyrics) -> Void) { self.onLyrics = onLyrics }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  url.scheme == "https", let host = url.host?.lowercased(),
                  host == "genius.com" || host.hasSuffix(".genius.com")
                    || (navigationAction.targetFrame?.isMainFrame == false && host == "challenges.cloudflare.com") else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
               url.scheme == "https", let host = url.host?.lowercased(),
               host == "genius.com" || host.hasSuffix(".genius.com") {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            extraction?.cancel()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !delivered, let url = webView.url,
                  GeniusResponsePolicy.songURL(url.absoluteString) != nil else { return }
            extraction?.cancel()
            extraction = Task { [weak self, weak webView] in
                guard let self, let webView else { return }
                guard let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String,
                      !Task.isCancelled, webView.url == url,
                      GeniusResponsePolicy.isUsable(html, kind: .html),
                      let text = GeniusLyricsService.extractLyrics(from: html), !text.isEmpty else { return }
                delivered = true
                onLyrics(Lyrics(text: text, source: "Genius", sourceURL: url))
            }
        }
    }
}

import Foundation

enum GeniusResponsePolicy {
    static func isUsable(_ text: String, kind: GeniusWebFetcher.Kind) -> Bool {
        switch kind {
        case .json:
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return object["response"] is [String: Any]
        case .html:
            // Require a real container tag. A song can legitimately contain
            // “Just a moment”, and Cloudflare can inject its script into an
            // otherwise usable page; neither should hide available lyrics.
            return text.range(
                of: #"<div\b[^>]*(?:\bdata-lyrics-container\s*=\s*["']true["']|\bclass\s*=\s*["'][^"']*(?:Lyrics__Container|\blyrics\b))"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }

    static func songURL(_ value: String) -> URL? {
        guard let url = URL.secureRemoteURL(value), let host = url.host?.lowercased(),
              host == "genius.com" || host.hasSuffix(".genius.com"),
              url.path.lowercased().hasSuffix("-lyrics") else { return nil }
        return url
    }
}

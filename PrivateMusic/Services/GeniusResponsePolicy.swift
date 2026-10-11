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
            let lower = text.lowercased()
            guard !lower.contains("cloudflare_error.challenge"),
                  !lower.contains("just a moment"), !lower.contains("challenge-platform") else {
                return false
            }
            return lower.contains("data-lyrics-container") || lower.contains("lyrics__container")
                || lower.range(of: #"class\s*=\s*["'][^"']*\blyrics\b"#, options: .regularExpression) != nil
        }
    }

    static func songURL(_ value: String) -> URL? {
        guard let url = URL.secureRemoteURL(value), let host = url.host?.lowercased(),
              host == "genius.com" || host.hasSuffix(".genius.com"),
              url.path.lowercased().hasSuffix("-lyrics") else { return nil }
        return url
    }
}

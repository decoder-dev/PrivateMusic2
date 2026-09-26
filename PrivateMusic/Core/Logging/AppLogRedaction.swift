import Foundation

enum AppLogRedaction {
    private static let sensitiveFormKeys: Set<String> = [
        "access_token",
        "access_key",
        "audios", // VK embeds access keys in owner_id_audio_id_access_key values.
        "token",
        "refresh_token",
        "client_" + "secret",
        "client_id",
        "password",
        "code",
        "remixdsid",
        "p",
        "hash",
        "cookie",
        "session_id",
    ]

    static func redactFormValue(forKey key: String, value: String) -> String {
        if sensitiveFormKeys.contains(key.lowercased()) {
            return "<redacted>"
        }
        return redact(value)
    }

    static func describeForm(_ form: [String: String]) -> String {
        form.keys.sorted().map { key in
            let value = form[key] ?? ""
            return "\(key)=\(redactFormValue(forKey: key, value: value))"
        }
        .joined(separator: "&")
    }

    static func redact(_ value: String, truncate: Bool = true) -> String {
        var sanitized = value
        let patterns: [(String, String)] = [
            (#"(?i)((?:access_key|audios)=)[^&\s]+"#, "$1<redacted>"),
            (#"(?i)(HLS fetch encryptionKey:[^\r\n]*?magic\s+)[0-9a-f]+"#, "$1<redacted>"),
            (#"(?i)(access_token=)[^&\s]+"#, "$1<redacted>"),
            (#"(?i)(refresh_token=)[^&\s]+"#, "$1<redacted>"),
            (#"(?i)(token=)[^&\s]+"#, "$1<redacted>"),
            (#"(?i)(remixdsid=)[^&\s]+"#, "$1<redacted>"),
            (#"(?i)(cookie:\s*)[^\n]+"#, "$1<redacted>"),
            (#"(?i)(authorization:\s*bearer\s+)[^\s]+"#, "$1<redacted>"),
        ]
        for (pattern, template) in patterns {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: template,
                options: .regularExpression
            )
        }
        if truncate && sanitized.count > 512 {
            let index = sanitized.index(sanitized.startIndex, offsetBy: 512)
            sanitized = String(sanitized[..<index]) + "…"
        }
        return sanitized
    }

    /// Re-sanitize historical logs without truncating multi-line archives.
    static func redactArchiveData(_ data: Data) -> Data {
        Data(redact(String(decoding: data, as: UTF8.self), truncate: false).utf8)
    }

    static func redactURL(_ url: URL) -> String {
        redact(url.absoluteString)
    }
}

import Foundation

enum AppLogRedaction {
    private static let sensitiveFormKeys: Set<String> = [
        "access_token",
        "access_key",
        "track_code",
        "events",
        "audio",
        "photo",
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
            // Signed stream URLs, session ids and secrets in query form.
            (#"(?i)((?:extra|sig|sid|secret|password)=)[^&\s]+"#, "$1<redacted>"),
            // The same keys when a body is logged as JSON.
            (
                #"(?i)("(?:access_token|refresh_token|token|access_key|secret|password|remixsid|sid|extra)"\s*:\s*")(?:\\.|[^"\\])*"#,
                "$1<redacted>"
            ),
            (#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1<redacted>"),
        ]
        for (pattern, template) in patterns {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: template,
                options: .regularExpression
            )
        }
        // Structure-only response skeletons carry no values and are already
        // capped by APIResponseShape, so they get a larger budget.
        let limit = sanitized.contains(" shape=")
            ? APIResponseShape.maximumLength + 256
            : 512
        if truncate && sanitized.count > limit {
            let index = sanitized.index(sanitized.startIndex, offsetBy: limit)
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

import Foundation

struct AppConfiguration: Sendable {
    let vkAPIBaseURL: URL
    let telegramGroupURL: URL
    let telegramVPNURL: URL
    let apiVersion: String

    static let current: AppConfiguration = {
        let info = Bundle.main.infoDictionary ?? [:]

        func url(_ key: String, fallback: String) -> URL {
            let raw = info[key] as? String ?? fallback
            guard let value = URL(string: raw) else {
                preconditionFailure("Invalid URL for \(key)")
            }
            return value
        }

        // A malformed value would make every VK call fail, so only accept
        // "major.minor" and otherwise keep the known-good default.
        func version(_ key: String, fallback: String) -> String {
            guard let raw = info[key] as? String,
                  raw.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil
            else { return fallback }
            return raw
        }

        return AppConfiguration(
            vkAPIBaseURL: url("VK_API_BASE_URL", fallback: "https://api.vk.ru"),
            telegramGroupURL: url(
                "TELEGRAM_GROUP_URL",
                fallback: "https://t.me/+myDvOG6Y4s9mMDUy"
            ),
            telegramVPNURL: url(
                "TELEGRAM_VPN_URL",
                fallback: "https://t.me/decshopBot"
            ),
            apiVersion: version("VK_API_VERSION", fallback: "5.199")
        )
    }()
}

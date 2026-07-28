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
            apiVersion: "5.199"
        )
    }()
}

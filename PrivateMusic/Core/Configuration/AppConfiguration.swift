import Foundation

struct AppConfiguration: Sendable {
    let vkAPIBaseURL: URL
    let geniusAPIBaseURL: URL
    let telegramGroupURL: URL
    let telegramVPNURL: URL
    let apiVersion: String
    let demoMode: Bool

    static let current: AppConfiguration = {
        let info = Bundle.main.infoDictionary ?? [:]

        func url(_ key: String, fallback: String) -> URL {
            let raw = info[key] as? String ?? fallback
            guard let value = URL(string: raw) else {
                preconditionFailure("Invalid URL for \(key)")
            }
            return value
        }

        #if DEBUG
        let demo = ProcessInfo.processInfo.arguments.contains("--demo")
            || ProcessInfo.processInfo.environment["PRIVATE_MUSIC_DEMO"] == "1"
        #else
        let demo = false
        #endif

        return AppConfiguration(
            vkAPIBaseURL: url("VK_API_BASE_URL", fallback: "https://api.vk.ru"),
            geniusAPIBaseURL: url(
                "GENIUS_API_BASE_URL",
                fallback: "https://api.genius.com"
            ),
            telegramGroupURL: url(
                "TELEGRAM_GROUP_URL",
                fallback: "https://t.me/+myDvOG6Y4s9mMDUy"
            ),
            telegramVPNURL: url(
                "TELEGRAM_VPN_URL",
                fallback: "https://t.me/decshopBot"
            ),
            apiVersion: "5.199",
            demoMode: demo
        )
    }()
}


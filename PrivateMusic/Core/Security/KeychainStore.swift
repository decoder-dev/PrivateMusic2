import Foundation
import Security

/// Narrow seam over Keychain persistence so tests can substitute an
/// in-memory fake instead of depending on the OS Keychain being reachable
/// in the test host (Simulator Keychain access has been an observed source
/// of CI flakiness).
protocol KeychainStoring: Sendable {
    func save<Value: Codable>(_ value: Value, account: String) throws
    func load<Value: Codable>(
        _ type: Value.Type,
        account: String
    ) throws -> Value?
    func delete(account: String) throws
}

struct KeychainStore: KeychainStoring, Sendable {
    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(status):
                return "Keychain error: \(status)"
            case .invalidData:
                return "Keychain contains invalid data."
            }
        }
    }

    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.dec.privatemusic2") {
        self.service = service
    }

    func save<Value: Codable>(_ value: Value, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let query = baseQuery(account: account)
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            values as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var newItem = query
        values.forEach { newItem[$0.key] = $0.value }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    func load<Value: Codable>(
        _ type: Value.Type,
        account: String
    ) throws -> Value? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.invalidData
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

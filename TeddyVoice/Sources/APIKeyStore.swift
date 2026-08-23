import Foundation
import Security

struct APIKeyStore: Sendable {
    enum CredentialSource: String, Sendable {
        case teddyKeychain = "Trousseau Teddy CLI"
        case environment = "Variable XAI_API_KEY"
        case legacyKeychain = "Trousseau compatible hérité"
    }

    struct Credential: Sendable {
        let value: String
        let source: CredentialSource
    }

    private let ownService = "com.sipiyou.teddycli"
    private let ownAccount = "xai-api-key"
    // Compatibility bridge for keys stored by the earlier local prototype.
    // A successful read is immediately copied into Teddy CLI's own item.
    private let legacyService = "com.gaiko.app"
    private let legacyAccount = "com.gaiko.xaiAPIKey"

    func load() -> Credential? {
        if let key = read(service: ownService, account: ownAccount) {
            return Credential(value: key, source: .teddyKeychain)
        }

        if let key = normalized(ProcessInfo.processInfo.environment["XAI_API_KEY"]) {
            _ = saveToOwnKeychain(key)
            return Credential(value: key, source: .environment)
        }

        if let key = read(service: legacyService, account: legacyAccount) {
            _ = saveToOwnKeychain(key)
            return Credential(value: key, source: .legacyKeychain)
        }

        return nil
    }

    @discardableResult
    func saveToOwnKeychain(_ key: String) -> Bool {
        guard let key = normalized(key), let data = key.data(using: .utf8) else { return false }

        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: ownAccount,
        ]
        SecItemDelete(identity as CFDictionary)

        var item = identity
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return normalized(value)
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

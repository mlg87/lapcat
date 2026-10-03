import Foundation
import Security

/// Generic-password storage for the Anthropic API key (service `com.lapcat.app`, account `anthropic-api-key`).
public enum Keychain {
    public static let service = "com.lapcat.app"
    public static let apiKeyAccount = "anthropic-api-key"

    public struct Error: Swift.Error, Equatable {
        public let status: OSStatus
    }

    public static func apiKey() -> String? { string(account: apiKeyAccount) }
    public static func setAPIKey(_ key: String) throws { try setString(key, account: apiKeyAccount) }
    public static func deleteAPIKey() { delete(account: apiKeyAccount) }

    static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func string(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setString(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Error(status: status) }
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}

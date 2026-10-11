import Foundation
import Security

public struct RPKeychainError: LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        "Secure storage failed (\(status))."
    }
}

public enum RPKeychain {
    public static func save(_ data: Data, account: String, service: String) throws {
        let query = baseQuery(account: account, service: service)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var entry = query
            attributes.forEach { entry[$0.key] = $0.value }
            result = SecItemAdd(entry as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw RPKeychainError(status: result) }
    }

    public static func load(account: String, service: String) throws -> Data? {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RPKeychainError(status: status)
        }
        return data
    }

    public static func delete(account: String, service: String) throws {
        let status = SecItemDelete(baseQuery(account: account, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RPKeychainError(status: status) }
    }

    public static func saveString(_ string: String, account: String, service: String) throws {
        try save(Data(string.utf8), account: account, service: service)
    }

    public static func loadString(account: String, service: String) throws -> String? {
        guard let data = try load(account: account, service: service) else { return nil }
        guard let string = String(data: data, encoding: .utf8) else {
            throw RPKeychainError(status: errSecDecode)
        }
        return string
    }

    private static func baseQuery(account: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
}

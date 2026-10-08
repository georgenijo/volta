import Foundation
import Security

protocol TokenStoring: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

struct KeychainTokenStore: TokenStoring {
    let service: String
    let account: String
    init(service: String = "com.georgenijo.volta.device-token", account: String = "device") {
        self.service = service; self.account = account
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func load() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw StoreError(status: status) }
        return token
    }
    func save(_ token: String) throws {
        let data = Data(token.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; attributes.forEach { insert[$0.key] = $0.value }
            let result = SecItemAdd(insert as CFDictionary, nil)
            guard result == errSecSuccess else { throw StoreError(status: result) }
        } else if status != errSecSuccess { throw StoreError(status: status) }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError(status: status) }
    }
    struct StoreError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "The device token could not be accessed securely (\(status))." }
    }
}

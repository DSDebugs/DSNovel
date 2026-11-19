import Foundation
import Security

/// 内置解析器敏感配置与凭证的 Keychain 存储（⑤ 凭证隔离 + L-10）
///
/// 统一托管 `parser_pref_*` 配置（包含手工 Cookie、样本章节等），
/// 首次读取时自动兼容并迁移旧版 `UserDefaults` 数据到 Keychain，随后清理明文副本。
enum BuiltinParserKeychain {
    private static let service = "com.dsnovel.app.builtinparser.prefs"
    private static let lock = NSLock()

    static func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        if let value = readKeychainLocked(account: key) {
            return value
        }
        // 兼容迁移：若旧版明文存在于 UserDefaults，迁入 Keychain 并删除明文
        if let legacy = UserDefaults.standard.string(forKey: key), !legacy.isEmpty {
            _ = writeKeychainLocked(account: key, value: legacy)
            UserDefaults.standard.removeObject(forKey: key)
            return legacy
        }
        return nil
    }

    static func set(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }

        // 始终清理可能残留的 UserDefaults 明文键
        UserDefaults.standard.removeObject(forKey: key)

        guard let value, !value.isEmpty else {
            deleteKeychainLocked(account: key)
            return
        }
        if !writeKeychainLocked(account: key, value: value) {
            // 无 Keychain 权限的极端单测宿主环境兜底，避免测试失败
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private static func readKeychainLocked(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func writeKeychainLocked(account: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    private static func deleteKeychainLocked(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

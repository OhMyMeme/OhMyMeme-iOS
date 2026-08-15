import Foundation
import CryptoKit
import Security

enum CryptoUtil {
    private static let keychainService = "com.ohmymeme.app"
    private static let keychainAccount = "config-key"

    private static func loadOrCreateKey() -> SymmetricKey {
        if let data = keychainData(account: keychainAccount), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        saveKeychainData(data, account: keychainAccount)
        return key
    }

    static func encrypt(_ plaintext: String) -> String {
        guard !plaintext.isEmpty else { return "" }
        guard let data = plaintext.data(using: .utf8) else { return plaintext }
        do {
            let sealed = try AES.GCM.seal(data, using: loadOrCreateKey())
            return sealed.combined?.base64EncodedString() ?? ""
        } catch {
            return plaintext
        }
    }

    static func decrypt(_ encoded: String) -> String {
        guard !encoded.isEmpty else { return "" }
        guard let combined = Data(base64Encoded: encoded), !combined.isEmpty else { return encoded }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let data = try AES.GCM.open(box, using: loadOrCreateKey())
            return String(data: data, encoding: .utf8) ?? encoded
        } catch {
            return encoded
        }
    }

    private static func keychainData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private static func saveKeychainData(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
}
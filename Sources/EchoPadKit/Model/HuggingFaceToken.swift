import Foundation
import Security

/// The Hugging Face read token the external transcriber needs for gated models, kept as a
/// generic password in the login Keychain. It is only ever handed to `--setup` as `HF_TOKEN`.
enum HuggingFaceToken {
    static let SERVICE = "io.github.pieralukasz.echopad"
    static let ACCOUNT = "huggingface"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: SERVICE,
         kSecAttrAccount as String: ACCOUNT]
    }

    /// Checks for a stored token without reading it.
    static var isStored: Bool {
        SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    static func save(_ token: String) throws {
        delete()
        var query = query
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrLabel as String] = "EchoPad Hugging Face token"
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

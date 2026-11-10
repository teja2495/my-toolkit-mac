import Foundation
import Security

enum WritingFixAPIKeyStore {
    /// Removes an OpenAI API key saved by earlier versions; API keys are no longer supported.
    static func deleteLegacyKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tk.toolkit.rewritely.chatgpt",
            kSecAttrAccount as String: "openai-api-key"
        ]
        SecItemDelete(query as CFDictionary)
    }
}

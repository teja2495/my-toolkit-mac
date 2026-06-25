import CryptoKit
import Foundation
import Security

final class PhoneBridgeCrypto {
    private let keychainService = "com.tk.toolkit.phone-bridge"
    private let identityAccount = "identity-key-v1"

    func getOrCreateIdentityKey() throws -> P256.KeyAgreement.PrivateKey {
        if let data = loadKeychainData(account: identityAccount) {
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
        let key = P256.KeyAgreement.PrivateKey()
        try saveKeychainData(key.rawRepresentation, account: identityAccount)
        return key
    }

    func publicKeyBase64(_ key: P256.KeyAgreement.PublicKey) -> String {
        key.derRepresentation.base64EncodedString()
    }

    func publicKey(fromBase64 value: String) throws -> P256.KeyAgreement.PublicKey {
        guard let data = Data(base64Encoded: value) else {
            throw PhoneBridgeCryptoError.invalidPublicKey
        }
        return try P256.KeyAgreement.PublicKey(derRepresentation: data)
    }

    func deriveSessionKey(
        localPrivateKey: P256.KeyAgreement.PrivateKey,
        remotePublicKey: P256.KeyAgreement.PublicKey,
        salt: Data
    ) throws -> SymmetricKey {
        let secret = try localPrivateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("tk-toolkit-phone-v1".utf8),
            outputByteCount: 32
        )
    }

    func verificationCode(localPublicKeyBase64: String, remotePublicKeyBase64: String) -> String {
        let ordered = [localPublicKeyBase64, remotePublicKeyBase64].sorted().joined(separator: ":")
        let digest = SHA256.hash(data: Data(ordered.utf8))
        let prefix = digest.prefix(4).reduce(UInt32(0)) { value, byte in
            (value << 8) | UInt32(byte)
        } & 0x7fffffff
        return String(format: "%06d", prefix % 1_000_000)
    }

    func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw PhoneBridgeCryptoError.encryptionFailed
        }
        return combined
    }

    func decrypt(_ ciphertext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    private func loadKeychainData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func saveKeychainData(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PhoneBridgeCryptoError.keychainSaveFailed(status)
        }
    }
}

enum PhoneBridgeCryptoError: Error {
    case invalidPublicKey
    case encryptionFailed
    case keychainSaveFailed(OSStatus)
}

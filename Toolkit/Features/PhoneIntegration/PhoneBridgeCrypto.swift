import CryptoKit
import Foundation

final class PhoneBridgeCrypto {
    private let store: PhoneBridgeStore

    init(store: PhoneBridgeStore = PhoneBridgeStore()) {
        self.store = store
    }

    func getOrCreateIdentityKey() throws -> P256.KeyAgreement.PrivateKey {
        if let data = store.identityKeyData() {
            do {
                return try P256.KeyAgreement.PrivateKey(rawRepresentation: data)
            } catch {
                store.removeIdentityKeyData()
            }
        }
        let key = P256.KeyAgreement.PrivateKey()
        // TODO: Move this pairing identity back to Keychain with non-interactive access once the feature is finalized.
        store.saveIdentityKeyData(key.rawRepresentation)
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
}

enum PhoneBridgeCryptoError: Error {
    case invalidPublicKey
    case encryptionFailed
}

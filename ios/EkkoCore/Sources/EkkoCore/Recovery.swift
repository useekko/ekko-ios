import CryptoKit
import Foundation

// Swift port of src/core/recovery.ts. The 24-word phrase is the account-free backup: it
// deterministically derives the recovery key (which authorizes rotating a device key while
// keeping your @handle) and every device key. Restore the phrase on a new device — or on this
// phone after using the browser extension — and you get the SAME identity and fingerprint.
public enum Recovery {
    static let kdfSalt = Data("Ekko/recovery/v1".utf8)

    public static func generateMnemonic() -> String { BIP39.generateMnemonic() }
    public static func isValidMnemonic(_ p: String) -> Bool { BIP39.isValid(p) }
    public static func normalize(_ p: String) -> String { BIP39.normalize(p) }

    /// The recovery key: a fixed derivation that never rotates. Its private half proves you own
    /// the phrase; the directory stores its public bundle as the account-free recovery anchor.
    public static func recoveryIdentity(phrase: String) throws -> Identity {
        try derive(seed: BIP39.seed(from: phrase), path: "recovery")
    }

    /// The device key at a rotation index (0 = first). Losing a device → derive the next index
    /// from the same phrase and prove control of the recovery key to rebind the handle.
    public static func deviceIdentity(phrase: String, index: Int = 0) throws -> Identity {
        try derive(seed: BIP39.seed(from: phrase), path: "device/\(index)")
    }

    /// HKDF gives clean domain separation, so the recovery key and each device key are
    /// independent: 32 bytes for the X25519 scalar, 64 for the ML-KEM seed.
    static func derive(seed: Data, path: String) throws -> Identity {
        let out = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: seed),
            salt: kdfSalt,
            info: Data(path.utf8),
            outputByteCount: 96
        ).withUnsafeBytes { Data($0) }
        return try EkkoCrypto.identity(xPriv: out.subdata(in: 0..<32), kSeed: out.subdata(in: 32..<96))
    }
}

import CommonCrypto
import Foundation

/// Encrypted key backup — the Swift half of `src/core/backup.ts`. Read that file first: it carries
/// the reasoning (why the blob is opaque to whoever stores it, why PBKDF2 and not the local vault's
/// scrypt, and why the answer to PBKDF2 being fast is a six-word generated passphrase rather than a
/// slower KDF).
///
/// The two implementations must agree byte for byte, because a blob written by the browser
/// extension has to open on the phone and vice versa. `npm run ios:interop` is what holds them
/// together; it seals with the real TypeScript core and opens here, and back again.
public enum Backup {
    public static let version = 1
    public static let iterations = 600_000
    public static let minPassphraseLength = 12

    static let kdfName = "pbkdf2-sha256"

    public enum Error: Swift.Error, LocalizedError {
        case passphraseTooShort
        case wrongPassphrase
        case unsupportedVersion(Int)
        case unknownKDF(String)
        case unusableIterations
        case malformed

        public var errorDescription: String? {
            switch self {
            case .passphraseTooShort:
                return "Passphrase must be at least \(Backup.minPassphraseLength) characters."
            case .wrongPassphrase: return "That passphrase does not open this backup."
            case .unsupportedVersion(let v):
                return "This backup was written by a newer version of Ekko (v\(v))."
            case .unknownKDF(let k): return "Unknown key derivation: \(k)"
            case .unusableIterations: return "This backup has an unusable iteration count."
            case .malformed: return "This backup is damaged."
            }
        }
    }

    /// The stored envelope. `salt`, `nonce` and `ct` are base64url, matching the TS side exactly.
    public struct Blob: Codable, Sendable, Equatable {
        public var v: Int
        public var kdf: String
        public var iter: Int
        public var salt: String
        public var nonce: String
        public var ct: String

        public init(v: Int, kdf: String, iter: Int, salt: String, nonce: String, ct: String) {
            self.v = v
            self.kdf = kdf
            self.iter = iter
            self.salt = salt
            self.nonce = nonce
            self.ct = ct
        }
    }

    /// A contact as it travels inside the blob. `addedAt` is milliseconds since the epoch, because
    /// that is what `Date.now()` gives the TypeScript core and the wire format is shared.
    public struct BackedUpContact: Codable, Sendable, Equatable {
        public var bundle: String  // base64url
        public var label: String
        public var verified: Bool
        public var addedAt: Double
    }

    public struct Payload: Codable, Sendable, Equatable {
        public var v: Int
        public var mnemonic: String
        public var contacts: [BackedUpContact]
    }

    // MARK: - Passphrase

    /// Six words from the BIP39 list (~77 bits). See backup.ts: this, not the KDF, is what makes an
    /// offline attack on the blob hopeless.
    public static func generatePassphrase(words: Int = 6) -> String {
        (0..<words).map { _ in
            var b = Data(count: 2)
            _ = b.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 2, $0.baseAddress!) }
            let i = (Int(b[0]) << 8 | Int(b[1])) & 0x7ff
            return BIP39Wordlist.words[i]
        }
        .joined(separator: " ")
    }

    // MARK: - Seal / open

    public static func seal(
        mnemonic: String, contacts: [Contact], passphrase: String
    ) throws -> Blob {
        guard passphrase.count >= minPassphraseLength else { throw Error.passphraseTooShort }
        let salt = random(16)
        let nonce = random(24)
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)

        let payload = Payload(
            v: version,
            mnemonic: mnemonic,
            contacts: contacts.map {
                BackedUpContact(
                    bundle: b64u($0.bundle),
                    label: $0.label,
                    verified: $0.verified,
                    addedAt: $0.addedAt.timeIntervalSince1970 * 1000)
            })

        let plaintext = try JSONEncoder().encode(payload)
        let ct = try XChaCha.seal(
            key: key, nonce: nonce, aad: header(version, kdfName, iterations), plaintext: plaintext)

        return Blob(
            v: version, kdf: kdfName, iter: iterations,
            salt: b64u(salt), nonce: b64u(nonce), ct: b64u(ct))
    }

    public static func open(_ blob: Blob, passphrase: String) throws -> Payload {
        guard blob.v == version else { throw Error.unsupportedVersion(blob.v) }
        guard blob.kdf == kdfName else { throw Error.unknownKDF(blob.kdf) }
        // A hostile row could otherwise ask for a billion rounds and wedge the phone rather than
        // failing. The lower bound is the one that matters: it is the downgrade attack.
        guard blob.iter >= 1, blob.iter <= 10_000_000 else { throw Error.unusableIterations }
        guard let salt = b64uDecode(blob.salt),
            let nonce = b64uDecode(blob.nonce),
            let ct = b64uDecode(blob.ct)
        else { throw Error.malformed }

        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: blob.iter)
        // The KDF parameters are AAD, so editing them in the database breaks the tag rather than
        // silently weakening the key.
        let aad = header(blob.v, blob.kdf, blob.iter)

        let plaintext: Data
        do {
            plaintext = try XChaCha.open(key: key, nonce: nonce, aad: aad, sealed: ct)
        } catch {
            // Poly1305 cannot distinguish a wrong key from a tampered blob. The wrong passphrase is
            // overwhelmingly the likelier one; do not accuse the server.
            throw Error.wrongPassphrase
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: plaintext),
            !payload.mnemonic.isEmpty
        else { throw Error.malformed }
        return payload
    }

    /// The contacts from an opened payload, back as the type the vault stores.
    public static func contacts(from payload: Payload) -> [Contact] {
        payload.contacts.compactMap { c in
            guard let bundle = b64uDecode(c.bundle) else { return nil }
            return Contact(
                bundle: bundle, label: c.label, verified: c.verified,
                addedAt: Date(timeIntervalSince1970: c.addedAt / 1000))
        }
    }

    // MARK: - Internals

    /// Byte-identical to `JSON.stringify({ v, kdf, iter })` in backup.ts. Hand-built rather than
    /// encoded, because JSONEncoder does not promise key order and this string is authenticated —
    /// a different byte order here means every blob the extension wrote fails to open.
    static func header(_ v: Int, _ kdf: String, _ iter: Int) -> Data {
        Data(#"{"v":\#(v),"kdf":"\#(kdf)","iter":\#(iter)}"#.utf8)
    }

    static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> Data {
        // NFKC, matching `passphrase.normalize('NFKC')` on the TS side: without it the same words
        // typed on two keyboards can derive two different keys.
        let pw = Data(passphrase.precomposedStringWithCompatibilityMapping.utf8)
        var out = Data(count: 32)

        let status = out.withUnsafeMutableBytes { outBuf -> Int32 in
            salt.withUnsafeBytes { saltBuf -> Int32 in
                pw.withUnsafeBytes { pwBuf -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBuf.baseAddress!.assumingMemoryBound(to: CChar.self), pw.count,
                        saltBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == kCCSuccess else { throw Error.malformed }
        return out
    }

    static func random(_ n: Int) -> Data {
        var d = Data(count: n)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }
}

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

    /// A session as it travels inside the blob. `handshakeWire` is deliberately absent: it is
    /// pending-delivery state, while these keys are the capability that opens message history.
    ///
    /// `threadId` and `acct` belong to the browser's routing model. iOS does not interpret them,
    /// but it must preserve both so restoring and then backing up on a phone does not strip state
    /// that a later browser restore needs.
    public struct BackedUpSession: Codable, Sendable, Equatable {
        public var id: String  // base64url, 8 bytes
        public var key0to1: String  // base64url, 32 bytes
        public var key1to0: String  // base64url, 32 bytes
        public var myParty: Int  // the reference restore normalizes 1 to 1 and everything else to 0
        public var peerFingerprint: String  // base64url, 32 bytes
        public var threadId: String?
        public var acct: Bool?

        public init(
            id: String, key0to1: String, key1to0: String, myParty: Int,
            peerFingerprint: String, threadId: String? = nil, acct: Bool? = nil
        ) {
            self.id = id
            self.key0to1 = key0to1
            self.key1to0 = key1to0
            self.myParty = myParty
            self.peerFingerprint = peerFingerprint
            self.threadId = threadId
            self.acct = acct
        }

        private enum CodingKeys: String, CodingKey {
            case id, key0to1, key1to0, myParty, peerFingerprint, threadId, acct
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            key0to1 = try c.decode(String.self, forKey: .key0to1)
            key1to0 = try c.decode(String.self, forKey: .key1to0)
            myParty = try c.decode(Int.self, forKey: .myParty)
            peerFingerprint = try c.decode(String.self, forKey: .peerFingerprint)
            // Match the TypeScript restore's `typeof` checks: bad optional metadata is ignored,
            // while malformed key material makes only this entry lossy (see Payload below).
            threadId = try? c.decode(String.self, forKey: .threadId)
            acct = try? c.decode(Bool.self, forKey: .acct)
        }
    }

    public struct Payload: Codable, Sendable, Equatable {
        public var v: Int
        public var mnemonic: String
        public var contacts: [BackedUpContact]
        /// Empty for v1 blobs written before sessions joined the additive payload.
        public var sessions: [BackedUpSession]

        public init(
            v: Int, mnemonic: String, contacts: [BackedUpContact],
            sessions: [BackedUpSession] = []
        ) {
            self.v = v
            self.mnemonic = mnemonic
            self.contacts = contacts
            self.sessions = sessions
        }

        private enum CodingKeys: String, CodingKey { case v, mnemonic, contacts, sessions }

        private struct LossySession: Decodable {
            let value: BackedUpSession?

            init(from decoder: Decoder) {
                value = try? BackedUpSession(from: decoder)
            }
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            v = try c.decode(Int.self, forKey: .v)
            mnemonic = try c.decode(String.self, forKey: .mnemonic)
            contacts = try c.decode([BackedUpContact].self, forKey: .contacts)
            // A missing field is an old blob. A malformed element is skipped independently so one
            // damaged session never prevents the identity and every other session from restoring.
            sessions = (try? c.decode([LossySession].self, forKey: .sessions))?
                .compactMap(\.value) ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(v, forKey: .v)
            try c.encode(mnemonic, forKey: .mnemonic)
            try c.encode(contacts, forKey: .contacts)
            try c.encode(sessions, forKey: .sessions)
        }
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
        mnemonic: String, contacts: [Contact], sessions: [Session] = [], passphrase: String
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
            },
            sessions: sessions.map {
                BackedUpSession(
                    id: b64u($0.id),
                    key0to1: b64u($0.key0to1),
                    key1to0: b64u($0.key1to0),
                    myParty: Int($0.myParty),
                    peerFingerprint: b64u($0.peerFingerprint),
                    // A restored browser scope wins. The fallback supports sessions constructed
                    // directly with a browser-like scope while keeping iOS's private `ios:` route
                    // out of the shared format.
                    threadId: $0.browserThreadId
                        ?? $0.threadId.flatMap { $0.hasPrefix("ios:") ? nil : $0 },
                    acct: $0.acct)
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

    /// Valid sessions from an opened payload, back as the type the vault stores. Each row stands
    /// alone: invalid base64url or a wrong byte length drops that row and nothing else.
    public static func sessions(from payload: Payload) -> [Session] {
        payload.sessions.compactMap { s in
            guard let id = b64uDecode(s.id), id.count == Proto.sid,
                let key0to1 = b64uDecode(s.key0to1), key0to1.count == 32,
                let key1to0 = b64uDecode(s.key1to0), key1to0.count == 32,
                let peerFingerprint = b64uDecode(s.peerFingerprint), peerFingerprint.count == 32
            else { return nil }

            return Session(
                id: id,
                key0to1: key0to1,
                key1to0: key1to0,
                myParty: s.myParty == 1 ? 1 : 0,
                peerFingerprint: peerFingerprint,
                browserThreadId: s.threadId,
                acct: s.acct)
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

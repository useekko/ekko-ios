import CryptoKit
import Foundation

// XChaCha20-Poly1305 — the AEAD the Ekko wire format uses (24-byte nonce).
//
// CryptoKit ships only the IETF ChaCha20-Poly1305 (12-byte nonce), so the extended-nonce
// variant is built on top of it exactly as draft-irtf-cfrg-xchacha specifies:
//
//   subkey     = HChaCha20(key, nonce[0..<16])
//   ietf_nonce = 0x00000000 ‖ nonce[16..<24]
//   output     = ChaCha20-Poly1305(subkey, ietf_nonce, aad, plaintext)
//
// Only HChaCha20 is hand-written; the AEAD itself stays in CryptoKit. Verified against
// @noble/ciphers vectors in InteropTests.
enum XChaCha {
    static let nonceSize = 24
    static let keySize = 32
    static let tagSize = 16

    enum Error: Swift.Error {
        case badKeySize
        case badNonceSize
        case authenticationFailed
    }

    /// noble's `.encrypt()` returns ciphertext ‖ tag; match that layout so the bytes are
    /// interchangeable with what the extension produces.
    static func seal(key: Data, nonce: Data, aad: Data, plaintext: Data) throws -> Data {
        let (subkey, ietfNonce) = try derive(key: key, nonce: nonce)
        let box = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: subkey),
            nonce: try ChaChaPoly.Nonce(data: ietfNonce),
            authenticating: aad
        )
        return box.ciphertext + box.tag
    }

    /// `sealed` is ciphertext ‖ tag. Throws on tamper (the tag check is CryptoKit's).
    static func open(key: Data, nonce: Data, aad: Data, sealed: Data) throws -> Data {
        guard sealed.count >= tagSize else { throw Error.authenticationFailed }
        let (subkey, ietfNonce) = try derive(key: key, nonce: nonce)
        let split = sealed.count - tagSize
        let box = try ChaChaPoly.SealedBox(
            nonce: try ChaChaPoly.Nonce(data: ietfNonce),
            ciphertext: sealed.prefix(split),
            tag: sealed.suffix(tagSize)
        )
        do {
            return try ChaChaPoly.open(box, using: SymmetricKey(data: subkey), authenticating: aad)
        } catch {
            throw Error.authenticationFailed
        }
    }

    private static func derive(key: Data, nonce: Data) throws -> (subkey: Data, ietfNonce: Data) {
        guard key.count == keySize else { throw Error.badKeySize }
        guard nonce.count == nonceSize else { throw Error.badNonceSize }
        let subkey = hchacha20(key: key, nonce16: nonce.prefix(16))
        // 4 zero bytes ‖ the trailing 8 nonce bytes.
        let ietfNonce = Data(repeating: 0, count: 4) + nonce.suffix(8)
        return (subkey, ietfNonce)
    }

    // MARK: - HChaCha20 (RFC draft, §2.2)

    private static let sigma: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]

    private static func hchacha20(key: Data, nonce16: Data) -> Data {
        var s = [UInt32](repeating: 0, count: 16)
        s[0] = sigma[0]; s[1] = sigma[1]; s[2] = sigma[2]; s[3] = sigma[3]
        let k = [UInt8](key)
        for i in 0..<8 { s[4 + i] = le32(k, i * 4) }
        let n = [UInt8](nonce16)
        for i in 0..<4 { s[12 + i] = le32(n, i * 4) }

        for _ in 0..<10 {
            quarter(&s, 0, 4, 8, 12)
            quarter(&s, 1, 5, 9, 13)
            quarter(&s, 2, 6, 10, 14)
            quarter(&s, 3, 7, 11, 15)
            quarter(&s, 0, 5, 10, 15)
            quarter(&s, 1, 6, 11, 12)
            quarter(&s, 2, 7, 8, 13)
            quarter(&s, 3, 4, 9, 14)
        }

        // HChaCha20 takes the first and last rows of the permuted state, with NO feed-forward
        // addition of the original state (that is what makes it a PRF rather than a stream).
        var out = Data(capacity: 32)
        for i in [0, 1, 2, 3, 12, 13, 14, 15] { appendLE32(&out, s[i]) }
        return out
    }

    private static func quarter(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] &+= s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 16)
        s[c] &+= s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 12)
        s[a] &+= s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 8)
        s[c] &+= s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 7)
    }

    private static func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 { (v << n) | (v >> (32 - n)) }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    private static func appendLE32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xff))
        d.append(UInt8((v >> 8) & 0xff))
        d.append(UInt8((v >> 16) & 0xff))
        d.append(UInt8((v >> 24) & 0xff))
    }
}

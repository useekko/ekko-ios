import CommonCrypto
import CryptoKit
import Foundation

// BIP39 mnemonic. Swift port of what @scure/bip39 does for src/core/recovery.ts, so the same
// 24 words derive the same seed on iPhone and in the browser.
//
// ponytail: PBKDF2 comes from CommonCrypto (system), the wordlist is a frozen constant, and the
// bit-packing is 30 lines. No dependency for any of it.
public enum BIP39 {
    public enum BIP39Error: Error { case badWordCount, unknownWord, badChecksum }

    /// 24 words = 256-bit entropy. Deliberately stronger than a wallet's usual 12: every key here
    /// is DERIVED from this seed, so 128 bits would cap a seed-derived ML-KEM-768 key at ~2^64
    /// under Grover, undercutting the whole post-quantum promise. 256 keeps the full PQ margin.
    public static func generateMnemonic() -> String {
        var entropy = Data(count: 32)
        entropy.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return entropyToMnemonic(entropy)
    }

    /// Lowercase, collapse whitespace — tolerant of how a user re-types their words.
    public static func normalize(_ phrase: String) -> String {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    public static func isValid(_ phrase: String) -> Bool {
        (try? validate(phrase)) != nil
    }

    /// Seed for key derivation: PBKDF2-HMAC-SHA512(phrase, "mnemonic", 2048) → 64 bytes.
    /// Matches @scure/bip39's `mnemonicToSeedSync` with an empty passphrase.
    public static func seed(from phrase: String) -> Data {
        let pw = Data(normalize(phrase).decomposedStringWithCompatibilityMapping.utf8)  // NFKD
        let salt = Data("mnemonic".decomposedStringWithCompatibilityMapping.utf8)
        return pbkdf2SHA512(password: pw, salt: salt, rounds: 2048, keyLength: 64)
    }

    // MARK: - words <-> entropy

    static func entropyToMnemonic(_ entropy: Data) -> String {
        // bits = entropy ‖ first (len*8/32) bits of sha256(entropy); each 11 bits indexes a word.
        let checksumBits = entropy.count * 8 / 32
        var bits = [Bool]()
        for byte in entropy {
            for i in (0..<8).reversed() { bits.append((byte >> UInt8(i)) & 1 == 1) }
        }
        let hash = sha256(entropy)
        for i in 0..<checksumBits {
            let byte = hash[i / 8]
            bits.append((byte >> UInt8(7 - i % 8)) & 1 == 1)
        }
        var words: [String] = []
        for i in stride(from: 0, to: bits.count, by: 11) {
            var idx = 0
            for j in 0..<11 { idx = idx << 1 | (bits[i + j] ? 1 : 0) }
            words.append(BIP39Wordlist.words[idx])
        }
        return words.joined(separator: " ")
    }

    @discardableResult
    static func validate(_ phrase: String) throws -> Data {
        let words = normalize(phrase).split(separator: " ").map(String.init)
        guard [12, 15, 18, 21, 24].contains(words.count) else { throw BIP39Error.badWordCount }

        var bits = [Bool]()
        for w in words {
            guard let idx = BIP39Wordlist.index[w] else { throw BIP39Error.unknownWord }
            for i in (0..<11).reversed() { bits.append((idx >> i) & 1 == 1) }
        }
        let entropyBits = words.count * 11 * 32 / 33
        let checksumBits = bits.count - entropyBits

        var entropy = Data()
        for i in stride(from: 0, to: entropyBits, by: 8) {
            var byte: UInt8 = 0
            for j in 0..<8 { byte = byte << 1 | (bits[i + j] ? 1 : 0) }
            entropy.append(byte)
        }
        let hash = sha256(entropy)
        for i in 0..<checksumBits {
            let expected = (hash[i / 8] >> UInt8(7 - i % 8)) & 1 == 1
            guard bits[entropyBits + i] == expected else { throw BIP39Error.badChecksum }
        }
        return entropy
    }

    // MARK: - PBKDF2

    static func pbkdf2SHA512(password: Data, salt: Data, rounds: Int, keyLength: Int) -> Data {
        var out = Data(count: keyLength)
        let status = out.withUnsafeMutableBytes { outBuf in
            password.withUnsafeBytes { pwBuf in
                salt.withUnsafeBytes { saltBuf in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBuf.baseAddress!.assumingMemoryBound(to: CChar.self), password.count,
                        saltBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        UInt32(rounds),
                        outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), keyLength
                    )
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return out
    }
}

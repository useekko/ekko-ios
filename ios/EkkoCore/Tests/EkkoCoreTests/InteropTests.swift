import Foundation
import Testing

@testable import EkkoCore

// The load-bearing test for the whole iOS app: prove the Swift core and the TypeScript core
// (src/core) are the same protocol, byte for byte.
//
// Vectors are produced by the REAL src/core — run `npm run ios:interop`, which regenerates
// vectors.json, runs this test, then opens what this test seals using the TS core. Running
// `swift test` alone checks the TS → Swift direction against whatever vectors are committed.

struct Vectors: Decodable {
    struct Bundle: Decodable {
        let bundle: String
        var fingerprint: String?
        var xPub: String?
    }
    struct MLKEMSeed: Decodable {
        let seed: String
        let pub: String
    }
    struct XChaChaVec: Decodable {
        let key: String
        let nonce: String
        let aad: String
        let plaintext: String
        let sealed: String
    }
    struct TSToSwift: Decodable {
        let handshakeWire: String
        let messageBody: String
        let expectedPlaintext: String
        let sessionId: String
        let key0to1: String
        let key1to0: String
        let initiatorParty: Int
    }
    struct ChunkVec: Decodable {
        let id: String
        let maxLen: Int
        let parts: [String]
    }
    struct ClassifyVec: Decodable {
        let text: String
        let kind: String?
        let standalone: Bool
    }
    struct BackupSessionVec: Decodable {
        let id: String
        let key0to1: String
        let key1to0: String
        let myParty: Int
        let peerFingerprint: String
        let threadId: String
        let acct: Bool
    }
    struct BackupVec: Decodable {
        let passphrase: String
        let blob: Backup.Blob
        let legacyBlob: Backup.Blob
        let expectedMnemonic: String
        let expectedContactBundle: String
        let expectedContactLabel: String
        let expectedContactAddedAt: Double
        let expectedSession: BackupSessionVec
    }

    let phraseA: String
    let phraseB: String
    let seedA: String
    let deviceA: Bundle
    let deviceB: Bundle
    let recoveryA: Bundle
    let mlkemSeed: MLKEMSeed
    let xchacha: XChaChaVec
    let tsToSwift: TSToSwift
    let safetyNumber: String
    let fingerprintHexA: String
    let inviteA: String
    let chunk: ChunkVec
    let classify: [ClassifyVec]
    let backup: BackupVec
}

let vectors: Vectors = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("vectors.json")
    guard let data = try? Data(contentsOf: url) else {
        fatalError("vectors.json missing — run `npm run ios:interop` to generate it")
    }
    return try! JSONDecoder().decode(Vectors.self, from: data)
}()

func hexData(_ s: String) -> Data { Data(hexString: s)! }

@Suite("TypeScript interop")
struct InteropTests {

    // MARK: - Identity derivation

    @Test("BIP39 seed matches @scure/bip39")
    func seed() {
        #expect(BIP39.seed(from: vectors.phraseA).hexString == vectors.seedA)
    }

    @Test("the same 24 words derive the same identity as the browser extension")
    func identityFromPhrase() throws {
        let a = try Recovery.deviceIdentity(phrase: vectors.phraseA)
        #expect(a.bundle.hexString == vectors.deviceA.bundle)
        #expect(a.fingerprint.hexString == vectors.deviceA.fingerprint)
        #expect(a.xPubKey.hexString == vectors.deviceA.xPub)

        let b = try Recovery.deviceIdentity(phrase: vectors.phraseB)
        #expect(b.bundle.hexString == vectors.deviceB.bundle)

        // The recovery key is a separate HKDF path and must not collide with the device key.
        let r = try Recovery.recoveryIdentity(phrase: vectors.phraseA)
        #expect(r.bundle.hexString == vectors.recoveryA.bundle)
        #expect(r.bundle != a.bundle)
    }

    @Test("CryptoKit ML-KEM-768 expands a seed identically to @noble/post-quantum")
    func mlkemSeedExpansion() throws {
        let id = try EkkoCrypto.identity(
            xPriv: Data(repeating: 1, count: 32), kSeed: hexData(vectors.mlkemSeed.seed))
        #expect(id.kPubKey.hexString == vectors.mlkemSeed.pub)
    }

    // MARK: - AEAD

    @Test("XChaCha20-Poly1305 matches @noble/ciphers")
    func xchachaVector() throws {
        let v = vectors.xchacha
        let sealed = try XChaCha.seal(
            key: hexData(v.key), nonce: hexData(v.nonce), aad: hexData(v.aad),
            plaintext: hexData(v.plaintext))
        #expect(sealed.hexString == v.sealed)

        let opened = try XChaCha.open(
            key: hexData(v.key), nonce: hexData(v.nonce), aad: hexData(v.aad),
            sealed: hexData(v.sealed))
        #expect(opened.hexString == v.plaintext)
    }

    @Test("XChaCha20-Poly1305 rejects a tampered tag")
    func xchachaTamper() throws {
        let v = vectors.xchacha
        var bad = hexData(v.sealed)
        bad[bad.count - 1] ^= 1
        #expect(throws: (any Error).self) {
            try XChaCha.open(
                key: hexData(v.key), nonce: hexData(v.nonce), aad: hexData(v.aad), sealed: bad)
        }
    }

    // MARK: - Handshake + message, TS → Swift

    @Test("a TypeScript handshake establishes the same session in Swift")
    func acceptsTSHandshake() throws {
        let me = try Recovery.deviceIdentity(phrase: vectors.phraseB)  // Swift plays B
        let (session, peerBundle) = try EkkoCrypto.acceptHandshake(
            me: me, wire: hexData(vectors.tsToSwift.handshakeWire))

        #expect(peerBundle.hexString == vectors.deviceA.bundle)
        #expect(session.id.hexString == vectors.tsToSwift.sessionId)
        #expect(session.key0to1.hexString == vectors.tsToSwift.key0to1)
        #expect(session.key1to0.hexString == vectors.tsToSwift.key1to0)
        // Canonical party assignment is order-independent: the two sides must disagree.
        #expect(Int(session.myParty) != vectors.tsToSwift.initiatorParty)
    }

    @Test("a TypeScript-sealed message opens in Swift")
    func opensTSMessage() throws {
        let me = try Recovery.deviceIdentity(phrase: vectors.phraseB)
        let (session, _) = try EkkoCrypto.acceptHandshake(
            me: me, wire: hexData(vectors.tsToSwift.handshakeWire))
        let text = try EkkoCrypto.openMessage(
            session: session, body: hexData(vectors.tsToSwift.messageBody))
        #expect(text == vectors.tsToSwift.expectedPlaintext)
    }

    @Test("a tampered message body fails to open")
    func tamperedMessage() throws {
        let me = try Recovery.deviceIdentity(phrase: vectors.phraseB)
        let (session, _) = try EkkoCrypto.acceptHandshake(
            me: me, wire: hexData(vectors.tsToSwift.handshakeWire))
        var body = hexData(vectors.tsToSwift.messageBody)
        body[body.count - 1] ^= 1
        #expect(throws: (any Error).self) {
            try EkkoCrypto.openMessage(session: session, body: body)
        }
    }

    // MARK: - Display + wire strings

    @Test("safety number and fingerprint render identically")
    func display() throws {
        let a = try Recovery.deviceIdentity(phrase: vectors.phraseA)
        let b = try Recovery.deviceIdentity(phrase: vectors.phraseB)
        #expect(EkkoCrypto.safetyNumber(fpMe: a.fingerprint, fpPeer: b.fingerprint) == vectors.safetyNumber)
        // Symmetric: both sides read the same number aloud.
        #expect(
            EkkoCrypto.safetyNumber(fpMe: b.fingerprint, fpPeer: a.fingerprint) == vectors.safetyNumber)
        #expect(EkkoCrypto.fingerprintHex(a.fingerprint) == vectors.fingerprintHexA)
    }

    @Test("invite encoding matches")
    func invite() throws {
        let a = try Recovery.deviceIdentity(phrase: vectors.phraseA)
        #expect(Wire.formatInvite(a.bundle) == vectors.inviteA)
        let decoded = try Wire.decodeBody(vectors.inviteA)
        #expect(decoded.hexString == vectors.deviceA.bundle)
    }

    @Test("chunk split matches the TypeScript splitter")
    func chunkSplit() throws {
        let token = Wire.formatHandshake(hexData(vectors.tsToSwift.handshakeWire))
        let parts = try Chunk.split(token: token, maxLen: vectors.chunk.maxLen, id: vectors.chunk.id)
        #expect(parts == vectors.chunk.parts)

        // …and reassemble back to the original token, out of order.
        let r = Reassembler()
        var result: String?
        for p in parts.shuffled() { result = r.add(p) ?? result }
        #expect(result == token)
    }

    @Test("token classification matches")
    func classify() {
        for c in vectors.classify {
            let found = Wire.classify(c.text)
            #expect(found?.kind.rawValue == c.kind, "classify(\(c.text.prefix(30))…)")
            let standalone = Wire.classifyStandalone(c.text)
            #expect((standalone != nil) == c.standalone, "classifyStandalone(\(c.text.prefix(30))…)")
        }
    }

    @Test
    func legacyResonancePrefixesRemainReadable() {
        #expect(Wire.classify("RSN1I:AQ")?.kind == .invite)
        #expect(Wire.classify("RSN1H:AQ")?.kind == .handshake)
        #expect(Wire.classify("RSN1M:AQ")?.kind == .message)
        #expect(Wire.classify("RSN1C:a:0/1:x")?.kind == .chunk)
        #expect(Chunk.parse("RSN1C:a:0/1:x")?.part == "x")
    }

    // MARK: - Encrypted key backup

    // The feature these prove: sign in on a new device, type one passphrase, and your identity and
    // your people come back — without the server that held the blob ever being able to read it.
    // If these break, a backup written in the browser is a brick on the phone.

    @Test("a backup sealed by the TypeScript core opens on iOS")
    func backupFromTypeScript() throws {
        let v = vectors.backup
        let payload = try Backup.open(v.blob, passphrase: v.passphrase)

        #expect(payload.mnemonic == v.expectedMnemonic)
        #expect(payload.contacts.count == 1)
        #expect(payload.sessions.count == 1)

        let contacts = Backup.contacts(from: payload)
        #expect(contacts.first?.bundle.hexString == v.expectedContactBundle)
        #expect(contacts.first?.label == v.expectedContactLabel)
        // Milliseconds on the wire, Date in the vault — an off-by-1000 here would silently date
        // every restored contact to 1970.
        #expect(
            contacts.first.map {
                abs($0.addedAt.timeIntervalSince1970 * 1000 - v.expectedContactAddedAt) < 1
            } == true)

        // And the identity it carries really is the one it claims to be.
        let restored = try Recovery.deviceIdentity(phrase: payload.mnemonic)
        #expect(restored.bundle.hexString == vectors.deviceA.bundle)

        // Session bytes and browser-only metadata must arrive exactly as TypeScript sealed them.
        let sessions = Backup.sessions(from: payload)
        #expect(sessions.count == 1)
        #expect(sessions.first?.id.hexString == v.expectedSession.id)
        #expect(sessions.first?.key0to1.hexString == v.expectedSession.key0to1)
        #expect(sessions.first?.key1to0.hexString == v.expectedSession.key1to0)
        #expect(sessions.first.map { Int($0.myParty) } == v.expectedSession.myParty)
        #expect(sessions.first?.peerFingerprint.hexString == v.expectedSession.peerFingerprint)
        #expect(sessions.first?.browserThreadId == v.expectedSession.threadId)
        #expect(sessions.first?.acct == v.expectedSession.acct)
    }

    @Test("a sessions-less v1 TypeScript backup still opens with an empty session list")
    func legacyBackupFromTypeScript() throws {
        let v = vectors.backup
        let payload = try Backup.open(v.legacyBlob, passphrase: v.passphrase)
        #expect(payload.mnemonic == v.expectedMnemonic)
        #expect(payload.sessions.isEmpty)
        #expect(Backup.sessions(from: payload).isEmpty)
    }

    @Test("one malformed backup session is skipped without sinking its neighbors")
    func malformedBackupSessionIsLossy() throws {
        let opened = try Backup.open(vectors.backup.blob, passphrase: vectors.backup.passphrase)
        let good = try #require(opened.sessions.first)

        // A structurally damaged row must not make Payload decoding all-or-nothing.
        let goodObject = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [String: Any])
        let wire: [String: Any] = [
            "v": opened.v,
            "mnemonic": opened.mnemonic,
            "contacts": [],
            "sessions": [["id": 7], goodObject],
        ]
        let lossy = try JSONDecoder().decode(
            Backup.Payload.self, from: JSONSerialization.data(withJSONObject: wire))
        #expect(lossy.sessions == [good])

        // Structurally valid base64url still has to describe the exact protocol widths.
        var shortKey = good
        shortKey.key0to1 = b64u(Data(repeating: 0, count: 31))
        var mixed = lossy
        mixed.sessions = [shortKey, good]
        let adopted = Backup.sessions(from: mixed)
        #expect(adopted.count == 1)
        #expect(adopted.first?.id.hexString == vectors.backup.expectedSession.id)
    }

    @Test("a TypeScript session restores into the engine and survives a phone re-backup")
    func backupSessionEngineRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ekko-backup-interop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = EkkoEngine(store: EkkoStore(directory: dir))
        #expect(try engine.restore(
            backup: vectors.backup.blob, passphrase: vectors.backup.passphrase) == 1)
        engine.reload()  // prove the opaque metadata made it through the on-disk Codable vault too
        let contact = try #require(engine.contacts.first)
        #expect(engine.hasSession(with: contact))

        // This body was sealed before the phone restored, under the session inside the TS blob.
        let oldMessage = Wire.formatMessage(hexData(vectors.tsToSwift.messageBody))
        guard case .message(let plaintext, _, _) = try engine.ingest(oldMessage) else {
            Issue.record("restored session did not open pre-restore history")
            return
        }
        #expect(plaintext == vectors.tsToSwift.expectedPlaintext)

        let resealed = try engine.sealBackup(passphrase: vectors.backup.passphrase)
        let reopened = try Backup.open(resealed, passphrase: vectors.backup.passphrase)
        let carried = try #require(reopened.sessions.first)
        #expect(carried.threadId == vectors.backup.expectedSession.threadId)
        #expect(carried.acct == vectors.backup.expectedSession.acct)
    }

    @Test("a wrong passphrase does not open a TypeScript-sealed backup")
    func backupWrongPassphrase() {
        #expect(throws: (any Error).self) {
            try Backup.open(vectors.backup.blob, passphrase: vectors.backup.passphrase + "x")
        }
    }

    @Test("the KDF header is authenticated, so a server cannot downgrade the iterations")
    func backupDowngrade() {
        // The one attack the storage provider is actually positioned to run: hand the client back a
        // blob that says "one round" and let it derive a key a laptop can brute-force. The header is
        // AAD, so this must fail the tag rather than decrypt.
        var weakened = vectors.backup.blob
        weakened.iter = 1
        #expect(throws: (any Error).self) {
            try Backup.open(weakened, passphrase: vectors.backup.passphrase)
        }
    }

    @Test("a generated passphrase is six words and actually opens what it sealed")
    func generatedPassphrase() throws {
        let phrase = Backup.generatePassphrase()
        #expect(phrase.split(separator: " ").count == 6)
        #expect(phrase != Backup.generatePassphrase())

        let blob = try Backup.seal(mnemonic: vectors.phraseA, contacts: [], passphrase: phrase)
        #expect(try Backup.open(blob, passphrase: phrase).mnemonic == vectors.phraseA)
    }

    // MARK: - Swift → TypeScript (the return leg)

    /// Seals a handshake + message from Swift and writes them where scripts/ios-interop.mjs
    /// picks them up and opens them with the real TS core. Skipped under a bare `swift test`.
    @Test("emit a Swift-sealed handshake + message for the TypeScript side to open")
    func emitForTypeScript() throws {
        guard let out = ProcessInfo.processInfo.environment["EKKO_INTEROP_OUT"] else { return }

        let me = try Recovery.deviceIdentity(phrase: vectors.phraseB)  // Swift is B
        let peerBundle = hexData(vectors.deviceA.bundle)
        let (session, wire) = try EkkoCrypto.startHandshake(me: me, peerBundle: peerBundle)
        let plaintext = "hello from swift 🔒 ✓"
        let body = try EkkoCrypto.sealMessage(session: session, plaintext: plaintext)

        // Sanity: we can open our own echo, which is how the extension reads its own sent bubbles.
        #expect(try EkkoCrypto.openMessage(session: session, body: body) == plaintext)

        // The return leg of the backup: the phone seals its vault, and the extension must open it.
        // Swift is B, so it backs up phrase B and carries A as a contact.
        let peer = Contact(
            bundle: peerBundle, label: "Alice", verified: false,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000))
        var backedSession = session
        backedSession.browserThreadId = "telegram:swift-backup-interop"
        backedSession.acct = true
        let backupBlob = try Backup.seal(
            mnemonic: vectors.phraseB, contacts: [peer],
            sessions: [backedSession],
            passphrase: vectors.backup.passphrase)

        let payload: [String: Any] = [
            "handshakeWire": wire.hexString,
            "messageBody": body.hexString,
            "expectedPlaintext": plaintext,
            "sessionId": session.id.hexString,
            "deviceBBundle": me.bundle.hexString,
            "inviteB": Wire.formatInvite(me.bundle),
            "backupSession": [
                "id": backedSession.id.hexString,
                "key0to1": backedSession.key0to1.hexString,
                "key1to0": backedSession.key1to0.hexString,
                "myParty": Int(backedSession.myParty),
                "peerFingerprint": backedSession.peerFingerprint.hexString,
                "threadId": backedSession.browserThreadId!,
                "acct": backedSession.acct!,
            ],
            "backupBlob": [
                "v": backupBlob.v,
                "kdf": backupBlob.kdf,
                "iter": backupBlob.iter,
                "salt": backupBlob.salt,
                "nonce": backupBlob.nonce,
                "ct": backupBlob.ct,
            ],
        ]
        let url = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted).write(to: url)
    }
}

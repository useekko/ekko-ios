import Foundation
import Testing

@testable import EkkoCore

// Two engines on scratch stores talk to each other exactly the way two phones would: seal →
// (tokens travel as text) → ingest. This is the check that fails if the broker's session
// bookkeeping, chunking, or replay rules break.

private func scratchEngine() throws -> EkkoEngine {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ekko-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return EkkoEngine(store: EkkoStore(directory: dir))
}

@Suite("Engine")
struct EngineTests {

    @Test("a fresh identity is created from a 24-word phrase and reloads from disk")
    func createAndReload() throws {
        let e = try scratchEngine()
        #expect(!e.hasIdentity)

        let phrase = try e.createIdentity(username: "alice")
        #expect(e.hasIdentity)
        #expect(phrase.split(separator: " ").count == 24)
        #expect(Recovery.isValidMnemonic(phrase))
        #expect(e.username == "alice")

        // The phrase alone reproduces the identity — this is the whole backup story.
        let restored = try Recovery.deviceIdentity(phrase: phrase)
        #expect(restored.fingerprint == e.identity?.fingerprint)

        e.reload()
        #expect(e.identity?.fingerprint == restored.fingerprint)
    }

    @Test("importing the same phrase on another device yields the same identity")
    func importIsIdempotent() throws {
        let a = try scratchEngine()
        let phrase = try a.createIdentity()

        let b = try scratchEngine()
        try b.importIdentity(mnemonic: phrase)
        #expect(a.identity?.fingerprint == b.identity?.fingerprint)

        // Tolerant of how the words get re-typed.
        let c = try scratchEngine()
        try c.importIdentity(mnemonic: "  " + phrase.uppercased().replacingOccurrences(of: " ", with: "   "))
        #expect(c.identity?.fingerprint == a.identity?.fingerprint)
    }

    @Test("a bad phrase is refused")
    func badPhrase() throws {
        let e = try scratchEngine()
        #expect(throws: EngineError.badMnemonic) {
            try e.importIdentity(mnemonic: "not actually a valid bip39 phrase at all no sir")
        }
    }

    @Test("setup travels as an invitation and the first chat message is short")
    func firstContact() throws {
        let alice = try scratchEngine()
        let bob = try scratchEngine()
        try alice.createIdentity(username: "alice")
        try bob.createIdentity(username: "bob")

        // Alice adds Bob from his invite. Bob has never heard of Alice.
        let bobContact = try alice.addContact(invite: bob.invite!, label: "Bob")
        #expect(alice.contacts.count == 1)
        #expect(!bobContact.verified)  // trust-on-first-use until safety numbers match

        // Setup is exchanged in the app/backend, not in the user's conversation. The handshake
        // already contains Alice's public identity, so Bob can paste it as her return invitation.
        let setup = try alice.prepareSetup(to: bobContact)!
        let aliceContact = try bob.addContact(invite: setup, label: "Alice")
        #expect(alice.hasSession(with: bobContact))
        #expect(bob.hasSession(with: aliceContact))

        let tokens = try alice.seal(to: bobContact, plaintext: "meet me at 8 🔒")
        #expect(tokens.count == 1)
        #expect(tokens[0].hasPrefix("EKK1M:"))

        guard case .message(let opened, let from, let mine) = try bob.ingest(tokens[0]) else {
            Issue.record("Bob could not open the first message")
            return
        }
        #expect(!mine)
        #expect(from.id == alice.identity!.fingerprint.hexString)
        #expect(opened == "meet me at 8 🔒")

        // Bob's keyboard now defaults to replying to Alice, with no picker.
        #expect(bob.lastContact?.id == alice.identity!.fingerprint.hexString)
    }

    @Test("sealing fails closed until setup, then never emits setup into chat")
    func setupNeverEntersChat() throws {
        let alice = try scratchEngine()
        let bob = try scratchEngine()
        try alice.createIdentity()
        try bob.createIdentity()
        let bobC = try alice.addContact(invite: bob.invite!, label: "Bob")

        #expect(throws: EngineError.noSession) {
            try alice.seal(to: bobC, plaintext: "too early")
        }

        let setup = try alice.prepareSetup(to: bobC)!
        _ = try bob.addContact(invite: setup, label: "Alice")
        let first = try alice.seal(to: bobC, plaintext: "one")
        let second = try alice.seal(to: bobC, plaintext: "two")
        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first[0].hasPrefix("EKK1M:"))
        #expect(second[0].hasPrefix("EKK1M:"))
    }

    @Test("an account session backs up threadless and restores old messages")
    func accountSessionBackup() throws {
        let alice = try scratchEngine()
        let bob = try scratchEngine()
        try alice.createIdentity()
        try bob.createIdentity()
        let bobC = try alice.addContact(invite: bob.invite!, label: "Bob")
        _ = try bob.addContact(invite: try alice.prepareSetup(to: bobC)!, label: "Alice")

        // AccountSync calls this after the setup mailbox owns the wire. The iOS-local `ios:`
        // routing key must not leak into the browser field, while the account marker must.
        try alice.markSetupPublished(to: bobC)
        let old = try alice.seal(to: bobC, plaintext: "before restore")
        let passphrase = "account backup test passphrase"
        let blob = try alice.sealBackup(passphrase: passphrase)
        let payload = try Backup.open(blob, passphrase: passphrase)
        #expect(payload.sessions.count == 1)
        #expect(payload.sessions.first?.threadId == nil)
        #expect(payload.sessions.first?.acct == true)

        let restored = try scratchEngine()
        #expect(try restored.restore(backup: blob, passphrase: passphrase) == 1)
        guard case .message(let text, _, _) = try restored.ingest(old[0]) else {
            Issue.record("restored account session did not open its pre-restore message")
            return
        }
        #expect(text == "before restore")
    }

    @Test("a whole multi-message paste reassembles in one shot")
    func multiTokenPaste() throws {
        let alice = try scratchEngine()
        let bob = try scratchEngine()
        try alice.createIdentity()
        try bob.createIdentity()
        let bobC = try alice.addContact(invite: bob.invite!, label: "Bob")
        _ = try bob.addContact(invite: try alice.prepareSetup(to: bobC)!, label: "Alice")
        let tokens = try alice.seal(to: bobC, plaintext: "all at once")

        // WhatsApp's multi-select copy joins the bubbles with newlines — one paste, done.
        let result = try bob.ingest(tokens.joined(separator: "\n"))
        guard case .message(let text, _, let mine) = result else {
            Issue.record("expected a message, got \(result)")
            return
        }
        #expect(text == "all at once")
        #expect(!mine)
    }

    @Test("a long message chunks without adding a setup group")
    func longMessageChunks() throws {
        let alice = try scratchEngine()
        let bob = try scratchEngine()
        try alice.createIdentity()
        try bob.createIdentity()
        let bobC = try alice.addContact(invite: bob.invite!, label: "Bob")
        _ = try bob.addContact(invite: try alice.prepareSetup(to: bobC)!, label: "Alice")

        let long = String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 30)
        #expect(long.count > 620)

        let tokens = try alice.seal(to: bobC, plaintext: long)
        let ids = Set(tokens.compactMap { Chunk.parse($0)?.id })
        #expect(ids.count == 1, "only the encrypted message belongs in chat")

        var opened: String?
        for t in tokens {
            if case .message(let text, _, let mine) = try bob.ingest(t) {
                opened = text
                #expect(!mine)
            }
        }
        #expect(opened == long)
    }

    @Test("a partial paste reports progress instead of failing")
    func partialChunks() throws {
        let alice = try scratchEngine()
        let bob = try scratchEngine()
        try alice.createIdentity()
        try bob.createIdentity()
        let bobC = try alice.addContact(invite: bob.invite!, label: "Bob")
        _ = try bob.addContact(invite: try alice.prepareSetup(to: bobC)!, label: "Alice")
        let tokens = try alice.seal(to: bobC, plaintext: String(repeating: "x", count: 1000))

        guard case .needMoreChunks(let have, let total) = try bob.ingest(tokens[0]) else {
            Issue.record("expected chunk progress")
            return
        }
        #expect(have == 1)
        #expect(total > 1)
    }

    @Test("we can read our own echoed bubble")
    func ownEcho() throws {
        let alice = try scratchEngine()
        let bob = try scratchEngine()
        try alice.createIdentity()
        try bob.createIdentity()
        let bobC = try alice.addContact(invite: bob.invite!, label: "Bob")
        _ = try alice.prepareSetup(to: bobC)!

        // Instagram renders your sent message back to you; it must decrypt, marked as yours.
        let tokens = try alice.seal(to: bobC, plaintext: "my own words")
        let msg = tokens.last { $0.hasPrefix("EKK1M:") }!
        guard case .message(let text, _, let mine) = try alice.ingest(msg) else {
            Issue.record("own echo did not open")
            return
        }
        #expect(text == "my own words")
        #expect(mine)
    }

    @Test("ordinary text and unknown sessions are handled, not crashed on")
    func nonEkkoText() throws {
        let e = try scratchEngine()
        try e.createIdentity()
        guard case .nothing = try e.ingest("hey, are we still on for tonight?") else {
            Issue.record("plain text should be nothing")
            return
        }
        // A message for a session we never had (peer rekeyed, or it is not for us).
        guard case .unknownSession = try e.ingest("RSN1M:" + b64u(Data(repeating: 1, count: 60))) else {
            Issue.record("expected unknownSession")
            return
        }
    }

    @Test("adding your own invite is refused, and safety numbers are symmetric")
    func selfAddAndSafety() throws {
        let alice = try scratchEngine()
        let bob = try scratchEngine()
        try alice.createIdentity()
        try bob.createIdentity()

        #expect(throws: EngineError.thatIsYou) {
            try alice.addContact(invite: alice.invite!, label: "me")
        }
        let bobC = try alice.addContact(invite: bob.invite!, label: "Bob")
        let aliceC = try bob.addContact(invite: alice.invite!, label: "Alice")
        // The number both people read aloud must match.
        #expect(try alice.safetyNumber(for: bobC) == (try bob.safetyNumber(for: aliceC)))
    }

    @Test("removing a contact drops their sessions")
    func removeContact() throws {
        let alice = try scratchEngine()
        let bob = try scratchEngine()
        try alice.createIdentity()
        try bob.createIdentity()
        let bobC = try alice.addContact(invite: bob.invite!, label: "Bob")
        _ = try alice.prepareSetup(to: bobC)!
        _ = try alice.seal(to: bobC, plaintext: "hi")

        try alice.remove(bobC)
        #expect(alice.contacts.isEmpty)
        #expect(alice.lastContact == nil)
        // Nothing left that could keep encrypting to them.
        #expect(throws: (any Error).self) { try alice.seal(to: bobC, plaintext: "still there?") }
    }
}

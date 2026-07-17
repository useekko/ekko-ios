import EkkoCore
import Foundation
import Testing

// The keyboard's logic, driven against a fake text field. Guard the manual replacement path and
// the send queue (only encrypted message tokens; setup must never leak into the conversation).

/// Stands in for the messenger's composer.
@MainActor
final class MockHost: HostTextField {
    var text = ""
    private var cursor = 0
    var clipboard: String?
    private(set) var nextKeyboardCount = 0

    var textBefore: String { String(text.prefix(cursor)) }
    var textAfter: String { String(text.dropFirst(cursor)) }
    var selectedText: String { "" }

    func insert(_ t: String) {
        let i = text.index(text.startIndex, offsetBy: cursor)
        text.insert(contentsOf: t, at: i)
        cursor += t.count
    }
    func deleteBackward() {
        guard cursor > 0 else { return }
        let i = text.index(text.startIndex, offsetBy: cursor)
        text.remove(at: text.index(before: i))
        cursor -= 1
    }
    func moveCursor(by offset: Int) {
        cursor = min(text.count, max(0, cursor + offset))
    }
    func nextKeyboard() { nextKeyboardCount += 1 }

    /// The user tapped Send in the host app, so the host cleared its own composer.
    func simulateSend() {
        text = ""
        cursor = 0
    }
}

@MainActor
private func scratchEngine() throws -> EkkoEngine {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ekko-kb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return EkkoEngine(store: EkkoStore(directory: dir))
}

/// A model wired to an identity with one contact ("Bob"), ready to seal. `peer` is Bob's own
/// engine, i.e. the other phone, so a test can drive both ends of a real conversation.
@MainActor
private func readyModel() throws -> (
    model: KeyboardModel, host: MockHost, engine: EkkoEngine, bob: Contact, peer: EkkoEngine
) {
    let engine = try scratchEngine()
    try engine.createIdentity(username: "me")

    let peer = try scratchEngine()
    try peer.createIdentity()
    let bob = try engine.addContact(invite: peer.invite!, label: "Bob")
    _ = try peer.addContact(invite: try engine.prepareSetup(to: bob)!, label: "Alice")

    let host = MockHost()
    let model = KeyboardModel()
    model.start(host: host, engine: engine)
    return (model, host, engine, bob, peer)
}

@Suite("Keyboard")
@MainActor
struct KeyboardModelTests {

    // MARK: - Composer editing

    @Test("sealed mode types into the host composer")
    func lockedTypingUsesComposer() throws {
        let (model, host, _, _, _) = try readyModel()
        #expect(model.locked)  // armed automatically: there is an identity and a contact

        for ch in "meet me at 8" { model.tap(String(ch)) }

        #expect(host.text == "meet me at 8")
    }

    @Test("unlocked, it is an ordinary keyboard and types straight through")
    func unlockedTypingPassesThrough() throws {
        let (model, host, _, _, _) = try readyModel()
        model.toggleLock()
        #expect(!model.locked)

        for ch in "hello" { model.tap(String(ch)) }
        #expect(host.text == "hello")

        model.backspace()
        #expect(host.text == "hell")
    }

    @Test("backspace always edits the visible composer")
    func backspaceEditsComposer() throws {
        let (model, host, _, _, _) = try readyModel()
        model.tap("h")
        model.tap("i")
        model.backspace()
        #expect(host.text == "h")

        model.backspace()
        model.backspace()
        #expect(host.text.isEmpty)
    }

    @Test("with no contact to seal to, the lock cannot be armed")
    func noContactNoLock() throws {
        let engine = try scratchEngine()
        try engine.createIdentity()
        let host = MockHost()
        let model = KeyboardModel()
        model.start(host: host, engine: engine)

        #expect(!model.locked)
        #expect(model.setupNeeded != nil)
        model.toggleLock()
        #expect(!model.locked)  // still refuses: there is nobody to seal to

        // …and it behaves as a plain keyboard rather than swallowing the user's typing.
        model.tap("h")
        #expect(host.text == "h")
    }

    @Test("a copied invite can become the first contact")
    func decryptInviteWithoutExistingContact() throws {
        let engine = try scratchEngine()
        try engine.createIdentity()
        let peer = try scratchEngine()
        try peer.createIdentity()

        let host = MockHost()
        let model = KeyboardModel()
        model.start(host: host, engine: engine)
        #expect(model.canDecrypt)
        #expect(model.setupNeeded != nil)

        model.decrypt(peer.invite)

        guard case .invited = model.decrypted else {
            Issue.record("copied invite was not decrypted: \(model.decrypted)")
            return
        }
        #expect(model.contacts.count == 1)
        #expect(model.setupNeeded == nil)
        #expect(host.text.isEmpty)
    }

    // MARK: - Seal and the send queue

    @Test("sealing a first message emits only the encrypted message")
    func sealQueuesTokens() throws {
        let (model, host, _, _, _) = try readyModel()
        for ch in "hi" { model.tap(String(ch)) }
        model.seal()

        let q = try #require(model.queue)
        #expect(q.total == 1)

        // The plaintext was replaced by only the first encrypted token.
        #expect(host.text == q.tokens[0])
        #expect(host.text.count <= Wire.maxMessageLen)
        #expect(host.text.hasPrefix("EKK1M:"))
    }

    @Test("a successful seal hands the words to the view to dissolve, and a keystroke takes them back")
    func sealHandsOverThePlaintext() throws {
        let (model, host, _, _, _) = try readyModel()
        for ch in "hi" { model.tap(String(ch)) }
        #expect(model.sealing == nil)

        model.seal()

        // The view needs the plaintext for the half second it spends showing it turn into
        // ciphertext. The host composer has already been replaced.
        let sealed = try #require(model.sealing)
        #expect(sealed.text == "hi")
        #expect(sealed.to == "Bob")

        // Typing means the user has moved on; the animation must not outlive their attention.
        model.tap("x")
        #expect(model.sealing == nil)
        #expect(model.queue == nil)
        #expect(host.text == "x")
    }

    @Test("a seal that fails animates nothing")
    func failedSealHandsOverNothing() throws {
        // No contact to seal to, so seal() cannot succeed — and must not pretend it did.
        let engine = try scratchEngine()
        try engine.createIdentity()
        let host = MockHost()
        let model = KeyboardModel()
        model.start(host: host, engine: engine)

        model.tap("h")
        model.tap("i")
        model.seal()
        #expect(model.sealing == nil)
        #expect(model.queue == nil)
        #expect(host.text == "hi")
    }

    @Test("manual seal replaces the whole composer when the cursor is in the middle")
    func sealFromMiddleOfComposer() throws {
        let (model, host, _, _, _) = try readyModel()
        model.tap("h")
        model.tap("i")
        host.moveCursor(by: -1)

        model.seal()

        #expect(host.text.hasPrefix("EKK1M:"))
        #expect(model.sealing?.text == "hi")
    }

    @Test("a contact without out-of-band setup fails closed")
    func unpairedContactDoesNotEmitSetup() throws {
        let engine = try scratchEngine()
        try engine.createIdentity()
        let peer = try scratchEngine()
        try peer.createIdentity()
        _ = try engine.addContact(invite: peer.invite!, label: "Bob")
        let host = MockHost()
        let model = KeyboardModel()
        model.start(host: host, engine: engine)

        model.tap("h")
        model.seal()

        #expect(model.queue == nil)
        #expect(host.text == "h")
        #expect(model.status?.contains("Open Ekko") == true)
    }

    @Test("the queue advances by itself and short messages stay one token")
    func queueAutoAdvances() throws {
        let (model, host, _, _, _) = try readyModel()
        model.tap("h")
        model.seal()
        let total = try #require(model.queue).total

        for i in 1..<total {
            host.simulateSend()  // the user taps Send; the host clears its composer
            model.hostTextChanged()

            let q = try #require(model.queue)
            #expect(q.index == i)
            #expect(host.text == q.tokens[i])
        }

        // Last one goes out and the queue retires.
        host.simulateSend()
        model.hostTextChanged()
        #expect(model.queue == nil)
        #expect(host.text.isEmpty)
        #expect(model.status?.contains("Sent") == true)

        // Every short message stays one token; setup never enters the queue.
        model.tap("x")
        model.seal()
        #expect(try #require(model.queue).total == 1)
        #expect(host.text.hasPrefix("EKK1M:"))
    }

    @Test("the queue does not advance while the token is still sitting in the composer")
    func queueWaitsForSend() throws {
        let (model, host, _, _, _) = try readyModel()
        model.tap("h")
        model.seal()
        let first = host.text

        // textDidChange fires when WE insert too. That must not be read as "the user sent it".
        model.hostTextChanged()
        #expect(try #require(model.queue).index == 0)
        #expect(host.text == first)
    }

    @Test("cancelling a queue clears the ciphertext out of the composer")
    func cancelClearsHost() throws {
        let (model, host, _, _, _) = try readyModel()
        model.tap("h")
        model.seal()
        #expect(!host.text.isEmpty)

        model.cancelQueue()
        #expect(model.queue == nil)
        #expect(host.text.isEmpty)  // no half-sent ciphertext left behind

        // Cancelling does not cause setup to appear on the next attempt either.
        model.tap("x")
        model.seal()
        #expect(try #require(model.queue).total == 1)
    }

    @Test("backspace removes inserted ciphertext and stops queue tracking")
    func backspaceDeletesCiphertext() throws {
        let (model, host, _, _, _) = try readyModel()
        model.tap("h")
        model.seal()

        model.backspace()

        #expect(host.text.isEmpty)
        #expect(model.queue == nil)
    }

    @Test("a whole conversation round-trips between two keyboards")
    func twoKeyboardsTalk() throws {
        // Alice's phone, and Bob's — paired before either keyboard enters the conversation.
        let (alice, aliceHost, aliceEngine, _, bobEngine) = try readyModel()

        let bobHost = MockHost()
        let bob = KeyboardModel()
        bob.start(host: bobHost, engine: bobEngine)

        // Alice types privately and seals.
        for ch in "the key is under the mat" { alice.tap(String(ch)) }
        alice.seal()

        // Every token she sends arrives in Bob's chat; he copies each and taps Decrypt.
        var tokens: [String] = []
        var q = try #require(alice.queue)
        tokens.append(aliceHost.text)
        while !q.isLast {
            aliceHost.simulateSend()
            alice.hostTextChanged()
            q = try #require(alice.queue)
            tokens.append(aliceHost.text)
        }

        for t in tokens { bob.decrypt(t) }

        // Bob can read it, and his keyboard has already armed a sealed reply to Alice.
        guard case .message(let text, _, let mine) = bob.decrypted else {
            Issue.record("bob could not read the message: \(bob.decrypted)")
            return
        }
        #expect(text == "the key is under the mat")
        #expect(!mine)
        #expect(bobHost.text.isEmpty)  // plaintext stays in Ekko's strip, never the host composer
        #expect(bob.locked)
        #expect(bob.contact?.id == aliceEngine.identity?.fingerprint.hexString)
    }

    // MARK: - Decrypt

    @Test("decrypting junk says so instead of failing silently")
    func decryptJunk() throws {
        let (model, _, _, _, _) = try readyModel()

        model.decrypt("just a normal text message")
        guard case .failed = model.decrypted else {
            Issue.record("expected .failed, got \(model.decrypted)")
            return
        }

        model.decrypt(nil)
        guard case .failed = model.decrypted else {
            Issue.record("expected .failed for an empty clipboard")
            return
        }
    }

    @Test("decrypting our own echoed message is marked as ours")
    func decryptOwnEcho() throws {
        let (model, host, _, _, _) = try readyModel()
        model.tap("x")
        model.seal()

        // Messengers render your sent bubble back to you; copying it must not look like a reply.
        var last = host.text
        var q = try #require(model.queue)
        while !q.isLast {
            host.simulateSend()
            model.hostTextChanged()
            q = try #require(model.queue)
            last = host.text
        }
        model.decrypt(last)

        guard case .message(let text, _, let mine) = model.decrypted else {
            Issue.record("own echo did not open: \(model.decrypted)")
            return
        }
        #expect(text == "x")
        #expect(mine)
    }

    @Test("copied rich text tolerates invisible layout marks and opens the private reader")
    func decryptRichClipboardText() throws {
        let (alice, aliceHost, _, _, bobEngine) = try readyModel()
        for ch in "meet me by the north gate" { alice.tap(String(ch)) }
        alice.seal()

        let token = aliceHost.text
        let split = token.index(token.startIndex, offsetBy: min(24, token.count))
        let richCopy = "Alice, 9:41 PM\n\(token[..<split])\u{200b}\u{2060}\(token[split...])\nEncrypted with Ekko"

        let bobHost = MockHost()
        let bob = KeyboardModel()
        bob.start(host: bobHost, engine: bobEngine)
        bob.decrypt(String(richCopy))

        guard case .message(let text, _, _) = bob.decrypted else {
            Issue.record("rich clipboard text did not decrypt: \(bob.decrypted)")
            return
        }
        #expect(text == "meet me by the north gate")
        #expect(bob.readerVisible)
        #expect(bobHost.text.isEmpty)

        bob.hideSensitiveContent()
        #expect(!bob.readerVisible)
        #expect(bobHost.text.isEmpty)
    }

    @Test("copied chunks decrypt one tap at a time without touching the composer")
    func decryptChunks() throws {
        let (alice, aliceHost, _, _, bobEngine) = try readyModel()
        for ch in String(repeating: "private words ", count: 100) { alice.tap(String(ch)) }
        alice.seal()

        var tokens: [String] = []
        var queue = try #require(alice.queue)
        while true {
            tokens.append(aliceHost.text)
            if queue.isLast { break }
            aliceHost.simulateSend()
            alice.hostTextChanged()
            queue = try #require(alice.queue)
        }
        #expect(tokens.count > 1)

        let bobHost = MockHost()
        let bob = KeyboardModel()
        bob.start(host: bobHost, engine: bobEngine)
        for token in tokens.dropLast() {
            bob.decrypt(token)
            guard case .needMoreChunks = bob.decrypted else {
                Issue.record("a partial copied message did not ask for the next chunk")
                return
            }
        }
        bob.decrypt(tokens[tokens.count - 1])

        guard case .message(let text, _, _) = bob.decrypted else {
            Issue.record("the final copied chunk did not decrypt the message")
            return
        }
        #expect(text == String(repeating: "private words ", count: 100))
        #expect(bobHost.text.isEmpty)
    }

    // MARK: - Shift

    @Test("shift is one-shot and caps lock sticks")
    func shiftBehaviour() throws {
        let (model, _, _, _, _) = try readyModel()
        #expect(model.shifted)  // sentence starts capitalised

        model.tap("A")
        #expect(!model.shifted)  // one-shot: dropped after a key

        model.toggleShift()
        #expect(model.shifted)
        model.toggleShift()
        #expect(model.capsLock)

        model.tap("B")
        #expect(model.capsLock)  // caps lock survives a keypress
        model.toggleShift()
        #expect(!model.capsLock)
        #expect(!model.shifted)
    }
}

import EkkoCore
import Observation
import SwiftUI

// The keyboard's state machine, kept apart from UIKit so it can be reasoned about (and tested)
// on its own. The view controller owns the host text field; this owns everything else.
//
// In sealed mode the user still edits the messenger's real composer. The keyboard replaces that
// plaintext with ciphertext only when they tap its manual Seal action. Unlike the Safari content
// script, a system keyboard cannot intercept the host app's own Send button.

/// What the view controller can do to the text field it is attached to.
/// Main-actor isolated: the conforming type is a UIInputViewController, and every call here
/// touches UIKit.
@MainActor
protocol HostTextField: AnyObject {
    var textBefore: String { get }
    var textAfter: String { get }
    var selectedText: String { get }
    func insert(_ text: String)
    func deleteBackward()
    func moveCursor(by offset: Int)
    func nextKeyboard()
}

@Observable
@MainActor
final class KeyboardModel {
    enum Plane: Equatable { case letters, numbers, symbols, emoji }

    /// What the private reader is currently showing.
    enum Decrypted {
        case none
        case message(text: String, from: String, mine: Bool)
        case secureChannel(with: String, added: Bool)
        case invited(String)
        case needMoreChunks(have: Int, total: Int)
        case unknownSession
        case failed(String)
    }

    /// Tokens waiting to be sent, one per tap of the host app's Send button.
    struct SendQueue {
        var tokens: [String]
        var index: Int = 0
        var sent: Int { index }
        var total: Int { tokens.count }
        var current: String { tokens[index] }
        var isLast: Bool { index >= tokens.count - 1 }
    }

    /// The plaintext that has just been sealed, kept only long enough for the keyboard to show it
    /// turning into ciphertext. The view clears it when that finishes; a keystroke clears it sooner,
    /// because the user has moved on.
    struct Sealed: Equatable {
        let text: String
        let to: String
    }

    weak var host: HostTextField?
    private(set) var engine: EkkoEngine?

    /// Lock ON = the compact Seal action targets `contact`. Typing always uses the host composer.
    var locked = false
    var plane: Plane = .letters
    var shifted = true
    var capsLock = false

    var contact: Contact?
    var contacts: [Contact] = []
    var showContacts = false

    var queue: SendQueue?
    var sealing: Sealed?
    var decrypted: Decrypted = .none
    var status: String?
    var setupNeeded: String?

    /// Decryption only needs this device's identity. In particular, a copied invite can become the
    /// first contact, so the Decrypt action must remain available even when the contact list is empty.
    var canDecrypt: Bool { engine?.hasIdentity == true }

    /// A successful message, an in-progress chunk group, and an actionable failure all belong in
    /// the reader. Keeping this decision in the state machine lets the keyboard swap the cramped
    /// key plane for a real reading surface without duplicating enum logic in its root view.
    var readerVisible: Bool {
        if case .none = decrypted { return false }
        return true
    }

    /// Drives feedback and reader-content transitions when the user pastes a second message while
    /// the reader is already open.
    private(set) var decryptRevision = 0

    // MARK: - Lifecycle

    /// `injected` is the test seam: tests hand in an engine on a scratch store, since a unit-test
    /// bundle has no App Group entitlement.
    func start(host: HostTextField, engine injected: EkkoEngine? = nil) {
        self.host = host
        do {
            let e = try injected ?? EkkoEngine()
            engine = e
            contacts = e.contacts
            contact = e.lastContact ?? e.contacts.first
            if !e.hasIdentity {
                setupNeeded = "Open the Ekko app to set up your identity."
            } else if e.contacts.isEmpty {
                setupNeeded = "Add a contact in the Ekko app, then come back here to send them a sealed message."
            }
            // Nothing to seal to yet, so do not pretend we can.
            locked = e.hasIdentity && !e.contacts.isEmpty
        } catch {
            // No App Group means no keys. Say so instead of silently typing plaintext.
            setupNeeded = "Ekko can't reach its keys. Turn on Allow Full Access for the Ekko keyboard in Settings."
            locked = false
        }
    }

    /// The app and the keyboard are two processes over one vault file. Re-read on every
    /// appearance, or a contact added in the app would not show up here until the phone reboots.
    func reloadFromDisk() {
        guard let engine else { return }
        engine.reload()
        contacts = engine.contacts
        if contact == nil || !contacts.contains(where: { $0.id == contact?.id }) {
            contact = engine.lastContact ?? contacts.first
        }
        if engine.hasIdentity && !contacts.isEmpty {
            setupNeeded = nil
        } else if engine.hasIdentity {
            setupNeeded = "Add a contact in the Ekko app, then come back here to send them a sealed message."
            locked = false
        }
    }

    // MARK: - Typing

    func tap(_ key: String) {
        // Typing after sealing means "edit that message", not "append plaintext to ciphertext".
        if queue != nil { cancelQueue() }
        host?.insert(key)
        if shifted && !capsLock { shifted = false }
        clearTransient()
    }

    func backspace() {
        // A sealed token is indivisible. One delete cancels it instead of leaving corrupt partial
        // ciphertext in the composer or mistaking an emptied field for a successful Send.
        if queue != nil {
            cancelQueue()
            return
        }
        host?.deleteBackward()
        clearTransient()
    }

    func space() { tap(" ") }

    func toggleShift() {
        if capsLock {
            capsLock = false
            shifted = false
        } else if shifted {
            capsLock = true
        } else {
            shifted = true
        }
    }

    func toggleLock() {
        guard engine?.hasIdentity == true, !contacts.isEmpty else { return }
        locked.toggle()
        clearTransient()
    }

    private func clearTransient() {
        status = nil
        sealing = nil
        if case .none = decrypted {} else { decrypted = .none }
    }

    // MARK: - Seal

    func seal() {
        guard locked, let engine, let contact, let host else { return }
        let plaintext = host.textBefore + host.selectedText + host.textAfter
        guard !plaintext.isEmpty else { return }
        do {
            let tokens = try engine.seal(to: contact, plaintext: plaintext)
            // Hand the words to the view before dropping them, so it can show them becoming the
            // ciphertext that actually leaves the phone. Only on success: a seal that threw sealed
            // nothing, and must not be animated as if it had.
            sealing = Sealed(text: plaintext, to: contact.label)
            decrypted = .none

            // Replace the visible plaintext only after encryption succeeds. A missing session or
            // other failure leaves the user's draft exactly where they wrote it.
            clearHostField()

            var q = SendQueue(tokens: tokens)
            q.index = 0
            queue = q
            host.insert(tokens[0])
            status = tokens.count > 1
                ? "Send this, and Ekko will fill in the next part."
                : "Sealed. Tap send."
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? "Could not seal that message."
        }
    }

    /// Called whenever the host's text changes. When the field goes empty while a token is
    /// pending, the host app just sent it — so drop the next one in.
    ///
    /// Setup never enters this queue. Only an unusually long encrypted message can span multiple
    /// host sends, and auto-advancing keeps that to repeated taps instead of repeated copy-paste.
    func hostTextChanged() {
        guard var q = queue, let host else { return }
        let empty = host.textBefore.isEmpty && host.textAfter.isEmpty
        guard empty else { return }

        if q.isLast {
            queue = nil
            status = "Sent. Your message crossed the wire sealed."
            return
        }
        q.index += 1
        queue = q
        host.insert(q.current)
        status = "Part \(q.index + 1) of \(q.total). Keep tapping send."
    }

    func cancelQueue() {
        // Retire tracking before deleting; textDidChange fires during deletion and must not treat
        // an intentional cancel as Send or auto-insert the next chunk.
        queue = nil
        clearHostField()
        status = nil
        sealing = nil
    }

    private func clearHostField() {
        guard let host else { return }
        // A selection sits between the two context strings. Delete it before collapsing the
        // cursor to the end so the complete draft captured above is replaced.
        if !host.selectedText.isEmpty { host.deleteBackward() }
        // Deletion is backward-only. Move to the end first when the user sealed with the cursor in
        // the middle, then remove the whole composer.
        var moveGuard = 0
        while !host.textAfter.isEmpty && moveGuard < 4000 {
            let distance = host.textAfter.count
            host.moveCursor(by: distance)
            moveGuard += distance
        }
        // Bounded: a runaway delete loop in a keyboard is unrecoverable for the user.
        var guardCount = 0
        while !host.textBefore.isEmpty && guardCount < 4000 {
            host.deleteBackward()
            guardCount += 1
        }
    }

    // MARK: - Decrypt

    /// Accept the string delivered by the system Paste control and try to make sense of it. This is
    /// how an INBOUND message is read: long-press the ciphertext bubble in any messenger, Copy,
    /// come back here, tap Paste. The plaintext stays in the reader and never enters the text field.
    func decrypt(_ text: String?) {
        showContacts = false
        status = nil
        sealing = nil
        defer { decryptRevision += 1 }
        guard let engine, engine.hasIdentity else {
            decrypted = .failed("Set up your identity in the Ekko app first.")
            return
        }
        guard let text else {
            decrypted = .failed("The copied item is not text. Copy the full Ekko message and try again.")
            return
        }

        // Rich-text clipboards occasionally insert invisible layout characters into a long token.
        // They are not part of base64url and used to truncate the match, making an intact-looking
        // bubble fail to decrypt. Remove only characters that carry no visible message content;
        // ordinary whitespace and surrounding messenger metadata remain untouched.
        let copied = Self.cleanCopiedText(text)
        guard !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            decrypted = .failed("Nothing was pasted. Copy an Ekko message first.")
            return
        }
        do {
            switch try engine.ingest(copied) {
            case .message(let plain, let from, let mine):
                decrypted = .message(text: plain, from: from.label, mine: mine)
                // Reading their message is the strongest possible signal for who you are about to
                // reply to. Pre-select them, so replying takes no picker at all.
                if !mine {
                    contact = from
                    engine.lastContact = from
                    locked = true
                }
            case .secureChannel(let with, let added):
                contacts = engine.contacts
                contact = with
                locked = true
                setupNeeded = nil
                decrypted = .secureChannel(with: with.label, added: added)
            case .invited(let c):
                contacts = engine.contacts
                setupNeeded = nil
                decrypted = .invited(c.label)
            case .needMoreChunks(let have, let total):
                decrypted = .needMoreChunks(have: have, total: total)
            case .unknownSession:
                decrypted = .unknownSession
            case .nothing:
                decrypted = .failed("No complete Ekko message was found. Copy the entire encrypted bubble and try again.")
            }
        } catch {
            decrypted = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? "That message is incomplete or damaged. Copy the full bubble and try again.")
        }
    }

    /// Close the reader without touching the host composer or a pending encrypted send.
    func dismissDecrypted() {
        decrypted = .none
    }

    /// Plaintext should not remain onscreen after the user leaves this keyboard. The core's chunk
    /// reassembler deliberately survives so copying part two can still finish a long message.
    func hideSensitiveContent() {
        decrypted = .none
        sealing = nil
        showContacts = false
    }

    private static func cleanCopiedText(_ text: String) -> String {
        var cleaned = text
        for invisible in ["\u{00ad}", "\u{200b}", "\u{200c}", "\u{200d}", "\u{2060}", "\u{feff}"] {
            cleaned = cleaned.replacingOccurrences(of: invisible, with: "")
        }
        return cleaned
    }

    func pick(_ c: Contact) {
        contact = c
        engine?.lastContact = c
        locked = true
        showContacts = false
        clearTransient()
    }
}

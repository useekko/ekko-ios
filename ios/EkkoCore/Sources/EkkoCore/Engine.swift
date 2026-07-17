import Foundation
import Observation

// The broker. Mirrors src/background.ts: it owns the vault, holds the keys, and is the only
// thing that seals or opens. The app and the keyboard extension each hold one, backed by the
// same App Group file.
//
// Kept @Observable so SwiftUI can bind straight to it — no view-model layer for a class whose
// whole job is already "the app's state".

@Observable
public final class EkkoEngine {
    /// A device keeps at most four sessions per peer and thread, so history stays decryptable
    /// while a rekey is in flight without growing without bound (PROTOCOL.md).
    static let maxSessionsPerPeerThread = 4

    private let store: EkkoStore
    private var vault: VaultData?
    /// Inbound chunk groups, buffered across pastes. Not persisted — a half-pasted handshake is
    /// cheap to redo and pointless to survive a relaunch.
    private let reassembler = Reassembler()

    public private(set) var identity: Identity?
    public private(set) var contacts: [Contact] = []
    public var username: String? { vault?.username }
    public var mnemonic: String? { vault?.mnemonic }
    public var platformHandles: [String: String] { vault?.platformHandles ?? [:] }
    public var hasIdentity: Bool { identity != nil }

    /// The contact the keyboard seals to by default. Set every time we reveal a message from
    /// someone, so "read their message, tap Seal, reply" needs no picker.
    public var lastContact: Contact? {
        get { contacts.first { $0.id == vault?.lastContact } }
        set {
            vault?.lastContact = newValue?.id
            try? persist()
        }
    }

    public init(store: EkkoStore) {
        self.store = store
        reload()
    }

    public convenience init() throws {
        self.init(store: try EkkoStore())
    }

    /// Re-read the vault from disk. The app calls this on foreground and the keyboard on
    /// appearance, because the other process may have changed it.
    public func reload() {
        vault = try? store.load()
        identity = try? vault?.identity.identity()
        contacts = (vault?.contacts ?? []).sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private func persist() throws {
        guard var v = vault else { throw StoreError.noVault }
        v.contacts = contacts
        vault = v
        try store.save(v)
    }

    // MARK: - Identity lifecycle

    /// Create a brand-new identity. The phrase is generated here and IS the backup — the caller
    /// must show it before this device is treated as set up.
    @discardableResult
    public func createIdentity(username: String? = nil) throws -> String {
        let phrase = Recovery.generateMnemonic()
        try adopt(phrase: phrase, username: username)
        return phrase
    }

    /// Restore an identity from its 24 words. Re-derives the same device key, so the identity,
    /// fingerprint and @handle are the same ones the browser extension has.
    public func importIdentity(mnemonic phrase: String) throws {
        guard Recovery.isValidMnemonic(phrase) else { throw EngineError.badMnemonic }
        try adopt(phrase: Recovery.normalize(phrase), username: nil)
    }

    private func adopt(phrase: String, username: String?) throws {
        let id = try Recovery.deviceIdentity(phrase: phrase)
        let v = VaultData(
            identity: StoredIdentity(xPriv: id.xPriv, kSeed: id.kSeed),
            mnemonic: phrase,
            username: username
        )
        try store.save(v)
        reload()
    }

    public func setUsername(_ name: String) throws {
        vault?.username = name
        try persist()
    }

    public func setPlatformHandle(_ handle: String, platform: String) throws {
        vault?.platformHandles[platform] = handle
        try persist()
    }

    public func destroyIdentity() throws {
        try store.destroy()
        vault = nil
        identity = nil
        contacts = []
    }

    // MARK: - Encrypted backup

    /// Seal this device's identity and contacts into the blob that may sit on a server. Requires
    /// the 24 words to be present: a vault restored from a raw key (there is no such path today)
    /// could not be backed up, and failing loudly beats writing a blob that restores to nothing.
    public func sealBackup(passphrase: String) throws -> Backup.Blob {
        guard let mnemonic = vault?.mnemonic, !mnemonic.isEmpty else { throw EngineError.noPhrase }
        return try Backup.seal(mnemonic: mnemonic, contacts: contacts, passphrase: passphrase)
    }

    /// Open a backup and become the identity inside it, contacts and all.
    ///
    /// Sessions are NOT restored (the blob never carried them): account sync or the invitation flow
    /// re-establishes them before the next message. The keyboard never sends setup into a chat.
    ///
    /// This OVERWRITES whatever identity is on the device. The UI must only offer it where there is
    /// nothing to lose (a fresh install) or where the user has been told plainly.
    @discardableResult
    public func restore(backup blob: Backup.Blob, passphrase: String) throws -> Int {
        let payload = try Backup.open(blob, passphrase: passphrase)
        try importIdentity(mnemonic: payload.mnemonic)

        // Straight in, keeping each contact's original addedAt and verified flag — routing them
        // through addContact would stamp them all with today's date and silently drop the
        // verification the user did by comparing safety numbers.
        let restored = Backup.contacts(from: payload).filter { $0.bundle != identity?.bundle }
        contacts = restored.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
        vault?.contacts = contacts
        try persist()
        return contacts.count
    }

    // MARK: - Contacts

    public var invite: String? {
        identity.map { Wire.formatInvite($0.bundle) }
    }

    public func contact(id: String) -> Contact? { contacts.first { $0.id == id } }

    public func safetyNumber(for c: Contact) throws -> String {
        guard let me = identity else { throw StoreError.noVault }
        return EkkoCrypto.safetyNumber(fpMe: me.fingerprint, fpPeer: c.fingerprint)
    }

    /// Add a contact from their public invite or from a setup response to one of our invites.
    /// Trust-on-first-use — comparing the safety number is what upgrades it to verified.
    @discardableResult
    public func addContact(invite raw: String, label: String?) throws -> Contact {
        guard let c = Wire.classifyStandalone(raw) ?? Wire.classify(raw) else {
            throw EngineError.notAnInvite
        }
        switch c.kind {
        case .invite:
            let bundle = try Wire.decodeBody(c.raw)
            _ = try EkkoCrypto.parseBundle(bundle)  // reject anything malformed before it lands
            return try addPeer(bundle: bundle, label: label)
        case .handshake:
            return try acceptSetup(c.raw, expected: nil, label: label)
        case .message, .chunk:
            throw EngineError.notAnInvite
        }
    }

    @discardableResult
    private func addPeer(bundle: Data, label: String?) throws -> Contact {
        guard let me = identity else { throw StoreError.noVault }
        guard bundle != me.bundle else { throw EngineError.thatIsYou }

        let fp = sha256(bundle).hexString
        if let existing = contacts.first(where: { $0.id == fp }) {
            if let label, !label.isEmpty, existing.label != label {
                try rename(existing, to: label)
                return contact(id: fp) ?? existing
            }
            return existing
        }
        let c = Contact(bundle: bundle, label: label?.isEmpty == false ? label! : "Unnamed")
        contacts.append(c)
        contacts.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        try persist()
        return c
    }

    public func rename(_ c: Contact, to label: String) throws {
        guard let i = contacts.firstIndex(where: { $0.id == c.id }) else { return }
        contacts[i].label = label
        contacts.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        try persist()
    }

    public func setVerified(_ c: Contact, _ verified: Bool) throws {
        guard let i = contacts.firstIndex(where: { $0.id == c.id }) else { return }
        contacts[i].verified = verified
        try persist()
    }

    /// Remove a contact and everything that could keep encrypting to them.
    public func remove(_ c: Contact) throws {
        contacts.removeAll { $0.id == c.id }
        vault?.sessions.removeAll { $0.peerFingerprint.hexString == c.id }
        if vault?.lastContact == c.id { vault?.lastContact = nil }
        try persist()
    }

    // MARK: - Sessions

    /// One conversation per contact on this device. The wire carries the session id, so a session
    /// started here coexists with whatever the browser extension negotiated for the same peer.
    private func threadId(for c: Contact) -> String { "ios:\(c.id)" }

    private func put(_ s: Session) {
        guard var v = vault else { return }
        v.sessions.removeAll { $0.id == s.id }
        v.sessions.append(s)

        let peer = s.peerFingerprint.hexString
        let mine = v.sessions.filter { $0.peerFingerprint.hexString == peer && $0.threadId == s.threadId }
        if mine.count > Self.maxSessionsPerPeerThread {
            let drop = Set(mine.prefix(mine.count - Self.maxSessionsPerPeerThread).map(\.id))
            v.sessions.removeAll { drop.contains($0.id) }
        }
        vault = v
    }

    public func hasSession(with c: Contact) -> Bool {
        let tid = threadId(for: c)
        return vault?.sessions.contains {
            $0.peerFingerprint.hexString == c.id && $0.threadId == tid
        } == true
    }

    /// Create the post-quantum setup payload outside the user's conversation. Account sync uploads
    /// it to the peer's private connection mailbox; off-grid users send it back as their invitation.
    /// nil means a setup from this peer already established the session.
    public func prepareSetup(to c: Contact) throws -> String? {
        guard let me = identity else { throw StoreError.noVault }
        _ = try EkkoCrypto.parseBundle(c.bundle)
        guard c.bundle != me.bundle else { throw EngineError.thatIsYou }
        let tid = threadId(for: c)
        if let s = vault?.sessions.last(where: {
            $0.peerFingerprint.hexString == c.id && $0.threadId == tid
        }) {
            return s.handshakeWire.map(Wire.formatHandshake)
        }

        var (session, wire) = try EkkoCrypto.startHandshake(me: me, peerBundle: c.bundle)
        session.threadId = tid
        session.handshakeWire = wire
        put(session)
        try persist()
        return Wire.formatHandshake(wire)
    }

    /// Accept setup fetched by the app for an already-known account contact. The expected contact
    /// check keeps a swapped backend row from creating or selecting a different recipient.
    public func acceptSetup(_ raw: String, from c: Contact) throws {
        guard contacts.contains(where: { $0.id == c.id }) else { throw EngineError.unknownContact }
        _ = try acceptSetup(raw, expected: c, label: nil)
    }

    private func acceptSetup(_ raw: String, expected: Contact?, label: String?) throws -> Contact {
        guard let me = identity,
              let token = Wire.classifyStandalone(raw) ?? Wire.classify(raw),
              token.kind == .handshake
        else { throw EngineError.notAnInvite }

        var (session, bundle) = try EkkoCrypto.acceptHandshake(
            me: me, wire: try Wire.decodeBody(token.raw))
        if let expected, expected.bundle != bundle { throw EngineError.wrongSetup }
        let peer = try addPeer(bundle: bundle, label: expected?.label ?? label)
        session.threadId = threadId(for: peer)
        if vault?.sessions.contains(where: { $0.id == session.id }) != true { put(session) }
        vault?.lastContact = peer.id
        try persist()
        return peer
    }

    /// The backend now owns the durable copy; the phone only needs the derived session keys.
    public func markSetupPublished(to c: Contact) throws {
        let tid = threadId(for: c)
        guard let i = vault?.sessions.lastIndex(where: {
            $0.peerFingerprint.hexString == c.id && $0.threadId == tid && $0.handshakeWire != nil
        }) else { return }
        vault?.sessions[i].handshakeWire = nil
        try persist()
    }

    // MARK: - Seal

    /// Message tokens only. Session setup belongs in the app/backend or invitation flow and is
    /// never emitted into a host-app conversation by the keyboard.
    public func seal(to c: Contact, plaintext: String) throws -> [String] {
        guard identity != nil, let v = vault else { throw StoreError.noVault }
        // Callers hold Contact values, which outlive a removal. Re-check the book here rather
        // than at each call site: this is the only path that seals, so one guard covers them all.
        guard contacts.contains(where: { $0.id == c.id }) else { throw EngineError.unknownContact }
        let tid = threadId(for: c)

        guard let session = v.sessions.last(where: {
            $0.peerFingerprint.hexString == c.id && $0.threadId == tid
        }) else { throw EngineError.noSession }

        let token = Wire.formatMessage(
            try EkkoCrypto.sealMessage(session: session, plaintext: plaintext))

        vault?.lastContact = c.id
        try persist()
        return try Chunk.split(token: token, id: Chunk.randomId())
    }

    // MARK: - Ingest

    public enum Ingested: Sendable {
        /// A message we could read. `mine` is true for our own echoed bubble.
        case message(text: String, from: Contact, mine: Bool)
        /// A handshake landed: the session is live. `added` is set if the peer was new (TOFU).
        case secureChannel(with: Contact, added: Bool)
        /// An invite landed: the contact is in the book, but no session yet.
        case invited(Contact)
        /// Part of a chunked token. Copy the next piece.
        case needMoreChunks(have: Int, total: Int)
        /// A message for a session we do not have — usually a rekey we missed, or not for us.
        case unknownSession
        /// Nothing that looked like Ekko.
        case nothing
    }

    /// Feed arbitrary text (a pasted bubble, or several bubbles at once). Handles every token in
    /// the text: multi-select-copy in WhatsApp joins messages with newlines, which is exactly how
    /// a 4-part handshake arrives in one paste.
    public func ingest(_ text: String) throws -> Ingested {
        guard identity != nil else { throw StoreError.noVault }

        var result: Ingested = .nothing
        var pending: (have: Int, total: Int)?

        for token in allTokens(in: text) {
            if token.hasPrefix(WireKind.chunk.prefix) {
                guard let part = Chunk.parse(token) else { continue }
                if let whole = reassembler.add(token) {
                    result = try process(whole) ?? result
                } else {
                    pending = (part.index + 1, part.total)
                }
                continue
            }
            if let r = try process(token) { result = r }
        }

        if case .nothing = result, let p = pending { return .needMoreChunks(have: p.have, total: p.total) }
        return result
    }

    private func allTokens(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .compactMap { Wire.classify(String($0))?.raw }
    }

    private func process(_ token: String) throws -> Ingested? {
        guard let me = identity, let c = Wire.classify(token) else { return nil }

        switch c.kind {
        case .invite:
            let bundle = try Wire.decodeBody(c.raw)
            _ = try EkkoCrypto.parseBundle(bundle)
            return .invited(try addPeer(bundle: bundle, label: nil))

        case .handshake:
            let (session, peerBundle) = try EkkoCrypto.acceptHandshake(
                me: me, wire: try Wire.decodeBody(c.raw))
            let fp = sha256(peerBundle).hexString
            let isNew = !contacts.contains { $0.id == fp }
            let peer = try addPeer(bundle: peerBundle, label: nil)

            // A handshake replayed out of another conversation must not create a second session.
            if vault?.sessions.contains(where: { $0.id == session.id }) == true { return nil }
            var s = session
            s.threadId = threadId(for: peer)
            put(s)
            vault?.lastContact = peer.id
            try persist()
            return .secureChannel(with: peer, added: isNew)

        case .message:
            let body = try Wire.decodeBody(c.raw)
            guard let sid = EkkoCrypto.readSessionId(body),
                let session = vault?.sessions.first(where: { $0.id == sid })
            else { return .unknownSession }

            let text = try EkkoCrypto.openMessage(session: session, body: body)
            guard let peer = contacts.first(where: { $0.id == session.peerFingerprint.hexString })
            else { return .unknownSession }

            let fromPeer = EkkoCrypto.isFromPeer(body: body, session: session)
            if fromPeer {
                // They answered, so they have our handshake — stop replaying it.
                if session.handshakeWire != nil, let i = vault?.sessions.firstIndex(where: { $0.id == sid }) {
                    vault?.sessions[i].handshakeWire = nil
                }
                vault?.lastContact = peer.id
                try persist()
            }
            return .message(text: text, from: peer, mine: !fromPeer)

        case .chunk:
            return nil  // handled by the caller's reassembler
        }
    }
}

public enum EngineError: Error, LocalizedError {
    case badMnemonic
    case notAnInvite
    case thatIsYou
    case noSession
    case unknownContact
    case wrongSetup
    case noPhrase

    public var errorDescription: String? {
        switch self {
        case .badMnemonic: "Those 24 words are not a valid recovery phrase."
        case .notAnInvite: "That is not an Ekko invite."
        case .thatIsYou: "That invite is your own."
        case .noSession: "Open Ekko to finish secure setup with that contact."
        case .unknownContact: "That contact is no longer in your list."
        case .wrongSetup: "That setup belongs to a different contact."
        case .noPhrase: "This identity has no recovery phrase, so it cannot be backed up."
        }
    }
}

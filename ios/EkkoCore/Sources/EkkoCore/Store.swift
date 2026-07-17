import Foundation

// At-rest storage for the identity, contacts and sessions — shared by the app and the keyboard
// extension through their App Group container.
//
// The browser vault (src/core/vault.ts) is a scrypt-passphrase-encrypted blob because
// chrome.storage.local is plaintext. iOS gives us a better primitive for free: Data Protection.
// The file is written with `.completeFileProtection` (its class key is wrapped by the device
// passcode and evicted when the phone locks) and excluded from backups, so there is no
// passphrase to type — which is also what makes the keyboard usable at all.
//
// ponytail: one file, no Keychain, no scrypt. The Keychain's only edge here is backup exclusion,
// and setting isExcludedFromBackup closes that. Revisit only if secrets need per-item ACLs.

public struct StoredIdentity: Codable, Sendable {
    public var xPriv: Data
    public var kSeed: Data

    public func identity() throws -> Identity {
        try EkkoCrypto.identity(xPriv: xPriv, kSeed: kSeed)
    }
}

public struct Contact: Codable, Sendable, Identifiable, Equatable {
    public var bundle: Data
    public var label: String
    public var verified: Bool
    public var addedAt: Date

    public var id: String { fingerprint.hexString }
    public var fingerprint: Data { sha256(bundle) }
    public var fingerprintHex: String { EkkoCrypto.fingerprintHex(fingerprint) }

    public init(bundle: Data, label: String, verified: Bool = false, addedAt: Date = Date()) {
        self.bundle = bundle
        self.label = label
        self.verified = verified
        self.addedAt = addedAt
    }
}

public struct VaultData: Codable, Sendable {
    public var identity: StoredIdentity
    /// The 24-word phrase this identity was derived from. It IS the backup; showing it to the
    /// user is the "write this down" flow.
    public var mnemonic: String?
    public var username: String?
    /// Platform handles linked for discovery (platform -> handle as typed). The directory only
    /// ever stores their hash; this local copy is so the UI can show what is linked.
    public var platformHandles: [String: String] = [:]
    public var contacts: [Contact] = []
    public var sessions: [Session] = []
    /// Which contact the keyboard should seal to by default — set whenever a message from them
    /// is revealed, so replying is zero-tap. See KeyboardViewController.
    public var lastContact: String?
}

public enum StoreError: Error, LocalizedError {
    case noAppGroup
    case noVault

    public var errorDescription: String? {
        switch self {
        case .noAppGroup:
            "Ekko's shared container is unavailable. Reinstall the app."
        case .noVault:
            "No Ekko identity on this device yet."
        }
    }
}

public struct EkkoStore: Sendable {
    /// Must match the App Group on every target's entitlements (see ios/project.yml).
    public static let appGroup = "group.app.useekko"

    let url: URL

    public init(appGroup: String = EkkoStore.appGroup) throws {
        guard
            let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { throw StoreError.noAppGroup }
        self.url = dir.appendingPathComponent("vault.json")
    }

    /// Test seam: point the store at a scratch directory.
    public init(directory: URL) {
        self.url = directory.appendingPathComponent("vault.json")
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func load() throws -> VaultData {
        guard exists else { throw StoreError.noVault }
        return try JSONDecoder().decode(VaultData.self, from: Data(contentsOf: url))
    }

    public func save(_ v: VaultData) throws {
        let data = try JSONEncoder().encode(v)

        // Data Protection is an iOS class. On macOS (where `swift test` runs) asking for it makes
        // the atomic write's temp file fail outright with EPERM, so it is iOS-only — which is the
        // only place it means anything anyway.
        #if os(iOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtection]
        #else
            let options: Data.WritingOptions = [.atomic]
        #endif
        try data.write(to: url, options: options)

        // Keep the vault out of iCloud/iTunes backups — a restored backup on another device
        // would otherwise carry the private keys with it.
        var u = url
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
    }

    public func destroy() throws {
        try? FileManager.default.removeItem(at: url)
    }
}

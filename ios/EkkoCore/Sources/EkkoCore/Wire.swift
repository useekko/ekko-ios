import Foundation

// Swift port of src/core/wire.ts + b64.ts. Every Ekko payload rides inside an ordinary DM as
// one whitespace-delimited token.

public enum WireKind: String, Sendable, Codable {
    case invite, handshake, message, chunk

    var prefix: String {
        switch self {
        case .invite: "EKK1I:"
        case .handshake: "EKK1H:"
        case .message: "EKK1M:"
        case .chunk: "EKK1C:"
        }
    }

    /// Read-only compatibility with ciphertext and contacts created under the Resonance name.
    var legacyPrefix: String {
        switch self {
        case .invite: "RSN1I:"
        case .handshake: "RSN1H:"
        case .message: "RSN1M:"
        case .chunk: "RSN1C:"
        }
    }
}

public enum Wire {
    /// Instagram's hard per-message cap is 1000 chars; 900 leaves headroom. The keyboard has no
    /// way to know which app is hosting it, so this conservative cap is used everywhere — it is
    /// correct on the tightest platform and merely chunkier than necessary on the others.
    public static let maxMessageLen = 900

    /// Optional one-line tag appended to sent ciphertext so a non-user sees what it is. Default
    /// OFF (see STATE.md issue 20) — an established contact decrypts the token and never sees it.
    public static let tagline = " · 🔒 Encrypted with Ekko (post-quantum) · useekko.app"

    // base64url is [A-Za-z0-9_-]; chunk tokens additionally use ':' and '/'.
    // Computed, not `static let`: Regex is not Sendable, and a regex literal is compiled at
    // build time, so rebuilding the value per call costs nothing.
    static var tokenRE: Regex<Substring> { /(?:EKK1|RSN1)[IHMC]:[A-Za-z0-9_\-:\/]+/ }
    // Matched LOOSELY: messengers linkify the trailing URL and mangle the emoji, so an exact
    // suffix compare strands real ciphertext as raw text (STATE.md issue 20).
    static var taglineSig: Regex<(Substring, Substring)> { /Encrypted with (Ekko|Resonance) \(post-quantum\)/ }

    /// Find a token anywhere in a blob of text.
    public static func classify(_ text: String) -> (kind: WireKind, raw: String)? {
        guard let m = text.firstMatch(of: tokenRE) else { return nil }
        let raw = String(m.output)
        for kind in [WireKind.invite, .handshake, .message, .chunk]
        where raw.hasPrefix(kind.prefix) || raw.hasPrefix(kind.legacyPrefix) {
            return (kind, raw)
        }
        return nil
    }

    /// Stricter: the token must START the text and only our tagline may follow it. Ordinary prose
    /// that merely *contains* an Ekko-token substring ("what is EKK1M:…?") is not ciphertext.
    public static func classifyStandalone(_ text: String) -> (kind: WireKind, raw: String)? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = classify(candidate), candidate.hasPrefix(c.raw) else { return nil }
        let rest = String(candidate.dropFirst(c.raw.count))
        let ok = rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || rest.firstMatch(of: taglineSig) != nil
        return ok ? c : nil
    }

    public static func formatInvite(_ bundle: Data) -> String { WireKind.invite.prefix + b64u(bundle) }
    public static func formatHandshake(_ w: Data) -> String { WireKind.handshake.prefix + b64u(w) }
    public static func formatMessage(_ body: Data) -> String { WireKind.message.prefix + b64u(body) }

    /// Strip the prefix and base64url-decode the body of a non-chunk token.
    public static func decodeBody(_ raw: String) throws -> Data {
        guard let i = raw.firstIndex(of: ":") else { throw WireError.badToken }
        guard let d = b64uDecode(String(raw[raw.index(after: i)...])) else { throw WireError.badToken }
        return d
    }

    public enum WireError: Error { case badToken }
}

// MARK: - base64url (unpadded)

public func b64u(_ d: Data) -> String {
    d.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

public func b64uDecode(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    if t.count % 4 != 0 { t += String(repeating: "=", count: 4 - t.count % 4) }
    return Data(base64Encoded: t)
}

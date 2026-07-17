import Foundation

// Swift port of src/core/chunk.ts. A single DM has a hard length cap but a handshake token is
// ~3127 chars, so oversized tokens are split into EKK1C:<id>:<i>/<n>:<part> and reassembled
// before decrypt.

public enum Chunk {
    /// 256 × 900-char messages is already far beyond a normal DM while keeping an abandoned
    /// group bounded.
    static let maxChunks = 256
    // Computed: Regex is not Sendable (see Wire.tokenRE).
    static var re: Regex<(Substring, Substring, Substring, Substring, Substring)> {
        /^(?:EKK1C|RSN1C):([0-9a-z]+):([0-9]+)\/([0-9]+):([\s\S]*)$/
    }

    public enum ChunkError: Error { case tooLong, maxLenTooSmall }

    static func headerLen(id: String, i: Int, n: Int) -> Int {
        "EKK1C:\(id):\(i)/\(n):".count
    }

    /// Random group id so chunk streams from different messages never collide in a receiver's
    /// long-lived Reassembler. Fixed 2 chars/byte keeps the concatenation injective.
    public static func randomId() -> String {
        var b = Data(count: 4)
        b.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        return b.map { byte in
            let s = String(byte, radix: 36)
            return s.count < 2 ? String(repeating: "0", count: 2 - s.count) + s : s
        }.joined()
    }

    public static func split(token: String, maxLen: Int = Wire.maxMessageLen, id: String) throws -> [String] {
        if token.count <= maxLen { return [token] }
        // n depends on per-chunk payload size, which depends on the digit-width of n. Iterate up
        // from an estimate until it is self-consistent (converges in 1-2 steps).
        var n = Int(ceil(Double(token.count) / Double(maxLen - headerLen(id: id, i: 0, n: 0))))
        if n > maxChunks { throw ChunkError.tooLong }
        while true {
            let avail = maxLen - headerLen(id: id, i: n, n: n)  // n bounds the index digit-width
            if avail <= 0 { throw ChunkError.maxLenTooSmall }
            let need = Int(ceil(Double(token.count) / Double(avail)))
            if need > maxChunks { throw ChunkError.tooLong }
            if need <= n { break }
            n = need
        }
        let avail = maxLen - headerLen(id: id, i: n, n: n)
        let chars = Array(token)
        return (0..<n).map { i in
            let lo = i * avail
            let hi = min(lo + avail, chars.count)
            return "EKK1C:\(id):\(i)/\(n):" + String(chars[lo..<hi])
        }
    }

    public struct Part {
        public let id: String
        public let index: Int
        public let total: Int
        public let part: String
    }

    public static func parse(_ s: String) -> Part? {
        guard let m = s.wholeMatch(of: re) else { return nil }
        guard let index = Int(m.2), let total = Int(m.3) else { return nil }
        guard total >= 1, total <= maxChunks, index >= 0, index < total else { return nil }
        return Part(id: String(m.1), index: index, total: total, part: String(m.4))
    }
}

/// Buffers chunks (arriving in any order, across renders) until a group is whole.
public final class Reassembler {
    private var buf: [String: [Int: String]] = [:]
    private var order: [String] = []

    public init() {}

    /// Returns the reassembled token once the last missing part arrives, else nil.
    public func add(_ s: String) -> String? {
        guard let c = Chunk.parse(s) else { return nil }
        if buf[c.id] == nil {
            // ponytail: FIFO cap keeps an abandoned-groups leak bounded; LRU if it ever matters
            if buf.count >= 64, let oldest = order.first {
                buf.removeValue(forKey: oldest)
                order.removeFirst()
            }
            buf[c.id] = [:]
            order.append(c.id)
        }
        buf[c.id]?[c.index] = c.part
        guard let group = buf[c.id], group.count >= c.total else { return nil }

        var out = ""
        for i in 0..<c.total {
            guard let p = group[i] else { return nil }  // gap — wait for more
            out += p
        }
        buf.removeValue(forKey: c.id)
        order.removeAll { $0 == c.id }
        return out
    }
}

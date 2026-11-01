import Foundation

/// File-system helpers shared by the host, the test method and the checks.
///
/// Command channels are private prototype surfaces. Files are created with
/// owner-only permissions; secrets are never written here except the pairing
/// record's short-lived FFI staging file, which uses complete file protection.
public enum BridgeFileProtection: Sendable {
    case complete
}

public enum BridgeAtomicFile {
    @discardableResult
    public static func writeJSON(_ object: Any, to url: URL, protection: BridgeFileProtection? = nil) -> Bool {
        guard JSONSerialization.isValidJSONObject(object) else { return false }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try write(data, to: url, protection: protection)
            return true
        } catch {
            BridgeLog.shared.append("atomic_write_failed target=\(url.lastPathComponent) error=\(error.localizedDescription)")
            return false
        }
    }

    public static func write(_ data: Data, to url: URL, protection: BridgeFileProtection? = nil) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var options: Data.WritingOptions = [.atomic]
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        if protection == .complete {
            options.insert(.completeFileProtection)
        }
        #else
        _ = protection
        #endif
        try data.write(to: url, options: options)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), data.count <= 1_048_576 else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    public static func safeIdentifier(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleaned = String(scalars.prefix(96))
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    public static func sha256(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var hash = SHA256Context()
            hash.update(bytes: base.assumingMemoryBound(to: UInt8.self), count: data.count)
            hash.finalize(into: &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Minimal SHA-256 for provenance records. CommonCrypto/CryptoKit add link
/// requirements to a framework also loaded by the network extension; this
/// implementation keeps BridgeCore dependency-free.
private struct SHA256Context {
    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var buffer = [UInt8]()
    private var length: UInt64 = 0

    mutating func update(bytes: UnsafePointer<UInt8>, count: Int) {
        length &+= UInt64(count)
        buffer.append(contentsOf: UnsafeBufferPointer(start: bytes, count: count))
        while buffer.count >= 64 {
            process(Array(buffer[0..<64]))
            buffer.removeFirst(64)
        }
    }

    mutating func finalize(into digest: inout [UInt8]) {
        let bitLength = length &* 8
        buffer.append(0x80)
        while buffer.count % 64 != 56 { buffer.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }
        while buffer.count >= 64 {
            process(Array(buffer[0..<64]))
            buffer.removeFirst(64)
        }
        for (index, word) in state.enumerated() {
            digest[index * 4] = UInt8((word >> 24) & 0xff)
            digest[index * 4 + 1] = UInt8((word >> 16) & 0xff)
            digest[index * 4 + 2] = UInt8((word >> 8) & 0xff)
            digest[index * 4 + 3] = UInt8(word & 0xff)
        }
    }

    private mutating func process(_ block: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            w[i] = (UInt32(block[i * 4]) << 24) |
                (UInt32(block[i * 4 + 1]) << 16) |
                (UInt32(block[i * 4 + 2]) << 8) |
                UInt32(block[i * 4 + 3])
        }
        for i in 16..<64 {
            let s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        for i in 0..<64 {
            let S1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
            let ch = (e & f) ^ ((~e) & g)
            let temp1 = h &+ S1 &+ ch &+ k[i] &+ w[i]
            let S0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = S0 &+ maj
            h = g; g = f; f = e; e = d &+ temp1
            d = c; c = b; b = a; a = temp1 &+ temp2
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }

    private func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}

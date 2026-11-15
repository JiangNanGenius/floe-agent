// SPDX-License-Identifier: MPL-2.0
import Foundation
import zlib

public enum RPGCodecError: Error, Equatable, CustomStringConvertible {
    case malformedArchive(String)
    case zlibError(String)
    case outputLimitExceeded
    case invalidTable(String)
    case unsupportedData(String)

    public var description: String {
        switch self {
        case .malformedArchive(let detail): return "malformed script archive: \(detail)"
        case .zlibError(let detail): return "zlib error: \(detail)"
        case .outputLimitExceeded: return "decompressed data exceeds limit"
        case .invalidTable(let detail): return "invalid table data: \(detail)"
        case .unsupportedData(let detail): return "unsupported data: \(detail)"
        }
    }
}

/// Bounded zlib inflate. Returns the decompressed bytes or a codec error.
public func zlibInflate(_ data: Data, maximumOutput: Int = 128 * 1_024 * 1_024) throws -> Data {
    var stream = z_stream()
    var status = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard status == Z_OK else { throw RPGCodecError.zlibError("inflateInit failed (\(status))") }
    defer { inflateEnd(&stream) }

    var output = Data()
    output.reserveCapacity(min(maximumOutput, max(data.count * 4, 64 * 1_024)))
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    let bufferCapacity = buffer.count
    let input = [UInt8](data)

    return try input.withUnsafeBufferPointer { inputPointer in
        stream.next_in = UnsafeMutablePointer<UInt8>(mutating: inputPointer.baseAddress)
        stream.avail_in = UInt32(input.count)
        while true {
            buffer.withUnsafeMutableBufferPointer { bufferPointer in
                stream.next_out = bufferPointer.baseAddress
                stream.avail_out = UInt32(bufferCapacity)
                status = inflate(&stream, Z_NO_FLUSH)
            }
            let produced = bufferCapacity - Int(stream.avail_out)
            output.append(contentsOf: buffer[0..<produced])
            guard output.count <= maximumOutput else { throw RPGCodecError.outputLimitExceeded }
            if status == Z_STREAM_END { break }
            guard status == Z_OK else { throw RPGCodecError.zlibError("inflate failed (\(status))") }
            guard produced > 0 || stream.avail_in > 0 else { throw RPGCodecError.zlibError("truncated stream") }
        }
        return output
    }
}

/// zlib deflate at the given level (Ruby's `Zlib::Deflate.deflate` equivalent).
public func zlibDeflate(_ data: Data, level: Int32 = Z_DEFAULT_COMPRESSION) throws -> Data {
    var stream = z_stream()
    var status = deflateInit_(&stream, level, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard status == Z_OK else { throw RPGCodecError.zlibError("deflateInit failed (\(status))") }
    defer { deflateEnd(&stream) }
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    let bufferCapacity = buffer.count
    let input = [UInt8](data)
    try input.withUnsafeBufferPointer { inputPointer in
        stream.next_in = UnsafeMutablePointer<UInt8>(mutating: inputPointer.baseAddress)
        stream.avail_in = UInt32(input.count)
        while true {
            buffer.withUnsafeMutableBufferPointer { bufferPointer in
                stream.next_out = bufferPointer.baseAddress
                stream.avail_out = UInt32(bufferCapacity)
                status = deflate(&stream, Z_FINISH)
            }
            output.append(contentsOf: buffer[0..<(bufferCapacity - Int(stream.avail_out))])
            if status == Z_STREAM_END { break }
            guard status == Z_OK else { throw RPGCodecError.zlibError("deflate failed (\(status))") }
        }
    }
    return output
}

/// One entry in a `Scripts.rxdata` / `Scripts.rvdata` / `Scripts.rvdata2`
/// archive. Compressed payloads that were not edited are re-emitted verbatim
/// so untouched script archives round-trip byte-identically.
public struct RPGScript: Equatable, Sendable {
    /// Editor magic number (RVPG disregards it; preserved as-is).
    public var magic: Int64
    public var title: RubyString
    /// Decompressed Ruby source bytes (UTF-8 in modern projects; arbitrary
    /// bytes are preserved for legacy projects).
    public var source: Data
    /// Original compressed payload when decoded from an archive and not yet
    /// edited; reused on encode for byte-exact output.
    public let originalCompressed: Data?

    public init(magic: Int64, title: RubyString, source: Data, originalCompressed: Data? = nil) {
        self.magic = magic
        self.title = title
        self.source = source
        self.originalCompressed = originalCompressed
    }

    public static func == (lhs: RPGScript, rhs: RPGScript) -> Bool {
        lhs.magic == rhs.magic && lhs.title == rhs.title && lhs.source == rhs.source
    }
}

/// Limits for script archive processing.
public struct RPGScriptLimits: Sendable {
    public var maximumScripts: Int
    public var maximumCompressedBytes: Int
    public var maximumDecompressedBytes: Int

    public init(maximumScripts: Int = 4_096,
                maximumCompressedBytes: Int = 16 * 1_024 * 1_024,
                maximumDecompressedBytes: Int = 128 * 1_024 * 1_024) {
        self.maximumScripts = maximumScripts
        self.maximumCompressedBytes = maximumCompressedBytes
        self.maximumDecompressedBytes = maximumDecompressedBytes
    }
}

/// Reads and writes RPG Maker script archives on top of a Marshal graph.
public enum RPGScriptArchive {
    /// Decodes `Scripts.rxdata`-shaped marshal bytes into ordered scripts.
    /// The marshal graph itself is returned too so unknown per-entry content
    /// beyond the triple shape stays recoverable by callers that need it.
    public static func decode(_ data: Data, limits: RPGScriptLimits = RPGScriptLimits(),
                              marshalLimits: MarshalParseLimits = MarshalParseLimits()) throws -> [RPGScript] {
        let root = try RubyMarshal.parse(data, limits: marshalLimits)
        return try decode(root: root, limits: limits)
    }

    public static func decode(root: RubyNode, limits: RPGScriptLimits = RPGScriptLimits()) throws -> [RPGScript] {
        guard case .array(let entries) = root.value.kind else {
            throw RPGCodecError.malformedArchive("root is not an array")
        }
        guard entries.count <= limits.maximumScripts else { throw RPGCodecError.malformedArchive("too many scripts") }
        var scripts: [RPGScript] = []
        scripts.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            guard case .array(let triple) = entry.value.kind, triple.count == 3 else {
                throw RPGCodecError.malformedArchive("entry \(index) is not a [magic, title, source] triple")
            }
            guard let magic = triple[0].value.kind.int64Value else {
                throw RPGCodecError.malformedArchive("entry \(index) magic is not an integer")
            }
            guard let title = triple[1].value.kind.stringValue else {
                throw RPGCodecError.malformedArchive("entry \(index) title is not a string")
            }
            let compressed = triple[2].value.kind.stringValue?.bytes
            guard let compressed, compressed.count <= limits.maximumCompressedBytes else {
                throw RPGCodecError.malformedArchive("entry \(index) payload missing or too large")
            }
            let source = try zlibInflate(compressed, maximumOutput: limits.maximumDecompressedBytes)
            scripts.append(RPGScript(magic: magic, title: title, source: source, originalCompressed: compressed))
        }
        return scripts
    }

    /// Encodes scripts back to `Scripts.rxdata`-shaped marshal bytes.
    /// Entries whose source is unchanged reuse their original compressed
    /// payload; edited entries are deflated fresh at default level (matching
    /// `Zlib::Deflate.deflate`). Script order is exactly the array order.
    public static func encode(_ scripts: [RPGScript], limits: RPGScriptLimits = RPGScriptLimits(),
                              marshalLimits: MarshalParseLimits = MarshalParseLimits()) throws -> Data {
        guard scripts.count <= limits.maximumScripts else { throw RPGCodecError.malformedArchive("too many scripts") }
        var entries: [RubyNode] = []
        entries.reserveCapacity(scripts.count)
        for (index, script) in scripts.enumerated() {
            let payload: Data
            if let original = script.originalCompressed, script.source.count <= limits.maximumDecompressedBytes {
                if let recompressed = try? zlibInflate(original, maximumOutput: limits.maximumDecompressedBytes),
                   recompressed == script.source {
                    payload = original
                } else {
                    payload = try zlibDeflate(script.source)
                }
            } else {
                payload = try zlibDeflate(script.source)
            }
            guard payload.count <= limits.maximumCompressedBytes else {
                throw RPGCodecError.malformedArchive("entry \(index) payload too large")
            }
            entries.append(RubyNode(RubyValue(kind: .array([
                RubyNode(RubyValue(kind: .integer(script.magic))),
                RubyNode(RubyValue(kind: .string(script.title))),
                RubyNode(RubyValue(kind: .string(RubyString(bytes: payload, encoding: .binary)))),
            ]))))
        }
        let root = RubyNode(RubyValue(kind: .array(entries)))
        return try RubyMarshal.serialize(root, limits: marshalLimits)
    }
}

// RubyString equality for RPGScript (bytes + encoding form).
extension RubyString: Equatable {
    public static func == (lhs: RubyString, rhs: RubyString) -> Bool {
        lhs.bytes == rhs.bytes
            && rubyConstantsEqual(lhs.encoding.ivarList, rhs.encoding.ivarList)
            && rubyConstantsEqual(lhs.extraIVars, rhs.extraIVars)
    }
}

private func rubyConstantsEqual(_ lhs: [(String, RubyConstant)],
                                _ rhs: [(String, RubyConstant)]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for index in lhs.indices {
        guard lhs[index].0 == rhs[index].0, lhs[index].1 == rhs[index].1 else { return false }
    }
    return true
}

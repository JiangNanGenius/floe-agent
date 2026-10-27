// FloeApp — staged-export pull contract.
//
// Pure core, Foundation only: this file owns the frozen v1 wire contract of
// the native staged-export PULL — the fixed read-back script source, the
// strict descriptor/chunk ingress validation (all size/checksum bounds are
// enforced BEFORE any base64 allocation), the PNG structure check and the
// receipt shape. It deliberately imports nothing else so the exact validation
// logic object-compiles and unit-tests standalone (host stage), while the
// WebKit-bound service that uses it lives in BrowserStagedExportService.swift.
//
// Trust model: an authorized native tool call (runtime-issued ToolContext)
// opens one export; the page NEVER initiates anything. The fixed script reads
// the page's own staged raster (`window.__posterExport` / `window.__artExport`
// as staged by the reviewed art/canvas packages) in bounded chunks; every
// reply is untrusted data re-validated here. Destination, ownership and write
// authority come only from the tool context and the workspace path guard.

import Foundation

// MARK: - Frozen contract constants

enum StagedExportContract {
    static let name = "floe.staged-export"
    static let version = 1
    static let descriptorSchema = "floe.staged-export-descriptor/1"

    /// Hard ceiling on the committed file bytes. Matches the page-side
    /// staging cap of the reviewed art/canvas packages (32 MiB); a larger
    /// declared raster is rejected before any chunk is requested.
    static let maxFileBytes = 32 * 1024 * 1024
    /// Base64 characters per chunk pull. Multiple of 4, so every chunk
    /// decodes independently; identical to the packages' own chunk size.
    static let chunkBase64Chars = 786_432
    /// Hard ceiling on chunk pulls for one export (32 MiB needs ≤ 57).
    static let maxChunks = 64
    /// PNG pixel bounds: per-side and total (structural anti-abuse; the deep
    /// content walk stays with the package's verify_png.py).
    static let maxDimension = 16_384
    static let maxPixelCount = 100_000_000
    /// One WebKit call (descriptor or one chunk).
    static let perCallTimeoutMilliseconds = 20_000
    /// One whole export operation.
    static let overallTimeoutMilliseconds = 120_000
}

// MARK: - Errors

enum StagedExportError: Error, Equatable {
    /// Validation refusal; reasons are safe, content-free strings.
    case rejected([String])
    /// The export was fenced by a lifecycle transition (navigation, tab
    /// close, takeover, handoff, release) or cancellation.
    case fenced(String)
    /// The bound page/endpoint could not serve the fixed read-back call.
    case unavailable(String)
    /// The fixed script returned an unusable reply envelope.
    case invalidReply(String)
    /// Staging/commit failure; the destination is untouched, the part file
    /// is removed by the caller's cleanup.
    case storage(String)
}

// MARK: - Descriptor

/// The strictly validated staged-export descriptor of the bound document.
/// Every field is untrusted page data that passed native validation; the
/// staged `name` is informational only — the destination always comes from
/// the authorized tool call.
struct StagedExportDescriptor: Sendable, Equatable {
    enum Source: String, Sendable {
        case poster
        case art
    }
    var source: Source
    var name: String
    var width: Int
    var height: Int
    var bytes: Int
    /// Required, lowercase 64-hex. A staged raster without a declared digest
    /// is refused (the reviewed packages always compute it on loopback, which
    /// is a secure context).
    var sha256: String

    /// Exact base64 length of the staged data URL payload for `bytes`.
    var expectedBase64Chars: Int { 4 * ((bytes + 2) / 3) }
}

enum StagedExportValidation {
    /// True for `^[A-Za-z0-9._-]{1,128}$` without any `..` component.
    static func isSafeStagedName(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        guard !value.contains("..") else { return false }
        let allowed: Set<Character> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return value.allSatisfy { allowed.contains($0) }
    }

    /// True for lowercase 64-hex.
    static func isSHA256Hex(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        let allowed: Set<Character> = Set("0123456789abcdef")
        return value.allSatisfy { allowed.contains($0) }
    }

    /// Strict canonical base64 GRAMMAR, checked before any decode and before
    /// any padding arithmetic: a multiple-of-4 run of base64 alphabet
    /// characters whose only `=` characters are the final one or two.
    ///
    /// This exists because `Data(base64Encoded:)` must NOT be assumed strict.
    /// Measured on Darwin Foundation (host `swift` run, 2026-10-28, and the
    /// real native failure `decodeChunkRefusesCorruptPadding` on the pinned
    /// iPad): it ACCEPTS misplaced padding and non-canonical trailing bits and
    /// silently decodes SHORT instead of failing —
    ///   * `"AA=A"` → 2 bytes (re-encodes to `"AAA="`)
    ///   * `"AB=="` → 1 byte (re-encodes to `"AA=="`)
    ///   * `"/x=="` → 1 byte (re-encodes to `"/w=="`)
    /// A forged or corrupt chunk would therefore become truncated bytes rather
    /// than a rejection. The frozen v1 wire contract is the canonical grammar
    /// the page's own `btoa`/`toDataURL` produces, so this scan accepts every
    /// genuine staged payload and refuses interior padding outright. Pure and
    /// allocation-free; the caller has already bounded `value` by
    /// `StagedExportContract.chunkBase64Chars`.
    static func isCanonicalBase64Grammar(_ value: String) -> Bool {
        let bytes = value.utf8
        let count = bytes.count
        guard count > 0, count % 4 == 0 else { return false }
        func isAlphabet(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "+"), UInt8(ascii: "/"):
                return true
            default:
                return false
            }
        }
        var position = 0
        var sawPadding = false
        for byte in bytes {
            if byte == UInt8(ascii: "=") {
                // `=` is legal only in the final two positions of the quantum
                // run, so interior padding such as "AA=A" is refused here
                // rather than decoded short by a lenient Foundation decoder.
                guard position >= count - 2 else { return false }
                sawPadding = true
            } else {
                // No alphabet character may follow padding, and every other
                // character must be in the standard base64 alphabet.
                guard !sawPadding, isAlphabet(byte) else { return false }
            }
            position += 1
        }
        return true
    }

    /// Workspace-relative destination validation for the EXPORT PATH (the
    /// authorized argument, not page data). The path guard still runs after
    /// this; this is the typed-contract layer (PNG-only operation).
    static func destinationRejections(_ path: String) -> [String] {
        var rejections: [String] = []
        guard !path.isEmpty, path.utf8.count <= 1024 else {
            rejections.append("destination path must be 1–1024 bytes")
            return rejections
        }
        if path.hasPrefix("/") || path.hasPrefix("~") {
            rejections.append("destination must be workspace-relative")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.contains(where: { $0 == ".." }) {
            rejections.append("destination must not traverse upward")
        }
        let last = components.last ?? ""
        if !isSafeStagedName(last) {
            rejections.append("destination file name must match [A-Za-z0-9._-]{1,128}")
        }
        if !last.lowercased().hasSuffix(".png") || last.lowercased() == ".png" {
            rejections.append("staged export commits PNG files only (.png destination required)")
        }
        return rejections
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              Double(number.intValue) == number.doubleValue,
              number.intValue > 0 else { return nil }
        return number.intValue
    }

    /// Strict descriptor ingress. Returns the validated descriptor or the
    /// exact rejection reasons; a rejected reply never yields a descriptor
    /// and never starts a chunk pull.
    static func decodeDescriptor(
        _ reply: [String: Any],
        expectedNonce: String,
        expectedLocation: String,
        expectedWidth: Int?,
        expectedHeight: Int?
    ) -> (descriptor: StagedExportDescriptor?, rejections: [String]) {
        var rejections: [String] = []
        if (reply["ok"] as? NSNumber)?.boolValue != true {
            let reason = (reply["reason"] as? String) ?? "unspecified"
            // `no-staged-export`/`not-staged` are the honest "the page staged
            // nothing" outcomes; keep them distinguishable in the refusal.
            return (nil, ["page reports no usable staged export (\(reason))"])
        }
        if (reply["nonce"] as? String) != expectedNonce {
            rejections.append("reply nonce does not match this call")
        }
        if (reply["loc"] as? String) != expectedLocation {
            rejections.append("reply location does not match the bound document")
        }
        if (reply["schema"] as? String) != StagedExportContract.descriptorSchema {
            rejections.append("descriptor schema is not \(StagedExportContract.descriptorSchema)")
        }
        guard let sourceRaw = reply["source"] as? String,
              let source = StagedExportDescriptor.Source(rawValue: sourceRaw) else {
            rejections.append("descriptor source is not poster/art")
            return (nil, rejections)
        }
        let name = (reply["name"] as? String) ?? ""
        if !isSafeStagedName(name) {
            rejections.append("staged name is not a safe single component")
        }
        guard let width = positiveInt(reply["width"]), let height = positiveInt(reply["height"]) else {
            rejections.append("descriptor width/height absent or not positive integers")
            return (nil, rejections)
        }
        if width > StagedExportContract.maxDimension || height > StagedExportContract.maxDimension {
            rejections.append("descriptor dimensions exceed \(StagedExportContract.maxDimension) per side")
        }
        if width * height > StagedExportContract.maxPixelCount {
            rejections.append("descriptor pixel count exceeds \(StagedExportContract.maxPixelCount)")
        }
        guard let bytes = positiveInt(reply["bytes"]) else {
            rejections.append("descriptor bytes absent or not a positive integer")
            return (nil, rejections)
        }
        if bytes > StagedExportContract.maxFileBytes {
            rejections.append("declared \(bytes) bytes exceeds the \(StagedExportContract.maxFileBytes)-byte cap")
        }
        guard let sha = reply["sha256"] as? String, isSHA256Hex(sha) else {
            rejections.append("descriptor sha256 is required and must be lowercase 64-hex")
            return (nil, rejections)
        }
        if (reply["hasDataURL"] as? NSNumber)?.boolValue != true {
            rejections.append("page staged no PNG data URL (oversize or unsupported engine)")
        }
        if let expectedWidth, expectedWidth != width {
            rejections.append("staged width \(width) != expected \(expectedWidth)")
        }
        if let expectedHeight, expectedHeight != height {
            rejections.append("staged height \(height) != expected \(expectedHeight)")
        }
        guard rejections.isEmpty else { return (nil, rejections) }
        return (StagedExportDescriptor(source: source, name: name, width: width,
                                       height: height, bytes: bytes, sha256: sha), [])
    }

    /// Chunk plan derived from the DECLARED byte count — computed and capped
    /// before any chunk is requested or any buffer allocated.
    static func chunkPlan(for descriptor: StagedExportDescriptor) -> (chunkCount: Int, totalChars: Int, rejections: [String]) {
        let totalChars = descriptor.expectedBase64Chars
        let chunkCount = (totalChars + StagedExportContract.chunkBase64Chars - 1) / StagedExportContract.chunkBase64Chars
        var rejections: [String] = []
        if totalChars < 4 { rejections.append("declared bytes produce no base64 payload") }
        if chunkCount > StagedExportContract.maxChunks {
            rejections.append("declared bytes need \(chunkCount) chunks > \(StagedExportContract.maxChunks)")
        }
        return (chunkCount, totalChars, rejections)
    }

    /// Strict one-chunk ingress. EVERY bound is checked on the encoded text
    /// before `Data(base64Encoded:)` runs, so an oversized reply is rejected
    /// without ever allocating its decoded form.
    static func decodeChunk(
        _ reply: [String: Any],
        expectedNonce: String,
        expectedLocation: String,
        expectedIndex: Int,
        expectedTotalChars: Int,
        remainingBytes: Int
    ) -> (data: Data?, rejections: [String]) {
        var rejections: [String] = []
        if (reply["ok"] as? NSNumber)?.boolValue != true {
            let reason = (reply["reason"] as? String) ?? "unspecified"
            return (nil, ["page could not serve chunk \(expectedIndex) (\(reason))"])
        }
        if (reply["nonce"] as? String) != expectedNonce {
            rejections.append("chunk nonce does not match this call")
        }
        if (reply["loc"] as? String) != expectedLocation {
            rejections.append("chunk location does not match the bound document")
        }
        guard let index = (reply["index"] as? NSNumber).flatMap({ Int(exactly: $0.intValue) }),
              index == expectedIndex else {
            rejections.append("chunk index is not \(expectedIndex)")
            return (nil, rejections)
        }
        guard let total = (reply["total"] as? NSNumber).flatMap({ Int(exactly: $0.intValue) }),
              total == expectedTotalChars else {
            rejections.append("staged payload length changed mid-export")
            return (nil, rejections)
        }
        guard let base64 = reply["data"] as? String else {
            rejections.append("chunk data is not a string")
            return (nil, rejections)
        }
        let chars = base64.utf8.count
        if chars == 0 {
            rejections.append("chunk is empty")
            return (nil, rejections)
        }
        if chars > StagedExportContract.chunkBase64Chars {
            rejections.append("chunk carries \(chars) chars > \(StagedExportContract.chunkBase64Chars)")
            return (nil, rejections)
        }
        let remainingChars = expectedTotalChars - expectedIndex * StagedExportContract.chunkBase64Chars
        if chars > remainingChars {
            rejections.append("chunk exceeds the declared remaining payload")
            return (nil, rejections)
        }
        if chars % 4 != 0 {
            rejections.append("chunk length is not a base64 quantum multiple")
            return (nil, rejections)
        }
        // Strict canonical grammar BEFORE any decode and before the padding
        // arithmetic below, because `Data(base64Encoded:)` is measurably lenient
        // on Darwin (it accepts "AA=A" as 2 bytes) and would otherwise turn a
        // corrupt chunk into silently truncated bytes. Refusing here keeps the
        // "chunk is not valid base64" refusal the page-facing truth.
        guard isCanonicalBase64Grammar(base64) else {
            rejections.append("chunk is not valid base64")
            return (nil, rejections)
        }
        // Exact pre-decode size bound. A base64 quantum string decodes to
        // chars/4*3 bytes MINUS its terminal '=' padding (0, 1 or 2). The
        // unpadded chars/4*3 over-estimates the final chunk of any payload
        // whose byte count is not a multiple of 3 (padding '=' or '==') by
        // exactly that padding, which used to refuse a genuine export whose
        // declared bytes equal the real decoded size. Counting the terminal
        // padding makes the bound exact, so it still refuses any chunk that
        // would decode past the remaining declared budget BEFORE allocating,
        // and never under-counts: a valid decode yields exactly this many
        // bytes. The grammar gate above is what refuses misplaced/corrupt
        // padding — Foundation's own decoder does not.
        let terminalPadding: Int
        if base64.hasSuffix("==") { terminalPadding = 2 }
        else if base64.hasSuffix("=") { terminalPadding = 1 }
        else { terminalPadding = 0 }
        if chars / 4 * 3 - terminalPadding > remainingBytes {
            rejections.append("chunk would exceed the declared byte total before decode")
            return (nil, rejections)
        }
        guard let data = Data(base64Encoded: base64) else {
            rejections.append("chunk is not valid base64")
            return (nil, rejections)
        }
        // Canonical round-trip. The grammar gate cannot see non-zero padding
        // BITS, which a lenient decoder also swallows (measured: "AB==" and
        // "/x==" each decode to 1 byte that re-encodes differently). A genuine
        // `btoa`/`toDataURL` payload always re-encodes to itself, so this is a
        // tightening only; it is bounded by the same chunk cap as the decode.
        guard data.base64EncodedString() == base64 else {
            rejections.append("chunk is not valid base64")
            return (nil, rejections)
        }
        if data.count > remainingBytes {
            rejections.append("decoded chunk exceeds the declared byte total")
            return (nil, rejections)
        }
        guard rejections.isEmpty else { return (nil, rejections) }
        return (data, [])
    }
}

// MARK: - PNG structure (head/tail; deep walk stays with verify_png.py)

enum StagedExportPNGStructure {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// The frozen CRC of the empty IEND chunk.
    static let iendCRC: UInt32 = 0xAE42_6082

    private static func be32(_ bytes: ArraySlice<UInt8>) -> UInt32? {
        guard bytes.count == 4 else { return nil }
        var value: UInt32 = 0
        for byte in bytes { value = (value << 8) | UInt32(byte) }
        return value
    }

    /// Validates the streamed head (first ≥33 bytes) and tail (last ≥12
    /// bytes) of the committed payload against the descriptor/caller
    /// expectations. Returns rejection reasons; empty means the structural
    /// contract holds. Full-chunk CRC/IDAT verification is deliberately the
    /// package's verify_png.py step (guest), documented in the receipt path.
    static func rejections(
        head: Data,
        tail: Data,
        totalBytes: Int,
        declaredWidth: Int,
        declaredHeight: Int,
        expectedWidth: Int?,
        expectedHeight: Int?
    ) -> [String] {
        var rejections: [String] = []
        let headBytes = [UInt8](head)
        let tailBytes = [UInt8](tail)
        guard headBytes.count >= 33 else {
            return ["payload shorter than a PNG header"]
        }
        guard headBytes.prefix(8) == ArraySlice(signature) else {
            rejections.append("payload is not a PNG (signature)")
            return rejections
        }
        guard be32(headBytes[8..<12]) == 13,
              headBytes[12] == 0x49, headBytes[13] == 0x48,
              headBytes[14] == 0x44, headBytes[15] == 0x52 else {
            rejections.append("first chunk is not a 13-byte IHDR")
            return rejections
        }
        guard let width32 = be32(headBytes[16..<20]), let height32 = be32(headBytes[20..<24]),
              width32 > 0, height32 > 0,
              width32 <= UInt32(StagedExportContract.maxDimension),
              height32 <= UInt32(StagedExportContract.maxDimension) else {
            rejections.append("IHDR dimensions are absent or out of bounds")
            return rejections
        }
        let width = Int(width32), height = Int(height32)
        if width * height > StagedExportContract.maxPixelCount {
            rejections.append("IHDR pixel count exceeds \(StagedExportContract.maxPixelCount)")
        }
        if width != declaredWidth || height != declaredHeight {
            rejections.append("IHDR \(width)x\(height) != declared \(declaredWidth)x\(declaredHeight)")
        }
        if let expectedWidth, expectedWidth != width {
            rejections.append("IHDR width \(width) != expected \(expectedWidth)")
        }
        if let expectedHeight, expectedHeight != height {
            rejections.append("IHDR height \(height) != expected \(expectedHeight)")
        }
        let bitDepth = headBytes[24], colorType = headBytes[25]
        if ![1, 2, 4, 8, 16].contains(bitDepth) {
            rejections.append("IHDR bit depth \(bitDepth) is not a PNG value")
        }
        if ![0, 2, 3, 4, 6].contains(colorType) {
            rejections.append("IHDR color type \(colorType) is not a PNG value")
        }
        if headBytes[26] != 0 || headBytes[27] != 0 {
            rejections.append("IHDR compression/filter methods are not 0")
        }
        if headBytes[28] != 0 {
            rejections.append("interlaced PNGs are refused (verify_png/png_to_pdf contract is non-interlaced)")
        }
        // sig(8) + IHDR chunk(25) + IEND chunk(12) is the structural floor.
        guard totalBytes >= 45 else {
            rejections.append("payload too short to be a complete PNG")
            return rejections
        }
        guard tailBytes.count >= 12 else {
            rejections.append("payload tail shorter than an IEND chunk")
            return rejections
        }
        let iend = tailBytes.suffix(12)
        if be32(iend.prefix(4)) != 0
            || iend.dropFirst(4).prefix(4) != ArraySlice([0x49, 0x45, 0x4E, 0x44])
            || be32(iend.suffix(4)) != iendCRC {
            rejections.append("payload does not terminate with a well-formed IEND (trailing bytes or truncation)")
        }
        return rejections
    }
}

// MARK: - Fixed read-back script (native-owned; data-only arguments)

/// The fixed producer script for the staged-export pull. It is the ONLY
/// JavaScript this operation ever runs: a native-owned constant source with
/// data-only arguments (`op`, `source`, `index`, `chars`, `nonce`), evaluated
/// in the bound tab's main frame. There is no arbitrary-eval parameter and no
/// message handler; a page can never start this script or a write.
///
/// Both reply shapes echo `nonce` (per-call) and `loc` (location.href) so the
/// native side binds every answer to the exact call and document it asked.
/// All returned values are untrusted data and pass the strict ingress above.
enum StagedExportScript {
    static let source = #"""
    if (typeof window === 'undefined') { return {ok:false, reason:'no-window'}; }
    const reply = (extra) => Object.assign({nonce: nonce, loc: String(location.href)}, extra);
    if (op === 'descriptor') {
      let found = null;
      if (window.__posterExport && typeof window.__posterExport === 'object') {
        found = {source: 'poster', d: window.__posterExport};
      } else if (window.__artExport && typeof window.__artExport === 'object') {
        found = {source: 'art', d: window.__artExport};
      }
      if (!found) { return reply({ok:false, reason:'no-staged-export'}); }
      const d = found.d;
      if (d.state !== 'staged') { return reply({ok:false, reason:'not-staged'}); }
      const num = (v) => (typeof v === 'number' && isFinite(v)) ? Math.trunc(v) : null;
      const url = (typeof d.dataURL === 'string') ? d.dataURL : '';
      return reply({
        ok: true,
        schema: 'floe.staged-export-descriptor/1',
        source: found.source,
        name: (typeof d.name === 'string') ? d.name.slice(0, 256) : '',
        width: num(d.width),
        height: num(d.height),
        bytes: num(d.bytes),
        sha256: (typeof d.sha256 === 'string' && d.sha256.length > 0) ? d.sha256.toLowerCase().slice(0, 128) : null,
        hasDataURL: url.indexOf('data:image/png;base64,') === 0
      });
    }
    if (op === 'chunk') {
      const d = (source === 'poster') ? window.__posterExport
              : (source === 'art') ? window.__artExport : null;
      if (!d || d.state !== 'staged' || typeof d.dataURL !== 'string') {
        return reply({ok:false, reason:'no-staged-data'});
      }
      const prefix = 'data:image/png;base64,';
      if (d.dataURL.indexOf(prefix) !== 0) { return reply({ok:false, reason:'not-png-dataurl'}); }
      const b64 = d.dataURL.slice(prefix.length);
      const start = index * chars;
      if (!(start >= 0) || start >= b64.length) { return reply({ok:false, reason:'index-past-end'}); }
      return reply({ok:true, index: index, total: b64.length, data: b64.slice(start, start + chars)});
    }
    return reply({ok:false, reason:'unknown-op'});
    """#

    static func descriptorArguments(nonce: String) -> [String: Any] {
        ["op": "descriptor", "source": "", "index": 0, "chars": 0, "nonce": nonce]
    }

    static func chunkArguments(source: StagedExportDescriptor.Source, index: Int, nonce: String) -> [String: Any] {
        ["op": "chunk", "source": source.rawValue, "index": index,
         "chars": StagedExportContract.chunkBase64Chars, "nonce": nonce]
    }
}

// MARK: - Byte sink (streamed staging; no whole-blob UI-actor buffer)

/// Append-only sink for the pulled chunks. The production sink streams every
/// decoded chunk straight to the exclusive part file and keeps only bounded
/// head/tail windows plus a running digest, so the full raster never lives as
/// one buffer on the main actor. Host tests inject an equivalent sink; the
/// validation order (caps before decode) lives in the contract above.
protocol StagedExportByteSinking: AnyObject {
    var bytesAppended: Int { get }
    /// First ≤64 bytes seen (PNG header window).
    var headBytes: Data { get }
    /// Last ≤16 bytes seen (IEND window).
    var tailBytes: Data { get }
    func append(_ data: Data) throws
    /// Closes the sink and returns the native-computed SHA-256 hex of every
    /// appended byte. Called exactly once on the success path.
    func finalizeDigest() throws -> String
    /// Best-effort abort: close and remove any staging bytes. Safe to call
    /// after failure, cancellation or fencing; never touches the destination.
    func discard()
}

// MARK: - Receipt (metadata-only tool output)

/// The model-facing receipt of one committed export. Paths are the
/// workspace-relative destination the CALL authorized; digests and dimensions
/// are native-measured from the committed bytes. No page text beyond the
/// validated staged name, no absolute host paths.
struct StagedExportReceipt: Codable, Sendable, Equatable {
    var state: String
    var exportID: String
    var path: String
    var stagedName: String
    var source: String
    var bytes: Int
    var sha256: String
    var declaredSHA256Matched: Bool
    var width: Int
    var height: Int
    var documentGeneration: Int
    var endpoint: String

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

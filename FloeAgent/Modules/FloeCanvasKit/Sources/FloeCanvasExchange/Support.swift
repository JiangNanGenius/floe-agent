// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import FloeCanvasCore

/// Errors thrown by FloeCanvasExchange. Every case carries an actionable,
/// host-presentable message; nothing here logs, crashes or silently drops
/// user content.
public enum CanvasExchangeError: Error, Hashable, Sendable {
    /// Input bytes are not a well-formed document of the requested format,
    /// or required structural invariants (identity, geometry) are violated.
    case invalid(String)
    /// The format cannot represent a requested content class; the caller
    /// should consult the returned issues and keep the native archive.
    case unsupported(String)
    /// The archive manifest references an asset/source that is missing or
    /// whose digest does not match. Recovery authority is the original file.
    case integrity(String)
    /// A bounded resource (entry count, single entry, expansion total,
    /// point count, raster size) would be exceeded.
    case limitExceeded(String)
    /// An injected asset resolver failed or produced inconsistent bytes.
    case assetUnavailable(String)
    /// Underlying I/O failure with a recoverable description.
    case io(String)

    public var isRecoverable: Bool {
        switch self {
        case .invalid, .unsupported, .assetUnavailable: return true
        case .integrity, .limitExceeded, .io: return false
        }
    }
}

/// One conversion observation. Codes are stable, dot-namespaced strings such
/// as `flowGraph.notRepresentable`; `contentClass` names the DTO family the
/// observation refers to (node, connection, region, stroke, pencil, media,
/// pdf, web, editor, source, flowGraph, scene, table, formula, richText,
/// shape, unknownContent, archive, asset).
public struct CanvasExchangeIssue: Codable, Hashable, Sendable {
    public enum Severity: String, Codable, Hashable, Sendable {
        /// Content could not be represented in the target format; it is
        /// retained in the native archive or the import sidecar only.
        case loss
        /// Content was preserved through a fallback projection (for example
        /// rasterized ink or an editable text projection of rich content).
        case preserved
        /// A referenced resource (asset, preview, source) was not available
        /// to the injected resolver at export time.
        case unavailable
        /// Input data was structurally invalid and rejected outright.
        case rejected
    }

    public var code: String
    public var detail: String
    public var contentClass: String
    public var severity: Severity

    public init(_ code: String, _ detail: String, contentClass: String, severity: Severity = .loss) {
        self.code = code
        self.detail = detail
        self.contentClass = contentClass
        self.severity = severity
    }
}

/// Deterministic digest used by the native archive manifest and id mapping.
public enum CanvasDigest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Maps foreign, non-UUID identity strings to stable UUIDs. The same raw id
/// inside the same namespace always maps to the same UUID, so re-importing
/// an edited file keeps identities stable and a round trip can recover the
/// original external id through `CanvasExchangeBundle.externalIDs`.
public enum CanvasExchangeIDs {
    public static func stable(_ namespace: String, _ raw: String) -> UUID {
        if let id = UUID(uuidString: raw) { return id }
        let digest = Array(CanvasDigest.sha256(Data((namespace + ":" + raw).utf8)).utf8)
        // 32 hex chars -> 8-4-4-4-12 uuid shape.
        let hex = Array(String(decoding: digest, as: UTF8.self))
        func group(_ range: Range<Int>) -> String { String(hex[range]) }
        let uuid = group(0..<8) + "-" + group(8..<12) + "-" + group(12..<16)
            + "-" + group(16..<20) + "-" + group(20..<32)
        return UUID(uuidString: String(uuid)) ?? UUID()
    }
}

/// Injected byte channel for canvas assets. The exchange module never reads
/// the filesystem or the network on its own; hosts provide bytes through
/// this protocol (mirrors the Integration `CanvasAssetStore` ownership rule).
public protocol CanvasAssetResolver: Sendable {
    func data(for locator: CanvasAssetLocator) async throws -> Data
}

/// Convenience in-memory resolver for qualification and tests.
public struct CanvasInMemoryAssetResolver: CanvasAssetResolver {
    private let bytes: [UUID: Data]
    public init(_ bytes: [UUID: Data]) { self.bytes = bytes }
    public func data(for locator: CanvasAssetLocator) async throws -> Data {
        guard let data = bytes[locator.id] else {
            throw CanvasExchangeError.assetUnavailable("asset \(locator.id) has no injected bytes")
        }
        return data
    }
}

/// Bounded, checked file read shared by every exchange code path that is
/// explicitly allowed to touch the disk (the trusted-root resolver and the
/// JSON Canvas trusted-root byte resolution). Reads go through a per-call
/// `FileHandle` in bounded chunks — never an unbounded `Data(contentsOf:)`
/// memory map — the opened descriptor is confirmed to be a regular file,
/// and the accumulated bytes can never exceed `maximumBytes` even if the
/// file grows while it is being read. Cancellation is honored between
/// chunks. Callers must have already resolved symlinks and verified root
/// containment.
enum CanvasBoundedFileReader {
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw CanvasExchangeError.io("open \(url.lastPathComponent): \(errno)")
        }
        defer { _ = Darwin.close(fd) }
        var status = Darwin.stat()
        guard Darwin.fstat(fd, &status) == 0 else {
            throw CanvasExchangeError.io("stat \(url.lastPathComponent): \(errno)")
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw CanvasExchangeError.assetUnavailable("\(url.lastPathComponent) is not a regular file")
        }
        let size = Int(status.st_size)
        guard size <= maximumBytes else {
            throw CanvasExchangeError.limitExceeded("file is \(size) bytes; the bound is \(maximumBytes)")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        data.reserveCapacity(size)
        while data.count < size {
            try Task.checkCancellation()
            let wanted = min(size - data.count, 1_048_576)
            guard let chunk = try handle.read(upToCount: wanted), !chunk.isEmpty else { break }
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw CanvasExchangeError.limitExceeded("file grew past the byte bound while reading")
            }
        }
        guard data.count == size else {
            throw CanvasExchangeError.io("short read on \(url.lastPathComponent) (\(data.count) of \(size) bytes)")
        }
        return data
    }
}

/// File-backed resolver confined to an explicit trusted root. Path
/// components are normalized, `..` segments and absolute paths are refused,
/// symlinks are resolved and must remain inside the root, the target must be
/// a regular file, and bytes are read in bounded chunks. This is the only
/// exchange code path that may touch the disk on its own, and only when a
/// host explicitly constructs it.
public struct CanvasTrustedFileAssetResolver: CanvasAssetResolver {
    public let root: URL
    public let maximumBytes: Int

    public init(root: URL, maximumBytes: Int = 64 * 1_024 * 1_024) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.maximumBytes = maximumBytes
    }

    public func data(for locator: CanvasAssetLocator) async throws -> Data {
        try Task.checkCancellation()
        guard let relative = locator.relativePath, !relative.isEmpty else {
            throw CanvasExchangeError.assetUnavailable("asset \(locator.id) has no relative path")
        }
        let resolved = URL(fileURLWithPath: relative, relativeTo: root)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else {
            throw CanvasExchangeError.assetUnavailable("asset \(locator.id) resolves outside the trusted root")
        }
        do {
            return try CanvasBoundedFileReader.read(resolved, maximumBytes: maximumBytes)
        } catch let error as CanvasExchangeError {
            throw error
        } catch {
            throw CanvasExchangeError.io("asset \(locator.id): \(error)")
        }
    }
}

/// A retained opaque original: the exact bytes of an imported foreign file
/// (legacy raw bytes, JSON Canvas / Excalidraw / draw.io originals) so the
/// native archive can recover anything the editable projection lost.
public struct CanvasOriginalSource: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case legacyRawBytes
        case jsonCanvasOriginal
        case excalidrawOriginal
        case drawioOriginal
        case externalReference
    }

    public var id: UUID
    public var kind: Kind
    /// Suggested filename for recovery (not a host path).
    public var suggestedName: String
    public var byteCount: Int
    public var sha256: String
    /// Optional hint of which node(s) came from this source.
    public var nodeIDs: [UUID]

    public init(id: UUID = UUID(), kind: Kind, suggestedName: String, byteCount: Int, sha256: String, nodeIDs: [UUID] = []) {
        self.id = id
        self.kind = kind
        self.suggestedName = suggestedName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.nodeIDs = nodeIDs
    }
}

/// Bundle returned by every import operation.
public struct CanvasExchangeBundle: Sendable {
    public var snapshot: CanvasSnapshot
    /// Resolved asset bytes keyed by asset id (only populated when the
    /// importer was allowed and able to resolve bytes).
    public var assets: [UUID: Data]
    /// Exact original file bytes retained for recovery.
    public var originalSources: [CanvasOriginalSource]
    /// node/element uuid -> external id string in the source file.
    public var externalIDs: [UUID: String]
    /// Per-node original foreign element tree (unknown fields, exact number
    /// literals). Re-export re-injects these verbatim where supported.
    public var originalNodes: [UUID: JSONValue]
    /// Per-edge original foreign element tree, keyed by connection id.
    public var originalEdges: [UUID: JSONValue]
    /// Whole original foreign document (for top-level unknown keys such as
    /// JSON Canvas `fixtureExtension` or Excalidraw `appState`).
    public var originalDocument: JSONValue?
    /// Verified reusable flow template definitions recovered from a native
    /// archive (data only — recovery never grants execution authority).
    public var flowTemplates: [CanvasNativeArchive.FlowTemplateDefinition]
    public var issues: [CanvasExchangeIssue]

    public init(
        snapshot: CanvasSnapshot,
        assets: [UUID: Data] = [:],
        originalSources: [CanvasOriginalSource] = [],
        externalIDs: [UUID: String] = [:],
        originalNodes: [UUID: JSONValue] = [:],
        originalEdges: [UUID: JSONValue] = [:],
        originalDocument: JSONValue? = nil,
        flowTemplates: [CanvasNativeArchive.FlowTemplateDefinition] = [],
        issues: [CanvasExchangeIssue] = []
    ) {
        self.snapshot = snapshot
        self.assets = assets
        self.originalSources = originalSources
        self.externalIDs = externalIDs
        self.originalNodes = originalNodes
        self.originalEdges = originalEdges
        self.originalDocument = originalDocument
        self.flowTemplates = flowTemplates
        self.issues = issues
    }
}

/// One produced file (single-page formats may produce several when a page
/// package is requested instead of silent loss).
public struct CanvasExchangeFile: Sendable, Hashable {
    public var name: String
    public var data: Data
    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// Safe output file names derived from arbitrary user text (canvas/page
/// titles): path separators, drive colons, NUL and control characters
/// collapse to "-"; dots are dropped entirely (a remaining interior ".."
/// would still read as a parent-directory reference, and leading dots would
/// hide the file); surrounding whitespace is trimmed; an empty result falls
/// back to a generic stem. `CanvasExchange.save` additionally refuses
/// anything that is not a plain basename — these two layers keep hostile
/// titles from ever producing paths outside the chosen directory.
public enum CanvasExchangeFilename {
    public static func sanitized(_ title: String, extension ext: String, fallback: String = "canvas") -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            if scalar == "." { continue }
            if scalar == "/" || scalar == "\\" || scalar == ":" || scalar == "\0"
                || CharacterSet.controlCharacters.contains(scalar) {
                scalars.append("-")
            } else {
                scalars.append(scalar)
            }
        }
        var name = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: " "))
        if name.isEmpty { name = fallback }
        return "\(name).\(ext)"
    }
}

/// Result of an export operation.
public struct CanvasExchangeOutput: Sendable {
    public var files: [CanvasExchangeFile]
    public var issues: [CanvasExchangeIssue]
    public init(files: [CanvasExchangeFile], issues: [CanvasExchangeIssue] = []) {
        self.files = files
        self.issues = issues
    }

    /// The primary file (first), for single-file convenience.
    public var primary: CanvasExchangeFile { files[0] }
}

// MARK: - Shared bounds

/// Resource ceilings applied by every codec in this module. They mirror the
/// DiagramKit exchange ceilings so both kits stay equally strict.
public enum CanvasExchangeLimits {
    public static let maxInputBytes = 128 * 1_024 * 1_024
    public static let maxArchiveEntries = 20_000
    public static let maxSingleEntryBytes = 64 * 1_024 * 1_024
    public static let maxExpandedTotalBytes = 512 * 1_024 * 1_024
    public static let maxForeignElements = 100_000
    public static let maxPointsPerStroke = 100_000
    public static let maxRasterPixels = 24_000_000
    public static let maxRasterDimension = 8_192
    public static let coordinateMagnitude = 100_000_000.0

    public static func validateInputSize(_ data: Data) throws {
        guard data.count <= maxInputBytes else {
            throw CanvasExchangeError.limitExceeded("input is \(data.count) bytes; the limit is \(maxInputBytes)")
        }
    }
}

// MARK: - Geometry / number helpers

public enum CanvasExchangeGeometry {
    /// JSON-compatible, deterministic number spelling (POSIX locale, up to
    /// 6 fractional digits, trailing zeros trimmed, non-finite clamped to 0
    /// with the caller expected to have issued an issue already).
    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let snapped = (value * 1_000_000).rounded() / 1_000_000
        if snapped == snapped.rounded(), abs(snapped) < 1e15 {
            return String(Int64(snapped))
        }
        var text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), snapped)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    public static func isUsableCoordinate(_ value: Double) -> Bool {
        value.isFinite && abs(value) < CanvasExchangeLimits.coordinateMagnitude
    }

    public static func isUsableLength(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value < CanvasExchangeLimits.coordinateMagnitude
    }

    /// Axis-aligned bounding box of a possibly-rotated frame.
    public static func rotatedBounds(_ frame: CanvasGeometry.Frame, rotationDegrees: Double) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let angle = rotationDegrees * .pi / 180
        let cosA = cos(angle), sinA = sin(angle)
        let halfW = frame.size.width / 2, halfH = frame.size.height / 2
        let corners = [
            (-halfW, -halfH), (halfW, -halfH), (halfW, halfH), (-halfW, halfH)
        ].map { (dx, dy) -> (Double, Double) in
            (frame.center.x + dx * cosA - dy * sinA,
             frame.center.y + dx * sinA + dy * cosA)
        }
        let xs = corners.map(\.0), ys = corners.map(\.1)
        return (xs.min()!, ys.min()!, xs.max()!, ys.max()!)
    }
}

// MARK: - JSON conveniences

public enum CanvasExchangeJSON {
    /// Keys of the unambiguous native date tag. Dates encode as a marked
    /// JSON object carrying BOTH the exact IEEE-754 bit pattern of the
    /// reference-date (2001-01-01T00:00:00Z) seconds — the canonical value —
    /// and a human-readable decimal rendering of the same bits.
    ///
    /// Raw reference seconds are stored on purpose: shifting a date by the
    /// 978307200-second 1970 offset before encoding loses sub-microsecond
    /// precision (Double has ~15-16 significant decimal digits, and the
    /// offset already spends 9 of them), so `Date(timeIntervalSinceReferenceDate:)`
    /// values did NOT round-trip through the earlier epoch-Double spelling.
    /// The bit-pattern key restores any finite reference-date second exactly.
    public static let dateTagKey = "floeDate"
    public static let dateBitsTagKey = "floeDateBits"

    /// Deterministic encoder used for archive documents and digests.
    /// Dates encode as the tagged native form above — bit-identical through
    /// a round trip. The decoder accepts the tagged form AND the two legacy
    /// spellings (epoch-seconds JSON numbers from the previous prototype,
    /// and older ISO8601 strings), so existing archives keep decoding.
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let seconds = date.timeIntervalSinceReferenceDate
            let tagged: [String: String] = [
                dateTagKey: String(describing: seconds),
                dateBitsTagKey: String(seconds.bitPattern, radix: 16),
            ]
            try container.encode(tagged)
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            // 1) Native tagged form (canonical, exact).
            if let tagged = try? container.decode([String: String].self) {
                if let hex = tagged[dateBitsTagKey], let bits = UInt64(hex, radix: 16) {
                    return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
                }
                if let text = tagged[dateTagKey], let seconds = Double(text) {
                    return Date(timeIntervalSinceReferenceDate: seconds)
                }
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "unrecognized tagged date \(tagged)")
            }
            // 2) Previous prototype: epoch-seconds JSON number.
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            // 3) Older prototype: ISO8601 strings (fractional or whole-second).
            let text = try container.decode(String.self)
            if let date = CanvasExchangeJSON.iso8601Fractional.date(from: text)
                ?? CanvasExchangeJSON.iso8601WholeSecond.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unparseable date \(text)")
        }
        return decoder
    }

    private static let iso8601Fractional: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    private static let iso8601WholeSecond: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()

    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        do { return try encoder(pretty: pretty).encode(value) }
        catch { throw CanvasExchangeError.io("encode \(T.self): \(error)") }
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder().decode(type, from: data) }
        catch { throw CanvasExchangeError.invalid("decode \(T.self): \(error)") }
    }

    public static func string(_ value: JSONValue) -> String? { value.stringValue }

    public static func number(_ value: JSONValue?) -> Double? {
        guard let literal = value?.numberLiteral else { return nil }
        return Double(literal)
    }

    /// Strict finite number from a foreign document; returns nil (so the
    /// caller can issue an issue) for NaN/Infinity/overflow spellings.
    public static func finiteNumber(_ value: JSONValue?) -> Double? {
        guard let literal = value?.numberLiteral, let number = Double(literal),
              number.isFinite, abs(number) < CanvasExchangeLimits.coordinateMagnitude else { return nil }
        return number
    }

    /// Bool accepting both JSON booleans and the common 0/1 spellings.
    public static func bool(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let flag): return flag
        case .number(let literal): return literal == "1" ? true : (literal == "0" ? false : nil)
        default: return nil
        }
    }
}

// MARK: - Style metadata keys

/// Node style keys shared with the frozen Core contract. The Core module
/// exposes the same spellings through `CanvasVisualMetadataKeys`; these
/// literals are duplicated here (values, not symbols) so this module stays
/// source-compatible even before that symbol lands, and a drift would be a
/// one-line fix in `CoreCompatibility.swift` only.
public enum CanvasExchangeStyleKey {
    public static let fillColor = CanvasVisualMetadataKeys.fillColor
    public static let strokeColor = CanvasVisualMetadataKeys.strokeColor
    public static let strokeWidth = CanvasVisualMetadataKeys.strokeWidth
    public static let textColor = CanvasVisualMetadataKeys.textColor
    /// Namespaced key under which exporters may record the foreign id this
    /// node had at import time (lossless re-export aid).
    public static let externalID = "floe.externalID"
}

/// Metadata keys binding a visual card node to its flow graph element
/// (root decision 2026-11-03: canvas node id and flow node id stay
/// independent; the mapping lives in node metadata and is saved completely
/// by the native archive). Open formats may render the visual projection
/// but never claim executable flow semantics.
public enum CanvasExchangeFlowKey {
    public static let graphID = "floe.flow.graphID"
    public static let nodeID = "floe.flow.nodeID"
}

// MARK: - Export scope

public enum CanvasCollapsedRegionPresentation: String, Codable, Sendable {
    /// Draw a collapsed chip with the region name.
    case chip
    /// Draw the full region contents regardless of `isCollapsed`.
    case expandedContents
}

public enum CanvasExportScope: Sendable, Hashable {
    /// Everything on each exported page.
    case wholePage
    /// One region and the nodes it contains.
    case region(UUID)
    /// One scene's focused nodes/regions.
    case scene(UUID)
    /// An explicit node set.
    case selection(Set<UUID>)
}

public enum CanvasRenderAppearance: String, Codable, Sendable {
    case light, dark
}

/// Single-page foreign formats (JSON Canvas, Excalidraw) cannot hold a
/// multipage canvas. The strategy is always explicit — content is never
/// silently dropped.
public enum CanvasMultiPageStrategy: Sendable, Hashable {
    /// Export exactly one page (the selected, or `pageID` when provided)
    /// and report every skipped page in the issues.
    case selectedPageOnly
    /// Produce one file per page instead of losing any page.
    case oneFilePerPage
}

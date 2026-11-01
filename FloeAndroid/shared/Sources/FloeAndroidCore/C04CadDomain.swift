// SPDX-License-Identifier: MPL-2.0
//
// C04A — offline read-only CAD / general-3D viewer domain.
//
// This file is the SWIFT authority for the viewer CONTRACT only. Pixel
// production stays in the App-owned WebView (the pinned DXF/OCCT/mesh
// readers); this domain owns:
//
//   * the closed format -> family/reader routing (verified from the pinned
//     bundle sources, not a marketing extension list);
//   * owner/path/resource containment and byte/digest validation for one
//     viewer session;
//   * the rendered-state gate (a loaded WASM/worker is not "ready" until the
//     host reports an actual rendered frame);
//   * a bounded PNG capture receipt whose header the host parsed from the
//     actual canvas bytes;
//   * the C04C `.floecad` package contract (mesh v1/v2, transforms, images,
//     resource digests, source units).
//
// No file bytes, image bytes, HTML, model path or credential enter the
// bridge. The App stages owned source bytes through the existing G04 native
// workspace egress and serves them to the local-only WebView.
//
// Source-only: this file is authored against the current FloeAndroidCore
// APIs and is compiled by Main's unified qualification, not by this lane.
import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

// MARK: - Closed wire identity

public enum C04CadWire {
    public static let version = 8
    public static let schema = "floe.cad/8"
    /// The frozen `floe_bridge_exchange` C string bound is 65,536 bytes.
    /// C04 requests are structured metadata only; no asset bytes are sent.
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 65_536
    public static let operations: [String] = [
        "handshake",
        "c04.session.begin",
        "c04.session.readiness",
        "c04.session.capture",
        "c04.session.end",
        "c04.extension.validate",
        "c04.cancelAll",
    ]
}

// MARK: - Errors

public struct C04CadError: Error, Equatable, Sendable {
    public let code: String
    public let reason: String

    public init(_ code: String, _ reason: String) {
        self.code = code
        self.reason = reason
    }

    public static let unsupportedVersion = C04CadError("unsupportedVersion", "version")
    public static let requestTooLarge = C04CadError("requestTooLarge", "requestBytes")
    public static let responseTooLarge = C04CadError("responseTooLarge", "responseBytes")
    public static let unsupportedOperation = C04CadError("unsupportedOperation", "operation")
    public static let invalidRequest = C04CadError("invalidRequest", "request")
    public static let invalidOwner = C04CadError("invalidOwner", "owner")
    public static let invalidPath = C04CadError("invalidPath", "path")
    public static let unknownFormat = C04CadError("unknownFormat", "format")
    public static let formatMismatch = C04CadError("formatMismatch", "format")
    public static let sourceTooLarge = C04CadError("sourceTooLarge", "sourceBytes")
    public static let resourceLimit = C04CadError("resourceLimit", "resourceCount")
    public static let resourceTooLarge = C04CadError("resourceTooLarge", "resourceBytes")
    public static let resourceOutsideScope = C04CadError("resourceOutsideScope", "resourceScope")
    public static let resourceDuplicate = C04CadError("resourceDuplicate", "resourcePath")
    public static let resourceExtension = C04CadError("resourceExtension", "resourceType")
    public static let invalidDigest = C04CadError("invalidDigest", "sha256")
    public static let invalidMediaType = C04CadError("invalidMediaType", "mediaType")
    public static let sessionLimit = C04CadError("sessionLimit", "sessionCount")
    public static let staleSession = C04CadError("staleSession", "session")
    public static let notReady = C04CadError("notReady", "readiness")
    public static let staleFrame = C04CadError("staleFrame", "frameSequence")
    public static let invalidFacts = C04CadError("invalidFacts", "facts")
    public static let invalidCapture = C04CadError("invalidCapture", "capture")
    public static let captureLimit = C04CadError("captureLimit", "captureCount")
    public static let invalidPackage = C04CadError("invalidPackage", "package")
    public static let packageLimit = C04CadError("packageLimit", "packageLimits")
    public static let unsupportedPackage = C04CadError("unsupportedPackage", "packageSchema")
}

// MARK: - Format routing

public enum C04CadFamily: String, Sendable, Equatable {
    case vector2D = "vector2d"
    case surface3D = "surface3d"
    case mesh3D = "mesh3d"
}

public enum C04CadUnits: String, CaseIterable, Sendable, Equatable {
    case millimeters = "mm"
    case centimeters = "cm"
    case meters = "m"
    case inches = "in"
    case feet = "ft"
    case yards = "yd"
    case unknown

    /// DXF `$INSUNITS` is the source drawing's declared unit. Unknown codes
    /// stay `.unknown`; drawing units are never assumed to be millimetres.
    public static func fromDXFCode(_ code: Int) -> C04CadUnits {
        switch code {
        case 1: return .inches
        case 2: return .feet
        case 4: return .millimeters
        case 5: return .centimeters
        case 6: return .meters
        case 10: return .yards
        default: return .unknown
        }
    }
}

public enum C04CadFormat: String, CaseIterable, Sendable, Equatable {
    case dxf
    case dwg
    case step
    case stp
    case iges
    case igs
    case brep
    case glb
    case gltf
    case obj
    case stl
    case threeMF = "3mf"
    /// Native FloeCAD DIRECTORY package. Its byte reader is the App C04C
    /// adapter; the pinned viewer renders the derived GLB plus bounded
    /// on-device B-Rep tessellation, never the package bytes directly.
    case floecad

    public var family: C04CadFamily {
        switch self {
        case .dxf, .dwg: return .vector2D
        case .step, .stp, .iges, .igs, .brep: return .surface3D
        case .glb, .gltf, .obj, .stl, .threeMF, .floecad: return .mesh3D
        }
    }

    /// Exact pinned reader/converter names used by the App viewer. These are
    /// provenance labels, not file-system paths.
    public var reader: String {
        switch self {
        case .dxf: return "dxf-viewer/1.0.48"
        case .dwg: return "floe-cad-engine/acadrust-0.5.5"
        case .step, .stp, .iges, .igs, .brep:
            return "occt-import-js/0.0.23"
        case .glb, .gltf, .obj, .stl, .threeMF:
            return "online-3d-viewer/0.18.0"
        case .floecad:
            return "floecad-package/1"
        }
    }

    /// Hard source caps. DWG and the OCCT worker have 10 MiB in-worker
    /// bounds; DXF and the mesh readers use the App's larger bounded import
    /// but stay well below the shared 256 MiB egress cap.
    public var sourceByteLimit: Int {
        switch self {
        case .dwg, .step, .stp, .iges, .igs, .brep: return 10 * 1024 * 1024
        case .dxf, .glb, .gltf, .obj, .stl, .threeMF: return 64 * 1024 * 1024
        case .floecad: return C04FloecadPackageLimits.maximumPackageBytes
        }
    }

    public var sourceExtensions: Set<String> {
        switch self {
        case .threeMF: return ["3mf"]
        default: return [rawValue]
        }
    }

    public var resourceExtensions: Set<String> {
        if self == .floecad {
            return C04FloecadPackageLimits.resourceExtensions
        }
        switch family {
        case .mesh3D:
            return ["bin", "mtl", "png", "jpg", "jpeg", "webp"]
        case .vector2D, .surface3D:
            return []
        }
    }

    /// Pure file extension routing. `.floecad` is a DIRECTORY package and is
    /// accepted through `isNativePackagePath` by the C04C session path; the
    /// ordinary single-file route deliberately stays nil for it (the C04A
    /// routing contract remains unchanged).
    public static func route(relativePath: String) -> C04CadFormat? {
        let name = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        let ext = name.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init)?.lowercased() ?? ""
        if ext == C04FloecadPackageLimits.packageExtension { return nil }
        return C04CadFormat(rawValue: ext)
    }

    public static func isNativePackagePath(_ relativePath: String) -> Bool {
        let name = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        return name.lowercased().hasSuffix("." + C04FloecadPackageLimits.packageExtension)
    }
}

public enum C04CadLimits {
    public static let maximumResources = 32
    public static let maximumResourceBytes = 64 * 1024 * 1024
    public static let maximumTotalResourceBytes = 256 * 1024 * 1024
    public static let maximumPathBytes = 4_096
    public static let maximumCaptureBytes = 32 * 1024 * 1024
    public static let maximumCaptureEdge = 8_192
    public static let minimumCaptureEdge = 64
    public static let maximumCapturesPerSession = 8
    public static let sessionTTL: TimeInterval = 15 * 60
    public static let maximumSessions = 4
    public static let maximumPackageBytes = 512 * 1024 * 1024
    public static let maximumPackageResources = 128
    public static let maximumPackageMeshes = 256
    public static let maximumPackageImages = 64
    public static let maximumPackageVertices = 20_000_000
    public static let maximumPackageTriangles = 20_000_000
    public static let maximumPackageTotalTriangles = 40_000_000
    public static let maximumMeshEdge = 16_384
}

// MARK: - Path / owner / digest primitives

public enum C04CadPath {
    /// Canonical workspace-relative path. Absolute paths, drive letters,
    /// URI schemes, backslashes, control bytes, empty components and `.`/
    /// `..` are refused before any resource can be staged or served.
    public static func normalize(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= C04CadLimits.maximumPathBytes else { return nil }
        guard !raw.hasPrefix("/"), !raw.hasPrefix("~") else { return nil }
        guard !raw.contains("\\"), !raw.contains(":") else { return nil }
        guard !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return nil
        }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        var output: [String] = []
        for part in parts {
            guard !part.isEmpty, part != ".", part != ".." else { return nil }
            guard part.utf8.count <= 255 else { return nil }
            output.append(part)
        }
        return output.joined(separator: "/")
    }

    public static func directory(of path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return "" }
        return String(path[..<index])
    }

    public static func basename(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// String-level canonical containment. The App never converts these
    /// values into host paths; the native workspace egress remains the only
    /// file authority. A sidecar must stay in the main file's directory
    /// subtree (the authorized resource scope).
    public static func contained(_ child: String, in directory: String) -> Bool {
        guard normalize(child) != nil else { return false }
        if directory.isEmpty { return true }
        guard let parent = normalize(directory) else { return false }
        return child == parent || child.hasPrefix(parent + "/")
    }

    public static func isIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return value.allSatisfy { allowed.contains($0) }
    }
}

public enum C04CadHex {
    public static func isSHA256(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        let allowed = Set("0123456789abcdefABCDEF")
        return value.allSatisfy { allowed.contains($0) }
    }

    public static func bytes(_ value: String) -> [UInt8]? {
        guard value.count % 2 == 0 else { return nil }
        let scalars = Array(value.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(scalars.count / 2)
        var index = 0
        while index < scalars.count {
            guard let high = nibble(scalars[index]),
                  let low = nibble(scalars[index + 1]) else { return nil }
            output.append((high << 4) | low)
            index += 2
        }
        return output
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}

public struct C04CadOwner: Sendable, Equatable {
    public let taskID: UUID
    public let workspaceID: UUID
    public let nativeEpoch: UInt64
    public let hostGeneration: UInt64

    public init(taskID: UUID, workspaceID: UUID,
                nativeEpoch: UInt64, hostGeneration: UInt64) throws {
        guard nativeEpoch > 0 else { throw C04CadError.invalidOwner }
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.nativeEpoch = nativeEpoch
        self.hostGeneration = hostGeneration
    }

    public static func parse(_ value: Any?) throws -> C04CadOwner {
        guard let object = value as? [String: Any],
              let task = c04String(object["taskID"], maxBytes: 64),
              let workspace = c04String(object["workspaceID"], maxBytes: 64),
              let taskID = UUID(uuidString: task),
              let workspaceID = UUID(uuidString: workspace),
              let epoch = c04UInt64(object["nativeEpoch"]),
              let generation = c04UInt64(object["hostGeneration"]) else {
            throw C04CadError.invalidOwner
        }
        return try C04CadOwner(taskID: taskID, workspaceID: workspaceID,
                               nativeEpoch: epoch, hostGeneration: generation)
    }

    public var wire: [String: Any] {
        [
            "taskID": taskID.uuidString,
            "workspaceID": workspaceID.uuidString,
            "nativeEpoch": nativeEpoch,
            "hostGeneration": hostGeneration,
        ]
    }
}

// MARK: - Source resources

public struct C04CadResourceDescriptor: Sendable, Equatable {
    public let relativePath: String
    public let byteCount: Int
    public let sha256: String
    public let mediaType: String

    public init(relativePath: String, byteCount: Int, sha256: String,
                mediaType: String,
                maximumBytes: Int = C04CadLimits.maximumResourceBytes) throws {
        guard let normalized = C04CadPath.normalize(relativePath) else {
            throw C04CadError.invalidPath
        }
        guard byteCount > 0, byteCount <= maximumBytes else {
            throw C04CadError.resourceTooLarge
        }
        guard C04CadHex.isSHA256(sha256) else { throw C04CadError.invalidDigest }
        guard mediaType.utf8.count in 1...128,
              !mediaType.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              mediaType.contains("/") else {
            throw C04CadError.invalidMediaType
        }
        self.relativePath = normalized
        self.byteCount = byteCount
        self.sha256 = sha256.lowercased()
        self.mediaType = mediaType
    }

    public static func parse(_ value: Any?,
                             maximumBytes: Int = C04CadLimits.maximumResourceBytes) throws
        -> C04CadResourceDescriptor {
        guard let object = value as? [String: Any],
              let path = c04String(object["relativePath"], maxBytes: C04CadLimits.maximumPathBytes),
              let bytes = c04Int(object["byteCount"]),
              let digest = c04String(object["sha256"], maxBytes: 64),
              let mediaType = c04String(object["mediaType"], maxBytes: 128) else {
            throw C04CadError.invalidRequest
        }
        return try C04CadResourceDescriptor(relativePath: path, byteCount: bytes,
                                            sha256: digest, mediaType: mediaType,
                                            maximumBytes: maximumBytes)
    }
}

public struct C04CadResourceGrant: Sendable, Equatable {
    public let id: UUID
    public let relativePath: String
    public let byteCount: Int
    public let sha256: String
    public let mediaType: String

    public var wire: [String: Any] {
        [
            "resourceID": id.uuidString,
            "relativePath": relativePath,
            "byteCount": byteCount,
            "sha256": sha256,
            "mediaType": mediaType,
        ]
    }
}

// MARK: - Scene facts and captures

public struct C04CadBounds: Sendable, Equatable {
    public let minimum: [Double]?
    public let maximum: [Double]?
    public let center: [Double]?
    public let radius: Double?

    public init(minimum: [Double]?, maximum: [Double]?,
                center: [Double]?, radius: Double?) throws {
        func valid(_ values: [Double]?) -> Bool {
            guard let values else { return true }
            return values.count == 3 && values.allSatisfy { $0.isFinite && abs($0) <= 1e12 }
        }
        guard valid(minimum), valid(maximum), valid(center) else {
            throw C04CadError.invalidFacts
        }
        guard (minimum == nil) == (maximum == nil) else {
            throw C04CadError.invalidFacts
        }
        if let minimum, let maximum {
            guard zip(minimum, maximum).allSatisfy({ $0 <= $1 }) else {
                throw C04CadError.invalidFacts
            }
        }
        guard (center == nil) == (radius == nil) else {
            throw C04CadError.invalidFacts
        }
        if let radius, !(radius.isFinite && radius >= 0 && radius <= 1e12) {
            throw C04CadError.invalidFacts
        }
        guard minimum != nil || center != nil else { throw C04CadError.invalidFacts }
        self.minimum = minimum
        self.maximum = maximum
        self.center = center
        self.radius = radius
    }

    public static func parse(_ value: Any?) throws -> C04CadBounds {
        guard let object = value as? [String: Any] else { throw C04CadError.invalidFacts }
        func vector(_ key: String) throws -> [Double]? {
            guard let raw = object[key] else { return nil }
            guard let array = raw as? [Any], array.count == 3 else {
                throw C04CadError.invalidFacts
            }
            let values = try array.map { item -> Double in
                guard let number = c04Double(item), number.isFinite,
                      abs(number) <= 1e12 else { throw C04CadError.invalidFacts }
                return number
            }
            return values
        }
        let radius = c04Double(object["radius"])
        if object["radius"] != nil && radius == nil { throw C04CadError.invalidFacts }
        return try C04CadBounds(minimum: try vector("min"),
                                maximum: try vector("max"),
                                center: try vector("center"),
                                radius: radius)
    }

    public var wire: [String: Any] {
        var value: [String: Any] = [:]
        if let minimum { value["min"] = minimum }
        if let maximum { value["max"] = maximum }
        if let center { value["center"] = center }
        if let radius { value["radius"] = radius }
        return value
    }
}

public struct C04CadSceneFacts: Sendable, Equatable {
    public let format: C04CadFormat
    public let sourceUnits: C04CadUnits
    public let displayUnits: C04CadUnits
    public let bounds: C04CadBounds
    public let entityCount: Int?
    public let meshCount: Int
    public let triangleCount: Int
    public let vertexCount: Int
    public let missingResourceCount: Int
    public let frameSequence: Int
    public let limitations: String

    public init(format: C04CadFormat, sourceUnits: C04CadUnits,
                displayUnits: C04CadUnits, bounds: C04CadBounds,
                entityCount: Int?, meshCount: Int, triangleCount: Int,
                vertexCount: Int, missingResourceCount: Int,
                frameSequence: Int, limitations: String) throws {
        guard frameSequence >= 1 else { throw C04CadError.staleFrame }
        guard meshCount >= 0, meshCount <= 1_000_000,
              triangleCount >= 0, triangleCount <= 100_000_000,
              vertexCount >= 0, vertexCount <= 100_000_000,
              missingResourceCount >= 0,
              missingResourceCount <= C04FloecadPackageLimits.maximumMissingResources else {
            throw C04CadError.invalidFacts
        }
        if let entityCount, !(0...10_000_000).contains(entityCount) {
            throw C04CadError.invalidFacts
        }
        guard limitations.utf8.count <= 512,
              !limitations.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw C04CadError.invalidFacts
        }
        self.format = format
        self.sourceUnits = sourceUnits
        self.displayUnits = displayUnits
        self.bounds = bounds
        self.entityCount = entityCount
        self.meshCount = meshCount
        self.triangleCount = triangleCount
        self.vertexCount = vertexCount
        self.missingResourceCount = missingResourceCount
        self.frameSequence = frameSequence
        self.limitations = limitations
    }

    public static func parse(_ value: Any?, expected: C04CadFormat) throws -> C04CadSceneFacts {
        guard let object = value as? [String: Any],
              let rendered = c04Bool(object["rendered"]), rendered,
              let formatValue = c04String(object["format"], maxBytes: 16),
              let format = C04CadFormat(rawValue: formatValue), format == expected,
              let unitsValue = c04String(object["sourceUnits"], maxBytes: 16),
              let sourceUnits = C04CadUnits(rawValue: unitsValue),
              let displayValue = c04String(object["displayUnits"], maxBytes: 16),
              let displayUnits = C04CadUnits(rawValue: displayValue),
              let frame = c04Int(object["frameSequence"]),
              let meshCount = c04Int(object["meshCount"]),
              let triangleCount = c04Int(object["triangleCount"]),
              let vertexCount = c04Int(object["vertexCount"]),
              let missing = c04Int(object["missingResourceCount"]),
              let limitations = c04String(object["limitations"], maxBytes: 512) else {
            throw C04CadError.invalidFacts
        }
        let entity = c04Int(object["entityCount"])
        if object["entityCount"] != nil && entity == nil { throw C04CadError.invalidFacts }
        return try C04CadSceneFacts(
            format: format,
            sourceUnits: sourceUnits,
            displayUnits: displayUnits,
            bounds: try C04CadBounds.parse(object["bounds"]),
            entityCount: entity,
            meshCount: meshCount,
            triangleCount: triangleCount,
            vertexCount: vertexCount,
            missingResourceCount: missing,
            frameSequence: frame,
            limitations: limitations)
    }

    public var wire: [String: Any] {
        var value: [String: Any] = [
            "format": format.rawValue,
            "sourceUnits": sourceUnits.rawValue,
            "displayUnits": displayUnits.rawValue,
            "bounds": bounds.wire,
            "meshCount": meshCount,
            "triangleCount": triangleCount,
            "vertexCount": vertexCount,
            "missingResourceCount": missingResourceCount,
            "frameSequence": frameSequence,
            "limitations": limitations,
        ]
        if let entityCount { value["entityCount"] = entityCount }
        return value
    }
}

public struct C04CadCaptureReceipt: Sendable, Equatable {
    public let receiptID: UUID
    public let sessionID: UUID
    public let format: C04CadFormat
    public let relativePath: String
    public let pngSHA256: String
    public let byteCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frameSequence: Int
    public let capturedAt: Date

    public var wire: [String: Any] {
        [
            "receiptID": receiptID.uuidString,
            "sessionID": sessionID.uuidString,
            "format": format.rawValue,
            "relativePath": relativePath,
            "pngSHA256": pngSHA256,
            "byteCount": byteCount,
            "pixelWidth": pixelWidth,
            "pixelHeight": pixelHeight,
            "frameSequence": frameSequence,
            "capturedAt": ISO8601DateFormatter().string(from: capturedAt),
            "attested": true,
        ]
    }
}

// MARK: - Session registry

private final class C04CadSessionRecord: @unchecked Sendable {
    let id: UUID
    let owner: C04CadOwner
    let relativePath: String
    let format: C04CadFormat
    let sourceBytes: Int
    let grants: [C04CadResourceGrant]
    var lastUsedAt: Date
    var facts: C04CadSceneFacts?
    var receipts: [C04CadCaptureReceipt] = []

    init(id: UUID, owner: C04CadOwner, relativePath: String,
         format: C04CadFormat, sourceBytes: Int,
         grants: [C04CadResourceGrant], createdAt: Date) {
        self.id = id
        self.owner = owner
        self.relativePath = relativePath
        self.format = format
        self.sourceBytes = sourceBytes
        self.grants = grants
        self.lastUsedAt = createdAt
    }
}

public final class C04CadSessionRegistry: @unchecked Sendable {
    public static let shared = C04CadSessionRegistry()

    private let lock = NSLock()
    private var records: [UUID: C04CadSessionRecord] = [:]
    private let now: @Sendable () -> Date
    private let maximumSessions: Int

    public init(now: @escaping @Sendable () -> Date = { Date() },
                maximumSessions: Int = C04CadLimits.maximumSessions) {
        self.now = now
        self.maximumSessions = max(1, maximumSessions)
    }

    public var sessionCount: Int {
        lock.lock(); defer { lock.unlock() }
        purgeExpiredLocked()
        return records.count
    }

    /// Starts one viewer session after the host has staged the source and
    /// every authorized sidecar. Returns opaque resource grants; the host
    /// uses them as local-only WebView resource ids.
    public func begin(owner: C04CadOwner, relativePath: String,
                      format: C04CadFormat, sourceBytes: Int,
                      resources: [C04CadResourceDescriptor]) throws
        -> (sessionID: UUID, grants: [C04CadResourceGrant]) {
        guard let path = C04CadPath.normalize(relativePath),
              (C04CadFormat.route(relativePath: path) == format ||
                (format == .floecad && C04CadFormat.isNativePackagePath(path))) else {
            throw C04CadError.formatMismatch
        }
        guard sourceBytes > 0, sourceBytes <= format.sourceByteLimit else {
            throw C04CadError.sourceTooLarge
        }
        let maximumResources = format == .floecad
            ? C04FloecadPackageLimits.maximumSessionResources
            : C04CadLimits.maximumResources
        guard resources.count <= maximumResources else {
            throw C04CadError.resourceLimit
        }
        if format.family != .mesh3D && !resources.isEmpty {
            throw C04CadError.resourceExtension
        }
        let directory = C04CadPath.directory(of: path)
        var seen = Set<String>()
        var total: Int64 = 0
        var grants: [C04CadResourceGrant] = []
        for resource in resources {
            guard C04CadPath.contained(resource.relativePath, in: directory) else {
                throw C04CadError.resourceOutsideScope
            }
            let ext = C04CadPath.basename(of: resource.relativePath)
                .split(separator: ".").last.map(String.init)?.lowercased() ?? ""
            guard format.resourceExtensions.contains(ext) else {
                throw C04CadError.resourceExtension
            }
            guard seen.insert(resource.relativePath).inserted else {
                throw C04CadError.resourceDuplicate
            }
            total += Int64(resource.byteCount)
            let maximumTotal = format == .floecad
                ? C04FloecadPackageLimits.maximumSessionTotalBytes
                : C04CadLimits.maximumTotalResourceBytes
            guard total <= Int64(maximumTotal) else {
                throw C04CadError.resourceLimit
            }
            grants.append(C04CadResourceGrant(
                id: UUID(), relativePath: resource.relativePath,
                byteCount: resource.byteCount, sha256: resource.sha256,
                mediaType: resource.mediaType))
        }
        lock.lock(); defer { lock.unlock() }
        purgeExpiredLocked()
        guard records.count < maximumSessions else { throw C04CadError.sessionLimit }
        let id = UUID()
        records[id] = C04CadSessionRecord(
            id: id, owner: owner, relativePath: path, format: format,
            sourceBytes: sourceBytes, grants: grants, createdAt: now())
        return (id, grants)
    }

    /// Records the host's ACTUAL rendered-frame facts. `rendered` and a
    /// positive frame sequence are required; a loaded reader alone is not
    /// readiness. Re-reporting an older frame is a typed stale refusal.
    @discardableResult
    public func readiness(sessionID: UUID, facts: C04CadSceneFacts) throws -> C04CadSceneFacts {
        lock.lock(); defer { lock.unlock() }
        guard let record = liveRecordLocked(sessionID) else { throw C04CadError.staleSession }
        guard facts.format == record.format else { throw C04CadError.formatMismatch }
        if let prior = record.facts, facts.frameSequence < prior.frameSequence {
            throw C04CadError.staleFrame
        }
        record.facts = facts
        record.lastUsedAt = now()
        return facts
    }

    /// Records a PNG artifact receipt. The host sends only the 33-byte PNG
    /// header and the digest of the actual artifact; the domain checks the
    /// signature/IHDR dimensions and the readiness/frame binding. The App
    /// additionally walks every PNG chunk before writing the artifact.
    public func capture(sessionID: UUID, pngHeaderHex: String,
                        pngSHA256: String, byteCount: Int,
                        pixelWidth: Int, pixelHeight: Int,
                        frameSequence: Int) throws -> C04CadCaptureReceipt {
        guard C04CadHex.isSHA256(pngSHA256) else { throw C04CadError.invalidDigest }
        guard byteCount >= 33, byteCount <= C04CadLimits.maximumCaptureBytes else {
            throw C04CadError.invalidCapture
        }
        guard pixelWidth >= C04CadLimits.minimumCaptureEdge,
              pixelWidth <= C04CadLimits.maximumCaptureEdge,
              pixelHeight >= C04CadLimits.minimumCaptureEdge,
              pixelHeight <= C04CadLimits.maximumCaptureEdge else {
            throw C04CadError.invalidCapture
        }
        guard let header = C04CadHex.bytes(pngHeaderHex), header.count == 33 else {
            throw C04CadError.invalidCapture
        }
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard Array(header[0..<8]) == signature,
              Array(header[12..<16]) == Array("IHDR".utf8) else {
            throw C04CadError.invalidCapture
        }
        let width = Int(header[16]) << 24 | Int(header[17]) << 16 |
            Int(header[18]) << 8 | Int(header[19])
        let height = Int(header[20]) << 24 | Int(header[21]) << 16 |
            Int(header[22]) << 8 | Int(header[23])
        guard width == pixelWidth, height == pixelHeight else {
            throw C04CadError.invalidCapture
        }
        lock.lock(); defer { lock.unlock() }
        guard let record = liveRecordLocked(sessionID) else { throw C04CadError.staleSession }
        guard let facts = record.facts else { throw C04CadError.notReady }
        guard frameSequence >= facts.frameSequence else { throw C04CadError.staleFrame }
        guard record.receipts.count < C04CadLimits.maximumCapturesPerSession else {
            throw C04CadError.captureLimit
        }
        let receipt = C04CadCaptureReceipt(
            receiptID: UUID(), sessionID: sessionID, format: record.format,
            relativePath: record.relativePath, pngSHA256: pngSHA256.lowercased(),
            byteCount: byteCount, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            frameSequence: frameSequence, capturedAt: now())
        record.receipts.append(receipt)
        record.lastUsedAt = now()
        return receipt
    }

    @discardableResult
    public func end(sessionID: UUID) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let record = records.removeValue(forKey: sessionID) else { return 0 }
        return record.grants.count
    }

    @discardableResult
    public func cancelAll() -> Int {
        lock.lock(); defer { lock.unlock() }
        let count = records.count
        records.removeAll()
        return count
    }

    public func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        records.removeAll()
    }

    private func liveRecordLocked(_ id: UUID) -> C04CadSessionRecord? {
        purgeExpiredLocked()
        return records[id]
    }

    private func purgeExpiredLocked() {
        let current = now()
        var kept: [UUID: C04CadSessionRecord] = [:]
        for (id, record) in records
        where current.timeIntervalSince(record.lastUsedAt) <= C04CadLimits.sessionTTL {
            kept[id] = record
        }
        records = kept
    }
}

// MARK: - C04C .floecad package contract

public struct C04CadPackageSummary: Sendable, Equatable {
    public let schema: String
    public let meshVersion: Int
    public let meshCount: Int
    public let imageCount: Int
    public let resourceCount: Int
    public let totalBytes: Int
    public let sourceUnits: C04CadUnits
    public let upAxis: String

    public var wire: [String: Any] {
        [
            "schema": schema,
            "meshVersion": meshVersion,
            "meshCount": meshCount,
            "imageCount": imageCount,
            "resourceCount": resourceCount,
            "totalBytes": totalBytes,
            "sourceUnits": sourceUnits.rawValue,
            "upAxis": upAxis,
            "contract": "floe.cad-package/1",
        ]
    }
}

private struct C04CadPackageResource {
    let id: String
    let path: String
    let bytes: Int
    let sha256: String
    let mediaType: String
}

private struct C04CadPackageMesh {
    let id: String
    let resourceID: String
    let format: String
    let transform: [Double]
    let vertexCount: Int?
    let triangleCount: Int?
}

private struct C04CadPackageImage {
    let id: String
    let resourceID: String
    let width: Int?
    let height: Int?
}

public enum C04CadPackageValidator {
    /// INTERMEDIATE metadata contract only (`floe.cad-package/1`). It is NOT
    /// the native `.floecad` source format: the native directory package is
    /// parsed by C04FloecadPackage and the App byte adapter, where a v1 mesh
    /// codec can legitimately carry a non-identity DOCUMENT/instance
    /// transform. The v1 identity rule below remains part of this separate
    /// intermediate contract and is not applied to native packages.
    public static let schema = "floe.cad-package/1"

    /// Structural validation only. The package adapter (C04C) remains the
    /// byte reader; this contract fixes ids, containment, digests, mesh
    /// version/transform semantics and resource references so a package can
    /// never smuggle a host path, external URL or untyped blob into C04C.
    public static func validate(_ manifest: [String: Any]) throws -> C04CadPackageSummary {
        guard let schemaValue = c04String(manifest["schema"], maxBytes: 64),
              schemaValue == schema else {
            throw C04CadError.unsupportedPackage
        }
        guard let scene = manifest["scene"] as? [String: Any],
              let meshVersion = c04Int(scene["meshVersion"]),
              meshVersion == 1 || meshVersion == 2,
              let unitsValue = c04String(scene["sourceUnits"], maxBytes: 16),
              let units = C04CadUnits(rawValue: unitsValue),
              let upAxis = c04String(scene["upAxis"], maxBytes: 1),
              upAxis == "y" || upAxis == "z" else {
            throw C04CadError.invalidPackage
        }
        guard let resourceArray = manifest["resources"] as? [Any],
              resourceArray.count <= C04CadLimits.maximumPackageResources else {
            throw C04CadError.packageLimit
        }
        var resources: [C04CadPackageResource] = []
        var resourceByID: [String: C04CadPackageResource] = [:]
        var resourcePaths = Set<String>()
        var totalBytes = 0
        for item in resourceArray {
            guard let object = item as? [String: Any],
                  let id = c04String(object["id"], maxBytes: 128),
                  C04CadPath.isIdentifier(id),
                  let rawPath = c04String(object["path"], maxBytes: C04CadLimits.maximumPathBytes),
                  let path = C04CadPath.normalize(rawPath),
                  let bytes = c04Int(object["bytes"]),
                  bytes > 0, bytes <= C04CadLimits.maximumPackageBytes,
                  let digest = c04String(object["sha256"], maxBytes: 64),
                  C04CadHex.isSHA256(digest),
                  let mediaType = c04String(object["mediaType"], maxBytes: 128),
                  mediaType.utf8.count in 1...128 else {
                throw C04CadError.invalidPackage
            }
            guard resourceByID[id] == nil, resourcePaths.insert(path).inserted else {
                throw C04CadError.invalidPackage
            }
            totalBytes += bytes
            guard totalBytes <= C04CadLimits.maximumPackageBytes else {
                throw C04CadError.packageLimit
            }
            let resource = C04CadPackageResource(
                id: id, path: path, bytes: bytes, sha256: digest.lowercased(),
                mediaType: mediaType)
            resources.append(resource)
            resourceByID[id] = resource
        }
        guard let meshArray = scene["meshes"] as? [Any],
              meshArray.count <= C04CadLimits.maximumPackageMeshes else {
            throw C04CadError.packageLimit
        }
        var meshes: [C04CadPackageMesh] = []
        var meshIDs = Set<String>()
        var meshTriangles = 0
        for item in meshArray {
            guard let object = item as? [String: Any],
                  let id = c04String(object["id"], maxBytes: 128),
                  C04CadPath.isIdentifier(id),
                  let resourceID = c04String(object["resourceID"], maxBytes: 128),
                  let formatValue = c04String(object["format"], maxBytes: 32),
                  let transformRaw = object["transform"] as? [Any],
                  transformRaw.count == 16 else {
                throw C04CadError.invalidPackage
            }
            guard meshIDs.insert(id).inserted else { throw C04CadError.invalidPackage }
            let expectedFormat = "floecad-mesh-v\(meshVersion)"
            guard formatValue == expectedFormat else { throw C04CadError.invalidPackage }
            let transform = try transformRaw.map { item -> Double in
                guard let value = c04Double(item), value.isFinite,
                      abs(value) <= 1e12 else { throw C04CadError.invalidPackage }
                return value
            }
            if meshVersion == 1 {
                let identity = [1.0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
                guard transform == identity else { throw C04CadError.invalidPackage }
            }
            let vertices = c04Int(object["vertexCount"])
            let triangles = c04Int(object["triangleCount"])
            if object["vertexCount"] != nil && vertices == nil ||
                object["triangleCount"] != nil && triangles == nil {
                throw C04CadError.invalidPackage
            }
            if let vertices, !(0...C04CadLimits.maximumPackageVertices).contains(vertices) {
                throw C04CadError.packageLimit
            }
            if let triangles, !(0...C04CadLimits.maximumPackageTriangles).contains(triangles) {
                throw C04CadError.packageLimit
            }
            meshTriangles += triangles ?? 0
            guard meshTriangles <= C04CadLimits.maximumPackageTotalTriangles else {
                throw C04CadError.packageLimit
            }
            guard let resource = resourceByID[resourceID],
                  resource.mediaType == "application/vnd.floe.cad.mesh.v\(meshVersion)" else {
                throw C04CadError.invalidPackage
            }
            if let bounds = object["bounds"] {
                _ = try C04CadBounds.parse(bounds)
            }
            meshes.append(C04CadPackageMesh(
                id: id, resourceID: resourceID, format: formatValue,
                transform: transform, vertexCount: vertices,
                triangleCount: triangles))
        }
        let imageArray = (scene["images"] as? [Any]) ?? []
        guard imageArray.count <= C04CadLimits.maximumPackageImages else {
            throw C04CadError.packageLimit
        }
        var images: [C04CadPackageImage] = []
        var imageIDs = Set<String>()
        for item in imageArray {
            guard let object = item as? [String: Any],
                  let id = c04String(object["id"], maxBytes: 128),
                  C04CadPath.isIdentifier(id),
                  let resourceID = c04String(object["resourceID"], maxBytes: 128),
                  imageIDs.insert(id).inserted else {
                throw C04CadError.invalidPackage
            }
            let width = c04Int(object["width"])
            let height = c04Int(object["height"])
            if object["width"] != nil && width == nil ||
                object["height"] != nil && height == nil {
                throw C04CadError.invalidPackage
            }
            if let width, !(1...C04CadLimits.maximumMeshEdge).contains(width) {
                throw C04CadError.packageLimit
            }
            if let height, !(1...C04CadLimits.maximumMeshEdge).contains(height) {
                throw C04CadError.packageLimit
            }
            guard let resource = resourceByID[resourceID],
                  ["image/png", "image/jpeg", "image/webp"].contains(resource.mediaType) else {
                throw C04CadError.invalidPackage
            }
            images.append(C04CadPackageImage(
                id: id, resourceID: resourceID, width: width, height: height))
        }
        return C04CadPackageSummary(
            schema: schema, meshVersion: meshVersion,
            meshCount: meshes.count, imageCount: images.count,
            resourceCount: resources.count, totalBytes: totalBytes,
            sourceUnits: units, upAxis: upAxis)
    }
}

// MARK: - Strict JSON value helpers (module-internal)

func c04String(_ value: Any?, maxBytes: Int) -> String? {
    guard let value = value as? String,
          !value.isEmpty, value.utf8.count <= maxBytes else { return nil }
    return value
}

private func c04IsBooleanNumber(_ value: NSNumber) -> Bool {
    #if canImport(CoreFoundation)
    return CFGetTypeID(value) == CFBooleanGetTypeID()
    #else
    return false
    #endif
}

func c04Int(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber, !c04IsBooleanNumber(value) {
        return value.intValue
    }
    return nil
}

func c04UInt64(_ value: Any?) -> UInt64? {
    if let value = value as? UInt64 { return value }
    if let value = value as? Int, value >= 0 { return UInt64(value) }
    if let value = value as? NSNumber, !c04IsBooleanNumber(value),
       value.int64Value >= 0 {
        return UInt64(value.int64Value)
    }
    return nil
}

func c04Double(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? NSNumber, !c04IsBooleanNumber(value) {
        return value.doubleValue
    }
    return nil
}

func c04Bool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber, c04IsBooleanNumber(value) {
        return value.boolValue
    }
    return nil
}

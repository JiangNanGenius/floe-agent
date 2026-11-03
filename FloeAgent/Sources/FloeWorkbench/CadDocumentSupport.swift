// FloeWorkbench — CAD document session identity and transaction gating.
//
// Two correctness properties from review:
//   * A CAD document identity must include the canonical workspace root (and
//     environment/owner), not just the workspace-relative path, so two roots
//     with the same file name never share an engine session.
//   * Document transactions must be serialized as a unit (open → edit → save →
//     commit), not command by command, because the engine session is stateful
//     and actor reentrancy otherwise lets two grants interleave at awaits.

import Foundation
import FloeCore

public enum CadDocumentIdentity {
    /// Stable session key for a resolved document. `rootPath` must already be
    /// canonicalized (standardized + symlink-resolved).
    public static func sessionKey(environmentID: String?, ownerKind: String?,
                                  ownerID: UUID?, rootPath: String,
                                  relativePath: String) -> String {
        [
            environmentID ?? "-",
            ownerKind ?? "-",
            ownerID?.uuidString ?? "-",
            rootPath,
            relativePath,
        ].joined(separator: "\u{1F}")
    }
}

/// A minimal fair async mutex. `lock()` waits for the current holder; `unlock()`
/// hands off to the next waiter. Used to serialize whole document transactions.
public actor AsyncMutex {    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func lock() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func unlock() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    /// Runs `body` while holding the lock; always releases.
    public func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await lock()
        do {
            let result = try await body()
            unlock()
            return result
        } catch {
            unlock()
            throw error
        }
    }

    public var isBusy: Bool { isLocked }
}

/// Mirror of one real viewport capture for the `cad.document` capture action.
/// FloeWorkbench deliberately does not import FloeCAD; the app host maps its
/// public `CADViewportCaptureResult` into this value at the boundary.
public struct CadViewportCapture: Sendable, Equatable {
    public var pngData: Data
    public var width: Int
    public var height: Int
    public var revision: Int64
    public var changeCount: Int
    public var contentSHA256: String
    public var sha256: String
    /// `engineering` or `presentation`; never guessed.
    public var renderer: String
    public var note: String

    public init(pngData: Data, width: Int, height: Int, revision: Int64,
                changeCount: Int, contentSHA256: String, sha256: String,
                renderer: String = "engineering", note: String) {
        self.pngData = pngData
        self.width = width
        self.height = height
        self.revision = revision
        self.changeCount = changeCount
        self.contentSHA256 = contentSHA256
        self.sha256 = sha256
        self.renderer = renderer
        self.note = note
    }
}

// MARK: - Animation values

/// One actual animation-frame capture request. The host resolves the live
/// document, applies the frame transiently and returns real rendered bytes;
/// it never substitutes a placeholder or an engineering viewport.
public struct CadAnimationCaptureRequest: Sendable, Equatable {
    public var clipID: UUID?
    public var timeSeconds: Double?
    public var frame: Int?
    public var fps: Int
    public var width: Int
    public var height: Int
    /// `png` or `jpeg`.
    public var format: String
    public var jpegQuality: Double
    public var expectedRevision: Int64?

    public init(clipID: UUID? = nil, timeSeconds: Double? = nil,
                frame: Int? = nil, fps: Int = 30,
                width: Int = 1920, height: Int = 1080,
                format: String = "png", jpegQuality: Double = 0.92,
                expectedRevision: Int64? = nil) {
        self.clipID = clipID
        self.timeSeconds = timeSeconds
        self.frame = frame
        self.fps = fps
        self.width = width
        self.height = height
        self.format = format
        self.jpegQuality = jpegQuality
        self.expectedRevision = expectedRevision
    }
}

public struct CadAnimationCapture: Sendable, Equatable {
    public var imageData: Data
    public var mimeType: String
    public var width: Int
    public var height: Int
    public var revision: Int64
    public var changeCount: Int
    public var contentSHA256: String
    public var sha256: String
    public var clipID: UUID
    public var timeSeconds: Double
    public var frameIndex: Int
    public var frameRate: Int
    public var renderer: String
    public var note: String
    /// Durable native task that produced this frame (filled by the host).
    public var taskID: UUID?

    public init(imageData: Data, mimeType: String, width: Int, height: Int,
                revision: Int64, changeCount: Int, contentSHA256: String,
                sha256: String, clipID: UUID, timeSeconds: Double,
                frameIndex: Int, frameRate: Int, renderer: String, note: String,
                taskID: UUID? = nil) {
        self.imageData = imageData
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.revision = revision
        self.changeCount = changeCount
        self.contentSHA256 = contentSHA256
        self.sha256 = sha256
        self.clipID = clipID
        self.timeSeconds = timeSeconds
        self.frameIndex = frameIndex
        self.frameRate = frameRate
        self.renderer = renderer
        self.note = note
        self.taskID = taskID
    }
}

/// Animation export options accepted by the tool. Values are validated again
/// by the engine; the tool only keeps the public contract small and explicit.
/// `format` is `mp4` (historical default) or `png_zip` (ordered lossless PNG
/// frames + manifest in one ZIP). `alpha` is `opaque` by default; the engine
/// refuses `transparent` before any output because the renderer composites an
/// opaque background.
public struct CadAnimationExportOptions: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var frameRate: Int
    /// `h264` (video default), `hevc`, or `png` for `png_zip`.
    public var codec: String
    public var bitrate: Int?
    public var overwrite: Bool
    public var posterEnabled: Bool
    public var format: String
    public var alpha: String

    public init(width: Int = 1920, height: Int = 1080, frameRate: Int = 30,
                codec: String = "h264", bitrate: Int? = nil,
                overwrite: Bool = false, posterEnabled: Bool = true,
                format: String = "mp4", alpha: String = "opaque") {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.bitrate = bitrate
        self.overwrite = overwrite
        self.posterEnabled = posterEnabled
        self.format = format
        self.alpha = alpha
    }

    private enum CodingKeys: String, CodingKey {
        case width, height, frameRate, codec, bitrate, overwrite
        case posterEnabled, format, alpha
    }

    /// Old durable task records have no X29 fields: they remain exactly the
    /// historical opaque MP4 request instead of failing to decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 1920
        height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 1080
        frameRate = try container.decodeIfPresent(Int.self, forKey: .frameRate) ?? 30
        codec = try container.decodeIfPresent(String.self, forKey: .codec) ?? "h264"
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        overwrite = try container.decodeIfPresent(Bool.self, forKey: .overwrite) ?? false
        posterEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .posterEnabled) ?? true
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? "mp4"
        alpha = try container.decodeIfPresent(String.self, forKey: .alpha) ?? "opaque"
    }
}

public struct CadAnimationExportReceipt: Sendable, Equatable {
    public var relativePath: String
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var durationSeconds: Double
    public var frameCount: Int
    public var codec: String
    public var hasAudio: Bool
    public var byteCount: Int64
    public var sha256: String
    public var posterPNG: Data?
    public var taskID: UUID
    public var note: String
    /// Exact output kind (`mp4` or `png_zip`) and declared alpha.
    public var format: String
    public var alpha: String
    public var frameTimes: [Double]?
    public var manifestSHA256: String?

    public init(relativePath: String, width: Int, height: Int,
                frameRate: Double, durationSeconds: Double, frameCount: Int,
                codec: String, hasAudio: Bool, byteCount: Int64, sha256: String,
                posterPNG: Data?, taskID: UUID, note: String,
                format: String = "mp4", alpha: String = "opaque",
                frameTimes: [Double]? = nil, manifestSHA256: String? = nil) {
        self.relativePath = relativePath
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.durationSeconds = durationSeconds
        self.frameCount = frameCount
        self.codec = codec
        self.hasAudio = hasAudio
        self.byteCount = byteCount
        self.sha256 = sha256
        self.posterPNG = posterPNG
        self.taskID = taskID
        self.note = note
        self.format = format
        self.alpha = alpha
        self.frameTimes = frameTimes
        self.manifestSHA256 = manifestSHA256
    }
}

/// Action names the `material` and `parameters` tool actions accept. Kept in
/// the tool-support module so validation does not need a FloeCAD dependency;
/// the engine service remains the authority and returns a structured refusal
/// for anything it does not implement.
public enum CadNativeEditActions {
    public static let material: Set<String> = [
        "list", "read", "create", "update", "remove", "apply", "applyFaces",
        "reassignFaces", "mapping", "textures", "unresolved", "libraryExport",
        "libraryImport", "libraryList", "environment.read", "environment.update", "environment.import", "undo", "redo",
        "uv.read", "uv.seams", "uv.unwrap", "uv.pack", "uv.transform", "uv.createSet",
        "uv.activateSet", "uv.removeSet", "uv.status", "uv.cancel",
        "paint.read", "paint.stroke", "paint.bakeAO", "paint.status", "paint.cancel",
    ]
    /// Same parameters route; the engine validates geometry and transaction
    /// ownership. Documentation and examples use the existing complete/paged
    /// CadDocumentHelp protocol, not another model tool or grant path.
    public static let loftSurface: Set<String> = [
        "loft.describe","loft.create","loft.update","surface.catalog",
        "surface.create","surface.update","surface.inspect",
    ]
    public static let loftSurfaceExamples: [String] = [
        #"{"action":"loft.update","feature_id":"00000000-0000-4000-8000-000000000001","changes":{"definition":{"version":1,"ruled":false,"guides":[],"start":{"tangent":{"point":[0,0,1]},"curvature":{"point":[0.01,0,0]},"angularTolerance":0.00001,"curvatureTolerance":0.000001},"end":{"tangent":{"point":[0,0,1]},"curvature":{"point":[0,0,0]},"angularTolerance":0.00001,"curvatureTolerance":0.000001}}}}"#,
        #"{"action":"loft.update","feature_id":"00000000-0000-4000-8000-000000000001","changes":{"definition":{"version":1,"guides":[{"version":1,"segments":[{"sketchID":"00000000-0000-4000-8000-000000000002","entityID":"00000000-0000-4000-8000-000000000003","reversed":false}]}]}}}"#,
        #"{"action":"loft.describe","feature_id":"30000000-0000-0000-0000-000000000001"}"#,
        #"{"action":"loft.create","sections":[{"sketchID":{"raw":"10000000-0000-0000-0000-000000000001"},"entityIDs":["20000000-0000-0000-0000-000000000001"],"holeEntityIDs":[]},{"sketchID":{"raw":"10000000-0000-0000-0000-000000000002"},"entityIDs":["20000000-0000-0000-0000-000000000002"],"holeEntityIDs":[]}],"definition":{"version":1,"ruled":false}}"#,
        #"{"action":"loft.update","feature_id":"30000000-0000-0000-0000-000000000001","changes":{"sections":[{"sketchID":{"raw":"10000000-0000-0000-0000-000000000002"},"entityIDs":["20000000-0000-0000-0000-000000000002"],"holeEntityIDs":[]},{"sketchID":{"raw":"10000000-0000-0000-0000-000000000001"},"entityIDs":["20000000-0000-0000-0000-000000000001"],"holeEntityIDs":[]}],"definition":{"version":1,"ruled":true}}}"#,
        #"{"action":"surface.catalog"}"#,
        #"{"action":"surface.create","definition":{"version":1,"operation":"loft","sections":[{"version":1,"segments":[{"sketchID":"10000000-0000-0000-0000-000000000001","entityID":"20000000-0000-0000-0000-000000000001","reversed":false}]},{"version":1,"segments":[{"sketchID":"10000000-0000-0000-0000-000000000002","entityID":"20000000-0000-0000-0000-000000000002","reversed":false}]}],"ruled":true}}"#,
        #"{"action":"surface.create","definition":{"version":1,"operation":"trim","sources":[{"producer":{"raw":"30000000-0000-0000-0000-000000000001"},"bodyID":{"raw":"40000000-0000-0000-0000-000000000001"}}],"trim":{"uMin":0.2,"uMax":0.8,"vMin":0.2,"vMax":0.8}}}"#,
        #"{"action":"surface.create","definition":{"version":1,"operation":"patch","sources":[{"producer":{"raw":"30000000-0000-0000-0000-000000000001"},"bodyID":{"raw":"40000000-0000-0000-0000-000000000001"}}]}}"#,
        #"{"action":"surface.create","definition":{"version":1,"operation":"sew","sources":[{"producer":{"raw":"30000000-0000-0000-0000-000000000001"},"bodyID":{"raw":"40000000-0000-0000-0000-000000000001"}},{"producer":{"raw":"30000000-0000-0000-0000-000000000002"},"bodyID":{"raw":"40000000-0000-0000-0000-000000000002"}}],"requireClosed":false}}"#,
        #"{"action":"surface.update","feature_id":"30000000-0000-0000-0000-000000000002","definition":{"version":1,"operation":"thicken","sources":[{"producer":{"raw":"30000000-0000-0000-0000-000000000001"},"bodyID":{"raw":"40000000-0000-0000-0000-000000000001"}}],"thickness":2}}"#,
        #"{"action":"surface.inspect","body_id":"40000000-0000-0000-0000-000000000001"}"#,
    ]
    public static let parameters: Set<String> = Set<String>([
        "list", "update", "updateSketchEntity", "deleteSketchEntity",
        "trimSketchCurve", "extendSketchCurve", "offsetSketchCurve", "unlinkSketchOffset",
        "setSketchDimension", "removeSketchDimension",
        "projectExternalEdges", "detachExternalReferences",
        "feature.suppress", "feature.delete", "feature.move",
        "variable.create", "variable.update", "variable.delete",
        "feature.setExpression",
        "thread.catalog", "thread.sources", "thread.create", "thread.update",
        "mechanical.catalog", "mechanical.inspect", "mechanical.update",
        "gear.catalog", "gear.create", "gear.update", "gear.inspect",
        "sheetMetal.create", "sheetMetal.update", "weldment.create", "weldment.update", "weldment.cutList",
        "datum.offsetPlane.create", "datum.offsetPlane.update", "datum.offsetPlane.delete",
        "datum.anglePlane.create", "datum.anglePlane.update", "datum.anglePlane.delete",
        "datum.threePointPlane.create", "datum.threePointPlane.update",
        "datum.threePointPlane.delete",
        "datum.axis.create", "datum.axis.update", "datum.axis.delete",
        "datum.point.create", "datum.point.update", "datum.point.delete",
        "sketch.setSupport", "sketch.clearSupport",
        "undo", "redo",
    ]).union(loftSurface)
    /// Authored/read animation operations. `capture`/`export` are media
    /// operations handled by the host, not document mutations.
    public static let animationReads: Set<String> = [
        "list", "query", "evaluate",
    ]
    public static let animationMutations: Set<String> = [
        "createClip", "updateClip", "deleteClip", "setActiveClip",
        "addTrack", "deleteTrack", "setKeyframe", "setCameraKeyframe",
        "setPartKeyframe", "deleteKeyframe", "preset", "undo", "redo",
    ]
    /// X22 persisted section / measurement overlay. `get` is read-only; every
    /// other action is one existing sceneSettings undoable edit.
    public static let sceneReads: Set<String> = ["get", "objects", "object.resources"]
    public static let sceneMutations: Set<String> = [
        "setSection", "setSectionEnabled", "flipSection", "removeSection",
        "setMeasurementsVisible", "addMeasurement", "removeMeasurement",
        "clearMeasurements", "undo", "redo",
        "object.createGroup", "object.reparent", "object.transform", "object.rename", "object.remove",
    ]
    public static let scene: Set<String> = sceneReads.union(sceneMutations)

    public static let animationMedia: Set<String> = ["capture", "export"]
    public static let animation: Set<String> =
        animationReads.union(animationMutations).union(animationMedia)

    /// Model-facing driving-dimension names accepted by
    /// `parameters setSketchDimension`. `length` is a line's point-to-point
    /// distance; `width`/`height` are stored as the solver's horizontal/
    /// vertical axis distances.
    public static let sketchDimensionKinds: Set<String> = [
        "length", "distance", "angle", "diameter", "radius", "width", "height",
    ]
}

/// The model-facing native operation vocabulary used by the every-turn tool
/// schema. FloeWorkbench deliberately does not import FloeCAD, so the schema
/// cannot read `FloeCADDocument` directly; these two lists are the single
/// schema authority and are pinned to the kernel/executor by
/// `NativeCADCapabilityDiscoveryTests`. `capabilities.operation_names` and
/// `capabilities.unavailable_operations` remain derived from the executor.
public enum CadNativeOperationVocabulary: Sendable {
    /// Every model-facing executable native op, in the order the kernel
    /// reports it. `document.import` is deliberately not here: it is an
    /// internal parser route used only by the guarded host import proposal.
    public static let executable: [String] = [
        "sketch.create", "sketch.addEntities", "sketch.addText",
        "feature.extrude", "feature.revolve", "feature.hole",
        "feature.pattern", "feature.mirror", "feature.transform",
        "feature.boolean", "feature.split", "feature.fillet", "feature.chamfer",
        "feature.shell", "feature.sweep", "feature.loft",
        "feature.pushPull", "feature.moveFace",
        "feature.deleteFace", "feature.replaceFace", "feature.draftFace",
        "body.setMaterial", "item.setHidden",
    ]

    /// Guaranteed-refusal ops retained for historical callers. They must
    /// never be presented as executable.
    public static let unavailable: [String] = [
        "feature.scaleFace", "feature.rotateFace",
    ]
}

// MARK: - Native package naming and creation/import policy

/// Shared policy for the native `.floecad` package surface (tool create/import
/// actions and the file-tree UI factory). The model never writes package
/// bytes and never guesses the internal manifest layout; this only guards the
/// document NAME and the workspace-relative location of a new package.
public enum NativeCADPolicy: Sendable {
    /// Package file extension (lowercased, without dot).
    public static let packageExtension = "floecad"

    /// Maximum length of a document stem or display name, counted in
    /// characters (grapheme clusters). Longer names are refused with an
    /// actionable message instead of being silently cut.
    public static let maximumStemLength = 120

    /// Characters allowed in addition to letters/numbers of ANY language:
    /// space, dash, underscore, dot and parentheses. Everything else (path
    /// separators, control characters, emoji, symbols) is replaced with a
    /// space, so a model-supplied name can never traverse directories.
    private static func isAllowedStemCharacter(_ character: Character) -> Bool {
        if character.isLetter || character.isNumber { return true }
        if " -_.()".contains(character) { return true }
        // Combining marks are part of a valid written name in many scripts.
        return character.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return true
            default: return false
            }
        }
    }

    /// Sanitizes a caller-supplied document name into a safe stem (no
    /// extension). Returns nil when nothing usable remains. Path separators,
    /// control characters and other unsafe letters are replaced with spaces,
    /// runs of whitespace collapsed, and the result is bounded and trimmed.
    /// Letters and digits of every language survive (`支架`, `ブラケット`,
    /// `Кронштейн`), so Chinese and mixed names are usable as real documents.
    public static func sanitizedStem(_ rawName: String) -> String? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Drop any caller-supplied extension once, repeatedly (e.g.
        // "plate.zip.floecad"), so the output never contains dots at the end.
        var stem = trimmed
        while (stem as NSString).pathExtension.lowercased() == packageExtension {
            stem = (stem as NSString).deletingPathExtension
        }
        let mapped = String(stem.map { character -> Character in
            if isAllowedStemCharacter(character) { return character }
            return " "
        })
        // Collapse whitespace runs and reject hidden/traversal-looking names.
        let parts = mapped.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        var cleaned = parts.joined(separator: " ")
        while cleaned.hasPrefix(".") {
            cleaned = String(cleaned.dropFirst())
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned != "." else { return nil }
        if cleaned.count > maximumStemLength {
            cleaned = String(cleaned.prefix(maximumStemLength))
                .trimmingCharacters(in: .whitespaces)
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Validates a caller-supplied document display name against the real
    /// usability rules and returns a human-readable, bilingual explanation of
    /// the first problem, or nil when the name is usable. This is the
    /// actionable error a model/user sees instead of a silent rename or a
    /// generic failure:
    ///   * empty names are refused;
    ///   * names longer than `maximumStemLength` characters are refused
    ///     (never silently truncated);
    ///   * path separators / `..` segments are refused (no traversal);
    ///   * control or invisible characters (newlines, bidi controls, zero
    ///     width joiners, NUL) are refused;
    ///   * names with no usable characters at all are refused.
    /// Letters and digits of any language, spaces and `-_.()` remain valid.
    /// Actionable message for an empty (blank) document name; shared by the
    /// validator and the create path (an explicitly blank name is refused, it
    /// is never silently replaced by the path-stem fallback).
    public static let emptyNameMessage =
        "A CAD document name is required. 需要填写 CAD 文档名称。"

    public static func validateName(_ rawName: String) -> String? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return emptyNameMessage
        }
        guard trimmed.count <= maximumStemLength else {
            return "The CAD document name is too long: \(trimmed.count) characters; at most "
                + "\(maximumStemLength) are supported. CAD 文档名称过长：当前 \(trimmed.count) 个字符，最多支持 "
                + "\(maximumStemLength) 个字符。"
        }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed == "." || trimmed == ".." {
            return "The CAD document name must not contain path separators ('/' or '\\') or a '..' path segment. "
                + "CAD 文档名称不能包含路径分隔符（/、\\）或 “..”。"
        }
        for scalar in trimmed.unicodeScalars where isUnsafeScalar(scalar) {
            return "The CAD document name must not contain control or invisible characters. "
                + "CAD 文档名称不能包含控制字符或不可见字符。"
        }
        guard sanitizedStem(trimmed) != nil else {
            return "The CAD document name must contain at least one usable character "
                + "(a letter or digit of any language, space, - _ ( ) or .). "
                + "CAD 文档名称必须包含可用字符（任意语言的字母或数字、空格、- _ ( ) 或 .）。"
        }
        return nil
    }

    /// Control, format (bidi/zero-width) and line-separator scalars are never
    /// part of a usable document name.
    private static func isUnsafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.controlCharacters.contains(scalar) { return true }
        if CharacterSet.illegalCharacters.contains(scalar) { return true }
        switch scalar.properties.generalCategory {
        case .format, .lineSeparator, .paragraphSeparator, .surrogate:
            return true
        default:
            return false
        }
    }

    /// The exact relative package path for `stem` inside `parent` (a
    /// workspace-relative directory, "" for the workspace root). Never
    /// contains ".." and never escapes `parent`.
    public static func packageRelativePath(parent: String, stem: String) -> String {
        let file = "\(stem).\(packageExtension)"
        let normalizedParent = parent
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: "/")
        return normalizedParent.isEmpty ? file : "\(normalizedParent)/\(file)"
    }

    /// Unique-ify `relativePath` against `exists`, appending " 2", " 3", … to
    /// the stem, exactly like the file-tree UI factory. `exists` answers for
    /// workspace-relative paths and MUST answer true for cloud/network roots
    /// (the caller never reaches this for those) so nothing is overwritten.
    public static func uniquePackagePath(relativePath: String,
                                          exists: (String) -> Bool) -> String {
        guard exists(relativePath) else { return relativePath }
        let directory = (relativePath as NSString).deletingLastPathComponent
        let fileName = (relativePath as NSString).lastPathComponent
        let stem = (fileName as NSString).deletingPathExtension
        var serial = 2
        while true {
            let candidateFile = "\(stem) \(serial).\(packageExtension)"
            let candidate = directory.isEmpty ? candidateFile : "\(directory)/\(candidateFile)"
            if !exists(candidate) { return candidate }
            serial += 1
        }
    }

    /// Normalizes a caller-supplied import format (extension or explicit
    /// format) to one of the recognized exchange formats, or nil.
    public static func normalizedImportFormat(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "step", "stp": return "step"
        case "iges", "igs": return "iges"
        case "stl": return "stl"
        case "obj": return "obj"
        case "glb": return "glb"
        case "gltf": return "gltf"
        case "zip", "blend", "usd", "usda", "usdc", "usdz": return raw
        default: return nil
        }
    }

    /// Import formats recognized by the native kernel path, by exchange
    /// family. STEP/IGES carry exact B-rep geometry; an IGES shell/face is
    /// kept as an exact open-surface body (`surfaceBRep`) rather than a
    /// render mesh. STL/OBJ/GLB/glTF are mesh exchanges imported as render/
    /// mesh bodies without a parametric history — the reply states which.
    public static let importExtensions: Set<String> =
        ["step", "stp", "iges", "igs", "stl", "obj", "glb", "gltf"]

    /// Formats the native kernel exports (the host validates against the
    /// output extension). STEP is closed-solid-only; IGES writes exact solid
    /// AND open-surface B-rep geometry back. PDF, SVG, DXF and the complete
    /// BOM CSV are page-scoped drawing exports and need `page_id`; CSV is a
    /// table, not a body-geometry exchange. `obj_bundle` is the single-file
    /// ZIP container (output extension .zip); plain `obj` remains a real OBJ
    /// with UVs and no materials.
    public static let exportExtensions: Set<String> =
        ["step", "stp", "iges", "igs", "stl", "obj", "obj_bundle", "3mf", "glb",
         "usdz", "pdf", "svg", "dxf", "csv"]
}

/// Per-format capability matrix advertised by the native `.floecad` surface.
/// View/edit describe whether imported geometry participates in the kernel
/// (exact B-rep solids/open surfaces vs render-only mesh bodies); export lists
/// the formats that geometry class can leave as. Kept explicit so the model
/// never treats a mesh import as a parametric solid or assumes feature
/// history exists.
public enum NativeCADCapabilityMatrix: Sendable {
    public struct FormatRow: Sendable, Equatable {
        public var format: String
        public var aliases: [String]
        /// "brep" for exact solids/surfaces, "mesh" for tessellated bodies.
        public var geometryClass: String
        public var create: Bool
        public var `import`: Bool
        public var view: Bool
        public var edit: Bool
        public var export: [String]
        public var note: String

        public init(format: String, aliases: [String], geometryClass: String,
                    create: Bool, import: Bool, view: Bool, edit: Bool,
                    export: [String], note: String) {
            self.format = format
            self.aliases = aliases
            self.geometryClass = geometryClass
            self.create = create
            self.import = `import`
            self.view = view
            self.edit = edit
            self.export = export
            self.note = note
        }
    }

    /// Native package creation row plus every supported exchange format.
    public static let rows: [FormatRow] = [
        FormatRow(format: "floecad", aliases: [], geometryClass: "native",
                  create: true, import: false, view: true, edit: true,
                  export: ["step", "iges", "stl", "obj", "obj_bundle", "3mf", "glb",
                           "usdz", "pdf", "svg", "dxf", "csv"],
                  note: "Native parametric package created with the create action; "
                    + "never build the package by hand. obj_bundle writes one .zip "
                    + "containing model.obj, model.mtl and relative textures; plain obj "
                    + "remains a single .obj with UVs and no materials."),
        FormatRow(format: "step", aliases: ["stp"], geometryClass: "brep",
                  create: false, import: true, view: true, edit: true,
                  export: ["step", "iges", "stl", "obj", "obj_bundle", "3mf", "glb", "usdz"],
                  note: "Exact OCCT B-rep solids (AP214). Imported solids are editable; "
                    + "no parametric feature history is synthesized. STEP export here "
                    + "writes closed solids only; IGES can also return exact surfaces."),
        FormatRow(format: "iges", aliases: ["igs"], geometryClass: "brep",
                  create: false, import: true, view: true, edit: true,
                  export: ["step", "iges", "stl", "obj", "obj_bundle", "3mf", "glb", "usdz"],
                  note: "Surface exchange: closed solids and open shells/faces import as "
                    + "exact B-rep bodies. Surface bodies support move/rotate/scale, material, "
                    + "save/reopen, undo and IGES re-export; solid boolean/fillet/shell and "
                    + "STEP export require closed solids, so surfaces are excluded there with "
                    + "a truthful reason. Imported surfaces are not captured as graph-owned authoring inputs; native authored surfaces use the versioned parameters actions. No IGES assembly metadata."),
        FormatRow(format: "stl", aliases: [], geometryClass: "mesh",
                  create: false, import: true, view: true, edit: false,
                  export: ["stl", "obj", "obj_bundle", "3mf", "glb", "usdz"],
                  note: "Triangle mesh imported as a render body; no parametric history "
                    + "and no boolean/fillet/shell on the imported body."),
        FormatRow(format: "obj", aliases: [], geometryClass: "mesh",
                  create: false, import: true, view: true, edit: false,
                  export: ["stl", "obj", "obj_bundle", "3mf", "glb", "usdz"],
                  note: "Wavefront mesh imported as render body(ies); loose .obj keeps "
                    + "its .mtl/texture siblings. No parametric history. obj_bundle "
                    + "re-exports the applied appearance as a self-contained .zip."),
        FormatRow(format: "glb", aliases: ["gltf"], geometryClass: "mesh",
                  create: false, import: true, view: true, edit: false,
                  export: ["glb", "stl", "obj", "obj_bundle", "3mf", "usdz"],
                  note: "Binary .glb mesh(es) import as render bodies with materials, "
                    + "no parametric history. A JSON .gltf imports ONLY when every "
                    + "buffer/image is an embedded data: URI (self-contained); a .gltf "
                    + "referencing external .bin buffers or textures is reported "
                    + "unsupported by the tool rather than dropping geometry."),
    ]

    public static func row(forFormat format: String) -> FormatRow? {
        rows.first { $0.format == format || $0.aliases.contains(format) }
    }

    /// JSON-serializable representation for capabilities replies.
    public static func json() -> [[String: Any]] {
        rows.map { row in
            [
                "format": row.format,
                "aliases": row.aliases,
                "geometry_class": row.geometryClass,
                "create": row.create,
                "import": row.import,
                "view": row.view,
                "edit": row.edit,
                "export": row.export,
                "note": row.note,
            ]
        }
    }
}

/// Cancellable FIFO gate used for whole CAD document transactions. Unlike a
/// plain mutex, a task cancelled while queued refuses to run when the gate
/// would otherwise open for it: it hands the gate to the next waiter and
/// throws `FloeError.cancelled`, so a cancelled tool call can never execute
/// later against a document someone else has since changed.
public actor CadDocumentGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func acquire() async throws {
        if Task.isCancelled { throw FloeError.cancelled }
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        // Woken while cancelled: pass the gate on and refuse to proceed.
        if Task.isCancelled {
            release()
            throw FloeError.cancelled
        }
    }

    public func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    public var isBusy: Bool { busy }
}

// MARK: - Authoritative workbench service operation catalog

/// The ONE authoritative list of the native workbench service operations the
/// model may reach through `cad.document` — the `three_d_assembly` /
/// `three_d_drawing` payload calls and `propose` with a `"<kind>.<action>"`
/// op.
///
/// The engine's routers (`CADAssemblyService`, `CADDrawingService`,
/// `CADScriptService`, `CADMeshService`) stay the executors. This catalog
/// mirrors their exact action and argument vocabularies for the two surfaces
/// that must agree and previously guessed: the agent tool
/// (`CadDocumentTool`, which validates and teaches before the host) and the
/// app host (`CadDocumentCenter`, which resolves the request before routing it
/// to the engine). It is data-only so both derive acceptance from one table.
///
/// Rules enforced here (and proven by the tests):
///   * a service payload MUST name its operation — `payload.action`, or the
///     explicit legacy alias `payload.op` in either `"<kind>.<action>"` or
///     bare `<action>` form. A payload with no recognizable action is REFUSED
///     with the known list; it is never silently defaulted to a read (`pages` /
///     `report`);
///   * an unknown action / unknown op / kind-prefix mismatch is refused with
///     the known actions and a suggestion, never normalized into something
///     else;
///   * `payload.args` (the propose-shaped envelope) is flattened into the
///     operation arguments with a conflict refusal, so one request shape works
///     on both surfaces;
///   * mutating operations remain unreachable as direct payload calls: the
///     host still answers `proposal_required`, and the only path to the engine
///     is propose → apply under the existing runtime authority. This catalog
///     never widens permission;
///   * `capabilities` serves this same table on demand (bounded page) so the
///     every-turn tool schema stays small while the model can still discover
///     the exact arguments and a runnable example before it guesses.
public enum CadServiceOperationCatalog: Sendable {

    /// Kinds the host routes through the workbench services.
    public static let kinds: [String] = ["assembly", "drawing", "script", "mesh"]

    /// One typed argument of an operation. `type` is the JSON/wire shape; the
    /// note carries enums, defaults and bounds the engine enforces.
    public struct Argument: Sendable, Equatable {
        public var name: String
        public var type: String
        public var required: Bool
        public var note: String

        public init(_ name: String, _ type: String, required: Bool = false, note: String = "") {
            self.name = name
            self.type = type
            self.required = required
            self.note = note
        }
    }

    /// One engine action, exactly as the service router spells it.
    public struct Operation: Sendable, Equatable {
        public var kind: String
        public var action: String
        /// True when the action writes document state and is therefore only
        /// reachable through `propose` + `apply`.
        public var mutating: Bool
        public var summary: String
        public var arguments: [Argument]
        /// Exact `args` object examples in the REAL argument names.
        public var examples: [String]

        public var op: String { "\(kind).\(action)" }
        /// The propose-form example for this operation.
        public var proposeExample: String { #"{"op":"\#(op)","args":\#(examples.first ?? "{}")}"# }
    }

    /// A deterministic, structured refusal (never a silent default).
    public struct ResolutionFailure: Error, LocalizedError, Equatable, Sendable {
        public var code: String
        public var message: String
        public var errorDescription: String? { message }

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    // MARK: Table

    private static func arg(_ name: String, _ type: String, required: Bool = false,
                            note: String = "") -> Argument {
        Argument(name, type, required: required, note: note)
    }

    private static let drawingOperations: [Operation] = [
        Operation(kind: "drawing", action: "standardSheet", mutating: true,
                  summary: "Replace or extend the drawing set with the standard four-view sheet "
                    + "(front, top, side, iso) projected from one body.",
                  arguments: [
                      arg("bodyID", "uuid", required: true, note: "live document body; bodyIDs[0] is also accepted"),
                      arg("title", "string", note: "title-block title; defaults to the document name"),
                      arg("replace", "boolean", note: "default false; true replaces every existing page"),
                  ],
                  examples: [#"{"bodyID":"<body uuid>"}"#]),
        Operation(kind: "drawing", action: "multiViewSheet", mutating: true,
                  summary: "Create ONE shared drawing page carrying front/top/side/section views "
                    + "with editable per-view scale and projection alignment.",
                  arguments: [
                      arg("bodyID", "uuid", note: "one source body; bodyIDs[0] is also accepted"),
                      arg("bodyIDs", "[uuid]", note: "1-12 source bodies shared by every view"),
                      arg("title", "string", note: "title-block title; defaults to the document name"),
                      arg("scale", "number", note: "initial view scale in (0, 1000]; default 1"),
                      arg("paper", "string", note: "default a3"),
                      arg("sectionOrigin", "[x,y,z]", note: "defaults to the selected sources' bounds centre"),
                      arg("sectionNormal", "[x,y,z]", note: "defaults to [0,0,1]"),
                      arg("assemblyMode", "boolean", note: "project placed instances instead of raw bodies"),
                      arg("explodedViewID", "uuid", note: "saved exploded view; implies assemblyMode"),
                      arg("replace", "boolean", note: "default false; true replaces every existing page"),
                  ],
                  examples: [#"{"bodyID":"<body uuid>","title":"Closure"}"#,
                             #"{"bodyIDs":["<body uuid>"],"paper":"a3","scale":0.5}"#]),
        Operation(kind: "drawing", action: "addView", mutating: true,
                  summary: "Add one view to a shared drawing page (or lift a legacy page to a sheet).",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("kind", "string", required: true, note: "front | top | side | iso | section | detail | exploded"),
                      arg("name", "string"), arg("scale", "number"),
                      arg("offset", "[x,y]", note: "absolute sheet offset for a free view; clears alignment"),
                      arg("nudge", "[x,y]", note: "extra offset applied after alignment"),
                      arg("viewNormal", "[x,y,z]"), arg("viewUp", "[x,y,z]"),
                      arg("sectionOrigin", "[x,y,z]"), arg("sectionNormal", "[x,y,z]"),
                      arg("detailOrigin", "[x,y,z]"), arg("detailSizeMM", "number | [width,height]"),
                      arg("bodyIDs", "[uuid]", note: "per-view source filter; inherited when omitted"),
                      arg("alignmentPlacement", "string", note: "free | above | below | left | right"),
                      arg("alignmentReferenceID", "uuid", note: "required when placement is not free"),
                      arg("gapMM", "number", note: "clear sheet-space gap; default 14"),
                  ],
                  examples: [#"{"pageID":"<page uuid>","kind":"section","sectionOrigin":[50,30,5],"sectionNormal":[0,0,1]}"#]),
        Operation(kind: "drawing", action: "updateView", mutating: true,
                  summary: "Edit one shared-sheet view's scale, offset, orientation, section/detail window, "
                    + "sources or projection alignment.",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("viewID", "uuid", required: true),
                      arg("kind", "string"), arg("name", "string"), arg("scale", "number"),
                      arg("offset", "[x,y]", note: "absolute sheet offset for a free view; clears alignment"),
                      arg("nudge", "[x,y]", note: "extra offset applied after alignment"),
                      arg("viewNormal", "[x,y,z]"), arg("viewUp", "[x,y,z]"),
                      arg("sectionOrigin", "[x,y,z]"), arg("sectionNormal", "[x,y,z]"),
                      arg("detailOrigin", "[x,y,z]"), arg("detailSizeMM", "number | [width,height]"),
                      arg("bodyIDs", "[uuid]"),
                      arg("alignmentPlacement", "string"), arg("alignmentReferenceID", "uuid"),
                      arg("gapMM", "number"),
                  ],
                  examples: [#"{"pageID":"<page uuid>","viewID":"<view uuid>","scale":0.5}"#,
                             #"{"pageID":"<page uuid>","viewID":"<view uuid>","alignmentPlacement":"below","alignmentReferenceID":"<front view uuid>"}"#]),
        Operation(kind: "drawing", action: "removeView", mutating: true,
                  summary: "Remove one view from a shared page; refuses to remove the last view or a view "
                    + "with annotations unless removeAnnotations=true.",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("viewID", "uuid", required: true),
                      arg("removeAnnotations", "boolean", note: "default false"),
                  ],
                  examples: [#"{"pageID":"<page uuid>","viewID":"<view uuid>"}"#]),
        Operation(kind: "drawing", action: "layoutViews", mutating: true,
                  summary: "Recompute a shared page's anchor position and projection alignment from live bounds.",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("marginMM", "number", note: "left/top margin for the anchor; default 25"),
                      arg("gapMM", "number", note: "clear gap between aligned views; default 14"),
                  ],
                  examples: [#"{"pageID":"<page uuid>"}"#]),
        Operation(kind: "drawing", action: "dimensionCandidates", mutating: false,
                  summary: "Read cylindrical kernel faces parallel to a view, with the exact reference "
                    + "object addDimension.feature accepts. Visibility is not classified (E12).",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("viewID", "uuid", note: "restrict to one sheet view"),
                  ],
                  examples: [#"{"pageID":"<page uuid>","viewID":"<view uuid>"}"#]),
        Operation(kind: "drawing", action: "assemblySheet", mutating: true,
                  summary: "Create the five-page assembly sheet (front, top, side, iso, exploded) "
                    + "projected from the live placed instances, optionally using one saved exploded view.",
                  arguments: [
                      arg("bodyIDs", "[uuid]", note: "optional source-body filter; defaults to every placed instance; alias sourceBodyIDs"),
                      arg("title", "string", note: "title-block title; defaults to the document name"),
                      arg("explodedViewID", "uuid", note: "saved exploded view; its offsets apply to every page"),
                      arg("scale", "number", note: "drawing mm per model mm in (0, 1000]; default 1"),
                      arg("paper", "string", note: "a4 | a3 | a2 | a1 | a0 | letter | tabloid | custom; default a3"),
                      arg("replace", "boolean", note: "default false; true replaces every existing page"),
                  ],
                  examples: [#"{"title":"Assembly"}"#,
                             #"{"explodedViewID":"<exploded view uuid>","scale":0.5}"#]),
        Operation(kind: "drawing", action: "addPage", mutating: true,
                  summary: "Add one drawing page (front/top/side/iso/section/detail/exploded) "
                    + "projected from bodyIDs; exploded pages and assemblyMode project the placed instances.",
                  arguments: [
                      arg("kind", "string", required: true, note: "front | top | side | iso | section | detail | exploded"),
                      arg("bodyIDs", "[uuid]", note: "1-12 live bodies; alias sourceBodyIDs"),
                      arg("name", "string", note: "page name; defaults to the kind title"),
                      arg("title", "string"), arg("partNumbers", "[string]"),
                      arg("scale", "number", note: "drawing mm per model mm in (0, 1000]; default 1"),
                      arg("paper", "string", note: "a4 | a3 | a2 | a1 | a0 | letter | tabloid | custom; default a3"),
                      arg("customWidthMM", "number"), arg("customHeightMM", "number"),
                      arg("viewNormal", "[x,y,z]"), arg("viewUp", "[x,y,z]"),
                      arg("sectionOrigin", "[x,y,z]", note: "section pages require it with sectionNormal"),
                      arg("sectionNormal", "[x,y,z]"),
                      arg("detailOrigin", "[x,y,z]", note: "detail pages require it with detailSizeMM"),
                      arg("detailSizeMM", "number | [width,height]"),
                      arg("showDimensions", "boolean"), arg("showCenterlines", "boolean"),
                      arg("assemblyMode", "boolean", note: "default false; project the placed assembly instances"),
                      arg("explodedViewID", "uuid", note: "saved exploded view; non-null implies assemblyMode; null clears the id"),
                      arg("explodedViewName", "string", note: "display label; normally derived from explodedViewID"),
                      arg("showBOM", "boolean", note: "default false; draw the page BOM table"),
                  ],
                  examples: [#"{"kind":"front","bodyIDs":["<body uuid>"]}"#,
                             #"{"kind":"iso","bodyIDs":["<body uuid>"],"scale":0.5,"paper":"a3","showDimensions":true}"#,
                             #"{"kind":"exploded","assemblyMode":true,"explodedViewID":"<exploded view uuid>"}"#]),
        Operation(kind: "drawing", action: "updatePage", mutating: true,
                  summary: "Update one page in place; omitted fields keep the current value "
                    + "(kind defaults to the existing page kind).",
                  arguments: [arg("pageID", "uuid", required: true, note: "alias id")]
                    + [arg("kind", "string", note: "front | top | side | iso | section | detail | exploded"),
                       arg("bodyIDs", "[uuid]"), arg("name", "string"),
                       arg("title", "string"), arg("partNumbers", "[string]"), arg("scale", "number"),
                       arg("paper", "string"), arg("customWidthMM", "number"),
                       arg("customHeightMM", "number"), arg("viewNormal", "[x,y,z]"),
                       arg("viewUp", "[x,y,z]"), arg("sectionOrigin", "[x,y,z]"),
                       arg("sectionNormal", "[x,y,z]"), arg("detailOrigin", "[x,y,z]"),
                       arg("detailSizeMM", "number | [width,height]"),
                       arg("showDimensions", "boolean"), arg("showCenterlines", "boolean"),
                       arg("assemblyMode", "boolean", note: "switch the page to placed-instance projection"),
                       arg("explodedViewID", "uuid", note: "saved exploded view; non-null implies assemblyMode; null clears the id"),
                       arg("explodedViewName", "string", note: "display label; normally derived from explodedViewID"),
                       arg("showBOM", "boolean", note: "draw or hide the page BOM table"),
                       arg("units", "string", note: "millimetre | centimetre | inch; display only, geometry stays mm"),
                       arg("precision", "integer", note: "0…4 decimal places for annotation text"),
                       arg("revisionRows", "[object]", note: "replace the page revision table: [{id?, revision, date?, description, approvedBy?}]"),
                       arg("titleBlock", "object", note: "{company, drawingNumber}; per-page override")],
                  examples: [#"{"pageID":"<page uuid>","scale":0.5,"showDimensions":true}"#,
                             #"{"pageID":"<page uuid>","units":"inch","precision":3,"revisionRows":[{"revision":"B","date":"2026-11-01","description":"Updated"}]}"#]),
        Operation(kind: "drawing", action: "removePage", mutating: true,
                  summary: "Remove one page from the drawing set.",
                  arguments: [arg("pageID", "uuid", required: true, note: "alias id")],
                  examples: [#"{"pageID":"<page uuid>"}"#]),
        Operation(kind: "drawing", action: "setBOM", mutating: true,
                  summary: "Derive the page BOM from the visible assembly (shared instances group with quantity) "
                    + "or replace it with explicit entries.",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("entries", "[object]", note: "explicit rows [{itemNumber, name, bodyID, instanceIDs?, partNumber?, material?, version?, partDefinitionID?, quantity?, id?}]; omit to derive"),
                      arg("showBOM", "boolean", note: "default true"),
                  ],
                  examples: [#"{"pageID":"<page uuid>"}"#,
                             #"{"pageID":"<page uuid>","entries":[{"itemNumber":1,"name":"Bracket","bodyID":"<body uuid>","quantity":2}]}"#]),
        Operation(kind: "drawing", action: "addBalloon", mutating: true,
                  summary: "Add a balloon linked to a BOM item and assembly instance; leaders follow live projection.",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("itemNumber", "integer", note: "positive BOM item number; or supply bomEntryID"),
                      arg("bomEntryID", "uuid", note: "alternative to itemNumber; must be on this page's BOM"),
                      arg("instanceID", "uuid", note: "required unless the BOM item already names an instance"),
                      arg("viewID", "uuid", note: "required on a multi-view sheet; coordinates are view-local"),
                      arg("anchor", "[x,y]", note: "balloon center in view mm; omitted = derived from the view's projected instance bounds"),
                      arg("target", "[x,y]", note: "leader target in view mm; omitted = nearest projected instance boundary point"),
                      arg("text", "string"),
                  ],
                  examples: [#"{"pageID":"<page uuid>","itemNumber":1,"instanceID":"<instance uuid>"}"#]),
        Operation(kind: "drawing", action: "updateBalloon", mutating: true,
                  summary: "Update one balloon's anchor, target, item number, instance or text.",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("balloonID", "uuid", required: true),
                      arg("anchor", "[x,y]", note: "drawing mm"),
                      arg("target", "[x,y]", note: "drawing mm; null clears the leader target"),
                      arg("text", "string"),
                      arg("itemNumber", "integer", note: "positive; re-links the balloon to that BOM entry"),
                      arg("instanceID", "uuid"),
                  ],
                  examples: [#"{"pageID":"<page uuid>","balloonID":"<balloon uuid>","anchor":[40,25]}"#]),
        Operation(kind: "drawing", action: "removeBalloon", mutating: true,
                  summary: "Remove one balloon from a page.",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("balloonID", "uuid", required: true),
                  ],
                  examples: [#"{"pageID":"<page uuid>","balloonID":"<balloon uuid>"}"#]),
        Operation(kind: "drawing", action: "addDimension", mutating: true,
                  summary: "Add a manual dimension bound to live geometry, or a linked diameter/radius "
                    + "bound to a stable kernel cylindrical face (remeasures Ø10→Ø8; dangling after deletion).",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("kind", "string", required: true, note: "length | angle | radius | diameter"),
                      arg("instanceID", "uuid", note: "required to bind modelPoints and for drawingPoints"),
                      arg("viewID", "uuid", note: "required on a multi-view sheet; annotation belongs to this view"),
                      arg("drawingPoints", "[[x,y]]", note: "2 points (3 for angle) in VIEW mm; mapped onto the part"),
                      arg("modelPoints", "[[x,y,z]]", note: "2 body-local points (3 for angle); needs instanceID"),
                      arg("feature", "object", note: "dimensionCandidates reference: a linked cylindrical face; diameter/radius only"),
                      arg("textPosition", "[x,y]", note: "view mm; defaults near the points"),
                      arg("text", "string", note: "text override"),
                      arg("tolerance", "object", note: "structured tolerance: {kind:symmetric, deviationMM} | {kind:deviation, upperDeviationMM, lowerDeviationMM} | {kind:limits, upperLimitMM, lowerLimitMM} | {kind:fit, fit:{holeGrade,shaftLetter,shaftGrade}}; linear/radius/diameter only"),
                  ],
                  examples: [#"{"pageID":"<page uuid>","kind":"length","instanceID":"<instance uuid>","modelPoints":[[0,0,0],[40,0,0]]}"#,
                             #"{"pageID":"<page uuid>","kind":"diameter","feature":{"bodyID":"<body uuid>","anchor":{"centroid":[50,30,5],"direction":[0,0,1]}},"tolerance":{"kind":"fit","fit":{"holeGrade":7,"shaftLetter":"h","shaftGrade":6}}}"#,
                             #"{"pageID":"<page uuid>","kind":"diameter","instanceID":"<instance uuid>","modelPoints":[[0,0,0],[20,0,0]]}"#]),
        Operation(kind: "drawing", action: "updateDimension", mutating: true,
                  summary: "Move one manual dimension's text or override its label; geometry follows the bound part.",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("dimensionID", "uuid", required: true),
                      arg("textPosition", "[x,y]", note: "drawing mm"),
                      arg("text", "string", note: "label override"),
                      arg("tolerance", "object | null", note: "structured tolerance object (same shape as addDimension) or null to clear"),
                  ],
                  examples: [#"{"pageID":"<page uuid>","dimensionID":"<dimension uuid>","textPosition":[30,15]}"#,
                             #"{"pageID":"<page uuid>","dimensionID":"<dimension uuid>","tolerance":{"kind":"symmetric","deviationMM":0.05}}"#]),
        Operation(kind: "drawing", action: "removeDimension", mutating: true,
                  summary: "Remove one manual dimension from a page.",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("dimensionID", "uuid", required: true),
                  ],
                  examples: [#"{"pageID":"<page uuid>","dimensionID":"<dimension uuid>"}"#]),
        Operation(kind: "drawing", action: "addAnnotation", mutating: true,
                  summary: "Add a text annotation; optional instance binding keeps it on the part as the view moves.",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("text", "string", required: true, note: "non-empty, <= 500 characters"),
                      arg("position", "[x,y]", required: true, note: "view mm"),
                      arg("heightMM", "number", note: "text height in [0.5, 50]; default 3.5"),
                      arg("instanceID", "uuid", note: "bind the annotation to a live assembly instance"),
                      arg("viewID", "uuid", note: "required on a multi-view sheet; position is view-local"),
                  ],
                  examples: [#"{"pageID":"<page uuid>","text":"Apply torque 12 N·m","position":[30,20]}"#]),
        Operation(kind: "drawing", action: "updateAnnotation", mutating: true,
                  summary: "Update one text annotation's text, position or height.",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("annotationID", "uuid", required: true),
                      arg("text", "string", note: "non-empty, <= 500 characters"),
                      arg("position", "[x,y]", note: "drawing mm; rebinds to the part when bound"),
                      arg("heightMM", "number", note: "in [0.5, 50]"),
                  ],
                  examples: [#"{"pageID":"<page uuid>","annotationID":"<annotation uuid>","heightMM":4.5}"#]),
        Operation(kind: "drawing", action: "removeAnnotation", mutating: true,
                  summary: "Remove one text annotation from a page.",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("annotationID", "uuid", required: true),
                  ],
                  examples: [#"{"pageID":"<page uuid>","annotationID":"<annotation uuid>"}"#]),
        Operation(kind: "drawing", action: "addManufacturingAnnotation", mutating: true,
                  summary: "Add one structured manufacturing annotation: datum feature, feature-control frame, "
                    + "surface finish, weld, or a thread/counterbore callout bound to a live mechanical hole. "
                    + "Free text is not a substitute for these records.",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("kind", "string", required: true, note: "datumFeature | featureControlFrame | surfaceFinish | weld | threadCallout | counterboreCallout"),
                      arg("position", "[x,y]", required: true, note: "view-local annotation box anchor in mm"),
                      arg("heightMM", "number", note: "in [0.5, 50]; default 3.0"),
                      arg("viewID", "uuid", note: "required on a multi-view sheet"),
                      arg("feature", "object", note: "dimensionCandidates reference; REQUIRED for threadCallout and counterboreCallout, optional for the other kinds"),
                      arg("datum", "object", note: "{letter:'A'…'Z', leaderTarget?} for datumFeature"),
                      arg("featureControlFrame", "object", note: "{characteristic, toleranceMM, diameterZone?, materialCondition?, datumReferences?, leaderTarget?}"),
                      arg("surfaceFinish", "object", note: "{raMicrometres, machiningMethod?, allAround?}"),
                      arg("weld", "object", note: "{type, sizeMM, lengthMM?, pitchMM?, allAround?, fieldWeld?, tailNote?, leaderTarget?}"),
                      arg("thread", "object", note: "{designation, pitchMM?, threadClass?, handedness?, through?, depthMM?, leaderTarget?}; checked against the linked hole pilot/nominal/tap-drill diameter"),
                      arg("counterbore", "object", note: "{leaderTarget?}; diameter/depth are read from the linked counterbore hole, never authored here"),
                  ],
                  examples: [
                      #"{"pageID":"<page uuid>","kind":"threadCallout","position":[30,20],"feature":{"bodyID":"<body uuid>","featureID":"<feature uuid>","anchor":{"centroid":[50,30,5],"direction":[0,0,1]}},"thread":{"designation":"M6","pitchMM":1.0,"threadClass":"6H","through":true}}"#,
                      #"{"pageID":"<page uuid>","kind":"featureControlFrame","position":[40,25],"feature":{"bodyID":"<body uuid>","anchor":{"centroid":[50,30,5],"direction":[0,0,1]}},"featureControlFrame":{"characteristic":"position","toleranceMM":0.2,"diameterZone":true,"datumReferences":[{"letter":"A"},{"letter":"B"}]}}"#,
                  ]),
        Operation(kind: "drawing", action: "updateManufacturingAnnotation", mutating: true,
                  summary: "Update one manufacturing annotation's position, height, source feature or structured payload.",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("annotationID", "uuid", required: true),
                      arg("position", "[x,y]", note: "view-local mm"),
                      arg("heightMM", "number", note: "in [0.5, 50]"),
                      arg("feature", "object | null", note: "replace or clear the linked source"),
                      arg("datum", "object"), arg("featureControlFrame", "object"),
                      arg("surfaceFinish", "object"), arg("weld", "object"),
                      arg("thread", "object"), arg("counterbore", "object"),
                  ],
                  examples: [#"{"pageID":"<page uuid>","annotationID":"<annotation uuid>","position":[32,22]}"#,
                             #"{"pageID":"<page uuid>","annotationID":"<annotation uuid>","thread":{"designation":"M6","pitchMM":1.0,"threadClass":"6H","through":true}}"#]),
        Operation(kind: "drawing", action: "removeManufacturingAnnotation", mutating: true,
                  summary: "Remove one manufacturing annotation from a page.",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("annotationID", "uuid", required: true),
                  ],
                  examples: [#"{"pageID":"<page uuid>","annotationID":"<annotation uuid>"}"#]),
        Operation(kind: "drawing", action: "listTemplates", mutating: false,
                  summary: "List the built-in first/third-angle presets and the document's saved sheet templates "
                    + "(frame, title block, revision rows, projection, units, precision, style).",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "drawing", action: "createTemplate", mutating: true,
                  summary: "Create one editable named sheet template in the document collection.",
                  arguments: [
                      arg("name", "string", required: true, note: "1…80 characters"),
                      arg("paper", "string", note: "a4 | a3 | a2 | a1 | a0 | letter | tabloid | custom; default a3"),
                      arg("customWidthMM", "number"), arg("customHeightMM", "number"),
                      arg("projection", "string", note: "firstAngle | thirdAngle; default thirdAngle"),
                      arg("units", "string", note: "millimetre | centimetre | inch; display only"),
                      arg("precision", "integer", note: "0…4; default 2"),
                      arg("style", "object", note: "{marginMM?, titleBlockWidthMM?, titleBlockHeightMM?, lineWidthMM?, textHeightMM?, showZoneGrid?}"),
                      arg("titleBlock", "object", note: "{company?, drawingNumber?}"),
                      arg("revisionRows", "[object]", note: "[{id?, revision, date?, description, approvedBy?}]; at most 6"),
                  ],
                  examples: [#"{"name":"Company A3 first angle","paper":"a3","projection":"firstAngle","units":"millimetre","precision":2,"revisionRows":[{"revision":"A","date":"2026-11-01","description":"Initial release"}]}"#]),
        Operation(kind: "drawing", action: "updateTemplate", mutating: true,
                  summary: "Edit a saved template; built-in presets are read-only (copy one first). "
                    + "Applied pages keep their independent snapshot.",
                  arguments: [
                      arg("templateID", "uuid", required: true, note: "alias id"),
                      arg("name", "string"), arg("paper", "string"),
                      arg("customWidthMM", "number"), arg("customHeightMM", "number"),
                      arg("projection", "string"), arg("units", "string"),
                      arg("precision", "integer"), arg("style", "object"),
                      arg("titleBlock", "object"), arg("revisionRows", "[object]"),
                  ],
                  examples: [#"{"templateID":"<template uuid>","precision":3,"revisionRows":[{"revision":"B","date":"2026-11-02","description":"Tolerance update"}]}"#]),
        Operation(kind: "drawing", action: "copyTemplate", mutating: true,
                  summary: "Copy a built-in or saved template into an editable saved template.",
                  arguments: [
                      arg("templateID", "uuid", required: true, note: "source template or built-in preset id"),
                      arg("name", "string", note: "copy name; defaults to '<source> Copy'"),
                  ],
                  examples: [#"{"templateID":"<template uuid>","name":"Plant B A3"}"#]),
        Operation(kind: "drawing", action: "applyTemplate", mutating: true,
                  summary: "Apply ONE template to selected pages in a single undoable drawing transaction. "
                    + "Page ids, views, source bindings and annotations are preserved; frame/title block/revision rows/"
                    + "projection/units/precision/style are copied and snapshotted per page.",
                  arguments: [
                      arg("templateID", "uuid", required: true, note: "saved or built-in template id"),
                      arg("pageIDs", "[uuid]", required: true, note: "1…64 page ids; all must exist or the batch is refused"),
                  ],
                  examples: [#"{"templateID":"<template uuid>","pageIDs":["<page 1>","<page 2>"]}"#]),
        Operation(kind: "drawing", action: "deleteTemplate", mutating: true,
                  summary: "Delete one saved template. Applied pages keep their snapshot; built-ins cannot be deleted.",
                  arguments: [arg("templateID", "uuid", required: true, note: "alias id")],
                  examples: [#"{"templateID":"<template uuid>"}"#]),
        Operation(kind: "drawing", action: "pages", mutating: false,
                  summary: "List pages with id/kind/paper/scale plus stale/missing-source state, "
                    + "assembly/BOM counters and annotation binding issues.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "drawing", action: "project", mutating: false,
                  summary: "Real projected 2D geometry for one page (outline/edges/section/detail), "
                    + "manual dimensions, balloons, annotations and the pinned source fingerprint.",
                  arguments: [arg("pageID", "uuid", required: true, note: "alias id")],
                  examples: [#"{"pageID":"<page uuid>"}"#]),
        Operation(kind: "drawing", action: "dimensions", mutating: false,
                  summary: "Computed dimensions/centerlines for one page.",
                  arguments: [arg("pageID", "uuid", required: true, note: "alias id")],
                  examples: [#"{"pageID":"<page uuid>"}"#]),
        Operation(kind: "drawing", action: "export", mutating: false,
                  summary: "Export one page as pdf/svg/dxf vector, png raster, or the COMPLETE BOM table as UTF-8 RFC 4180 CSV (base64 + sha256 in the reply).",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("format", "string", required: true, note: "pdf | svg | dxf | png | csv"),
                  ],
                  examples: [#"{"pageID":"<page uuid>","format":"pdf"}"#,
                             #"{"pageID":"<page uuid>","format":"dxf"}"#,
                             #"{"pageID":"<page uuid>","format":"csv"}"#]),
    ]

    private static let assemblyOperations: [Operation] = [
        Operation(kind: "assembly", action: "addInstance", mutating: true,
                  summary: "Place a body as an assembly instance (shared reference or independent copy).",
                  arguments: [
                      arg("bodyID", "uuid", required: true),
                      arg("transform", "object", note: "{\"position\":[x,y,z] mm,\"rotation\":[x,y,z,w] quaternion,\"scale\":[s,s,s] uniform positive}; default identity"),
                      arg("independentCopy", "boolean", note: "default false; true duplicates the body"),
                      arg("name", "string"),
                  ],
                  examples: [#"{"bodyID":"<body uuid>","transform":{"position":[0,0,0]},"name":"Part 1"}"#,
                             #"{"bodyID":"<body uuid>","transform":{"position":[60,0,0],"rotation":[0,0,0,1]}}"#]),
        Operation(kind: "assembly", action: "addConstraint", mutating: true,
                  summary: "Add an assembly constraint between two instances (or ground one); "
                    + "live-picked face/edge references are verified against the current revision.",
                  arguments: [
                      arg("kind", "string", required: true, note: "fixed | coaxial | planarAlign | distance | angle | hinge | slider"),
                      arg("instanceA", "uuid", required: true),
                      arg("instanceB", "uuid", note: "required for every kind except fixed"),
                      arg("parentID", "uuid", note: "optional subassembly instance; both instances must be its direct children; omitted = root scope"),
                      arg("referenceA", "object", note: "assembly.reference reply for A: {point, direction, source_revision?, fence?, source?}"),
                      arg("referenceB", "object", note: "assembly.reference reply for B"),
                      arg("faceA", "object", note: "{index, query_token? | signature?} kernel face for A"),
                      arg("edgeA", "object", note: "{index, query_token?} kernel edge for A"),
                      arg("faceB", "object", note: "{index, query_token? | signature?} kernel face for B"),
                      arg("edgeB", "object", note: "{index, query_token?} kernel edge for B"),
                      arg("pointA", "[x,y,z]"), arg("pointB", "[x,y,z]"),
                      arg("directionA", "[x,y,z]", note: "required for coaxial/planarAlign/angle/hinge/slider unless referenceA/faceA/edgeA is given"),
                      arg("directionB", "[x,y,z]", note: "required for coaxial/planarAlign/angle/hinge/slider unless referenceB/faceB/edgeB is given"),
                      arg("value", "number", note: "distance mm >=0; angle degrees 0...180; hinge signed degrees -180...180; slider signed mm. Omitted joint value is free inside limits."),
                      arg("lowerLimit", "number", note: "optional joint lower travel limit in joint units"),
                      arg("upperLimit", "number", note: "optional joint upper travel limit in joint units"),
                  ],
                  examples: [#"{"kind":"fixed","instanceA":"<instance uuid>"}"#,
                             #"{"kind":"distance","instanceA":"<instance uuid>","instanceB":"<instance uuid>","pointA":[0,0,0],"pointB":[0,0,0],"value":80}"#,
                             #"{"kind":"coaxial","instanceA":"<instance uuid>","instanceB":"<instance uuid>","directionA":[0,0,1],"directionB":[0,0,1]}"#,
                             #"{"kind":"planarAlign","instanceA":"<instance uuid>","instanceB":"<instance uuid>","referenceA":{"point":[0,0,0],"direction":[0,0,1],"source_revision":1,"fence":{"document_revision":1,"change_count":0}},"faceB":{"index":0,"query_token":"<query token>"}}"#]),
        Operation(kind: "assembly", action: "updateConstraint", mutating: true,
                  summary: "Edit one EXISTING assembly constraint in place, keeping its id, kind, "
                    + "instance scope and (unless re-picked) its geometry references and revision pins. "
                    + "The edited value and the solved placements commit as ONE undo step; an edit "
                    + "that would make the constraints unsatisfiable is refused without writing anything. "
                    + "A fixed constraint has no editable value or geometry reference.",
                  arguments: [
                      arg("id", "uuid", required: true, note: "constraint id from report/dof"),
                      arg("value", "number | null", note: "distance/angle or signed hinge degrees/slider mm; null releases joint drive, retaining limits"),
                      arg("lowerLimit", "number | null", note: "joint limit; null removes this bound"),
                      arg("upperLimit", "number | null", note: "joint limit; null removes this bound"),
                      arg("expectedValue", "number", note: "optional CAS fence: refuse if the stored value differs"),
                      arg("pointA", "[x,y,z]", note: "replacement local reference point on A (mm)"),
                      arg("directionA", "[x,y,z]", note: "replacement local axis/normal on A (non-zero)"),
                      arg("pointB", "[x,y,z]", note: "replacement local reference point on B (mm)"),
                      arg("directionB", "[x,y,z]", note: "replacement local axis/normal on B (non-zero)"),
                      arg("referenceA", "object", note: "fresh assembly.reference reply for A; re-pins sourceRevisionA"),
                      arg("referenceB", "object", note: "fresh assembly.reference reply for B; re-pins sourceRevisionB"),
                      arg("faceA", "object", note: "{index, query_token? | signature?} kernel face for A"),
                      arg("edgeA", "object", note: "{index, query_token?} kernel edge for A"),
                      arg("faceB", "object", note: "{index, query_token? | signature?} kernel face for B"),
                      arg("edgeB", "object", note: "{index, query_token?} kernel edge for B"),
                  ],
                  examples: [#"{"id":"<constraint uuid>","value":15}"#,
                             #"{"id":"<constraint uuid>","value":15,"expectedValue":10}"#,
                             #"{"id":"<constraint uuid>","referenceB":{"point":[0,0,20],"direction":[0,0,1],"fence":{"document_revision":1,"change_count":0}}}"#]),
        Operation(kind: "assembly", action: "removeInstance", mutating: true,
                  summary: "Remove one instance (a shared source body is never deleted).",
                  arguments: [arg("id", "uuid", required: true, note: "instance id from report/instances")],
                  examples: [#"{"id":"<instance uuid>"}"#]),
        Operation(kind: "assembly", action: "setTransform", mutating: true,
                  summary: "Replace one instance's placement.",
                  arguments: [
                      arg("id", "uuid", required: true),
                      arg("transform", "object", required: true, note: "position/rotation/scale as in addInstance"),
                  ],
                  examples: [#"{"id":"<instance uuid>","transform":{"position":[120,0,0]}}"#]),
        Operation(kind: "assembly", action: "setVisible", mutating: true,
                  summary: "Show or hide one instance.",
                  arguments: [arg("id", "uuid", required: true), arg("hidden", "boolean", required: true)],
                  examples: [#"{"id":"<instance uuid>","hidden":true}"#]),
        Operation(kind: "assembly", action: "removeConstraint", mutating: true,
                  summary: "Remove one constraint.",
                  arguments: [arg("id", "uuid", required: true, note: "constraint id")],
                  examples: [#"{"id":"<constraint uuid>"}"#]),
        Operation(kind: "assembly", action: "suppressConstraint", mutating: true,
                  summary: "Suppress or re-activate one constraint.",
                  arguments: [arg("id", "uuid", required: true), arg("suppressed", "boolean", required: true)],
                  examples: [#"{"id":"<constraint uuid>","suppressed":true}"#]),
        Operation(kind: "assembly", action: "solve", mutating: true,
                  summary: "Run the projection solver and rewrite instance placements.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "assembly", action: "sourceUpdate", mutating: true,
                  summary: "Detect or apply source-part revisions on the placed instances.",
                  arguments: [arg("apply", "boolean", note: "default false = detect only")],
                  examples: [#"{"apply":true}"#]),
        Operation(kind: "assembly", action: "clear", mutating: true,
                  summary: "Remove every instance and constraint.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "assembly", action: "reference", mutating: false,
                  summary: "Resolve one constraint reference in the instance frame: the live viewport selection "
                    + "(planar face normal, fitted cylinder axis or edge direction), an explicit kernel face/edge, "
                    + "or the instance reference point; returns the exact revision fence.",
                  arguments: [
                      arg("instanceID", "uuid", required: true, note: "alias id"),
                      arg("planeID", "uuid", note: "associate a construction plane instead of face/edge"),
                      arg("axisID", "uuid", note: "associate a construction axis instead of face/edge"),
                      arg("useSelection", "boolean", note: "default false; capture the live workbench selection now"),
                      arg("face", "object", note: "{index, query_token?, signature?} kernel planar/cylindrical face"),
                      arg("edge", "object", note: "{index, query_token?} kernel edge"),
                      arg("axisPreset", "[x,y,z]", note: "instance-local direction when no face/edge/selection is used; alias direction; default +Z"),
                  ],
                  examples: [#"{"instanceID":"<instance uuid>","useSelection":true}"#,
                             #"{"instanceID":"<instance uuid>","face":{"index":0,"query_token":"<query token>"}}"#]),
        Operation(kind: "assembly", action: "referenceCandidates", mutating: false,
                  summary: "List the instance's real planar/cylindrical faces and crease edges "
                    + "(point, direction, radius/length, stable signature, current query token).",
                  arguments: [
                      arg("instanceID", "uuid", required: true, note: "alias id"),
                      arg("scope", "string", note: "all | faces | edges; default all"),
                  ],
                  examples: [#"{"instanceID":"<instance uuid>","scope":"all"}"#]),
        Operation(kind: "assembly", action: "explodedViews", mutating: false,
                  summary: "Saved exploded views with their entries and per-instance offsets, plus the transient preview state.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "assembly", action: "addExplodedView", mutating: true,
                  summary: "Save a named exploded view; only listed instances are displaced, "
                    + "and the stored base placements are never changed.",
                  arguments: [
                      arg("name", "string", required: true, note: "unique view name"),
                      arg("direction", "[x,y,z]", note: "world direction for entries without their own; default [1,1,1]"),
                      arg("distanceMM", "number", note: "default 40; >= 0"),
                      arg("entries", "[object]", note: "[{instanceID, direction?, distanceMM?, id?}]; unlisted instances stay at base"),
                      arg("instanceIDs", "[uuid]", note: "convenience alternative: uniform entries for these instances"),
                  ],
                  examples: [#"{"name":"Exploded A","direction":[1,1,1],"distanceMM":40,"entries":[{"instanceID":"<instance uuid>"}]}"#]),
        Operation(kind: "assembly", action: "updateExplodedView", mutating: true,
                  summary: "Update a saved exploded view in place; omitted fields keep their value.",
                  arguments: [
                      arg("id", "uuid", required: true, note: "alias viewID"),
                      arg("name", "string"), arg("direction", "[x,y,z]"),
                      arg("distanceMM", "number", note: ">= 0"),
                      arg("entries", "[object]", note: "[{instanceID, direction?, distanceMM?, id?}]"),
                      arg("instanceIDs", "[uuid]", note: "convenience alternative: uniform entries for these instances"),
                  ],
                  examples: [#"{"id":"<exploded view uuid>","distanceMM":60}"#]),
        Operation(kind: "assembly", action: "removeExplodedView", mutating: true,
                  summary: "Remove a saved exploded view; an active preview of that view is reset.",
                  arguments: [arg("id", "uuid", required: true, note: "alias viewID")],
                  examples: [#"{"id":"<exploded view uuid>"}"#]),
        Operation(kind: "assembly", action: "previewExplodedView", mutating: false,
                  summary: "Transiently display a saved exploded view in the viewport and presentation snapshot; "
                    + "nothing is written, added to undo or marked dirty.",
                  arguments: [arg("id", "uuid", required: true, note: "alias viewID")],
                  examples: [#"{"id":"<exploded view uuid>"}"#]),
        Operation(kind: "assembly", action: "resetExplodedView", mutating: false,
                  summary: "Clear the transient exploded preview and return every instance to its saved placement.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "assembly", action: "partMetadata", mutating: false,
                  summary: "Engineering part number/material/version for each stable part definition. "
                    + "Shared instances resolve one record; an explicit independent copy has its own.",
                  arguments: [
                      arg("instanceID", "uuid", note: "limit to the part definition this live instance places"),
                      arg("definitionID", "uuid", note: "stable part-definition id; alias partID"),
                  ],
                  examples: ["{}", #"{"instanceID":"<instance uuid>"}"#]),
        Operation(kind: "assembly", action: "setPartMetadata", mutating: true,
                  summary: "Set the shared engineering record for one part definition (part number, "
                    + "engineering material, explicit version) as ONE undoable assembly command; an "
                    + "independent copy keeps its own record.",
                  arguments: [
                      arg("instanceID", "uuid", note: "target the definition this live instance places; alias id"),
                      arg("definitionID", "uuid", note: "alternative stable part-definition id; alias partID"),
                      arg("partNumber", "string", note: "<= 64 characters; empty clears"),
                      arg("material", "string", note: "engineering material, not PBR appearance; <= 64; empty clears"),
                      arg("version", "string", note: "explicit revision label; <= 32; empty clears"),
                  ],
                  examples: [#"{"instanceID":"<instance uuid>","partNumber":"PN-100","material":"6061-T6","version":"A"}"#]),
        Operation(kind: "assembly", action: "report", mutating: false,
                  summary: "Instances, constraints, stale-source and stale-reference state, "
                    + "exploded-preview state and totals.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "assembly", action: "instances", mutating: false,
                  summary: "The placed instances with their transforms.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "assembly", action: "dof", mutating: false,
                  summary: "Degrees-of-freedom model (kinematic rank, per-instance DOF, redundant constraints).",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "assembly", action: "interference", mutating: false,
                  summary: "Selected-instance all-pairs inspection with COMPLETE pair details. A "
                    + "subassembly id expands to its drawable parts; every requested pair is "
                    + "processed exactly once with real service-owned progress, cancellation and a "
                    + "revision/change-count stale fence. B-rep pairs use the exact OCCT common "
                    + "volume in mm³; other pairs use real triangle surface distance/contact/"
                    + "containment in mm (AABB is broadphase only). All four detail arrays are "
                    + "returned in full under a 6 MiB result envelope; the runtime's existing "
                    + "capture/paging presents that same retained text when a model window is "
                    + "smaller. A result that cannot fit refuses atomically with "
                    + "result_too_large instead of dropping completed rows.",
                  arguments: [
                      arg("toleranceMM", "number", note: "linear contact/clearance tolerance in mm; "
                          + "default 1e-6; never compared with a cubic volume"),
                      arg("volumeToleranceMM3", "number", note: "optional exact-common volume "
                          + "threshold in mm³; finite, non-negative; default 0 = any strictly "
                          + "positive common volume is penetrating. A positive volume below an "
                          + "explicit threshold is still reported with its actual volume and "
                          + "volumeBelowThreshold=true"),
                      arg("instanceIDs", "array", note: "optional leaf or subassembly instance uuids; "
                          + "omitted = every drawable occurrence, empty = no pairs; a subassembly "
                          + "expands to all of its drawable descendants"),
                  ],
                  examples: [
                      #"{"toleranceMM":0.001}"#,
                      #"{"instanceIDs":["<instance uuid>","<subassembly uuid>"],"toleranceMM":0.01,"volumeToleranceMM3":1.0}"#,
                  ]),
        Operation(kind: "assembly", action: "interferencePlan", mutating: false,
                  summary: "Resolve a selected instance/subassembly subset without running the check: "
                    + "returns the drawable leaf ids, selected names and all-pairs count. "
                    + "Uses the same selection expansion as assembly.interference.",
                  arguments: [arg("instanceIDs", "array", note: "optional leaf or subassembly uuids; "
                      + "omitted = every drawable occurrence, empty = none")],
                  examples: [#"{"instanceIDs":["<subassembly uuid>"]}"#]),
        Operation(kind: "assembly", action: "interferenceStatus", mutating: false,
                  summary: "Current service-owned progress of the active interference check "
                    + "(processed/requested pairs, classification counts, phase, cancellation).",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "assembly", action: "cancelInterference", mutating: false,
                  summary: "Request cancellation of the active interference check. The original "
                    + "caller receives cancelled only after the detached worker joins; no partial "
                    + "result is accepted.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "assembly", action: "motionStudy", mutating: false,
                  summary: "Drive one existing hinge/slider over a range; solve other parts from actual constraints, measure travel and optionally check exact interference per sample. Read-only, cancellable; no keyframes or document changes.",
                  arguments: [arg("id", "uuid", required: true), arg("from", "number", required: true),
                              arg("to", "number", required: true), arg("samples", "integer", note: "2...121, default21"),
                              arg("checkInterference", "boolean", note: "default true"),
                              arg("instanceIDs", "[uuid]", note: "optional interference subset")],
                  examples: [#"{"id":"<joint uuid>","from":-30,"to":60,"samples":21}"#]),
        Operation(kind: "assembly", action: "cancelMotionStudy", mutating: false,
                  summary: "Cancel the motion check and its worker. No partial result is accepted.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "assembly", action: "hierarchy", mutating: false,
                  summary: "Nested subassembly/instance tree, local constraints, stable BOM identities "
                    + "and structural integrity diagnostics. Never flattens or repairs the stored hierarchy.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "assembly", action: "references", mutating: false,
                  summary: "External native part references with pinned source version/hash, staged geometry hash, "
                    + "sharing counts, containing subassemblies and missing/update diagnosis. Cached geometry is reported, never dropped.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "assembly", action: "referenceDiagnostics", mutating: false,
                  summary: "Alias of references: persisted external-reference health and missing-source diagnosis.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "assembly", action: "addSubassembly", mutating: true,
                  summary: "Create an empty nested subassembly container at the root or inside another subassembly; "
                    + "its local constraints and child IDs are preserved independently.",
                  arguments: [
                      arg("name", "string", note: "defaults to Subassembly; unique among all instances"),
                      arg("parentID", "uuid", note: "optional existing subassembly instance; omitted = root"),
                      arg("transform", "object", note: "local placement; default identity"),
                  ],
                  examples: [#"{"name":"Gearbox"}"#,
                             #"{"name":"Stage 2","parentID":"<subassembly instance uuid>"}"#]),
        Operation(kind: "assembly", action: "placePartReference", mutating: true,
                  summary: "Place another shared occurrence of an already staged external part reference, "
                    + "optionally inside a subassembly or as an independent copy with its own geometry/material.",
                  arguments: [
                      arg("referenceID", "uuid", required: true),
                      arg("parentID", "uuid", note: "optional subassembly instance; omitted = root"),
                      arg("name", "string"),
                      arg("transform", "object"),
                      arg("independentCopy", "boolean", note: "default false; true owns a duplicated staged body"),
                  ],
                  examples: [#"{"referenceID":"<reference uuid>","parentID":"<subassembly instance uuid>"}"#,
                             #"{"referenceID":"<reference uuid>","independentCopy":true}"#]),
        Operation(kind: "assembly", action: "moveInstance", mutating: true,
                  summary: "Move an instance and its subtree under another subassembly or back to the root. "
                    + "Cycles and out-of-scope constraints are refused; instance/constraint IDs never change.",
                  arguments: [
                      arg("id", "uuid", required: true),
                      arg("parentID", "uuid", note: "null/omitted = root"),
                  ],
                  examples: [#"{"id":"<instance uuid>","parentID":"<subassembly instance uuid>"}"#,
                             #"{"id":"<instance uuid>","parentID":null}"#]),
        Operation(kind: "assembly", action: "removePartReference", mutating: true,
                  summary: "Remove a part reference only when no instance uses it; the cached staged body is retained.",
                  arguments: [arg("id", "uuid", required: true, note: "alias referenceID")],
                  examples: [#"{"id":"<reference uuid>"}"#]),
        Operation(kind: "assembly", action: "makeIndependent", mutating: true,
                  summary: "Convert one shared part instance into an independent copy in ONE undo step; "
                    + "the instance ID and every constraint/BOM reference stay unchanged, while geometry/material become owned.",
                  arguments: [arg("id", "uuid", required: true)],
                  examples: [#"{"id":"<instance uuid>"}"#]),
    ]

    private static let scriptOperations: [Operation] = [
        Operation(kind: "script", action: "put", mutating: true,
                  summary: "Create or update a stored ShapeScript record.",
                  arguments: [arg("source", "string", required: true, note: "<= 65536 bytes"),
                              arg("parameters", "object", note: "name -> number"),
                              arg("name", "string"), arg("id", "uuid", note: "update an existing record")],
                  examples: [#"{"source":"<ShapeScript text>","name":"Bracket script"}"#]),
        Operation(kind: "script", action: "remove", mutating: true,
                  summary: "Remove a stored script record (its output body is not deleted by this action).",
                  arguments: [arg("id", "uuid", required: true)],
                  examples: [#"{"id":"<script uuid>"}"#]),
        Operation(kind: "script", action: "apply", mutating: true,
                  summary: "Evaluate a stored or inline script and commit its output body.",
                  arguments: [arg("id", "uuid", note: "stored record; or supply source inline"),
                              arg("source", "string"), arg("name", "string"),
                              arg("parameters", "object"),
                              arg("conflict", "string", note: "auto | fork | rebuild; default auto"),
                              arg("expectedPreviewHash", "string"), arg("expectedChangeCount", "integer")],
                  examples: [#"{"id":"<script uuid>","conflict":"auto"}"#]),
        Operation(kind: "script", action: "list", mutating: false,
                  summary: "Stored script records with staleness/output state.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "script", action: "status", mutating: false,
                  summary: "The last evaluation result.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "script", action: "preview", mutating: false,
                  summary: "Evaluate without writing: bounded transient mesh + preview hash.",
                  arguments: [arg("id", "uuid"), arg("source", "string"), arg("parameters", "object")],
                  examples: [#"{"id":"<script uuid>"}"#]),
    ]

    private static let polygonMeshOperations: [Operation] = [
        Operation(kind: "mesh", action: "topology.create", mutating: true,
                  summary: "Create a polygon box with persistent vertex, edge and polygon-face identities.",
                  arguments: [arg("width", "number"), arg("height", "number"), arg("depth", "number")], examples: []),
        Operation(kind: "mesh", action: "topology.capture", mutating: true,
                  summary: "Capture actual polygon boundaries as a new stored control cage; explicit forceMesh is required for analytic solids.",
                  arguments: [arg("bodyID", "uuid", required: true), arg("forceMesh", "boolean")], examples: []),
        Operation(kind: "mesh", action: "topology.inspect", mutating: false,
                  summary: "Read stored cage identities, digest, modifier order and evaluated geometry counts.",
                  arguments: [arg("bodyID", "uuid", required: true)], examples: []),
        Operation(kind: "mesh", action: "topology.extrude", mutating: true,
                  summary: "Extrude a named control face outward; refuse self-overlap and preserve the original on failure.",
                  arguments: [arg("bodyID", "uuid", required: true), arg("cageDigest", "sha256", required: true), arg("faceID", "uuid", required: true), arg("distance", "number", required: true)], examples: []),
        Operation(kind: "mesh", action: "topology.loopCut", mutating: true,
                  summary: "Split the full quad edge ring by stable edge identity; triangles and poles refuse atomically.",
                  arguments: [arg("bodyID", "uuid", required: true), arg("cageDigest", "sha256", required: true), arg("edgeID", "uuid", required: true), arg("fraction", "number")], examples: []),
        Operation(kind: "mesh", action: "topology.inset", mutating: true,
                  summary: "Inset a convex planar control polygon with exact edge distance; refuse collapsing edges.",
                  arguments: [arg("bodyID", "uuid", required: true), arg("cageDigest", "sha256", required: true), arg("faceID", "uuid", required: true), arg("distance", "number", required: true)], examples: []),
        Operation(kind: "mesh", action: "topology.weld", mutating: true,
                  summary: "Weld selected nearby vertices to the first ID; reject broken manifold fans, reversed faces and opened closed cages.",
                  arguments: [arg("bodyID", "uuid", required: true), arg("cageDigest", "sha256", required: true), arg("vertexIDs", "[uuid]", required: true), arg("tolerance", "number", required: true)], examples: []),
        Operation(kind: "mesh", action: "modifier.add", mutating: true,
                  summary: "Add Catmull-Clark subdivision, boundary/outside-plane mirror or one convex right-angle bevel to the non-destructive stack.",
                  arguments: [arg("bodyID", "uuid", required: true), arg("cageDigest", "sha256", required: true), arg("kind", "subdivision | mirror | bevel", required: true), arg("levels", "integer"), arg("axis", "0 | 1 | 2"), arg("offset", "number"), arg("edgeID", "uuid"), arg("width", "number")], examples: []),
        Operation(kind: "mesh", action: "modifier.update", mutating: true,
                  summary: "Enable, disable or update a modifier; incompatible geometry/order keeps the old model.",
                  arguments: [arg("bodyID", "uuid", required: true), arg("cageDigest", "sha256", required: true), arg("modifierID", "uuid", required: true), arg("enabled", "boolean"), arg("kind", "subdivision | mirror | bevel"), arg("levels", "integer"), arg("axis", "integer"), arg("offset", "number"), arg("edgeID", "uuid"), arg("width", "number")], examples: []),
        Operation(kind: "mesh", action: "modifier.move", mutating: true,
                  summary: "Move a modifier to a zero-based position, preserving its identity and control cage.",
                  arguments: [arg("bodyID", "uuid", required: true), arg("cageDigest", "sha256", required: true), arg("modifierID", "uuid", required: true), arg("index", "integer", required: true)], examples: []),
        Operation(kind: "mesh", action: "modifier.remove", mutating: true,
                  summary: "Remove one modifier without changing the control cage.",
                  arguments: [arg("bodyID", "uuid", required: true), arg("cageDigest", "sha256", required: true), arg("modifierID", "uuid", required: true)], examples: []),
    ]

    private static let meshOperations: [Operation] = [
        Operation(kind: "mesh", action: "combine", mutating: true,
                  summary: "Combine bodies into one new body.",
                  arguments: [arg("bodyIDs", "[uuid]", required: true, note: "alias bodyID; <= 32 bodies"),
                              arg("name", "string")],
                  examples: [#"{"bodyIDs":["<body uuid>","<body uuid>"],"name":"Combined"}"#]),
        Operation(kind: "mesh", action: "boolean", mutating: true,
                  summary: "Mesh boolean (union/subtract/intersect) when the exact kernel path is not used.",
                  arguments: [arg("op", "string", required: true, note: "union | subtract | intersect"),
                              arg("target", "uuid", required: true), arg("tools", "[uuid]", required: true),
                              arg("forceMesh", "boolean", note: "required to downgrade analytic B-rep bodies")],
                  examples: [#"{"op":"subtract","target":"<body uuid>","tools":["<body uuid>"],"forceMesh":true}"#]),
        Operation(kind: "mesh", action: "transform", mutating: true,
                  summary: "Translate/rotate/scale one body.",
                  arguments: [arg("bodyID", "uuid", required: true), arg("translate", "[x,y,z]"),
                              arg("rotate", "object"), arg("scale", "number | [x,y,z]"),
                              arg("forceMesh", "boolean")],
                  examples: [#"{"bodyID":"<body uuid>","translate":[10,0,0]}"#]),
        Operation(kind: "mesh", action: "recomputeNormals", mutating: true,
                  summary: "Recompute render normals.",
                  arguments: [arg("bodyIDs", "[uuid]", note: "alias bodyID"), arg("forceMesh", "boolean")],
                  examples: [#"{"bodyID":"<body uuid>","forceMesh":true}"#]),
        Operation(kind: "mesh", action: "repair", mutating: true,
                  summary: "Clean up welded vertices/degenerate triangles and inspect remaining defects. repairComplete is false while defects remain. Specific unsupported defect repairs refuse without mutation; recomputeNormals does not fix triangle winding.",
                  arguments: [arg("bodyIDs", "[uuid]", note: "alias bodyID"),
                              arg("tolerance", "number"), arg("forceMesh", "boolean"),
                              arg("defect", "cleanup | holes | selfIntersections | orientation | nonManifold | all", note: "default cleanup preserves legacy weld/degenerate cleanup; specific repairs inspect first and explicitly refuse unsupported defects")],
                  examples: [#"{"bodyID":"<body uuid>","tolerance":0.01,"forceMesh":true}"#]),
        Operation(kind: "mesh", action: "simplify", mutating: true,
                  summary: "Simplify by ratio/tolerance while preserving open boundaries, UV/hard-edge seams and body materials. Returns actual achieved ratio and quality in preview/apply: bidirectional sampled surface/boundary deviations, a conservative surface-distance upper bound and signed-volume change. Samples are not exact Hausdorff or validated solid volume. Refuses topology changes and unsupported face-material remapping without mutation.",
                  arguments: [arg("bodyIDs", "[uuid]", note: "alias bodyID"),
                              arg("ratio", "number"), arg("tolerance", "number"),
                              arg("forceMesh", "boolean")],
                  examples: [#"{"bodyID":"<body uuid>","ratio":0.5,"forceMesh":true}"#]),
        Operation(kind: "mesh", action: "material", mutating: true,
                  summary: "Set material appearance on one body.",
                  arguments: [arg("bodyID", "uuid", required: true),
                              arg("color", "[r,g,b(,a)]", note: "0…1 components (canonical); #RRGGBB also accepted"),
                              arg("opacity", "number"), arg("metallic", "number"), arg("roughness", "number")],
                  examples: [##"{"bodyID":"<body uuid>","color":[0.53,0.6,0.67],"roughness":0.4}"##,
                             ##"{"bodyID":"<body uuid>","color":"#8899AA","roughness":0.4}"##]),
        Operation(kind: "mesh", action: "image", mutating: true,
                  summary: "Apply an image texture to a body.",
                  arguments: [arg("bodyID", "uuid"), arg("imageBase64", "string"), arg("imageID", "string")],
                  examples: [#"{"bodyID":"<body uuid>","imageID":"<workspace image id>"}"#]),
        Operation(kind: "mesh", action: "boundary", mutating: false,
                  summary: "Boundary/closure report for one or more bodies.",
                  arguments: [arg("bodyIDs", "[uuid]", note: "alias bodyID")],
                  examples: [#"{"bodyID":"<body uuid>"}"#]),
    ] + polygonMeshOperations

    /// Every known workbench operation, grouped by kind in declaration order.
    public static let operations: [Operation] =
        drawingOperations + assemblyOperations + scriptOperations + meshOperations

    /// Explicit, documented LEGACY alias normalization. These are the op
    /// spellings real callers already use; each maps to the engine action it
    /// has always meant. Nothing else is normalized — an unknown spelling is
    /// refused, never guessed.
    public static let documentedAliases: [String: String] = [
        "drawing.sheet": "drawing.standardSheet",
        "drawing.createSheet": "drawing.standardSheet",
        "assembly.placeInstance": "assembly.addInstance",
    ]

    /// SUGGESTIONS for a refused spelling. These are NEVER resolved — they only
    /// improve the refusal so a model that guessed (for example)
    /// `drawing.createPage` is pointed at the real action.
    public static let suggestions: [String: String] = [
        "createPage": "addPage", "newPage": "addPage", "createDrawing": "addPage",
        "deletePage": "removePage", "listPages": "pages", "getPages": "pages",
        "exportPage": "export", "addPart": "addInstance", "insert": "addInstance",
        "place": "addInstance", "removePart": "removeInstance",
        "transform": "setTransform", "constrain": "addConstraint", "solveConstraints": "solve",
        "ground": "addConstraint", "clearAssembly": "clear", "checkInterference": "interference",
    ]

    // MARK: Lookup

    public static func isKnownKind(_ kind: String) -> Bool {
        kinds.contains(kind)
    }

    public static func operations(forKind kind: String) -> [Operation] {
        operations.filter { $0.kind == kind }
    }

    public static func operation(kind: String, action: String) -> Operation? {
        operations.first { $0.kind == kind && $0.action == action }
    }

    public static func isMutating(kind: String, action: String) -> Bool {
        operation(kind: kind, action: action)?.mutating ?? false
    }

    /// The action names reachable for `kind`, in declaration order.
    public static func actionNames(forKind kind: String) -> [String] {
        operations(forKind: kind).map(\.action)
    }

    /// Resolves the canonical engine action for an explicit, documented op
    /// spelling. `.some(action)` means the spelling is recognized; `nil` means
    /// it is not (the caller refuses).
    public static func normalizedAction(kind: String, raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var candidate = trimmed
        if trimmed.contains(".") {
            let parts = trimmed.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == kind else { return nil }
            candidate = parts[1]
        }
        if let operation = operation(kind: kind, action: candidate) {
            return operation.action
        }
        if let canonical = documentedAliases["\(kind).\(candidate)"],
           let action = canonical.split(separator: ".").last,
           let operation = operation(kind: kind, action: String(action)) {
            return operation.action
        }
        return nil
    }

    public static func suggestion(for raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains(".") ? String(trimmed.split(separator: ".").last ?? "") : trimmed
        return suggestions[candidate]
    }

    // MARK: Resolution (the request contract)

    /// Resolves one service request payload into its canonical operation and
    /// flattened argument dictionary. Throws a `ResolutionFailure` for every
    /// malformed or unrecognized request; it never picks a default action.
    public static func resolve(kind: String, payload: [String: Any]) throws
        -> (operation: Operation, arguments: [String: Any]) {
        guard isKnownKind(kind) else {
            throw ResolutionFailure(
                code: "unknown_kind",
                message: "Unknown workbench service '\(kind)'. Known services: \(kinds.joined(separator: ", ")).")
        }
        let rawAction = payload["action"]
        let rawOp = payload["op"]
        if let rawAction, !(rawAction is NSNull), !(rawAction is String) {
            throw failure(kind: kind, code: "bad_action", detail: "payload.action must be a string.")
        }
        if let rawOp, !(rawOp is NSNull), !(rawOp is String) {
            throw failure(kind: kind, code: "bad_op", detail: "payload.op must be a string.")
        }
        let actionValue = (rawAction as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let opValue = (rawOp as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var canonical: String?
        if let actionValue, !actionValue.isEmpty {
            guard let resolved = normalizedAction(kind: kind, raw: actionValue) else {
                throw failure(kind: kind, code: "unknown_action",
                              detail: "Unknown \(kind) action '\(actionValue)'.",
                              suggestion: suggestion(for: actionValue))
            }
            canonical = resolved
        }
        if let opValue, !opValue.isEmpty {
            guard let resolved = normalizedAction(kind: kind, raw: opValue) else {
                throw failure(kind: kind, code: "unknown_op",
                              detail: "Unknown \(kind) operation '\(opValue)'.",
                              suggestion: suggestion(for: opValue))
            }
            if let canonical, canonical != resolved {
                throw failure(
                    kind: kind, code: "conflicting_selector",
                    detail: "payload.action '\(actionValue ?? "")' and payload.op '\(opValue)' name different "
                        + "\(kind) operations; send exactly one.")
            }
            canonical = resolved
        }
        guard let canonical, let operation = operation(kind: kind, action: canonical) else {
            throw failure(
                kind: kind, code: "missing_action",
                detail: "The \(kind) request needs payload.action (or the legacy payload.op).")
        }
        var arguments: [String: Any] = [:]
        for (key, value) in payload where key != "action" && key != "op" && key != "args" {
            arguments[key] = value
        }
        if let nested = payload["args"], !(nested is NSNull) {
            guard let object = nested as? [String: Any] else {
                throw failure(kind: kind, code: "bad_args",
                              detail: "payload.args must be a JSON object of operation arguments.")
            }
            for (key, value) in object {
                if let existing = arguments[key], !jsonEqual(existing, value) {
                    throw failure(
                        kind: kind, code: "conflicting_args",
                        detail: "Argument '\(key)' is defined twice with different values "
                            + "(payload and payload.args).")
                }
                arguments[key] = value
            }
        }
        return (operation, arguments)
    }

    private static func failure(kind: String, code: String, detail: String,
                                suggestion: String? = nil) -> ResolutionFailure {
        let ops = operations(forKind: kind)
        let mutating = ops.filter(\.mutating).map(\.action).joined(separator: ", ")
        let reading = ops.filter { !$0.mutating }.map(\.action).joined(separator: ", ")
        var message = detail
        if let suggestion {
            message += " Did you mean '\(suggestion)'?"
        }
        message += " Known \(kind) actions — mutating (call via propose with op \"\(kind).<action>\" then apply): "
            + "\(mutating). Read-only (call directly with payload.action): \(reading)."
            + " A payload with no recognizable action is refused, never defaulted to a read."
            + " Call action=capabilities kind=\"\(kind)\" for every argument and a runnable example."
        return ResolutionFailure(code: code, message: message)
    }

    private static func jsonEqual(_ left: Any, _ right: Any) -> Bool {
        switch (left, right) {
        case let (left as String, right as String): return left == right
        case let (left as NSNumber, right as NSNumber): return left == right
        case let (left as [Any], right as [Any]):
            return left.count == right.count && zip(left, right).allSatisfy { jsonEqual($0, $1) }
        case let (left as [String: Any], right as [String: Any]):
            return left.count == right.count
                && left.allSatisfy { key, value in right[key].map { jsonEqual(value, $0) } ?? false }
        case (_ as NSNull, _ as NSNull): return true
        default: return false
        }
    }

    // MARK: Capabilities (paged, on demand)

    /// Default page size for the on-demand operation detail. The tool schema
    /// stays small; the model asks for one kind at a time.
    public static let defaultPageSize = 8
    public static let maximumPageSize = 24

    /// The runtime gives a `cad.document` result at most 4096 characters
    /// (`AgentRuntime.executeToolCall`'s per-tool summary cap), so a reply that
    /// exceeds it arrives as a truncated JSON. Every model-facing capabilities
    /// reply built here stays inside this budget, shrinking the detail page
    /// (down to ONE operation) before it would ever emit broken JSON.
    public static let modelSummaryBudget = 4_000

    /// Compact catalog summary: per-kind counts plus the request contract. Used
    /// when the reply must stay small (it adds well under 400 characters to an
    /// engine reply that is already near the budget).
    public static func summaryJSON(compact: Bool = true) -> [String: Any] {
        var kindsJSON: [String: Any] = [:]
        for kind in kinds {
            let ops = operations(forKind: kind)
            if compact {
                kindsJSON[kind] = ops.count
            } else {
                kindsJSON[kind] = [
                    "count": ops.count,
                    "mutating": ops.filter(\.mutating).map(\.action),
                    "read_only": ops.filter { !$0.mutating }.map(\.action),
                ]
            }
        }
        if compact {
            // Deliberately tiny: a full engine capabilities reply is already
            // ~3.8 KB, and the model-visible summary cap is 4 KiB.
            return [
                "kinds": kindsJSON,
                "detail_hint": "Call capabilities with kind=drawing|assembly|script|mesh "
                    + "for exact arguments and examples.",
            ]
        }
        return [
            "kinds": kindsJSON,
            "note": "Service requests name exactly one action (payload.action, or the explicit legacy payload.op "
                + "\"<kind>.<action>\"). Mutating actions run through propose then apply; read-only actions are "
                + "callable directly. A payload with no recognizable action is refused, never defaulted to a read.",
            "detail_hint": "Call capabilities with kind=drawing|assembly|script|mesh for that service's exact "
                + "arguments and runnable examples.",
        ]
    }

    /// `service_operations` for the capabilities reply. With no kind this is
    /// the compact summary (kind → action names + effect split); with a kind it
    /// additionally carries one bounded page of arguments and examples.
    public static func capabilitiesJSON(detailKind: String? = nil,
                                        offset: Int = 0,
                                        limit: Int? = nil) throws -> [String: Any] {
        var reply: [String: Any] = summaryJSON(compact: detailKind == nil)
        guard let detailKind, !detailKind.isEmpty else { return reply }
        guard isKnownKind(detailKind) else {
            throw ResolutionFailure(
                code: "unknown_kind",
                message: "Unknown workbench service '\(detailKind)'. Known services: \(kinds.joined(separator: ", ")).")
        }
        let ops = operations(forKind: detailKind)
        let start = min(max(0, offset), ops.count)
        let size = min(max(1, limit ?? defaultPageSize), maximumPageSize)
        let page = Array(ops[start..<min(start + size, ops.count)])
        let next = start + page.count
        reply["detail"] = [
            "kind": detailKind,
            "offset": start,
            "limit": size,
            "total": ops.count,
            "next_offset": next < ops.count ? next : NSNull(),
            "operations": page.map(operationJSON),
        ]
        return reply
    }

    /// One operation as a JSON dictionary (arguments + examples).
    public static func operationJSON(_ operation: Operation) -> [String: Any] {
        [
            "action": operation.action,
            "op": operation.op,
            "mutating": operation.mutating,
            "call": operation.mutating ? "propose then apply" : "direct",
            "summary": operation.summary,
            "args": operation.arguments.map { argument -> [String: Any] in
                var row: [String: Any] = ["name": argument.name, "type": argument.type]
                if argument.required { row["required"] = true }
                if !argument.note.isEmpty { row["note"] = argument.note }
                return row
            },
            "examples": operation.examples,
        ]
    }

    /// Merges complete contracts into retained output. The runtime chooses
    /// what fits the real model window; only callers explicitly supplying a
    /// presentation budget request a smaller, still pageable contract.
    /// Returns the reply unchanged on any non-object input.
    public static func mergingCapabilities(into reply: String, detailKind: String?,
                                           offset: Int, limit: Int?,
                                           maximumCharacters: Int? = nil) -> String {
        guard let data = reply.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return reply
        }
        return mergingCapabilities(into: object, detailKind: detailKind, offset: offset,
                                   limit: limit, maximumCharacters: maximumCharacters)
    }

    public static func mergingCapabilities(into object: [String: Any], detailKind: String?,
                                           offset: Int, limit: Int?,
                                           maximumCharacters: Int? = nil) -> String {
        // The runtime owns the model's real context budget. A UI's 4 KiB
        // summary must not destroy the retained capabilities before paging.
        let budget = maximumCharacters.map { max(256, $0) } ?? Int.max
        func encoded(_ value: [String: Any]) -> String? {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        }
        if let detailKind, !detailKind.isEmpty {
            // A detail request is answered by a catalog-focused reply: the
            // engine matrix is large (≈3.8 KB on its own), so appending to it
            // could never stay parseable. The page shrinks until it fits.
            guard isKnownKind(detailKind), !operations(forKind: detailKind).isEmpty else {
                return encoded(object) ?? "{}"
            }
            let ops = operations(forKind: detailKind)
            let start = min(max(0, offset), ops.count)
            let requested = max(1, min(limit ?? defaultPageSize, maximumPageSize))
            for pageSize in stride(from: requested, through: 1, by: -1) {
                guard let catalog = try? capabilitiesJSON(detailKind: detailKind, offset: offset,
                                                          limit: pageSize) else { continue }
                let detailReply: [String: Any] = [
                    "ok": true,
                    "service_operations": catalog,
                    "engine_capabilities": "Call capabilities without kind for the full engine matrix; "
                        + "this reply serves the requested service's operation contract.",
                ]
                guard let text = encoded(detailReply) else { continue }
                if text.count <= budget { return text }
            }
            // Even one operation does not fit (should not happen): keep the
            // summary with an honest next_offset so the JSON stays parseable.
            var fallback = summaryJSON(compact: true)
            let nextOffset: Any = start < ops.count ? start : NSNull()
            fallback["detail"] = [
                "kind": detailKind,
                "offset": start,
                "limit": 0,
                "total": ops.count,
                "next_offset": nextOffset,
                "operations": [],
                "note": "The requested page exceeds the model-visible reply budget; request fewer operations.",
            ]
            return encoded(["ok": true, "service_operations": fallback]) ?? "{}"
        }
        var merged = object
        merged["service_operations"] = summaryJSON(compact: true)
        // Legacy host arrays are replaced, not merely supplemented by a
        // second contradictory list of callable actions.
        for kind in kinds { merged["\(kind)_actions"] = actionNames(forKind: kind) }
        merged["unavailable_actions"] = ["mesh.text": [
            "code": "text_mesh_unavailable",
            "alternative_op": "sketch.addText",
            "message": "This service has no standalone text-to-mesh operation. Its native text route is: propose "
                + "sketch.addText {sketchID,text,height,fontName?,origin?} → apply, then propose "
                + "feature.extrude on the resulting closed profiles. Text outlines are real native "
                + "sketch geometry (counter loops become holes) with ordinary revision, undo, save "
                + "and reopen."
        ]]
        if let text = encoded(merged), text.count <= budget { return text }
        // The engine reply alone is already at the budget: dropping the summary
        // keeps the JSON parseable instead of emitting a truncated object.
        merged["service_operations"] = nil
        return encoded(merged) ?? "{}"
    }
}

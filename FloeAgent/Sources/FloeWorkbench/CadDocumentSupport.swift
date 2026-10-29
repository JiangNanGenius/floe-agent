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

/// Action names the `material` and `parameters` tool actions accept. Kept in
/// the tool-support module so validation does not need a FloeCAD dependency;
/// the engine service remains the authority and returns a structured refusal
/// for anything it does not implement.
public enum CadNativeEditActions {
    public static let material: Set<String> = [
        "list", "read", "create", "update", "remove", "apply", "applyFaces",
        "reassignFaces", "mapping", "textures", "unresolved", "libraryExport",
        "libraryImport", "libraryList", "undo", "redo",
    ]
    public static let parameters: Set<String> = ["list", "update", "updateSketchEntity", "undo", "redo"]
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
        default: return nil
        }
    }

    /// Import formats recognized by the native kernel path, by exchange
    /// family. STEP/IGES carry exact B-rep solids; STL/OBJ/GLB/glTF are mesh
    /// exchanges imported as render/mesh bodies without a parametric
    /// history — the reply states which.
    public static let importExtensions: Set<String> =
        ["step", "stp", "iges", "igs", "stl", "obj", "glb", "gltf"]

    /// Formats the native kernel exports (the host validates against the
    /// output extension; IGES export is not available in this build).
    public static let exportExtensions: Set<String> =
        ["step", "stp", "stl", "obj", "3mf", "glb", "usdz", "pdf", "svg", "dxf"]
}

/// Per-format capability matrix advertised by the native `.floecad` surface.
/// View/edit describe whether imported geometry participates in the kernel
/// (exact solids vs render-only mesh bodies); export lists the formats that
/// geometry class can leave as. Kept explicit so the model never treats a
/// mesh import as a parametric solid or assumes feature history exists.
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
                  export: ["step", "stl", "obj", "3mf", "glb", "usdz", "pdf", "svg", "dxf"],
                  note: "Native parametric package created with the create action; "
                    + "never build the package by hand."),
        FormatRow(format: "step", aliases: ["stp"], geometryClass: "brep",
                  create: false, import: true, view: true, edit: true,
                  export: ["step", "stl", "obj", "3mf", "glb", "usdz"],
                  note: "Exact OCCT B-rep solids (AP214). Imported solids are editable; "
                    + "no parametric feature history is synthesized."),
        FormatRow(format: "iges", aliases: ["igs"], geometryClass: "brep",
                  create: false, import: true, view: true, edit: true,
                  export: ["step", "stl", "obj", "3mf", "glb", "usdz"],
                  note: "Surface exchange: closed solids import as exact B-rep bodies; "
                    + "shells/faces import as render-only bodies that cannot take boolean/fillet/shell. "
                    + "IGES export is not available in this build."),
        FormatRow(format: "stl", aliases: [], geometryClass: "mesh",
                  create: false, import: true, view: true, edit: false,
                  export: ["stl", "obj", "3mf", "glb", "usdz"],
                  note: "Triangle mesh imported as a render body; no parametric history "
                    + "and no boolean/fillet/shell on the imported body."),
        FormatRow(format: "obj", aliases: [], geometryClass: "mesh",
                  create: false, import: true, view: true, edit: false,
                  export: ["stl", "obj", "3mf", "glb", "usdz"],
                  note: "Wavefront mesh imported as render body(ies); loose .obj keeps "
                    + "its .mtl/texture siblings. No parametric history."),
        FormatRow(format: "glb", aliases: ["gltf"], geometryClass: "mesh",
                  create: false, import: true, view: true, edit: false,
                  export: ["glb", "stl", "obj", "3mf", "usdz"],
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
        Operation(kind: "drawing", action: "addPage", mutating: true,
                  summary: "Add one drawing page (front/top/side/iso/section/detail) projected from bodyIDs.",
                  arguments: [
                      arg("kind", "string", required: true, note: "front | top | side | iso | section | detail"),
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
                  ],
                  examples: [#"{"kind":"front","bodyIDs":["<body uuid>"]}"#,
                             #"{"kind":"iso","bodyIDs":["<body uuid>"],"scale":0.5,"paper":"a3","showDimensions":true}"#]),
        Operation(kind: "drawing", action: "updatePage", mutating: true,
                  summary: "Update one page in place; omitted fields keep the current value "
                    + "(kind defaults to the existing page kind).",
                  arguments: [arg("pageID", "uuid", required: true, note: "alias id")]
                    + [arg("kind", "string"), arg("bodyIDs", "[uuid]"), arg("name", "string"),
                       arg("title", "string"), arg("partNumbers", "[string]"), arg("scale", "number"),
                       arg("paper", "string"), arg("customWidthMM", "number"),
                       arg("customHeightMM", "number"), arg("viewNormal", "[x,y,z]"),
                       arg("viewUp", "[x,y,z]"), arg("sectionOrigin", "[x,y,z]"),
                       arg("sectionNormal", "[x,y,z]"), arg("detailOrigin", "[x,y,z]"),
                       arg("detailSizeMM", "number | [width,height]"),
                       arg("showDimensions", "boolean"), arg("showCenterlines", "boolean")],
                  examples: [#"{"pageID":"<page uuid>","scale":0.5,"showDimensions":true}"#]),
        Operation(kind: "drawing", action: "removePage", mutating: true,
                  summary: "Remove one page from the drawing set.",
                  arguments: [arg("pageID", "uuid", required: true, note: "alias id")],
                  examples: [#"{"pageID":"<page uuid>"}"#]),
        Operation(kind: "drawing", action: "pages", mutating: false,
                  summary: "List pages with id/kind/paper/scale plus stale/missing-source state.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "drawing", action: "project", mutating: false,
                  summary: "Real projected 2D geometry for one page (outline/edges/section/detail) "
                    + "and the pinned source fingerprint.",
                  arguments: [arg("pageID", "uuid", required: true, note: "alias id")],
                  examples: [#"{"pageID":"<page uuid>"}"#]),
        Operation(kind: "drawing", action: "dimensions", mutating: false,
                  summary: "Computed dimensions/centerlines for one page.",
                  arguments: [arg("pageID", "uuid", required: true, note: "alias id")],
                  examples: [#"{"pageID":"<page uuid>"}"#]),
        Operation(kind: "drawing", action: "export", mutating: false,
                  summary: "Vector export of one page as pdf, svg or dxf (base64 + sha256 in the reply).",
                  arguments: [
                      arg("pageID", "uuid", required: true, note: "alias id"),
                      arg("format", "string", required: true, note: "pdf | svg | dxf"),
                  ],
                  examples: [#"{"pageID":"<page uuid>","format":"pdf"}"#,
                             #"{"pageID":"<page uuid>","format":"dxf"}"#]),
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
                  summary: "Add an assembly constraint between two instances (or ground one).",
                  arguments: [
                      arg("kind", "string", required: true, note: "fixed | coaxial | planarAlign | distance | angle"),
                      arg("instanceA", "uuid", required: true),
                      arg("instanceB", "uuid", note: "required for every kind except fixed"),
                      arg("pointA", "[x,y,z]"), arg("pointB", "[x,y,z]"),
                      arg("directionA", "[x,y,z]", note: "required for coaxial/planarAlign/angle"),
                      arg("directionB", "[x,y,z]", note: "required for coaxial/planarAlign/angle"),
                      arg("value", "number", note: "distance in mm (>= 0) or angle in degrees [0, 180]"),
                  ],
                  examples: [#"{"kind":"fixed","instanceA":"<instance uuid>"}"#,
                             #"{"kind":"distance","instanceA":"<instance uuid>","instanceB":"<instance uuid>","pointA":[0,0,0],"pointB":[0,0,0],"value":80}"#,
                             #"{"kind":"coaxial","instanceA":"<instance uuid>","instanceB":"<instance uuid>","directionA":[0,0,1],"directionB":[0,0,1]}"#]),
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
        Operation(kind: "assembly", action: "report", mutating: false,
                  summary: "Instances, constraints, stale-source state and totals.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "assembly", action: "instances", mutating: false,
                  summary: "The placed instances with their transforms.",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "assembly", action: "dof", mutating: false,
                  summary: "Degrees-of-freedom model (kinematic rank, per-instance DOF, redundant constraints).",
                  arguments: [], examples: ["{}"]),
        Operation(kind: "assembly", action: "interference", mutating: false,
                  summary: "Exact pairwise interference through the kernel (<= 32 pairs, runs off the main actor).",
                  arguments: [arg("toleranceMM", "number", note: "default 1e-6")],
                  examples: [#"{"toleranceMM":0.001}"#]),
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
                  summary: "Repair a mesh body.",
                  arguments: [arg("bodyIDs", "[uuid]", note: "alias bodyID"),
                              arg("tolerance", "number"), arg("forceMesh", "boolean")],
                  examples: [#"{"bodyID":"<body uuid>","tolerance":0.01,"forceMesh":true}"#]),
        Operation(kind: "mesh", action: "simplify", mutating: true,
                  summary: "Simplify a mesh body by ratio/tolerance.",
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
        Operation(kind: "mesh", action: "text", mutating: true,
                  summary: "Create text geometry as a mesh body.",
                  arguments: [arg("text", "string", required: true), arg("size", "number"),
                              arg("position", "[x,y,z]"), arg("name", "string")],
                  examples: [#"{"text":"FLOE","size":10,"position":[0,0,0]}"#]),
        Operation(kind: "mesh", action: "image", mutating: true,
                  summary: "Apply an image texture to a body.",
                  arguments: [arg("bodyID", "uuid"), arg("imageBase64", "string"), arg("imageID", "string")],
                  examples: [#"{"bodyID":"<body uuid>","imageID":"<workspace image id>"}"#]),
        Operation(kind: "mesh", action: "boundary", mutating: false,
                  summary: "Boundary/closure report for one or more bodies.",
                  arguments: [arg("bodyIDs", "[uuid]", note: "alias bodyID")],
                  examples: [#"{"bodyID":"<body uuid>"}"#]),
    ]

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

    /// Merges the catalog into a capabilities reply. The `cad.document` runtime
    /// summary cap is respected: a detail request replaces the model-facing
    /// reply with the catalog page (shrunk page-by-page until it fits), and a
    /// plain request only adds the compact summary when the reply has room.
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
        let budget = max(256, maximumCharacters ?? modelSummaryBudget)
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
        if merged["service_operations"] == nil {
            merged["service_operations"] = summaryJSON(compact: true)
        }
        if let text = encoded(merged), text.count <= budget { return text }
        // The engine reply alone is already at the budget: dropping the summary
        // keeps the JSON parseable instead of emitting a truncated object.
        merged["service_operations"] = nil
        return encoded(merged) ?? "{}"
    }
}

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

// MARK: - Native package naming and creation/import policy

/// Shared policy for the native `.floecad` package surface (tool create/import
/// actions and the file-tree UI factory). The model never writes package
/// bytes and never guesses the internal manifest layout; this only guards the
/// document NAME and the workspace-relative location of a new package.
public enum NativeCADPolicy: Sendable {
    /// Package file extension (lowercased, without dot).
    public static let packageExtension = "floecad"

    /// Maximum length of a document stem after sanitization.
    public static let maximumStemLength = 120

    /// Characters allowed in a sanitized document stem, in addition to
    /// letters/numbers: space, dash, underscore, dot and parentheses. Anything
    /// else (path separators, control characters, leading dots) is replaced
    /// with a space so a model-supplied name can never traverse directories.
    private static let allowedStemCharacters: Set<Character> =
        Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_.()")

    /// Sanitizes a caller-supplied document name into a safe stem (no
    /// extension). Returns nil when nothing usable remains. Path separators,
    /// control characters and other unsafe letters are replaced with spaces,
    /// runs of whitespace collapsed, and the result is bounded and trimmed.
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
            if allowedStemCharacters.contains(character) { return character }
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

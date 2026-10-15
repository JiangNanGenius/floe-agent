// FloeTools — Typed mutable-target contract (single source of truth).
//
// The canonical `MutationTargetResolver` historically resolved mutation keys
// from generic argument shapes (`path` for `document.*`/`cad.*`, path verbs
// for `workspace.*`, a workspace wildcard for everything else). That left the
// ordinary document/media edit families — `document.pdf.edit`, the
// video/audio/image editors and `media.project` — on the workspace wildcard,
// so neither mutation coordination nor the approval policy could pin their
// REAL mutable outputs (a PDF `outputPath`, a video `output`, the media
// project's service-owned store record).
//
// This file is the typed contract those families resolve against. It declares,
// per registered tool, WHICH argument names a real mutable output, the role of
// that output, and the fixed documented default derivation used when the
// argument is absent. Three consumers share this ONE table, so permission
// classification, lease serialization and the runtime-authority canonical
// target can never disagree:
//
// - `MutationTargetResolver.resolve` builds lease/authority keys and the
//   `mutableTargets` classification from it (policy-visible write extent);
// - `RuntimeAuthorityDigest.canonicalTarget` consumes `resolve(...).keys`,
//   whose FIRST key keeps every existing consumer mirror intact (office and
//   CAD `file:<path>`, media.project `workspace:<root>`);
// - the deterministic approval carve-out classifies ONLY the mutable targets
//   listed here: a read-only source (`pdf inputPath`, office `imagePath`,
//   video/audio `input`, `mixPath`) never makes the call a repository write.
//
// Rules:
// - Read-only inputs are never listed; only outputs/rewrites/draft targets.
// - Every required target must resolve, or the WHOLE call is unresolved and
//   the resolver falls back to the workspace wildcard (existing policy).
// - Defaults replicate the tool/host's documented naming exactly
//   (`<name>.edited.<ext>`, `<name>-filled.pdf`, `<src>-edited.<ext>`,
//   `PDFRenders/`, `QRCode/`); a random-UUID default is NOT derivable and is
//   bounded to its documented directory instead of pretending a file path.
// - `media.project` records live in the app-owned `MediaProjectStore`
//   directory, addressed by `project_id`; the directory arrives as the
//   `serviceStorePaths` runtime input (same trusted-injection channel as the
//   workspace root). An absent store path fails closed.
// - Model arguments address targets; they never mint authority. Ownership,
//   revision/hash binding, replay and atomic commits stay in the tools/hosts.

import Foundation
import FloeModels

/// What a typed mutable target does to the bytes at its path.
public enum TypedMutableRole: String, Sendable, Hashable, Codable {
    /// A NEW file is written; the source bytes are preserved (PDF edit /
    /// fillForm / export / render copies, office automatic `<name>.edited`
    /// copy, video/audio outputs, image outputs, media project export).
    case outputWrite
    /// The file at this path — the source document/record itself — is
    /// rewritten in place under the tool's revision/hash binding (office
    /// grant apply, updateText, create*, media project apply).
    case sourceWrite
    /// The call writes NO original bytes: it stores or reads only internal
    /// draft state (office/media propose, cad propose/preview). The listed
    /// target is the workflow's declared mutable target, classified exactly
    /// like the commit that may follow it, so a repository original still
    /// keeps its review while the draft step itself needs no per-edit popup.
    case draftTarget
    /// Pinned by the legacy resolver without a role (tools this contract does
    /// not type, e.g. `cad.document` `path`, `workspace.*` path verbs).
    case pinned
}

/// What the contract does when a spec's argument is absent.
public enum TypedAbsentOutputRule: Sendable, Hashable {
    /// This spec contributes no target (another presence-conditional spec or
    /// the legacy fallback decides).
    case skip
    /// The argument is REQUIRED for the covered action; absent or
    /// unresolvable means the whole resolution is unresolved (fail closed).
    case required
    /// Absent → apply the tool's fixed default derivation.
    case derive(TypedOutputDerivation)
    /// Absent → the write set is bounded to the derived directory (used when
    /// the tool's default name contains a random component).
    case boundDirectory(TypedOutputDerivation)
}

/// Fixed default-output derivations, replicating the tools' documented naming.
public enum TypedOutputDerivation: Sendable, Hashable {
    /// Office automatic apply: `<source deleting extension>.edited.<sourceExt>`
    /// (absolute source → absolute result; relative source → same relative
    /// location under the workspace root).
    case editedCopySibling(sourceArgument: String)
    /// Office export: `<source>.export.<sourceExt>` (the source KEEPS its
    /// extension) under the workspace root.
    case exportAppendedSibling(sourceArgument: String)
    /// PDF fillForm: `<source deleting extension>-filled.pdf` beside the source.
    case filledPDFSibling(sourceArgument: String)
    /// image.process: `<source deleting extension>-edited.<ext>`; `ext` is the
    /// convert `format` (png/heic/jpg) for `operation=convert`, otherwise the
    /// source extension, defaulting to `jpg` when the source has none.
    case processedImageSibling(sourceArgument: String)
    /// cad.document export: `<dir>/<base|"drawing">.export.dxf` for a 2D
    /// drawing and `<dir>/<base|"part">.export.step` beside the package for a
    /// native `.floecad` document (the tool's documented defaults).
    case cadExportSibling(sourceArgument: String)
    /// media.project export: the REAL consumer output
    /// `Workbench/Exports/<file_name>.<ext>` under the project's recorded
    /// workspace (== the run workspace). `file_name` is a validated BASENAME
    /// (never a path), the extension is `mp4` for video and the requested
    /// `png`/`jpeg`/`heic` format for image; anything else fails closed.
    /// Derivation is shared with the tool (`MediaExportOutputContract`).
    case mediaExportOutput
    /// A fixed workspace-relative directory bounding every default output.
    case workspaceDirectory(relative: String)
}

/// One typed output declaration of the contract.
public struct TypedOutputSpec: Sendable, Hashable {
    /// Argument key that carries the output path (or `project_id` for
    /// service-store specs).
    public var argument: String
    public var role: TypedMutableRole
    public var whenAbsent: TypedAbsentOutputRule
    /// Set for service-owned store targets: the `serviceStorePaths` key whose
    /// value is the store's canonical root directory.
    public var storeKey: String?
    /// When set, the target is ALWAYS derived by this documented derivation;
    /// the argument is the derivation's INPUT (a basename inside a fixed
    /// directory), never a path, and a failed derivation leaves the whole
    /// call unresolved. Nil keeps the raw-argument path behavior.
    public var derivation: TypedOutputDerivation?

    public init(
        argument: String,
        role: TypedMutableRole,
        whenAbsent: TypedAbsentOutputRule,
        storeKey: String? = nil,
        derivation: TypedOutputDerivation? = nil
    ) {
        self.argument = argument
        self.role = role
        self.whenAbsent = whenAbsent
        self.storeKey = storeKey
        self.derivation = derivation
    }
}

/// One resolved mutable target: a canonical absolute path and its role.
public struct TypedMutableTarget: Sendable, Hashable {
    public var path: String
    public var role: TypedMutableRole

    public init(path: String, role: TypedMutableRole) {
        self.path = path
        self.role = role
    }
}

/// The typed mutable-target contract shared by mutation coordination, the
/// runtime-authority canonical target and the approval policy.
public enum TypedMutationContract {

    /// `serviceStorePaths` key for the app-owned media project store
    /// (`MediaProjectStore`, `media-project-<uuid>.json` records).
    public static let mediaProjectStoreKey = "mediaProject"

    /// Media project apply/export ALSO touches workspace-visible files
    /// (export `file_name`, staged assets referenced by relative paths), and
    /// its runtime-authority mirror expects the workspace key FIRST, so the
    /// bounding workspace key is preserved ahead of the typed store keys.
    /// Every other typed family fully bounds its write set and drops the
    /// wildcard for narrow file keys.
    public static func keepsWorkspaceBounding(_ toolName: String) -> Bool {
        toolName == "media.project"
    }

    // MARK: - Contract table

    /// The typed specs for one call. Action-gated: actions that only read or
    /// query return no specs and keep the legacy resolver behavior.
    public static func specs(
        for toolName: String,
        arguments: [String: Any]
    ) -> [TypedOutputSpec] {
        let action = (arguments["action"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch toolName {
        case "document.pdf.edit":
            // inputPath is read-only; the verified new copy is outputPath.
            return [.init(argument: "outputPath", role: .outputWrite, whenAbsent: .required)]

        case "document.pdf.fillForm":
            guard action == "fill" else { return [] } // list is read-only
            return [.init(argument: "outputPath", role: .outputWrite,
                          whenAbsent: .derive(.filledPDFSibling(sourceArgument: "inputPath")))]

        case "document.pdf.export":
            return [.init(argument: "outputPath", role: .outputWrite, whenAbsent: .required)]

        case "document.pdf.render":
            if let raw = arguments["outputPath"] as? String,
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Single explicit render target (validated page-only by tool).
                return [.init(argument: "outputPath", role: .outputWrite, whenAbsent: .required)]
            }
            // Default renders land in PDFRenders/ with random UUID names:
            // bound the directory instead of inventing file paths.
            return [.init(argument: "outputPath", role: .outputWrite,
                          whenAbsent: .boundDirectory(.workspaceDirectory(relative: "PDFRenders")))]

        case "document.office.updateText":
            // The package at `path` is rewritten in place under the exact
            // expected-sha256 binding; the tool reopens and verifies it.
            return [.init(argument: "path", role: .sourceWrite, whenAbsent: .required)]

        case "document.createWord", "document.createWorkbook",
             "document.presentation.createDeck":
            // A NEW package is written at `path` (non-overwriting factory).
            return [.init(argument: "path", role: .outputWrite, whenAbsent: .required)]

        case "cad.document":
            // CAD family (J-frozen tool): the package at `path` is the
            // document identity; export writes a separate copy at `output`
            // (default beside the source/package). Propose/three_d_propose
            // store a revision-bound draft only; import rewrites the package.
            switch action {
            case "create":
                return [.init(argument: "path", role: .outputWrite, whenAbsent: .required)]
            case "apply", "save", "three_d_apply", "import":
                return [.init(argument: "path", role: .sourceWrite, whenAbsent: .required)]
            case "propose", "three_d_propose", "preview":
                // Draft-only steps: no original bytes are written; classified
                // against the declared document like the commit that follows.
                return [.init(argument: "path", role: .draftTarget, whenAbsent: .required)]
            case "export":
                return [.init(argument: "output", role: .outputWrite,
                              whenAbsent: .derive(.cadExportSibling(sourceArgument: "path")))]
            default:
                return []
            }

        case "document.office.edit":
            switch action {
            case "replaceimage":
                // imagePath is a read-only source; the package at `path` is rewritten.
                return [.init(argument: "path", role: .sourceWrite, whenAbsent: .required)]
            case "apply":
                let grant = (arguments["grant_id"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !grant.isEmpty {
                    // UI-granted commit rewrites the document at `path`
                    // (output alongside grant_id is refused by the tool).
                    return [.init(argument: "path", role: .sourceWrite, whenAbsent: .required)]
                }
                // The automatic copy is addressed relative to the document at
                // `path`; without `path` the tool's own canonical target
                // stays the workspace root (the stored proposal's document is
                // authoritative), so the contract must NOT claim a file
                // target it cannot prove — the required `path` spec fails
                // closed to the unresolved wildcard.
                guard hasNonemptyString("path", in: arguments) else {
                    return [.init(argument: "path", role: .sourceWrite, whenAbsent: .required)]
                }
                // Runtime-authorized automatic copy publishes the verified
                // edited copy at `output` (default `<name>.edited.<ext>`);
                // the source is never modified.
                return [.init(argument: "output", role: .outputWrite,
                              whenAbsent: .derive(.editedCopySibling(sourceArgument: "path")))]
            case "export":
                // Export requires `path` (tool validation); without it the
                // call cannot be pinned and fails closed.
                guard hasNonemptyString("path", in: arguments) else {
                    return [.init(argument: "path", role: .sourceWrite, whenAbsent: .required)]
                }
                return [.init(argument: "output", role: .outputWrite,
                              whenAbsent: .derive(.exportAppendedSibling(sourceArgument: "path")))]
            case "propose":
                // Stores an internal proposal record only; classify the
                // declared document target like the apply that follows it.
                return [.init(argument: "path", role: .draftTarget, whenAbsent: .required)]
            default:
                return []
            }

        case "media.project":
            switch action {
            case "propose":
                return [.init(argument: "project_id", role: .draftTarget,
                              whenAbsent: .required, storeKey: mediaProjectStoreKey)]
            case "apply":
                // The service-owned project record is rewritten in place under
                // the proposal's revision binding; source assets are untouched.
                return [.init(argument: "project_id", role: .sourceWrite,
                              whenAbsent: .required, storeKey: mediaProjectStoreKey)]
            case "export":
                // The verified export file is written under the project's
                // recorded workspace (= this run's workspace, enforced by the
                // host's authorizeAccess) at
                // `Workbench/Exports/<file_name>.<ext>` — the derivation is
                // SHARED with the real tool (`MediaExportOutputContract`), and
                // `file_name` is a validated basename, never a path. An
                // invalid name / unknown kind / unsupported image format fails
                // closed instead of claiming a path the tool would reject.
                return [.init(argument: "export.file_name", role: .outputWrite,
                              whenAbsent: .skip, derivation: .mediaExportOutput)]
            default:
                return []
            }

        case "video.edit", "video.interpolate", "video.superResolution",
             "video.remux", "video.proxy", "video.transcode", "video.thumbnail",
             "audio.edit", "audio.convert", "audio.mix":
            // `input` (and audio.mix `mixPath`) are read-only sources.
            return [.init(argument: "output", role: .outputWrite, whenAbsent: .required)]

        case "video.extractFrames":
            // Every frame file is written inside the required outputDirectory.
            return [.init(argument: "outputDirectory", role: .outputWrite, whenAbsent: .required)]

        case "image.process":
            return [.init(argument: "outputPath", role: .outputWrite,
                          whenAbsent: .derive(.processedImageSibling(sourceArgument: "path")))]

        case "image.svgDocument":
            // The tool's schema key is `operation` (inspect/edit), never
            // `action`: reading the wrong key left every real edit call
            // untyped and back on the workspace wildcard.
            let svgOperation = (arguments["operation"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard svgOperation == "edit" else { return [] } // inspect is read-only
            return [.init(argument: "outputPath", role: .outputWrite, whenAbsent: .required)]

        case "image.qr.generate":
            if let raw = arguments["outputPath"] as? String,
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [.init(argument: "outputPath", role: .outputWrite, whenAbsent: .required)]
            }
            // Default name is QRCode/qr-<UUID>.png: bound the directory.
            return [.init(argument: "outputPath", role: .outputWrite,
                          whenAbsent: .boundDirectory(.workspaceDirectory(relative: "QRCode")))]

        default:
            return []
        }
    }

    // MARK: - Resolution

    /// Resolves the mutable targets for one call through the contract.
    /// Returns nil when ANY required target cannot be pinned — the caller
    /// must then treat the write extent as unresolved (workspace wildcard,
    /// existing approval policy). Never returns a partial list.
    ///
    /// `effectiveRootURL` is the root this call's relative paths are actually
    /// resolved against (for an authorized Canvas staged `cad.document` call:
    /// the staged draft root, mirroring the tool's `access.workspacePath`).
    /// Nil falls back to `workspaceRootURL`.
    public static func resolveMutableTargets(
        for toolName: String,
        arguments: [String: Any],
        workspaceRootURL: URL?,
        serviceStorePaths: [String: String],
        effectiveRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> [TypedMutableTarget]? {
        let specs = specs(for: toolName, arguments: arguments)
        guard !specs.isEmpty else { return [] }
        let root = effectiveRootURL ?? workspaceRootURL

        var targets: [TypedMutableTarget] = []
        for spec in specs {
            guard let resolved = resolveSpec(
                spec,
                toolName: toolName,
                arguments: arguments,
                workspaceRootURL: root,
                serviceStorePaths: serviceStorePaths,
                fileManager: fileManager
            ) else { return nil }
            if let resolved { targets.append(resolved) }
        }
        var seen = Set<String>()
        return targets.filter { seen.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
    }

    private static func resolveSpec(
        _ spec: TypedOutputSpec,
        toolName: String,
        arguments: [String: Any],
        workspaceRootURL: URL?,
        serviceStorePaths: [String: String],
        fileManager: FileManager
    ) -> TypedMutableTarget?? {
        if let storeKey = spec.storeKey {
            guard let storeRoot = serviceStorePaths[storeKey],
                  !storeRoot.isEmpty,
                  let rawID = stringArgument(spec.argument, in: arguments),
                  let projectID = UUID(uuidString: rawID.trimmingCharacters(in: .whitespacesAndNewlines))
            else { return nil } // unresolved
            let file = "media-project-\(projectID.uuidString.lowercased()).json"
            let path = URL(fileURLWithPath: storeRoot)
                .appendingPathComponent(file)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            return .some(TypedMutableTarget(path: path, role: spec.role))
        }

        if let derivation = spec.derivation {
            // The real consumer output is derived from the specification
            // (fixed directory + validated basename inside the export object),
            // never from a raw argument treated as a path.
            guard let path = derive(derivation, arguments: arguments,
                                    workspaceRootURL: workspaceRootURL,
                                    fileManager: fileManager)
            else { return nil } // derivation failed: unresolved (fail closed)
            return .some(TypedMutableTarget(path: path, role: spec.role))
        }

        let raw = stringArgument(spec.argument, in: arguments)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            guard let path = canonicalPath(trimmed, root: workspaceRootURL, fileManager: fileManager)
            else { return nil } // present but unresolvable: unresolved
            return .some(TypedMutableTarget(path: path, role: spec.role))
        }

        switch spec.whenAbsent {
        case .skip:
            return .some(nil)
        case .required:
            return nil // required argument missing: unresolved
        case .derive(let derivation):
            guard let path = derive(derivation, arguments: arguments,
                                    workspaceRootURL: workspaceRootURL,
                                    fileManager: fileManager)
            else { return nil }
            return .some(TypedMutableTarget(path: path, role: spec.role))
        case .boundDirectory(let derivation):
            guard let path = derive(derivation, arguments: arguments,
                                    workspaceRootURL: workspaceRootURL,
                                    fileManager: fileManager)
            else { return nil }
            return .some(TypedMutableTarget(path: path, role: spec.role))
        }
    }

    /// String argument lookup supporting one nested level (`export.file_name`
    /// for `media.project`'s export object).
    static func stringArgument(_ key: String, in arguments: [String: Any]) -> String? {
        if let value = arguments[key] as? String { return value }
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let nested = arguments[parts[0]] as? [String: Any] else { return nil }
        return nested[parts[1]] as? String
    }

    static func hasNonemptyString(_ key: String, in arguments: [String: Any]) -> Bool {
        guard let value = stringArgument(key, in: arguments) else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func derive(
        _ derivation: TypedOutputDerivation,
        arguments: [String: Any],
        workspaceRootURL: URL?,
        fileManager: FileManager
    ) -> String? {
        switch derivation {
        case .mediaExportOutput:
            guard let export = arguments["export"] as? [String: Any],
                  let kind = export["kind"] as? String,
                  let fileName = export["file_name"] as? String,
                  let relative = MediaExportOutputContract.relativeOutput(
                      kind: kind, fileName: fileName, format: export["format"] as? String)
            else { return nil }
            return canonicalPath(relative, root: workspaceRootURL, fileManager: fileManager)

        case .cadExportSibling(let sourceArgument):
            guard let source = stringArgument(sourceArgument, in: arguments)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty,
                source.utf8.count <= 4096
            else { return nil }
            let ns = source as NSString
            let isNative = ns.pathExtension.lowercased() == "floecad"
            let name = ns.lastPathComponent
            let base = (name as NSString).deletingPathExtension
            let directory = ns.deletingLastPathComponent
            let file = "\(base.isEmpty ? (isNative ? "part" : "drawing") : base).export."
                + (isNative ? "step" : "dxf")
            let relative = directory.isEmpty ? file : "\(directory)/\(file)"
            return canonicalPath(relative, root: workspaceRootURL, fileManager: fileManager)

        case .editedCopySibling(let sourceArgument):
            guard let source = stringArgument(sourceArgument, in: arguments),
                  let sourcePath = canonicalPath(source, root: workspaceRootURL, fileManager: fileManager)
            else { return nil }
            let ns = sourcePath as NSString
            let ext = ns.pathExtension
            guard !ext.isEmpty else { return nil }
            let base = ns.deletingPathExtension
            return base + ".edited." + ext

        case .exportAppendedSibling(let sourceArgument):
            guard let source = stringArgument(sourceArgument, in: arguments),
                  let sourcePath = canonicalPath(source, root: workspaceRootURL, fileManager: fileManager)
            else { return nil }
            let ns = sourcePath as NSString
            let ext = ns.pathExtension
            guard !ext.isEmpty else { return nil }
            // The export path keeps the source extension: report.docx →
            // report.docx.export.docx, resolved under the workspace root.
            let relative = source.trimmingCharacters(in: .whitespacesAndNewlines) + ".export." + ext
            return canonicalPath(relative, root: workspaceRootURL, fileManager: fileManager)

        case .filledPDFSibling(let sourceArgument):
            guard let source = stringArgument(sourceArgument, in: arguments),
                  let sourcePath = canonicalPath(source, root: workspaceRootURL, fileManager: fileManager)
            else { return nil }
            let ns = sourcePath as NSString
            guard !ns.pathExtension.isEmpty else { return nil }
            return ns.deletingPathExtension + "-filled.pdf"

        case .processedImageSibling(let sourceArgument):
            guard let source = stringArgument(sourceArgument, in: arguments),
                  let sourcePath = canonicalPath(source, root: workspaceRootURL, fileManager: fileManager)
            else { return nil }
            let ns = sourcePath as NSString
            let base = ns.deletingPathExtension
            let ext: String
            if (arguments["operation"] as? String) == "convert",
               let format = (arguments["format"] as? String)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }),
               ["png", "heic", "jpeg", "jpg"].contains(format) {
                ext = format == "jpeg" ? "jpg" : format
            } else if !ns.pathExtension.isEmpty {
                ext = ns.pathExtension
            } else {
                ext = "jpg"
            }
            return base + "-edited." + ext

        case .workspaceDirectory(let relative):
            guard let root = workspaceRootURL else { return nil }
            return root.appendingPathComponent(relative)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
    }

    /// Canonical file resolution identical to the legacy resolver: trimmed,
    /// bounded, absolute or workspace-root-relative, standardized with
    /// symlinks resolved.
    static func canonicalPath(
        _ raw: String,
        root: URL?,
        fileManager: FileManager
    ) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4096 else { return nil }
        let url: URL
        if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed)
        } else if let root {
            url = root.appendingPathComponent(trimmed)
        } else {
            return nil
        }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

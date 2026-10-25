// FloeSkills — install a complete skill package from a task workspace directory.
//
// `skill.install` lets the model install a package the task already built in
// its own workspace (the directory exported to the Linux task environment as
// /workspace). This file owns only the deterministic contract:
//
// - one normalized workspace-relative directory grammar plus a containment
//   check that resolves symlinks and refuses every escape;
// - package planning through the SAME `SkillPackageValidator` used by every
//   Finder, GitHub and folder import, so byte/path/script/manifest rules can
//   never diverge from the reviewed installer;
// - a private, bounded staging copy that binds the exact reviewed canonical
//   digest, preserves the upstream bytes (including a traditional manifest's
//   sidecar behavior) and leaves the user's directory untouched;
// - a bounded receipt built from the reviewed plan and the App transaction's
//   read-back commit.
//
// Nothing here executes a package script, starts an interpreter or subprocess,
// grants a capability or writes Floe metadata into the source directory. The
// App target supplies `SkillWorkspaceInstalling` through its existing
// SkillsCenter install transaction; no parallel installer lives in this file.

import Foundation
import FloeCore

/// The two explicit workspace install intents. `install` refuses an existing
/// skill; `replace` additionally requires the current installed digest, so a
/// stale model action can never silently discard a newer revision.
public enum SkillWorkspaceInstallMode: String, Codable, Sendable, CaseIterable {
    case install
    case replace
}

/// Stable, model-facing failure vocabulary. Messages never include a host
/// absolute path: workspace directories are reported as normalized relative
/// paths and package file names are the validator's relative paths.
public enum SkillWorkspaceInstallError: Error, Equatable, Sendable, LocalizedError {
    case invalidDirectory(String)
    case internalCacheDirectory
    case workspaceUnavailable
    case directoryMissing(String)
    case directoryOutsideWorkspace
    case directoryNotDirectory(String)
    case reservedIdentifier(String)
    case expectedDigestRequired
    case unexpectedExpectedDigest
    case invalidExpectedDigest
    case packageChanged
    case alreadyInstalled(String)
    case notInstalled(String)
    case installConflict(String)
    case ownershipDenied(String)
    case commitMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory(let reason):
            "Invalid workspace directory: \(reason)"
        case .internalCacheDirectory:
            "Floe's internal .floe workspace cache is not an install source; use a user package directory"
        case .workspaceUnavailable:
            "This task has no workspace directory bound to the run"
        case .directoryMissing(let directory):
            "The package directory does not exist in this task workspace: \(directory)"
        case .directoryOutsideWorkspace:
            "The package directory resolves outside this task workspace"
        case .directoryNotDirectory(let directory):
            "The package path is not a directory: \(directory)"
        case .reservedIdentifier(let id):
            "Skill '\(id)' is reserved by a built-in or official skill; choose a different name"
        case .expectedDigestRequired:
            "mode=replace requires expectedDigest from the installed skill's current digest"
        case .unexpectedExpectedDigest:
            "mode=install accepts no expectedDigest; use mode=replace to replace an existing skill"
        case .invalidExpectedDigest:
            "expectedDigest must be the 64-character SHA-256 of the installed skill"
        case .packageChanged:
            "The package bytes changed after review; run skill.install again"
        case .alreadyInstalled(let id):
            "Skill '\(id)' is already installed; use mode=replace with its current digest to replace it"
        case .notInstalled(let id):
            "Skill '\(id)' is not installed; use mode=install"
        case .installConflict(let id):
            "Skill '\(id)' changed since it was read; refresh its digest with skill.read and retry"
        case .ownershipDenied(let id):
            "Skill '\(id)' is a built-in, official or locally created skill and cannot be replaced by a workspace package"
        case .commitMismatch:
            "The installed package does not match the reviewed package; nothing was reported as installed"
        }
    }
}

/// One workspace-relative package directory. Shared by tool validation, the
/// planner and the App bridge so every layer accepts exactly the same names.
public enum SkillWorkspacePackageDirectory {
    public static let maximumBytes = 512
    public static let maximumComponents = 24
    public static let maximumComponentBytes = 255

    /// Trims surrounding whitespace and one run of trailing slashes, then
    /// requires plain relative path components. Absolute paths, `~`, `..`,
    /// backslashes, NUL/control characters, empty components and Floe's
    /// internal `.floe` tree are refused.
    public static func normalized(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SkillWorkspaceInstallError.invalidDirectory("the directory is empty")
        }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            throw SkillWorkspaceInstallError.invalidDirectory("use a path relative to the task workspace")
        }
        guard !trimmed.contains("\\"), !trimmed.contains("\0") else {
            throw SkillWorkspaceInstallError.invalidDirectory("backslashes and NUL are not supported")
        }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw SkillWorkspaceInstallError.invalidDirectory("control characters are not supported")
        }
        var value = trimmed
        while value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty else {
            throw SkillWorkspaceInstallError.invalidDirectory("the directory is empty")
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= maximumComponents else {
            throw SkillWorkspaceInstallError.invalidDirectory(
                "at most \(maximumComponents) path components are allowed"
            )
        }
        var normalized: [String] = []
        normalized.reserveCapacity(components.count)
        for component in components {
            guard !component.isEmpty else {
                throw SkillWorkspaceInstallError.invalidDirectory("empty path components are not allowed")
            }
            guard component != ".", component != ".." else {
                throw SkillWorkspaceInstallError.invalidDirectory("'.' and '..' components are not allowed")
            }
            guard component.utf8.count <= maximumComponentBytes else {
                throw SkillWorkspaceInstallError.invalidDirectory("one path component is too long")
            }
            normalized.append(String(component))
        }
        guard normalized.first != ".floe" else {
            throw SkillWorkspaceInstallError.internalCacheDirectory
        }
        let joined = normalized.joined(separator: "/")
        guard joined.utf8.count <= maximumBytes else {
            throw SkillWorkspaceInstallError.invalidDirectory(
                "at most \(maximumBytes) bytes are allowed"
            )
        }
        return joined
    }

    /// Resolves one already-normalized directory beneath the run's trusted
    /// workspace root. The real target must be a directory whose resolved path
    /// is still inside the resolved root, so an interior symlink cannot point
    /// the installer at another host location.
    public static func resolve(_ directory: String, in workspaceRoot: URL) throws -> URL {
        let normalized = try normalized(directory)
        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        var isRootDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isRootDirectory),
              isRootDirectory.boolValue else {
            throw SkillWorkspaceInstallError.workspaceUnavailable
        }
        let candidate = root.appendingPathComponent(normalized, isDirectory: true)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            throw SkillWorkspaceInstallError.directoryOutsideWorkspace
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            throw SkillWorkspaceInstallError.directoryMissing(normalized)
        }
        guard isDirectory.boolValue else {
            throw SkillWorkspaceInstallError.directoryNotDirectory(normalized)
        }
        return resolved
    }
}

/// One validated request shape (`directory` + `mode` + optional digest).
/// Construction normalizes the directory and enforces the mode/digest
/// contract, so neither the tool nor the App bridge has to re-derive it.
public struct SkillWorkspaceInstallRequest: Sendable, Equatable {
    public let directory: String
    public let mode: SkillWorkspaceInstallMode
    public let expectedDigest: String?

    public init(
        directory: String,
        mode: SkillWorkspaceInstallMode = .install,
        expectedDigest: String? = nil
    ) throws {
        self.directory = try SkillWorkspacePackageDirectory.normalized(directory)
        self.mode = mode
        self.expectedDigest = try SkillWorkspacePackageDirectory.expectedDigest(
            mode: mode,
            expectedDigest: expectedDigest
        )
    }
}

extension SkillWorkspacePackageDirectory {
    /// `install` accepts no digest; `replace` requires one exact 64-character
    /// hex SHA-256 and normalizes its case so comparisons stay canonical.
    public static func expectedDigest(
        mode: SkillWorkspaceInstallMode,
        expectedDigest: String?
    ) throws -> String? {
        let raw = expectedDigest?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch mode {
        case .install:
            guard raw.isEmpty else { throw SkillWorkspaceInstallError.unexpectedExpectedDigest }
            return nil
        case .replace:
            guard !raw.isEmpty else { throw SkillWorkspaceInstallError.expectedDigestRequired }
            guard raw.count == 64, raw.allSatisfy(\.isHexDigit) else {
                throw SkillWorkspaceInstallError.invalidExpectedDigest
            }
            return raw.lowercased()
        }
    }
}

/// The reviewed package shape. Every value comes from the validator that also
/// guards the App's install transaction; the file list is the validator's
/// sorted inventory, not a model-provided declaration.
public struct SkillWorkspacePackageSummary: Sendable, Equatable {
    public let skillID: String
    public let version: String
    public let canonicalSHA256: String
    public let fileCount: Int
    public let totalBytes: Int
    public let files: [String]
    public let declaredCapabilities: [String]
    public let toolNames: [String]
    public let scriptRuntime: String
    public let pythonPackageSpecs: [String]
    public let hasPackagedManifest: Bool

    public init(package: ValidatedSkillPackage) {
        skillID = package.manifest.id
        version = package.manifest.version
        canonicalSHA256 = package.canonicalSHA256
        fileCount = package.files.count
        totalBytes = package.files.reduce(0) { $0 + $1.byteCount }
        files = package.files.map(\.relativePath)
        declaredCapabilities = package.manifest.capabilities.sorted()
        toolNames = package.manifest.tools.sorted()
        scriptRuntime = package.manifest.scriptRuntime.rawValue
        pythonPackageSpecs = package.manifest.pythonPackages.map(\.spec)
        hasPackagedManifest = package.files.contains { $0.relativePath == "floe.json" }
    }

    public var containsScripts: Bool { files.contains { $0.hasPrefix("scripts/") } }
}

/// One immutable install plan: the resolved directory, its honest external
/// source binding and the reviewed package summary. `directoryURL` is a host
/// path and is never placed in the receipt or tool output.
public struct SkillWorkspaceInstallPlan: Sendable, Equatable {
    public let directory: String
    public let workspaceRootURL: URL
    public let directoryURL: URL
    public let sourceURL: URL
    public let mode: SkillWorkspaceInstallMode
    public let expectedDigest: String?
    public let package: SkillWorkspacePackageSummary

    public init(
        directory: String,
        workspaceRootURL: URL,
        directoryURL: URL,
        sourceURL: URL,
        mode: SkillWorkspaceInstallMode,
        expectedDigest: String?,
        package: SkillWorkspacePackageSummary
    ) {
        self.directory = directory
        self.workspaceRootURL = workspaceRootURL
        self.directoryURL = directoryURL
        self.sourceURL = sourceURL
        self.mode = mode
        self.expectedDigest = expectedDigest
        self.package = package
    }

    public var isReplacement: Bool { mode == .replace }
}

/// Identity written by this import route. It is deliberately NOT the creator
/// binding (`floe-creator`), the Finder rewrite marker or an official
/// `github-reviewed-<commit>` binding, so `SkillOriginResolver` classifies a
/// workspace import honestly as external and an official ID can never appear
/// self-generated or official through this path.
public enum SkillWorkspaceInstallIdentity {
    public static let sourceScheme = "floe-folder"
    public static let rewriteModelID = "workspace-import"
}

/// Builds one plan from the trusted run workspace. The package is validated
/// read-only; the source directory is never modified.
public enum SkillWorkspaceInstallPlanner {
    /// Every bundled/visible preset ID plus the four signed official IDs is
    /// reserved: a workspace import may never shadow one of those identities.
    public static let reservedSkillIDs: Set<String> = {
        Set(BundledDomainSkills.all.map(\.id)).union(OfficialSkillHub.skillIDs)
    }()

    public static func plan(
        _ request: SkillWorkspaceInstallRequest,
        in workspaceRoot: URL,
        validator: SkillPackageValidator = SkillPackageValidator()
    ) throws -> SkillWorkspaceInstallPlan {
        let directoryURL = try SkillWorkspacePackageDirectory.resolve(request.directory, in: workspaceRoot)
        let package = try validator.validate(packageAt: directoryURL, requireManifest: false)
        guard !reservedSkillIDs.contains(package.manifest.id) else {
            throw SkillWorkspaceInstallError.reservedIdentifier(package.manifest.id)
        }
        guard let sourceURL = sourceBinding(for: request.directory) else {
            throw SkillWorkspaceInstallError.invalidDirectory(
                "the directory cannot be encoded as an install source"
            )
        }
        return SkillWorkspaceInstallPlan(
            directory: request.directory,
            workspaceRootURL: workspaceRoot.standardizedFileURL.resolvingSymlinksInPath(),
            directoryURL: directoryURL,
            sourceURL: sourceURL,
            mode: request.mode,
            expectedDigest: request.expectedDigest,
            package: SkillWorkspacePackageSummary(package: package)
        )
    }

    /// Honest external binding: scheme + the normalized relative directory
    /// only. It carries no host path, query or fragment, and `SkillOriginResolver`
    /// treats the `floe-folder` scheme as external.
    public static func sourceBinding(for directory: String) -> URL? {
        var components = URLComponents()
        components.scheme = SkillWorkspaceInstallIdentity.sourceScheme
        components.host = "local"
        components.path = "/" + directory
        return components.url
    }
}

/// Bounded, private staging for the reviewed bytes. `stage` copies the whole
/// resolved directory to a fresh temporary container, re-validates that copy
/// with the same validator, and requires the planned identity/digest before
/// returning it. Any failure removes only this call's container.
public enum SkillWorkspaceInstallStaging {
    /// Directory name prefix for this helper's private temporary container.
    public static let containerPrefix = "floe-workspace-skill-"

    public static func stage(
        _ plan: SkillWorkspaceInstallPlan,
        parent: URL = FileManager.default.temporaryDirectory,
        validator: SkillPackageValidator = SkillPackageValidator()
    ) throws -> ValidatedSkillPackage {
        // Re-resolve AT STAGING TIME: a component between the workspace root
        // and the package can be replaced by a link after planning, and the
        // plan's lexical path alone would then follow it outside the task.
        let workspace = plan.workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let source = plan.directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard source.path != workspace.path, source.path.hasPrefix(workspace.path + "/") else {
            throw SkillWorkspaceInstallError.directoryOutsideWorkspace
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SkillWorkspaceInstallError.directoryMissing(plan.directory)
        }
        guard !isSymbolicLink(source) else {
            throw SkillValidationError.symbolicLink(plan.directory)
        }
        // Cheap pre-flight against the same caps, so a directory that grew
        // after planning is refused before any large copy begins.
        try assertBoundedSource(source, directory: plan.directory, limits: validator.limits)

        let parent = parent.standardizedFileURL
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let container = parent.appendingPathComponent(
            containerPrefix + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let stagedRoot = container.appendingPathComponent("package", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: source, to: stagedRoot)
            let package = try validator.validate(packageAt: stagedRoot, requireManifest: false)
            guard package.manifest.id == plan.package.skillID,
                  package.manifest.version == plan.package.version,
                  package.canonicalSHA256.caseInsensitiveCompare(plan.package.canonicalSHA256) == .orderedSame else {
                throw SkillWorkspaceInstallError.packageChanged
            }
            return package
        } catch {
            try? FileManager.default.removeItem(at: container)
            throw error
        }
    }

    /// Walks the real source tree without following symlinks and enforces the
    /// same size/count/shape caps the validator would apply to the copy.
    static func assertBoundedSource(
        _ root: URL,
        directory: String,
        limits: SkillValidationLimits
    ) throws {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
            ],
            options: []
        ) else {
            throw SkillWorkspaceInstallError.directoryMissing(directory)
        }
        let maximumEntries = limits.maximumFileCount > Int.max / 2
            ? Int.max
            : limits.maximumFileCount * 2
        var entryCount = 0
        var fileCount = 0
        var totalBytes = 0
        for case let url as URL in enumerator {
            entryCount += 1
            guard entryCount <= maximumEntries else {
                throw SkillValidationError.tooManyEntries(limit: maximumEntries)
            }
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(prefix) else {
                throw SkillValidationError.unsafePath(url.lastPathComponent)
            }
            let relative = String(standardized.path.dropFirst(prefix.count))
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            if values.isSymbolicLink == true {
                throw SkillValidationError.symbolicLink(relative)
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw SkillValidationError.unsupportedFile(relative)
            }
            let size = values.fileSize ?? 0
            guard size <= limits.maximumFileBytes else {
                throw SkillValidationError.fileTooLarge(path: relative, limit: limits.maximumFileBytes)
            }
            totalBytes += size
            guard totalBytes <= limits.maximumPackageBytes else {
                throw SkillValidationError.packageTooLarge(limit: limits.maximumPackageBytes)
            }
            fileCount += 1
            guard fileCount <= limits.maximumFileCount else {
                throw SkillValidationError.tooManyFiles(limit: limits.maximumFileCount)
            }
        }
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
}

/// What the App transaction actually committed, read back from persistence.
/// The tool verifies it against the reviewed plan before any success text is
/// produced, so a bridge cannot report a different ID, version or digest.
public struct SkillWorkspaceInstallCommit: Sendable, Equatable {
    public let skillID: String
    public let version: String
    public let canonicalSHA256: String
    public let previousDigest: String?

    public init(
        skillID: String,
        version: String,
        canonicalSHA256: String,
        previousDigest: String?
    ) {
        self.skillID = skillID
        self.version = version
        self.canonicalSHA256 = canonicalSHA256
        self.previousDigest = previousDigest
    }

    /// Requires the committed identity to equal the reviewed plan, and the
    /// replacement's previous revision to equal the caller's exact digest.
    public func verified(against plan: SkillWorkspaceInstallPlan) throws -> SkillWorkspaceInstallCommit {
        guard skillID == plan.package.skillID,
              version == plan.package.version,
              canonicalSHA256.caseInsensitiveCompare(plan.package.canonicalSHA256) == .orderedSame else {
            throw SkillWorkspaceInstallError.commitMismatch
        }
        switch plan.mode {
        case .install:
            guard previousDigest == nil else { throw SkillWorkspaceInstallError.commitMismatch }
        case .replace:
            guard let previousDigest,
                  let expected = plan.expectedDigest,
                  previousDigest.caseInsensitiveCompare(expected) == .orderedSame else {
                throw SkillWorkspaceInstallError.commitMismatch
            }
        }
        return self
    }
}

/// Bounded, host-path-free evidence of one completed install. The inventory is
/// the reviewed package's sorted file list, truncated to a fixed entry cap;
/// `omittedFileCount` keeps the count honest.
public struct SkillWorkspaceInstallReceipt: Codable, Sendable, Equatable {
    public static let maximumInventoryEntries = 32

    public let status: String
    public let skillID: String
    public let version: String
    public let canonicalSHA256: String
    public let previousDigest: String?
    public let directory: String
    public let source: String
    public let fileCount: Int
    public let totalBytes: Int
    public let inventory: [String]
    public let omittedFileCount: Int
    public let declaredCapabilities: [String]
    public let toolNames: [String]
    public let scriptRuntime: String
    public let pythonPackageSpecs: [String]
    public let hasPackagedManifest: Bool

    /// The intent this receipt proves; derived only from the committed status.
    public var mode: SkillWorkspaceInstallMode { status == "replaced" ? .replace : .install }

    public init(plan: SkillWorkspaceInstallPlan, commit: SkillWorkspaceInstallCommit) throws {
        let commit = try commit.verified(against: plan)
        status = plan.mode == .replace ? "replaced" : "installed"
        skillID = commit.skillID
        version = commit.version
        canonicalSHA256 = commit.canonicalSHA256
        previousDigest = commit.previousDigest
        directory = plan.directory
        source = plan.sourceURL.absoluteString
        fileCount = plan.package.fileCount
        totalBytes = plan.package.totalBytes
        inventory = Array(plan.package.files.prefix(Self.maximumInventoryEntries))
        omittedFileCount = max(0, plan.package.files.count - inventory.count)
        declaredCapabilities = plan.package.declaredCapabilities
        toolNames = plan.package.toolNames
        scriptRuntime = plan.package.scriptRuntime
        pythonPackageSpecs = plan.package.pythonPackageSpecs
        hasPackagedManifest = plan.package.hasPackagedManifest
    }
}

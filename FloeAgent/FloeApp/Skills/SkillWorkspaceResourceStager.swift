// FloeApp — installed Skill bundle delivery into the task's Linux workspace.
//
// The digest-pinned per-run snapshot already carries every bundled file, but it
// is materialized only inside the app container, so the Linux guest never sees
// the scripts' sibling assets/references an upstream guide expects. This actor
// stages the exact pinned snapshot bundle once into a reserved hidden cache
// tree under the ACTUAL workspace the bound local Linux environment exports
// as /workspace, and returns the portable guest root.
//
// Contract:
// - Uses the descriptor-time share map, so a COLD read that happens before
//   the task's first exec.shell still stages the tree the later first boot
//   mounts through the existing workspace share. An already-running guest is
//   never a precondition, and there is no host-side interpreter fallback.
// - Staging is an internal cache preparation inside the workspace the run
//   already owns. It grants no execution, network or tool permission, never
//   runs anything, and writes nothing outside the task root.
// - Reuse is granted only by full byte-for-byte verification against the
//   pinned snapshot (never by the `.markers` completion marker alone). A
//   foreign, damaged, symlinked or oversized tree at the staged path fails
//   closed and is left exactly as found.
// - Retention is workspace/task-scoped: a pinned tree stays until the
//   existing workspace-deletion lifecycle removes the workspace itself, so a
//   task running longer than a day never loses the tree it is executing from.
//   Only this helper's own abandoned `.staging-<canonical UUID>` temporaries
//   are ever removed; content bundles are never pruned by age, and marker
//   entries are never read or written through a planted symlink.
// - Publication is a single same-volume rename from a hidden staging tree, so
//   no reader ever observes a partial bundle; cancellation returns an honest
//   unavailable reason and never yields a staged path.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeExecution
import FloeSkills
import FloeTools

/// A bundle that was fully verified to match its pinned snapshot bytes and is
/// readable by the guest under the workspace share.
struct SkillStagedBundle: Sendable, Equatable {
    let guestRoot: String
    let pinnedSHA256: String
    let fileCount: Int
}

enum SkillStageOutcome: Sendable, Equatable {
    case staged(SkillStagedBundle)
    case unavailable(reason: String)
}

/// Stable, model-facing unavailable reasons. None of them ever carries a host
/// path, and none of them produces a guest path.
enum SkillStageReason {
    static let cancelled = "resource staging was cancelled"
    static let noBoundEnvironment = "no local Linux execution environment is bound to this task"
    static let noShareMap = "the bound environment's host/guest share map is unavailable"
    static let noWorkspaceShare = "the bound environment exports no workspace share"
    static let workspaceMismatch = "the task workspace root does not match the workspace exported to the guest"
    static let reservedConflict = "the reserved workspace cache path conflicts with existing entries"
    static let pathBlocked = "an existing entry occupies the staged path and does not match the pinned bundle"
    static let packageRejected = "the pinned bundle failed staging validation"
    static let writeFailed = "staging the bundle into the task workspace failed"
}

/// One verified file shape check result: the normalized bundle the stager may
/// publish. Built only from the pinned snapshot's own manifest and bytes.
struct SkillStagingBundle: Sendable {
    struct File: Sendable {
        let relativePath: String
        let data: Data
    }
    let skillID: String
    let digest: String
    /// Sorted by relative path for deterministic writes.
    let files: [File]
}

struct SkillExternalStageTarget: Sendable {
    let workspaceRoot: URL
    let executionRoot: String
    let publish: @Sendable (URL, SkillStagedBundle, CancellationToken) async throws -> Void
}

actor SkillWorkspaceResourceStager {
    /// Reserved hidden cache tree inside the task workspace:
    /// `<workspace>/.floe/skills`. Entries whose name starts with "." are
    /// internal (`.staging-` temporaries, `.markers`) and never content
    /// bundles; content bundles are `<skillID>@<canonicalSHA256>`.
    static let reservedComponents = [".floe", "skills"]
    static let markerDirectory = ".markers"
    static let stagingPrefix = ".staging-"
    /// Honest lifecycle bound: a content bundle is workspace/task-owned cache
    /// and is retained until the existing workspace-deletion lifecycle removes
    /// the workspace. NO pinned tree is pruned by age, so a run that lives
    /// longer than a day still executes against the tree it was given; growth
    /// per workspace equals the distinct `skillID@revision` bundles actually
    /// staged during the task's lifetime (each ≤ the package cap), not an
    /// absolute storage limit. This age bound applies ONLY to abandoned
    /// `.staging-<canonical UUID>` temporaries from this helper's own
    /// generator: an in-flight stage renames within seconds, so an older one
    /// is provably left over.
    static let staleStagingTemporaryAge: TimeInterval = 24 * 60 * 60

    private let pathMappingProvider: @Sendable (String) async -> LinuxGuestPathMap?
    private let limits: SkillValidationLimits
    private let externalTarget: (@Sendable (String, URL) async -> SkillExternalStageTarget?)?

    init(
        limits: SkillValidationLimits = SkillValidationLimits(),
        externalTarget: (@Sendable (String, URL) async -> SkillExternalStageTarget?)? = nil,
        pathMappingProvider: @escaping @Sendable (String) async -> LinuxGuestPathMap?
    ) {
        self.limits = limits
        self.externalTarget = externalTarget
        self.pathMappingProvider = pathMappingProvider
    }

    /// Prepare the pinned snapshot bundle in the task workspace. Never throws:
    /// every failure path returns an honest unavailable reason, publishes no
    /// partial tree and never removes anything this helper does not own.
    func stage(snapshot: SkillContentSnapshot, in context: SkillResourceContext) async -> SkillStageOutcome {
        let cancellation = context.cancellation
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .unavailable(reason: SkillStageReason.cancelled)
        }
        guard let environmentID = context.environmentID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !environmentID.isEmpty, let workspaceRootURL = context.workspaceRootURL else {
            return .unavailable(reason: SkillStageReason.noBoundEnvironment)
        }
        guard let bundle = Self.stagingBundle(
            manifestID: snapshot.package.manifest.id,
            digest: snapshot.package.canonicalSHA256,
            declaredFiles: snapshot.package.files,
            bytes: snapshot.files,
            limits: limits
        ) else {
            return .unavailable(reason: SkillStageReason.packageRejected)
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .unavailable(reason: SkillStageReason.cancelled)
        }

        // Descriptor-time mapping from the existing registry share table. The
        // guest does not need to be running: a cold read stages into the
        // workspace that a later first boot mounts. Nil (remote/unresolved)
        // stays an honest unavailable here — never a host fallback.
        let external = await externalTarget?(environmentID, workspaceRootURL)
        let executionRoot: String
        let exportedRoot: URL
        if let external {
            executionRoot = external.executionRoot; exportedRoot = external.workspaceRoot
            guard executionRoot.hasPrefix("/"), !executionRoot.split(separator: "/").contains("..") else {
                return .unavailable(reason: SkillStageReason.noWorkspaceShare)
            }
        } else {
            guard let pathMap = await pathMappingProvider(environmentID) else {
                return .unavailable(reason: SkillStageReason.noShareMap)
            }
            guard pathMap.workspaceGuestRoot == LinuxGuestMountPoint.workspace,
                  let root = pathMap.hostPath(forGuestPath: LinuxGuestMountPoint.workspace) else {
                return .unavailable(reason: SkillStageReason.noWorkspaceShare)
            }
            exportedRoot = root; executionRoot = LinuxGuestMountPoint.workspace
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .unavailable(reason: SkillStageReason.cancelled)
        }
        let workspaceRoot = workspaceRootURL.resolvingSymlinksInPath().standardizedFileURL
        guard workspaceRoot == exportedRoot.resolvingSymlinksInPath().standardizedFileURL else {
            return .unavailable(reason: SkillStageReason.workspaceMismatch)
        }
        var isWorkspaceDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspaceRoot.path, isDirectory: &isWorkspaceDirectory),
              isWorkspaceDirectory.boolValue else {
            return .unavailable(reason: SkillStageReason.workspaceMismatch)
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .unavailable(reason: SkillStageReason.cancelled)
        }
        guard let reservedRoot = Self.preparedReservedRoot(under: workspaceRoot) else {
            return .unavailable(reason: SkillStageReason.reservedConflict)
        }
        let leaf = "\(bundle.skillID)@\(bundle.digest)"
        let stagedRoot = reservedRoot.appendingPathComponent(leaf, isDirectory: true)
        let guestRoot = executionRoot + "/.floe/skills/" + leaf
        let published = SkillStagedBundle(
            guestRoot: guestRoot,
            pinnedSHA256: bundle.digest,
            fileCount: bundle.files.count
        )

        if FileManager.default.fileExists(atPath: stagedRoot.path) {
            // Reuse is decided ONLY by full verification against the pinned
            // bytes. Anything else that sits here — foreign, damaged,
            // symlinked or partial — is left exactly as found, and staging
            // fails closed without a guest path.
            guard Self.verify(stagedRoot: stagedRoot, bundle: bundle) else {
                return .unavailable(reason: SkillStageReason.pathBlocked)
            }
            // Fenced after verification and again immediately before the
            // staged return: a cancelled read never yields a path just
            // because a verified tree already exists.
            guard !cancellation.isCancelled, !Task.isCancelled else {
                return .unavailable(reason: SkillStageReason.cancelled)
            }
            Self.writeMarker(leaf: leaf, digest: bundle.digest, in: reservedRoot)
            Self.pruneStaleStagingTemps(in: reservedRoot)
            guard !cancellation.isCancelled, !Task.isCancelled else {
                return .unavailable(reason: SkillStageReason.cancelled)
            }
            if let external {
                do { try await external.publish(stagedRoot, published, cancellation) }
                catch { return .unavailable(reason: cancellation.isCancelled ? SkillStageReason.cancelled : SkillStageReason.writeFailed) }
            }
            return .staged(published)
        }

        let stagingRoot = reservedRoot.appendingPathComponent(
            Self.stagingPrefix + UUID().uuidString, isDirectory: true
        )
        // Fenced immediately before the first creation of this attempt.
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .unavailable(reason: SkillStageReason.cancelled)
        }
        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
            for file in bundle.files {
                guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
                let destination = stagingRoot.appendingPathComponent(file.relativePath)
                // Defense in depth: the bundle builder already rejected
                // traversal and absolute segments; re-check the resolved URL.
                guard destination.standardizedFileURL.path
                    .hasPrefix(stagingRoot.standardizedFileURL.path + "/") else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try file.data.write(to: destination, options: .atomic)
                let readBack = try Data(contentsOf: destination)
                guard readBack == file.data else { throw CocoaError(.fileWriteUnknown) }
            }
            // Verify the complete temporary tree (exact file/dir shape, no
            // symlinks, every byte equal) before any publication.
            guard Self.verify(stagedRoot: stagingRoot, bundle: bundle) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
            // Single same-volume commit: a rename, never a partial publish.
            try FileManager.default.moveItem(at: stagingRoot, to: stagedRoot)
        } catch {
            // Remove only OUR staging temporary; the final path is untouched.
            try? FileManager.default.removeItem(at: stagingRoot)
            if error is CancellationError {
                return .unavailable(reason: SkillStageReason.cancelled)
            }
            // A concurrent publisher may have won the rename (or an entry
            // appeared). Adopt only a tree that FULLY verifies; never overwrite.
            if FileManager.default.fileExists(atPath: stagedRoot.path) {
                if Self.verify(stagedRoot: stagedRoot, bundle: bundle) {
                    // A concurrent publisher already committed the same bytes.
                } else {
                    return .unavailable(reason: SkillStageReason.pathBlocked)
                }
            } else {
                return .unavailable(reason: SkillStageReason.writeFailed)
            }
        }
        // Advisory only: markers record OUR commits; reuse never trusts them,
        // so a failed marker write keeps the valid tree. Nothing is ever
        // deleted or trusted based on a marker.
        Self.writeMarker(leaf: leaf, digest: bundle.digest, in: reservedRoot)
        Self.pruneStaleStagingTemps(in: reservedRoot)
        // Fenced immediately before the staged return.
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .unavailable(reason: SkillStageReason.cancelled)
        }
        if let external {
            do { try await external.publish(stagedRoot, published, cancellation) }
            catch { return .unavailable(reason: cancellation.isCancelled ? SkillStageReason.cancelled : SkillStageReason.writeFailed) }
        }
        return .staged(published)
    }

    // MARK: - Bundle validation

    /// Normalizes the pinned snapshot into a writable bundle: valid skill id,
    /// lowercase 64-hex digest, safe relative paths, byte counts consistent
    /// with the validated manifest, and the existing package caps. The
    /// validator remains the authority for what a package may contain; this
    /// re-checks the staging safety boundary independently.
    static func stagingBundle(
        manifestID: String,
        digest: String,
        declaredFiles: [SkillFile],
        bytes: [String: Data],
        limits: SkillValidationLimits
    ) -> SkillStagingBundle? {
        guard (try? SkillIdentifier.validate(manifestID)) != nil else { return nil }
        guard isCanonicalLowercaseHexDigest(digest) else { return nil }
        guard !declaredFiles.isEmpty, declaredFiles.count <= limits.maximumFileCount else { return nil }
        var files: [SkillStagingBundle.File] = []
        var totalBytes = 0
        var seen: Set<String> = []
        for declared in declaredFiles.sorted(by: { $0.relativePath < $1.relativePath }) {
            let path = declared.relativePath
            guard seen.insert(path).inserted,
                  isSafeRelativePath(path) else { return nil }
            guard let data = bytes[path],
                  data.count == declared.byteCount,
                  data.count <= limits.maximumFileBytes else { return nil }
            totalBytes += data.count
            guard totalBytes <= limits.maximumPackageBytes else { return nil }
            files.append(.init(relativePath: path, data: data))
        }
        // Never carry bytes the pinned manifest does not declare.
        guard files.count == bytes.count else { return nil }
        return SkillStagingBundle(skillID: manifestID, digest: digest, files: files)
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 512,
              !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\u{0}") else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment != "." && segment != ".."
        }
    }

    // MARK: - Reserved root

    /// Creates the reserved `<workspace>/.floe/skills` tree step by step and
    /// refuses to proceed if any existing component is a symlink or a
    /// non-directory, so a planted link can never redirect writes outside the
    /// workspace. Concurrent stagers may race on creation; the loser simply
    /// validates the winner's directory instead of failing.
    static func preparedReservedRoot(under workspaceRoot: URL) -> URL? {
        var current = workspaceRoot
        for component in reservedComponents {
            current = current.appendingPathComponent(component, isDirectory: true)
            if !FileManager.default.fileExists(atPath: current.path) {
                // A concurrent staging call may create it between the check and
                // the create; both outcomes are validated below.
                try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !isSymbolicLink(current) else { return nil }
        }
        return current
    }

    // MARK: - Verification

    /// True only when `stagedRoot` is a non-symlink directory whose regular
    /// files exactly equal the bundle bytes, with the expected directory shape
    /// and no extra entry, symlink or special file anywhere.
    static func verify(stagedRoot: URL, bundle: SkillStagingBundle) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: stagedRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !isSymbolicLink(stagedRoot) else { return false }
        let prefix = stagedRoot.standardizedFileURL.path.hasSuffix("/")
            ? stagedRoot.standardizedFileURL.path
            : stagedRoot.standardizedFileURL.path + "/"
        var expected: [String: Data] = [:]
        var expectedDirectories: Set<String> = []
        for file in bundle.files {
            expected[file.relativePath] = file.data
            var parent = (file.relativePath as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                expectedDirectories.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        guard let enumerator = fileManager.enumerator(
            at: stagedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { return false }
        var foundFiles: Set<String> = []
        var foundDirectories: Set<String> = []
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(prefix) else { return false }
            let relative = String(standardized.path.dropFirst(prefix.count))
            guard isSafeRelativePath(relative) else { return false }
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
            ]) } catch { return false }
            guard values.isSymbolicLink != true else { return false }
            if values.isDirectory == true {
                foundDirectories.insert(relative)
                continue
            }
            guard values.isRegularFile == true, let expectedData = expected[relative] else { return false }
            guard values.fileSize == expectedData.count else { return false }
            guard let onDisk = try? Data(contentsOf: url), onDisk == expectedData else { return false }
            foundFiles.insert(relative)
        }
        return foundFiles == Set(expected.keys) && foundDirectories == expectedDirectories
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// A real directory: never a symlink (planted links must not be followed).
    static func isPlainDirectory(_ url: URL) -> Bool {
        guard !isSymbolicLink(url) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func containsSymbolicLink(at root: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return true }
        for case let url as URL in enumerator {
            if isSymbolicLink(url) { return true }
        }
        return false
    }

    // MARK: - Markers (advisory ownership records, never a trust source)

    private struct Marker: Codable {
        let digest: String
        let stagedAt: Date
    }

    static func markerURL(leaf: String, in reservedRoot: URL) -> URL {
        reservedRoot
            .appendingPathComponent(markerDirectory, isDirectory: true)
            .appendingPathComponent("\(leaf).json")
    }

    /// Best effort. Markers are OUR advisory ownership records: nothing is
    /// ever trusted or deleted from them, so a missing or skipped marker never
    /// blocks reuse. A planted symlink at `.markers` or at the marker file is
    /// never followed, written through or replaced — the marker is simply not
    /// written and the verified tree stays valid.
    static func writeMarker(leaf: String, digest: String, in reservedRoot: URL) {
        let markers = reservedRoot.appendingPathComponent(markerDirectory, isDirectory: true)
        if FileManager.default.fileExists(atPath: markers.path) {
            guard isPlainDirectory(markers) else { return }
        } else {
            try? FileManager.default.createDirectory(at: markers, withIntermediateDirectories: false)
            guard isPlainDirectory(markers) else { return }
        }
        let target = markerURL(leaf: leaf, in: reservedRoot)
        // An existing symlinked marker belongs to someone else: leave it.
        guard !isSymbolicLink(target) else { return }
        guard let data = try? JSONEncoder().encode(Marker(digest: digest, stagedAt: Date())) else { return }
        try? data.write(to: target, options: .atomic)
    }

    /// Exact ASCII lowercase hex SHA-256 shape: 64 UTF-8 bytes, each `0-9` or
    /// `a-f`. `Character.isLowercase` is FALSE for digits, so any case-property
    /// check rejects every real digest; the predicate must be byte-exact.
    static func isCanonicalLowercaseHexDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }
    }

    /// Parses `<id>@<64hex>`; dot-prefixed internal entries never qualify.
    static func parseLeaf(_ name: String) -> (skillID: String, digest: String)? {
        guard !name.hasPrefix("."), !name.hasPrefix("@"), !name.hasSuffix("@"),
              let at = name.lastIndex(of: "@") else { return nil }
        let id = String(name[..<at])
        let digest = String(name[name.index(after: at)...])
        guard (try? SkillIdentifier.validate(id)) != nil,
              isCanonicalLowercaseHexDigest(digest) else { return nil }
        return (id, digest)
    }

    // MARK: - Workspace-owned retention

    /// Removes ONLY this helper's abandoned staging temporaries. Ownership is
    /// proved by all of: the exact `.staging-` prefix plus a canonical
    /// `UUID().uuidString` round-trip (the prefix alone is never enough), a
    /// real non-symlink directory whose subtree contains no symlink, and an
    /// age beyond `staleStagingTemporaryAge` (an in-flight stage renames
    /// within seconds). Content-addressed bundles and markers are NEVER
    /// removed here: a pinned tree is retained for the task's lifetime and
    /// released with the workspace itself, so a long-running run keeps the
    /// tree it is executing from.
    static func pruneStaleStagingTemps(in reservedRoot: URL, now: Date = Date()) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: reservedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: []
        ) else { return }
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix(stagingPrefix) else { continue }
            // Defense in depth: a well-formed content leaf is never removed.
            guard parseLeaf(name) == nil else { continue }
            let suffix = String(name.dropFirst(stagingPrefix.count))
            guard let uuid = UUID(uuidString: suffix), uuid.uuidString == suffix else { continue }
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey
            ])
            guard values?.isSymbolicLink != true,
                  values?.isDirectory == true,
                  let createdAt = values?.contentModificationDate,
                  now.timeIntervalSince(createdAt) > staleStagingTemporaryAge else { continue }
            // A temporary that grew a symlink is left exactly as found.
            guard !containsSymbolicLink(at: url) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Model-facing section (bounded; no host paths, no per-file hashes)

    /// One compact section appended to an exact read's Markdown. The guest can
    /// enumerate real staged files with `ls`; the structured `resources`
    /// metadata keeps the root visible even when this section is not on the
    /// first page. Bytes and digests remain pinned internally.
    static func resourceFooter(
        id: String,
        pinnedSHA256: String,
        declaredFiles: [SkillFile],
        outcome: SkillStageOutcome
    ) -> String {
        var section = "\n\n## Package files (Linux task workspace)\n"
        switch outcome {
        case .staged(let bundle):
            section += "staged=true\npinnedSHA256=\(bundle.pinnedSHA256)\nguestRoot=\(bundle.guestRoot)\n"
            section += "fileCount=\(bundle.fileCount)\nrootContents: \(summarizeRootContents(declaredFiles))\n"
            section += "Upstream `$CODEX_HOME/skills/\(id)/` references in the guide resolve under this `guestRoot`. "
            section += "The guest can list every staged file with `ls -R \(bundle.guestRoot)`. "
            section += "This tree is a Floe-managed cache inside the task workspace: do not edit or commit it. "
            section += "Nothing was executed; scripts run only through the normal exec.shell approval flow, "
            section += "either from the pasted audited source or the staged copy — both are the same pinned bytes.\n"
        case .unavailable(let reason):
            section += "staged=false\npinnedSHA256=\(pinnedSHA256)\n"
            section += "fileCount=\(declaredFiles.count)\nreason=\(reason)\n"
            section += "The bundled assets/references are not available as files in the guest for this read. "
            section += "The pasted audited script sources above remain the only fallback; do not invent replacement bytes.\n"
        }
        return section
    }

    static func summarizeRootContents(_ files: [SkillFile]) -> String {
        var rootFiles: [String] = []
        var directories: [String: Int] = [:]
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            let segments = file.relativePath.split(separator: "/")
            if segments.count == 1 {
                rootFiles.append(file.relativePath)
            } else {
                directories[String(segments[0]), default: 0] += 1
            }
        }
        let summary = directories.keys.sorted().map { "\($0) (\(directories[$0]!) files)" }
        return (rootFiles + summary).joined(separator: ", ")
    }
}
#endif

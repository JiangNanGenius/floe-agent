// SPDX-License-Identifier: MPL-2.0
//
// MacWorkspaceTextMutation — the unified Mac host's file-authoring lane.
//
// Four model-facing tools join the existing createFile / replaceText
// capability with the exact public Floe workspace argument schemas and
// receipt prefixes:
//
//   workspace.writeFile       create (parent must exist) or overwrite with a
//                             verified pre-write SHA256 / optional mtime
//   workspace.appendFile      append UTF-8 text to an existing file,
//                             verified against its complete pre-edit SHA256
//   workspace.applyPatch      single-file unified diff through the shared
//                             WorkspaceTextMutationContract engine
//   workspace.createDirectory create the leaf and missing parents, one
//                             pinned mkdirat at a time
//
// Every mutation runs through the pinned-descriptor admission built in
// MacAgentWorkspaceTools (per-component openat(O_DIRECTORY | O_NOFOLLOW)
// walks with device/inode verification, the shared secret denylist, no `..` /
// symlink / trailing-slash paths, the task approval policy and the runtime's
// path authorization) and publishes through the proven stage → verify →
// exchange sequence: bytes are staged O_EXCL inside the pinned parent with
// the original's metadata (fcopyfile COPYFILE_METADATA), fsynced, read back
// byte-for-byte, identity-checked, then exchanged with
// renameatx_np(RENAME_SWAP) so the previous inode stays recoverable at a
// unique `.floe-previous-<uuid>` sibling. Cancellation between staging and
// commit fails closed and leaves the target untouched.
//
// Patch parsing/application deliberately reuses the Foundation-only
// WorkspaceTextMutationContract so hunk semantics stay byte-identical to the
// iPad/Linux workspace service; BOM and CRLF bytes survive because the
// engine operates on the decoded text whose lines keep their "\r".

import Foundation
import Darwin
import FloeAgentRuntime
import FloeCore
import FloeModels
import FloeTools

// MARK: - Shared staged publish

enum MacAgentWorkspaceTextMutation {

    /// The committed outcome of one staged text mutation.
    struct Receipt: Sendable {
        var sha256: String
        var byteCount: Int
        var mtime: TimeInterval
        /// Workspace-relative path of the preserved previous revision
        /// (`.floe-previous-<uuid>`); nil for a no-op or a new file.
        var previous: String?
        var change: WorkspaceTextMutationContract.Change = .unchanged

        func result(_ summary: String, path: String) -> ToolExecutionOutput {
            let preserved = previous.map { " previous=\($0)" } ?? ""
            return ToolExecutionOutput(digesting: WorkspaceTextMutationContract.savedReceipt(
                summary + preserved, path: path, change: change) + " preview=unavailable",
                maximumSummaryCharacters: 4096)
        }
    }

    /// Reads the complete contents of an already-open, verified descriptor.
    static func readBytes(_ descriptor: Int32, limit: Int) throws -> Data {
        let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try reader.seek(toOffset: 0)
        let data = try reader.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw MacAgentWorkspaceToolsError.tooLarge(limit: limit) }
        return data
    }

    /// True when the pinned directory entry `path` is exactly the file
    /// described by `expected` (device, inode, single hard link, regular).
    static func matches(_ expected: stat, named path: String, in parent: Int32) -> Bool {
        var actual = stat()
        return fstatat(parent, path, &actual, AT_SYMLINK_NOFOLLOW) == 0
            && actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino
            && actual.st_nlink == 1 && (actual.st_mode & S_IFMT) == S_IFREG
    }

    /// Exclusive staged creation inside the pinned parent — the same
    /// discipline as `workspace.createFile`: O_EXCL staging, fsync,
    /// byte-for-byte read-back, then `renameatx_np(RENAME_EXCL)` with a
    /// link/unlink fallback, so a concurrent writer can never win the name.
    static func publishNewFile(
        pin: MacAgentWorkspacePinSupport.Pin,
        data: Data,
        displayPath: String,
        cancellation: CancellationToken
    ) throws -> Receipt {
        let tempName = ".floe-agent-\(UUID().uuidString).tmp"
        let staged = openat(
            pin.parentFileDescriptor, tempName,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
        )
        guard staged >= 0 else {
            throw MacAgentWorkspaceToolsError.invalidArguments("the workspace directory is not writable")
        }
        defer {
            Darwin.close(staged)
            unlinkat(pin.parentFileDescriptor, tempName, 0)
        }

        let file = FileHandle(fileDescriptor: staged, closeOnDealloc: false)
        try file.write(contentsOf: data)
        try file.synchronize()
        try file.seek(toOffset: 0)
        let verified = try file.read(upToCount: data.count + 1) ?? Data()
        var held = stat(), named = stat()
        guard verified == data, fstat(staged, &held) == 0, held.st_nlink == 1,
              fstatat(pin.parentFileDescriptor, tempName, &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino else {
            throw MacAgentWorkspaceToolsError.invalidArguments("the staged file changed before publication")
        }
        try cancellation.throwIfCancelled()

        var result = renameatx_np(
            pin.parentFileDescriptor, tempName, pin.parentFileDescriptor, pin.name,
            UInt32(RENAME_EXCL)
        )
        if result != 0, errno == ENOTSUP {
            result = linkat(pin.parentFileDescriptor, tempName, pin.parentFileDescriptor, pin.name, 0)
        }
        guard result == 0 else {
            if errno == EEXIST { throw MacAgentWorkspaceToolsError.targetAlreadyExists(displayPath) }
            throw MacAgentWorkspaceToolsError.invalidArguments("the file could not be published")
        }

        let mtime = TimeInterval(held.st_mtimespec.tv_sec)
            + TimeInterval(held.st_mtimespec.tv_nsec) / 1_000_000_000
        return Receipt(sha256: FloeDigest.sha256Hex(verified), byteCount: data.count,
                       mtime: mtime, previous: nil, change: .created)
    }

    /// Stage `updated` beside the approved target inside the pinned parent,
    /// carry the original's metadata, fsync and read back, then exchange with
    /// `renameatx_np(RENAME_SWAP)`. This is the exact proven sequence of
    /// `MacAgentWorkspaceReplaceTextTool`: pre-commit cancellation, parent and
    /// target identity revalidation, displaced-inode validation and a guarded
    /// swap-back restore, so a swapped third inode after the open is observed
    /// and handed back instead of clobbered.
    static func publishStagedReplacement(
        pin: MacAgentWorkspacePinSupport.Pin,
        originalFD: Int32,
        originalIdentity: stat,
        originalBytes: Data,
        updated: Data,
        relative: String,
        limit: Int,
        cancellation: CancellationToken
    ) throws -> Receipt {
        let parent = pin.parentFileDescriptor
        let previous = ".floe-previous-\(UUID().uuidString)"
        let staged = openat(parent, previous, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard staged >= 0 else {
            throw MacAgentWorkspaceToolsError.invalidArguments("the workspace directory is not writable")
        }
        var stagedIdentity = stat()
        guard fstat(staged, &stagedIdentity) == 0 else {
            Darwin.close(staged)
            throw MacAgentWorkspaceToolsError.replacementUnconfirmed(previous)
        }
        defer {
            // Unlink only the inode we staged. After the exchange this
            // name holds the original or a concurrent writer's entry.
            if matches(stagedIdentity, named: previous, in: parent) {
                unlinkat(parent, previous, 0)
            }
            Darwin.close(staged)
        }
        guard fcopyfile(originalFD, staged, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
            throw MacAgentWorkspaceToolsError.invalidArguments("the file metadata could not be preserved")
        }
        let file = FileHandle(fileDescriptor: staged, closeOnDealloc: false)
        try file.write(contentsOf: updated)
        try file.synchronize()
        guard try readBytes(staged, limit: limit) == updated else {
            throw MacAgentWorkspaceToolsError.invalidArguments("the staged replacement could not be verified")
        }
        var written = stat()
        guard fstat(staged, &written) == 0 else {
            throw MacAgentWorkspaceToolsError.replacementUnconfirmed(previous)
        }
        try cancellation.throwIfCancelled()
        try Task.checkCancellation()
        var heldParent = stat(), currentParent = stat()
        guard fstat(parent, &heldParent) == 0, stat(pin.parentPhysicalPath, &currentParent) == 0,
              heldParent.st_dev == currentParent.st_dev, heldParent.st_ino == currentParent.st_ino,
              matches(originalIdentity, named: pin.name, in: parent),
              matches(stagedIdentity, named: previous, in: parent),
              try readBytes(originalFD, limit: limit) == originalBytes else {
            throw MacAgentWorkspaceToolsError.revisionChanged
        }
        guard renameatx_np(parent, previous, parent, pin.name, UInt32(RENAME_SWAP)) == 0 else {
            throw MacAgentWorkspaceToolsError.invalidArguments(
                "the filesystem could not exchange the file and its staged revision"
            )
        }
        var displaced = stat()
        let foundDisplaced = fstatat(parent, previous, &displaced, AT_SYMLINK_NOFOLLOW) == 0
        guard matches(stagedIdentity, named: pin.name, in: parent),
              matches(originalIdentity, named: previous, in: parent),
              (try? readBytes(originalFD, limit: limit)) == originalBytes else {
            // Restore the displaced entry only while our staged inode
            // still owns the target. A later writer's entry is kept.
            if foundDisplaced,
               matches(stagedIdentity, named: pin.name, in: parent),
               matches(displaced, named: previous, in: parent),
               renameatx_np(parent, previous, parent, pin.name, UInt32(RENAME_SWAP)) == 0 {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            throw MacAgentWorkspaceToolsError.replacementUnconfirmed(previous)
        }
        guard fsync(parent) == 0, (try? readBytes(staged, limit: limit)) == updated,
              matches(stagedIdentity, named: pin.name, in: parent),
              matches(originalIdentity, named: previous, in: parent) else {
            throw MacAgentWorkspaceToolsError.replacementUnconfirmed(previous)
        }
        let mtime = TimeInterval(written.st_mtimespec.tv_sec)
            + TimeInterval(written.st_mtimespec.tv_nsec) / 1_000_000_000
        let parentPath = relative.split(separator: "/").dropLast().joined(separator: "/")
        return Receipt(
            sha256: FloeDigest.sha256Hex(updated),
            byteCount: updated.count,
            mtime: mtime,
            previous: parentPath.isEmpty ? previous : parentPath + "/" + previous,
            change: .modified
        )
    }
}

// MARK: workspace.writeFile

/// Creates or overwrites one UTF-8 text file in the selected project
/// workspace with the exact approved `workspace.writeFile` contract of the
/// shared workspace service: exactly one of `content` or `sourcePath`
/// (a previously written local draft, verified against its complete
/// `expectedSourceSHA256` through a pinned read, preserved untouched), plus
/// optional observed target preconditions (`expectedSHA256` / `expectedMtime`)
/// from `workspace.inspectFileMetadata`.
///
/// Target semantics mirror the service: a missing target is created when its
/// parent directory already exists; an existing target is overwritten when
/// preconditions are supplied and match, or for inline content when no
/// preconditions were supplied. Source finalization without a target
/// precondition stays create-only — a retry can never replace a target whose
/// revision was never observed. The commit preserves the exact bytes — BOM
/// and CRLF included — and keeps the previous revision recoverable beside
/// the file.
public struct MacAgentWorkspaceWriteFileTool: AgentTool, MacAgentWorkspaceExecutable {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var content: String?
        /// Existing workspace text draft used instead of a giant inline
        /// body; authorized independently from `path` and never modified.
        public var sourcePath: String?
        public var expectedSourceSHA256: String?
        public var expectedMtime: Double?
        public var expectedSHA256: String?
        public var scope: String?

        public init(path: String, content: String? = nil, sourcePath: String? = nil,
                    expectedSourceSHA256: String? = nil, expectedMtime: Double? = nil,
                    expectedSHA256: String? = nil, scope: String? = nil) {
            self.path = path
            self.content = content
            self.sourcePath = sourcePath
            self.expectedSourceSHA256 = expectedSourceSHA256
            self.expectedMtime = expectedMtime
            self.expectedSHA256 = expectedSHA256
            self.scope = scope
        }
    }

    public static let name = MacAgentWorkspaceTools.writeFileToolName
    public static let toolDescription =
        "Write any UTF-8 plain-text workspace file natively: source code, scripts, HTML/CSS/JS, JSON/YAML/CSV, LaTeX, TXT, configuration, or an extensionless/unknown-extension file. Supply exactly one of content or sourcePath. The commit preserves the exact UTF-8 bytes supplied, including a leading BOM and the original CRLF/LF newlines. For a long document, create a new draft, append bounded chunks with the previous SHA as expectedSHA256, then finalize using sourcePath and its final expectedSourceSHA256; the source draft is verified through a pinned read and remains unchanged. Source finalization is create-only without a target precondition; for an existing target pass its observed expectedSHA256/expectedMtime. Conflicts and pre-commit cancellation leave the target untouched, and the previous revision stays recoverable beside the file."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative target path for any plain-text file"},
        "content": {"type": "string", "description": "New full UTF-8 text; omit when sourcePath is supplied"},
        "sourcePath": {"type": "string", "description": "Existing workspace text draft of any text type; mutually exclusive with content; never deleted"},
        "expectedSourceSHA256": {"type": "string", "pattern": "^[A-Fa-f0-9]{64}$", "description": "Required with sourcePath: exact final SHA returned by append/inspect"},
        "expectedMtime": {"type": "number", "description": "Observed target mtime in seconds since 1970"},
        "expectedSHA256": {"type": "string", "description": "Observed target SHA; stale values fail without overwrite"}
      },
      "required": ["path"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true

    static let descriptor = ToolCatalog.Descriptor(
        name: name,
        toolDescription: toolDescription,
        parametersJSON: parametersJSON,
        riskLabels: riskLabels,
        isSideEffecting: isSideEffecting,
        requiresHostScope: false
    )

    private let root: MacAgentWorkspaceRoot
    public init(rootURL: URL) { root = MacAgentWorkspaceRoot(rootURL) }

    public func validate(_ args: Arguments) throws {
        guard !args.path.trimmingCharacters(in: .whitespaces).isEmpty,
              (args.content != nil) != (args.sourcePath != nil) else {
            throw MacAgentWorkspaceToolsError.invalidArguments(
                "path and exactly one of content or sourcePath are required"
            )
        }
        if let mtime = args.expectedMtime, !mtime.isFinite || mtime < 0 {
            throw MacAgentWorkspaceToolsError.invalidArguments("expectedMtime must be finite and >= 0")
        }
        if let source = args.sourcePath {
            guard !source.trimmingCharacters(in: .whitespaces).isEmpty,
                  let digest = args.expectedSourceSHA256?.lowercased().utf8,
                  digest.count == 64, digest.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw MacAgentWorkspaceToolsError.invalidArguments(
                    "sourcePath requires its complete 64-digit expectedSourceSHA256"
                )
            }
        } else if args.expectedSourceSHA256 != nil {
            throw MacAgentWorkspaceToolsError.invalidArguments("expectedSourceSHA256 requires sourcePath")
        }
    }

    /// Pinned, digest-verified read of the source draft. The bytes are read
    /// through the pinned descriptor, decoded with the BOM re-attached, and
    /// required to round-trip byte-exactly, so the finalized bytes are
    /// exactly the bytes the model inspected.
    private func verifiedSourceBytes(
        physicalRoot: String, path: String, expectedSHA256: String
    ) throws -> Data {
        let limit = MacAgentWorkspaceTools.maxWriteBytes
        let (_, sourceRelative) = try macWorkspacePinSetup(root: root, path: path)
        guard sourceRelative != "." else {
            throw MacAgentWorkspaceToolsError.isDirectory(path)
        }
        return try MacAgentWorkspacePinSupport.withPinnedTarget(
            physicalRoot: physicalRoot, relative: sourceRelative, root: root
        ) { pin in
            let status = MacAgentWorkspacePinSupport.leafStatus(pin)
            guard status.exists, !status.symlink, status.info.st_mode & S_IFMT == S_IFREG else {
                throw MacAgentWorkspaceToolsError.notFound(path)
            }
            let descriptor = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(
                pin, physicalRoot: physicalRoot, displayPath: path
            )
            defer { Darwin.close(descriptor) }
            let bytes = try MacAgentWorkspaceTextMutation.readBytes(descriptor, limit: limit)
            guard let text = WorkspaceTextPolicy.decodeUTF8(bytes), Data(text.utf8) == bytes else {
                throw MacAgentWorkspaceToolsError.invalidArguments(
                    "the source draft does not round-trip as byte-exact UTF-8 text"
                )
            }
            guard FloeDigest.sha256Hex(bytes) == expectedSHA256 else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            return bytes
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        try validate(args)
        try macWorkspacePreflight(path: args.path, context: context, scopeArgument: args.scope)
        if let source = args.sourcePath {
            try macWorkspacePreflight(path: source, context: context, scopeArgument: nil)
        }
        let (physicalRoot, relative) = try macWorkspacePinSetup(root: root, path: args.path)
        guard relative != "." else {
            throw MacAgentWorkspaceToolsError.invalidArguments(
                "path must name a file, not the workspace root"
            )
        }
        let limit = MacAgentWorkspaceTools.maxWriteBytes
        let data: Data
        if let source = args.sourcePath, let expectedSource = args.expectedSourceSHA256?.lowercased() {
            data = try verifiedSourceBytes(
                physicalRoot: physicalRoot, path: source, expectedSHA256: expectedSource
            )
            guard data.count <= limit else { throw MacAgentWorkspaceToolsError.tooLarge(limit: limit) }
        } else if let inline = args.content {
            data = Data(inline.utf8)
            guard data.count <= limit else { throw MacAgentWorkspaceToolsError.tooLarge(limit: limit) }
            guard !data.contains(0) else { throw MacAgentWorkspaceToolsError.notTextFile(args.path) }
        } else {
            throw MacAgentWorkspaceToolsError.invalidArguments("Missing text source")
        }

        let receipt = try MacAgentWorkspacePinSupport.withPinnedTarget(
            physicalRoot: physicalRoot, relative: relative, root: root
        ) { pin in
            let status = MacAgentWorkspacePinSupport.leafStatus(pin)
            let sourceFinalizing = args.sourcePath != nil
            guard status.exists else {
                guard status.missing else {
                    throw MacAgentWorkspaceToolsError.invalidArguments(
                        "the target '\(args.path)' cannot be inspected: errno \(errno)"
                    )
                }
                // A stale expectation on a missing target is a conflict, never
                // permission to create (mirrors the shared workspace service).
                guard args.expectedSHA256 == nil, args.expectedMtime == nil else {
                    throw MacAgentWorkspaceToolsError.revisionChanged
                }
                return try MacAgentWorkspaceTextMutation.publishNewFile(
                    pin: pin, data: data, displayPath: args.path, cancellation: context.cancellation
                )
            }
            guard !status.symlink else {
                throw MacAgentWorkspaceToolsError.pathEscapesWorkspace(args.path)
            }
            guard status.info.st_mode & S_IFMT == S_IFREG else {
                throw MacAgentWorkspaceToolsError.isDirectory(args.path)
            }
            guard status.info.st_nlink == 1 else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            guard status.info.st_mode & (S_ISUID | S_ISGID) == 0 else {
                throw MacAgentWorkspaceToolsError.invalidArguments(
                    "files with setuid or setgid permissions cannot be edited"
                )
            }
            if sourceFinalizing, args.expectedSHA256 == nil, args.expectedMtime == nil {
                // Source finalization without a target precondition is
                // create-only; a retry can never replace an unobserved
                // revision (mirrors the shared workspace service).
                throw MacAgentWorkspaceToolsError.targetAlreadyExists(args.path)
            }
            let originalFD = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(
                pin, physicalRoot: physicalRoot, displayPath: args.path, writable: true
            )
            defer { Darwin.close(originalFD) }
            guard flock(originalFD, LOCK_EX | LOCK_NB) == 0 else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            var identity = stat()
            guard fstat(originalFD, &identity) == 0 else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            let original = try MacAgentWorkspaceTextMutation.readBytes(originalFD, limit: limit)
            if let expected = args.expectedSHA256?.lowercased(),
               FloeDigest.sha256Hex(original) != expected {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            if let expectedMtime = args.expectedMtime {
                let actual = TimeInterval(identity.st_mtimespec.tv_sec)
                    + TimeInterval(identity.st_mtimespec.tv_nsec) / 1_000_000_000
                guard abs(actual - expectedMtime) <= 0.001 else {
                    throw MacAgentWorkspaceToolsError.revisionChanged
                }
            }
            if original == data {
                let mtime = TimeInterval(identity.st_mtimespec.tv_sec)
                    + TimeInterval(identity.st_mtimespec.tv_nsec) / 1_000_000_000
                return MacAgentWorkspaceTextMutation.Receipt(
                    sha256: FloeDigest.sha256Hex(original), byteCount: original.count, mtime: mtime, previous: nil
                )
            }
            return try MacAgentWorkspaceTextMutation.publishStagedReplacement(
                pin: pin, originalFD: originalFD, originalIdentity: identity,
                originalBytes: original, updated: data, relative: relative,
                limit: limit, cancellation: context.cancellation
            )
        }
        return receipt.result("written=\(relative) bytes=\(receipt.byteCount) sha256=\(receipt.sha256) mtime=\(receipt.mtime)",
                              path: relative)
    }
}

// MARK: workspace.appendFile

/// Appends UTF-8 text to an existing workspace file. The optional pre-edit
/// SHA256 (from `workspace.inspectFileMetadata`) makes chunked draft retries
/// safe; the commit itself always compares the opened revision against the
/// staged bytes, so concurrent edits fail closed with or without a
/// precondition. The original bytes (BOM and CRLF included) are preserved
/// and the previous revision stays recoverable beside the file.
public struct MacAgentWorkspaceAppendFileTool: AgentTool, MacAgentWorkspaceExecutable {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var content: String
        public var expectedSHA256: String?
        public var scope: String?

        public init(path: String, content: String, expectedSHA256: String? = nil, scope: String? = nil) {
            self.path = path
            self.content = content
            self.expectedSHA256 = expectedSHA256
            self.scope = scope
        }
    }

    public static let name = MacAgentWorkspaceTools.appendFileToolName
    public static let toolDescription =
        "Append UTF-8 text to an existing plain-text workspace file: source code, scripts, HTML/CSS/JS, JSON/YAML/CSV, LaTeX, TXT, configuration, or an extensionless/unknown-extension file. Preserves the complete original bytes (including a UTF-8 BOM and CRLF newlines) and keeps the previous revision recoverable beside the file. Pass the complete pre-edit SHA256 from workspace.inspectFileMetadata as expectedSHA256 for safe chunk retries; the write still compares the opened revision against the staged bytes at commit, so concurrent edits are detected even without a precondition. For long text, append bounded chunks with the previous returned SHA as expectedSHA256."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path to an existing UTF-8 text file"},
        "content": {"type": "string", "description": "Exact UTF-8 text to append"},
        "expectedSHA256": {"type": "string", "description": "SHA of the complete file BEFORE this mutation; pass the previous returned SHA for safe chunk retries, never advance it when resending the same chunk"}
      },
      "required": ["path", "content"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true

    static let descriptor = ToolCatalog.Descriptor(
        name: name,
        toolDescription: toolDescription,
        parametersJSON: parametersJSON,
        riskLabels: riskLabels,
        isSideEffecting: isSideEffecting,
        requiresHostScope: false
    )

    private let root: MacAgentWorkspaceRoot
    public init(rootURL: URL) { root = MacAgentWorkspaceRoot(rootURL) }

    public func validate(_ args: Arguments) throws {
        guard !args.path.isEmpty else {
            throw MacAgentWorkspaceToolsError.invalidArguments("path is required")
        }
        if let digest = args.expectedSHA256?.lowercased().utf8 {
            guard digest.count == 64, digest.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw MacAgentWorkspaceToolsError.invalidArguments("expectedSHA256 must be a complete 64-digit SHA256")
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        try validate(args)
        try macWorkspacePreflight(path: args.path, context: context, scopeArgument: args.scope)
        let (physicalRoot, relative) = try macWorkspacePinSetup(root: root, path: args.path)
        let limit = MacAgentWorkspaceTools.maxWriteBytes
        let append = Data(args.content.utf8)
        guard append.count <= limit else { throw MacAgentWorkspaceToolsError.tooLarge(limit: limit) }

        let receipt = try MacAgentWorkspacePinSupport.withPinnedTarget(
            physicalRoot: physicalRoot, relative: relative, root: root
        ) { pin in
            let status = MacAgentWorkspacePinSupport.leafStatus(pin)
            guard status.exists else { throw MacAgentWorkspaceToolsError.notFound(args.path) }
            guard !status.symlink else {
                throw MacAgentWorkspaceToolsError.pathEscapesWorkspace(args.path)
            }
            guard status.info.st_mode & S_IFMT == S_IFREG else {
                throw MacAgentWorkspaceToolsError.isDirectory(args.path)
            }
            guard status.info.st_nlink == 1 else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            guard status.info.st_mode & (S_ISUID | S_ISGID) == 0 else {
                throw MacAgentWorkspaceToolsError.invalidArguments(
                    "files with setuid or setgid permissions cannot be edited"
                )
            }
            let originalFD = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(
                pin, physicalRoot: physicalRoot, displayPath: args.path, writable: true
            )
            defer { Darwin.close(originalFD) }
            guard flock(originalFD, LOCK_EX | LOCK_NB) == 0 else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            var identity = stat()
            guard fstat(originalFD, &identity) == 0 else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            let original = try MacAgentWorkspaceTextMutation.readBytes(originalFD, limit: limit)
            // Optional precondition: when the caller passes the observed
            // pre-edit SHA, it must match the opened revision. The actual
            // compare-and-swap happens at commit regardless, inside
            // publishStagedReplacement (opened bytes vs. staged bytes).
            if let expected = args.expectedSHA256?.lowercased(),
               FloeDigest.sha256Hex(original) != expected {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            guard let text = WorkspaceTextPolicy.decodeUTF8(original) else {
                throw MacAgentWorkspaceToolsError.notTextFile(args.path)
            }
            guard !append.contains(0) else { throw MacAgentWorkspaceToolsError.notTextFile(args.path) }
            let updated = Data((text + args.content).utf8)
            guard updated.count <= limit else { throw MacAgentWorkspaceToolsError.tooLarge(limit: limit) }
            if updated == original {
                let mtime = TimeInterval(identity.st_mtimespec.tv_sec)
                    + TimeInterval(identity.st_mtimespec.tv_nsec) / 1_000_000_000
                return MacAgentWorkspaceTextMutation.Receipt(
                    sha256: FloeDigest.sha256Hex(original), byteCount: original.count, mtime: mtime, previous: nil
                )
            }
            return try MacAgentWorkspaceTextMutation.publishStagedReplacement(
                pin: pin, originalFD: originalFD, originalIdentity: identity,
                originalBytes: original, updated: updated, relative: relative,
                limit: limit, cancellation: context.cancellation
            )
        }
        return receipt.result("edited=\(relative) bytes=\(receipt.byteCount) sha256=\(receipt.sha256) mtime=\(receipt.mtime)",
                              path: relative)
    }
}

// MARK: workspace.applyPatch

/// Applies a single-file unified diff to an existing workspace file through
/// the shared `WorkspaceTextMutationContract` engine. Hunks apply
/// sequentially against the current revision; any malformed, multi-file or
/// context-mismatched patch leaves the file untouched. The previous revision
/// stays recoverable beside the file when a change is committed.
public struct MacAgentWorkspaceApplyPatchTool: AgentTool, MacAgentWorkspaceExecutable {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        /// Standard unified diff (`diff -u` subset, single file).
        public var patch: String
        public var scope: String?

        public init(path: String, patch: String, scope: String? = nil) {
            self.path = path
            self.patch = patch
            self.scope = scope
        }
    }

    public static let name = MacAgentWorkspaceTools.applyPatchToolName
    public static let toolDescription =
        "Apply a single-file unified diff to any UTF-8 plain-text workspace file: code, scripts, HTML/CSS/JS, JSON/YAML/CSV, LaTeX, TXT, configuration, or an extensionless/unknown-extension file. Hunks apply sequentially; if any hunk fails, the file is left untouched. Multi-file patches are rejected. Read the file first; its current bytes supply the patch context, and BOM/CRLF bytes are preserved when the hunk context matches them."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative plain-text file path to patch"},
        "patch": {"type": "string", "description": "Unified diff (diff -u subset) for this one file; context must match the file's BOM/CRLF bytes"}
      },
      "required": ["path", "patch"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true

    static let descriptor = ToolCatalog.Descriptor(
        name: name,
        toolDescription: toolDescription,
        parametersJSON: parametersJSON,
        riskLabels: riskLabels,
        isSideEffecting: isSideEffecting,
        requiresHostScope: false
    )

    private let root: MacAgentWorkspaceRoot
    private let artifactRoot: URL?
    public init(rootURL: URL, artifactRoot: URL? = nil) {
        root = MacAgentWorkspaceRoot(rootURL)
        self.artifactRoot = artifactRoot
    }

    public func validate(_ args: Arguments) throws {
        guard !args.path.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MacAgentWorkspaceToolsError.invalidArguments("path must not be empty")
        }
        guard !args.patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacAgentWorkspaceToolsError.invalidArguments("patch must not be empty")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        try validate(args)
        try macWorkspacePreflight(path: args.path, context: context, scopeArgument: args.scope)
        let (physicalRoot, relative) = try macWorkspacePinSetup(root: root, path: args.path)
        let limit = MacAgentWorkspaceTools.maxWriteBytes

        let (receipt, application): (MacAgentWorkspaceTextMutation.Receipt, WorkspaceTextMutationContract.Application) = try MacAgentWorkspacePinSupport.withPinnedTarget(
            physicalRoot: physicalRoot, relative: relative, root: root
        ) { pin in
            let status = MacAgentWorkspacePinSupport.leafStatus(pin)
            guard status.exists else { throw MacAgentWorkspaceToolsError.notFound(args.path) }
            guard !status.symlink else {
                throw MacAgentWorkspaceToolsError.pathEscapesWorkspace(args.path)
            }
            guard status.info.st_mode & S_IFMT == S_IFREG else {
                throw MacAgentWorkspaceToolsError.isDirectory(args.path)
            }
            guard status.info.st_nlink == 1 else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            guard status.info.st_mode & (S_ISUID | S_ISGID) == 0 else {
                throw MacAgentWorkspaceToolsError.invalidArguments(
                    "files with setuid or setgid permissions cannot be edited"
                )
            }
            let originalFD = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(
                pin, physicalRoot: physicalRoot, displayPath: args.path, writable: true
            )
            defer { Darwin.close(originalFD) }
            guard flock(originalFD, LOCK_EX | LOCK_NB) == 0 else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            var identity = stat()
            guard fstat(originalFD, &identity) == 0 else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            let original = try MacAgentWorkspaceTextMutation.readBytes(originalFD, limit: limit)
            guard let text = WorkspaceTextPolicy.decodeUTF8(original) else {
                throw MacAgentWorkspaceToolsError.notTextFile(args.path)
            }

            let hunks: [WorkspaceTextMutationContract.Hunk]
            do {
                hunks = try WorkspaceTextMutationContract.parseUnifiedDiff(args.patch)
            } catch let error as WorkspaceTextMutationContract.ContractError {
                throw MacAgentWorkspaceToolsError.invalidPatch(error.reason)
            }
            let application: WorkspaceTextMutationContract.Application
            do {
                application = try WorkspaceTextMutationContract.apply(hunks: hunks, to: text) {
                    try context.cancellation.throwIfCancelled()
                }
            } catch let error as WorkspaceTextMutationContract.ContractError {
                throw MacAgentWorkspaceToolsError.invalidPatch(error.reason)
            }
            let updated = Data(application.text.utf8)
            guard updated.count <= limit else { throw MacAgentWorkspaceToolsError.tooLarge(limit: limit) }
            if updated == original {
                let receipt = MacAgentWorkspaceTextMutation.Receipt(
                    sha256: FloeDigest.sha256Hex(original), byteCount: original.count, mtime: 0, previous: nil
                )
                return (receipt, application)
            }
            let published = try MacAgentWorkspaceTextMutation.publishStagedReplacement(
                pin: pin, originalFD: originalFD, originalIdentity: identity,
                originalBytes: original, updated: updated, relative: relative,
                limit: limit, cancellation: context.cancellation
            )
            return (published, application)
        }
        let hunks = " hunks=\(application.hunksApplied) added=\(application.linesAdded) removed=\(application.linesRemoved)"
        var output = receipt.result("patched=\(relative)\(hunks) sha256=\(receipt.sha256)", path: relative)
        if receipt.change == .modified, let artifactRoot,
           let ref = try? FloeArtifactStore.storeChangeDiff(args.patch, runID: context.runID, root: artifactRoot) {
            output.artifacts.append(ref)
        }
        return output
    }
}

// MARK: workspace.createDirectory

/// Creates a directory (and any missing parent directories) in the
/// workspace, one pinned `mkdirat` per component, failing closed when a file
/// or symlink already occupies a component.
public struct MacAgentWorkspaceCreateDirectoryTool: AgentTool, MacAgentWorkspaceExecutable {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var scope: String?

        public init(path: String, scope: String? = nil) {
            self.path = path
            self.scope = scope
        }
    }

    public static let name = MacAgentWorkspaceTools.createDirectoryToolName
    public static let toolDescription =
        "Create a new directory (and any missing parent directories) in the workspace. Fails when a file or link already exists at the path, or when the directory already exists."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative directory path to create"}
      },
      "required": ["path"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true

    static let descriptor = ToolCatalog.Descriptor(
        name: name,
        toolDescription: toolDescription,
        parametersJSON: parametersJSON,
        riskLabels: riskLabels,
        isSideEffecting: isSideEffecting,
        requiresHostScope: false
    )

    private let root: MacAgentWorkspaceRoot
    public init(rootURL: URL) { root = MacAgentWorkspaceRoot(rootURL) }

    public func validate(_ args: Arguments) throws {
        guard !args.path.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MacAgentWorkspaceToolsError.invalidArguments("path must not be empty")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        try validate(args)
        try macWorkspacePreflight(path: args.path, context: context, scopeArgument: args.scope)
        let (physicalRoot, relative) = try macWorkspacePinSetup(root: root, path: args.path)
        guard relative != "." else {
            throw MacAgentWorkspaceToolsError.invalidArguments(
                "path must name a new directory, not the workspace root"
            )
        }
        try MacAgentWorkspacePinSupport.createDirectoryChain(
            physicalRoot: physicalRoot, relative: relative, root: root
        )
        return ToolExecutionOutput(digesting: "created=\(relative)", maximumSummaryCharacters: 4096)
    }
}

// MARK: - Approval preview

/// Decodes one workspace write call into the manual-approval preview triple
/// (path, proposed text, previous text) consumed by the host approval card.
/// `workspace.createDirectory` has no text payload — its path alone is the
/// review surface. Returns nil for calls outside the text-authoring lane so
/// the host can fall back to its other preview surfaces.
enum MacAgentWorkspaceMutationPreview {
    static func preview(of call: ToolCall) -> (path: String?, text: String?, previousText: String?)? {
        let decoder = JSONDecoder()
        switch call.toolName {
        case MacAgentWorkspaceTools.createFileToolName:
            guard let args = try? decoder.decode(
                MacAgentWorkspaceCreateFileTool.Arguments.self, from: call.argumentsJSON
            ) else { return nil }
            return (args.path, args.content, nil)
        case MacAgentWorkspaceTools.replaceTextToolName:
            guard let args = try? decoder.decode(
                MacAgentWorkspaceReplaceTextTool.Arguments.self, from: call.argumentsJSON
            ) else { return nil }
            return (args.path, args.newText, args.oldText)
        case MacAgentWorkspaceTools.writeFileToolName:
            guard let args = try? decoder.decode(
                MacAgentWorkspaceWriteFileTool.Arguments.self, from: call.argumentsJSON
            ) else { return nil }
            if let source = args.sourcePath, let digest = args.expectedSourceSHA256 {
                let sourcePreview = MacPermissionsText.t(
                    "从草稿写入 \(source)\n校验 SHA-256 \(digest)",
                    "Write from draft \(source)\nVerify SHA-256 \(digest)"
                )
                return (args.path, sourcePreview, nil)
            }
            return (args.path, args.content, nil)
        case MacAgentWorkspaceTools.appendFileToolName:
            guard let args = try? decoder.decode(
                MacAgentWorkspaceAppendFileTool.Arguments.self, from: call.argumentsJSON
            ) else { return nil }
            return (args.path, args.content, nil)
        case MacAgentWorkspaceTools.applyPatchToolName:
            guard let args = try? decoder.decode(
                MacAgentWorkspaceApplyPatchTool.Arguments.self, from: call.argumentsJSON
            ) else { return nil }
            return (args.path, args.patch, nil)
        case MacAgentWorkspaceTools.createDirectoryToolName:
            guard let args = try? decoder.decode(
                MacAgentWorkspaceCreateDirectoryTool.Arguments.self, from: call.argumentsJSON
            ) else { return nil }
            return (args.path, nil, nil)
        default:
            return nil
        }
    }
}

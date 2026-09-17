// SPDX-License-Identifier: MPL-2.0
//
// IDERunSourceStaging — the verified current-file transfer used before any
// remote IDE run. A remote plan is meaningless unless the remote host holds
// exactly the bytes the user just saved, so this module stages the saved
// snapshot through the paired host's Floe remote agent (v1/files/write +
// v1/files/read over the verified SSH tunnel) and proves the landing
// revision before the controller is allowed to dispatch:
//
// * every run stages into a run-owned, isolated directory
//   `floe-ide-run/<token>/` below the daemon cloud-workspace root; the
//   workspace-relative path is preserved inside it so two files with the
//   same basename never collide;
// * a `.floe-run-token` ownership marker is written first. Existing content
//   under the run path that is not ours is a conflict, never something to
//   clobber; an identical re-stage of the same token is an idempotent
//   resume;
// * after writing, the source is read back and must match the saved bytes
//   exactly (byte count, daemon-reported SHA-256 and a full byte compare);
// * the module is pure Foundation and transport-agnostic: production wires
//   `CloudWorkspaceService`, tests inject a fake transport. No credential
//   ever appears here — the tunnel token stays inside the service.
//
// Single-file mode is explicit: only the current file is staged. Project
// dependencies are not transferred, and the UI must not claim a whole-
// project build from this path.

import Foundation

// MARK: - Layout

/// Pure path layout for run-owned remote staging. The daemon resolves every
/// path relative to its cloud-workspace root (`resolve()` in
/// floe_remote_agent.py confines it there), so a staged path can never
/// escape into arbitrary host directories.
enum IDERunStagingLayout {
    /// Top-level directory, below the daemon root, that owns every IDE run.
    static let rootPrefix = "floe-ide-run"
    /// Ownership marker file name inside each run-owned staging root.
    static let markerName = ".floe-run-token"
    /// The daemon's default cloud-workspace root, expressed relative to the
    /// remote home directory (matches `FLOE_CLOUD_ROOT` default in
    /// floe_remote_agent.py and the installer's mkdir). A customized daemon
    /// root is detected by the SSH visibility probe, never guessed.
    static let daemonRootHomeRelative = ".floe/cloud-workspaces"
    /// Printed by the SSH visibility probe on success.
    static let visibilityMarker = "floe-ide-staged-visible"
    /// Printed by the marker-guarded cleanup command after it removed the
    /// run-owned directory.
    static let cleanupRemovedMarker = "floe-ide-cleanup-removed"
    /// Printed by the marker-guarded cleanup command when the run path does
    /// not (or no longer) carries this run's ownership marker. In that case
    /// nothing is removed: the path is not proven to be this run's.
    static let cleanupSkippedMarker = "floe-ide-cleanup-skipped"

    /// Token charset is restricted so the value can be embedded literally
    /// inside a single-quoted remote trap string.
    static func sanitizedToken(_ raw: String) -> String {
        let allowed = raw.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        let value = String(allowed.prefix(48))
        return value.isEmpty ? "run" : value
    }

    /// Every daemon-root-relative path one run owns.
    struct StagedPaths: Sendable, Equatable {
        let runToken: String
        /// `floe-ide-run/<token>` — the only directory the run may remove.
        let stagingRoot: String
        /// `floe-ide-run/<token>/<workspace-relative path>`.
        let stagedSourcePath: String
        /// `floe-ide-run/<token>/.floe-run-token`.
        let markerPath: String
        /// Directory of the staged source; the remote run cd's here.
        let workingDirectory: String
        /// Basename handed to the compile/run templates as `{source}`.
        let sourceFileName: String
    }

    /// Resolves the staging layout for a workspace-relative source path, or
    /// nil when the path cannot be represented safely. The workspace-relative
    /// structure is kept below the run token so `a/main.c` and `b/main.c`
    /// stage to distinct files.
    static func stagedPaths(workspaceRelativePath: String, runToken: String) -> StagedPaths? {
        guard IDELanguageRunPolicy.isSafeWorkspaceRelativePath(workspaceRelativePath) else { return nil }
        let token = sanitizedToken(runToken)
        let components = workspaceRelativePath.split(separator: "/").map(String.init)
        guard let fileName = components.last, !fileName.isEmpty else { return nil }
        let root = "\(rootPrefix)/\(token)"
        let staged = root + "/" + components.joined(separator: "/")
        let workdir = components.count > 1
            ? root + "/" + components.dropLast().joined(separator: "/")
            : root
        return StagedPaths(
            runToken: token,
            stagingRoot: root,
            stagedSourcePath: staged,
            markerPath: root + "/" + markerName,
            workingDirectory: workdir,
            sourceFileName: fileName
        )
    }
}

// MARK: - Cleanup outcome

/// Result of the marker-guarded cleanup a run performs when it aborts after
/// staging but before its execution trap was installed. `unconfirmed` is the
/// honest state when the host did not report a known cleanup marker: the
/// caller must keep that recovery detail instead of assuming the directory is
/// gone. Foreign data is never deleted, so `skippedForeignData` is a safe
/// no-op, not a failure.
enum IDERunStagingCleanupOutcome: Sendable, Equatable {
    /// This run's staging root was removed.
    case removed
    /// The path did not carry this run's marker; nothing was deleted.
    case skippedForeignData
    /// The host did not prove the outcome (transport/command failure or an
    /// unrecognized reply); the directory may remain.
    case unconfirmed(detail: String)
}

// MARK: - Bounded source read

/// Reads the exact saved source with a hard allocation cap. `Data(contentsOf:)`
/// followed by a size check allocates the whole file first, so a file grown
/// after the check could exhaust memory; this reads at most `maxBytes + 1`
/// bytes and fails as `sourceTooLarge` when the extra byte proves oversize.
/// Directory and non-regular targets are refused before any read. Callers must
/// pass an already-confined URL (see `WorkspacePathGuard.resolve`), so a
/// symlink escaping the workspace is rejected before this function runs.
enum IDERunSourceReader {
    static func readRegularFile(
        at url: URL,
        maxBytes: Int,
        fileManager: FileManager = .default
    ) throws -> Data {
        guard maxBytes >= 0 else { throw IDERunStagingFailure.sourceTooLarge(limit: maxBytes) }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        } catch {
            throw IDERunStagingFailure.sourceUnreadable
        }
        guard values.isDirectory != true, values.isRegularFile == true else {
            throw IDERunStagingFailure.sourceUnreadable
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw IDERunStagingFailure.sourceUnreadable
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        } catch {
            throw IDERunStagingFailure.sourceUnreadable
        }
        guard data.count <= maxBytes else {
            throw IDERunStagingFailure.sourceTooLarge(limit: maxBytes)
        }
        return data
    }
}

// MARK: - Failures

/// Typed staging failure. The controller localizes these; no English text is
/// baked into the staging layer.
enum IDERunStagingFailure: Error, Sendable, Equatable {
    /// The workspace-relative path failed the safety check.
    case invalidSourcePath
    /// The saved file exceeds the staging budget.
    case sourceTooLarge(limit: Int)
    /// The just-saved bytes could not be read back from local storage.
    case sourceUnreadable
    /// The run path holds data this run does not own (foreign or mismatched
    /// marker, or a conflicting file). Nothing was overwritten.
    case conflict
    /// The daemon did not acknowledge the exact SHA-256 of the bytes sent.
    case writeFailed
    /// The remote read-back does not equal the saved bytes exactly.
    case verificationFailed
    /// The staged file is not visible through the SSH shell at the daemon's
    /// default cloud root (for example a customized FLOE_CLOUD_ROOT).
    case notVisibleOnHost
}

// MARK: - Plan and receipt

struct IDERunStagingPlan: Sendable, Equatable {
    let paths: IDERunStagingLayout.StagedPaths
    let byteCount: Int
    /// SHA-256 of the exact saved bytes, computed locally before transfer.
    let expectedSHA256: String
    /// SHA-256 of the ownership marker contents (the sanitized token).
    let markerSHA256: String
}

struct IDERunStagingReceipt: Sendable, Equatable {
    let plan: IDERunStagingPlan
    /// True when an identical earlier stage of the same run was reused
    /// instead of written again.
    let resumed: Bool
}

// MARK: - Transport

/// The narrow file-verbs the stager needs. Production adapts
/// `CloudWorkspaceService` (verified SSH tunnel + loopback agent); tests
/// inject fakes. All paths are daemon-cloud-root-relative.
protocol IDERunStagingTransport: Sendable {
    /// Atomically writes `data` at `relativePath`; returns the SHA-256 the
    /// remote side computed over the bytes it actually stored.
    func writeFile(relativePath: String, data: Data) async throws -> String
    /// Reads `relativePath`; returns nil only when the path does not exist.
    func readFile(relativePath: String) async throws -> (sha256: String, data: Data)?
}

// MARK: - Stager

/// Plans and executes one verified staging operation. The stager never
/// deletes anything remotely; cleanup of the run-owned directory is part of
/// the remote run command itself (status-preserving trap in the policy).
struct IDERunSourceStager: Sendable {
    let transport: any IDERunStagingTransport
    let maximumSourceBytes: Int
    let sha256: @Sendable (Data) -> String
    /// Cooperative cancellation probe, checked immediately before and after
    /// every transport read/write. A stop between the marker read and the
    /// marker write (or between the marker write and the source upload) must
    /// abort before the next landing side effect instead of completing the
    /// stage. Defaults to the current task; the app injects its per-attempt
    /// token so `IDELanguageRunController.stop()` is observed here too.
    let checkCancellation: @Sendable () throws -> Void

    init(
        transport: any IDERunStagingTransport,
        maximumSourceBytes: Int = 1_048_576,
        sha256: @escaping @Sendable (Data) -> String,
        checkCancellation: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) {
        self.transport = transport
        self.maximumSourceBytes = maximumSourceBytes
        self.sha256 = sha256
        self.checkCancellation = checkCancellation
    }

    /// One transport read bracketed by cancellation checks, so a stop during
    /// the read is observed before the caller can act on its result.
    private func readFile(_ relativePath: String) async throws -> (sha256: String, data: Data)? {
        try checkCancellation()
        let result = try await transport.readFile(relativePath: relativePath)
        try checkCancellation()
        return result
    }

    /// One transport write bracketed by cancellation checks. The pre-check
    /// prevents the write from starting; the post-check prevents a stop during
    /// the write from being mistaken for a completed, successful stage.
    private func writeFile(_ relativePath: String, data: Data) async throws -> String {
        try checkCancellation()
        let sha = try await transport.writeFile(relativePath: relativePath, data: data)
        try checkCancellation()
        return sha
    }

    /// Pure validation + hashing. Throws a typed failure before any byte is
    /// transferred.
    func plan(relativePath: String, source: Data, runToken: String) throws -> IDERunStagingPlan {
        guard let paths = IDERunStagingLayout.stagedPaths(workspaceRelativePath: relativePath, runToken: runToken) else {
            throw IDERunStagingFailure.invalidSourcePath
        }
        guard source.count <= maximumSourceBytes else {
            throw IDERunStagingFailure.sourceTooLarge(limit: maximumSourceBytes)
        }
        return IDERunStagingPlan(
            paths: paths,
            byteCount: source.count,
            expectedSHA256: sha256(source),
            markerSHA256: sha256(Data(paths.runToken.utf8))
        )
    }

    /// Stages the exact saved bytes and proves the landing revision.
    ///
    /// Ordering: the ownership marker is written before the source so a
    /// crashed stage leaves a marked (therefore removable-by-that-run)
    /// directory, and a foreign marker aborts before any write. The final
    /// read-back compares byte count, daemon SHA-256 and the full bytes.
    /// Cancellation is checked before and after every transport read/write, so
    /// a stop during the marker read can never proceed to write the marker or
    /// upload the source.
    func stage(plan: IDERunStagingPlan, source: Data) async throws -> IDERunStagingReceipt {
        // The bytes handed in must still be the bytes the plan hashed.
        guard source.count == plan.byteCount, sha256(source) == plan.expectedSHA256 else {
            throw IDERunStagingFailure.verificationFailed
        }
        try checkCancellation()
        let markerBytes = Data(plan.paths.runToken.utf8)
        var resumed = false
        if let existingMarker = try await readFile(plan.paths.markerPath) {
            // A marker exists: only the identical token may proceed.
            guard existingMarker.sha256 == plan.markerSHA256, existingMarker.data == markerBytes else {
                throw IDERunStagingFailure.conflict
            }
            resumed = true
        } else {
            // No marker: pre-existing source content at our run path belongs
            // to something else unless it is byte-identical to this stage.
            if let existingSource = try await readFile(plan.paths.stagedSourcePath),
               existingSource.sha256 != plan.expectedSHA256 {
                throw IDERunStagingFailure.conflict
            }
            let writtenMarkerSHA = try await writeFile(plan.paths.markerPath, data: markerBytes)
            guard writtenMarkerSHA == plan.markerSHA256 else {
                throw IDERunStagingFailure.writeFailed
            }
        }

        if resumed,
           let existingSource = try await readFile(plan.paths.stagedSourcePath),
           existingSource.sha256 == plan.expectedSHA256, existingSource.data == source {
            // Identical content already landed for this run token; resume.
        } else {
            let writtenSHA = try await writeFile(plan.paths.stagedSourcePath, data: source)
            guard writtenSHA == plan.expectedSHA256 else {
                throw IDERunStagingFailure.writeFailed
            }
        }

        // Read-back proof: the remote copy must equal the saved bytes
        // exactly, not merely report a success string.
        guard let readBack = try await readFile(plan.paths.stagedSourcePath),
              readBack.sha256 == plan.expectedSHA256,
              readBack.data == source else {
            throw IDERunStagingFailure.verificationFailed
        }
        guard let markerBack = try await readFile(plan.paths.markerPath),
              markerBack.data == markerBytes else {
            throw IDERunStagingFailure.verificationFailed
        }
        try checkCancellation()
        return IDERunStagingReceipt(plan: plan, resumed: resumed)
    }
}

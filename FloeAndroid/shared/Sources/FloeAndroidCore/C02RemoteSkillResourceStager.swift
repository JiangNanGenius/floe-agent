// SPDX-License-Identifier: MPL-2.0
//
// N07 remote lane — run-bound Skill resource staging over the REAL SFTP
// subsystem of the existing C02 SSH authority.
//
// This is the typed remote staging transport the SkillWorkspaceResourceStager
// remote lane rides. It never runs a remote command, never opens the
// model-facing C05 SFTP lanes, never copies bytes to a fallback local path,
// and never broadens any model-facing SFTP policy:
//
//   * AUTHORITY — one fresh `C02SSHExecutionAuthorization` is minted per
//     publish through the SAME C02ExecutionTargetDomain gate the remote shell
//     uses (policy, ownership, migration, host, run pin). No approval, no
//     bytes. The minted grant is re-validated by the adapter, and the
//     authoritative binding + scoped approval + epoch + cancellation are
//     RE-CHECKED through `beforePromote` directly before the commit: an
//     authority lost mid-transfer refuses instead of committing.
//   * TRANSPORT — ONE exclusive SFTP channel on a dedicated connection this
//     call owns end to end: the host key is decided against the approved
//     fingerprint from the pinned target (a first-use or changed key is the
//     existing typed refusal, never silently trusted), and the connection is
//     closed before the call returns. Nothing enters the exec session table.
//   * ROOTED PUBLICATION — the reserved tree is `<remoteRoot>/.floe/skills`
//     under the VERIFIED remote task root of the pinned target. The root and
//     every created directory are canonicalized over the same channel; a
//     symlinked, redirected or otherwise ambiguous component refuses
//     (`pathFence`) instead of writing. Lexical path grammar is re-checked
//     on this side before anything is sent.
//   * STAGE-THEN-PROMOTE — the complete bundle is uploaded into a UNIQUE
//     sibling staging directory (`.staging-<UUID>`, the local-lane pattern)
//     and verified byte-for-byte over the SAME channel BEFORE anything is
//     committed. Readers never observe a partial bundle: the final digest
//     directory appears only through one directory rename. On ANY error only
//     the uniquely owned staging directory is removed; the final path is
//     NEVER deleted after an uncertain commit, and an existing final is
//     adopted only by full byte-for-byte equality (never overwritten).
//     `SSH_FXP_RENAME` (Citadel `rename(at:to:flags: 0)`) leaves overwrite
//     semantics to the server (OpenSSH replaces existing targets), so
//     promotion never relies on no-replacement behavior: absence is re-proven
//     immediately before the rename and the committed tree is verified after
//     it.
//   * VISIBILITY — `applied` is returned only when the committed tree was
//     verified byte-for-byte over the SAME channel (the read-back is the ONLY
//     visibility authority for the remote lane); `refused` is a terminal
//     authority/filesystem refusal with a bounded code; `unconfirmed` means
//     the commit may or may not have landed and never invents visibility.
import Foundation
import FloeCore
import FloeTools
import FloeSkills
import FloeSSH

// MARK: - SFTP operation outcome

public enum C02RemoteSFTPStageOutcome: Sendable, Equatable {
    /// Every declared file is present and byte-verified on the remote target.
    case applied(uploaded: Int, reused: Int)
    /// A deterministic refusal with a bounded, printable token (never a host
    /// path, payload or free text).
    case refused(reason: String)
    /// The outcome is unknown (transport loss, timeout, cancellation, or a
    /// commit that could not be verified): the bundle may or may not be
    /// complete on the remote target.
    case unconfirmed(detail: String?)
}

private struct C02RemoteSFTPRefusal: Error {
    let outcome: C02RemoteSFTPStageOutcome
}

/// Carrier for the pre-promote authority recheck: the publisher's
/// `revalidatePromotion` seam throws this when the run's binding, scoped
/// approval or epoch is no longer current; the stager maps it to a precise
/// `refused` outcome and removes only the uniquely owned staging tree.
public struct C02RemotePromotionRefusal: Error, Sendable, Equatable {
    public var code: String
    public init(code: String) { self.code = code }
}

// MARK: - Typed SFTP staging operation

/// One bounded, cancellation-aware stage-then-promote publication of a
/// pinned bundle over ONE SFTP channel. The function is deliberately
/// transport-shaped: it depends on nothing but the `SSHSFTPChannel`
/// vocabulary, so deterministic fakes cover every branch (no real host
/// connection is ever needed).
public enum C02RemoteSkillSFTPStager {
    public static let transferChunkBytes = 32 * 1_024
    /// Bound for the recursive cleanup of OUR staging tree only.
    static let removalEntryCeiling = 10_000

    /// - Parameter beforePromote: authority recheck executed AFTER the
    ///   staging tree is complete and verified but BEFORE the commit
    ///   rename. Throwing aborts the commit, removes only the uniquely owned
    ///   staging tree and maps to a `refused` outcome (a
    ///   `C02RemotePromotionRefusal` carries its bounded code through).
    public static func stage(
        bundle: SkillStagingBundle,
        remoteRootPath: String,
        channel: any SSHSFTPChannel,
        cancellation: CancellationToken,
        beforePromote: (@Sendable () async throws -> Void)? = nil
    ) async -> C02RemoteSFTPStageOutcome {
        var root = remoteRootPath
        while root.count > 1, root.hasSuffix("/") { root = String(root.dropLast()) }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .unconfirmed(detail: "cancelled")
        }
        guard SkillWorkspaceResourceStager.isSafeRemoteRoot(root) else {
            return .refused(reason: "invalidRemoteRoot")
        }
        do {
            return try await stageThrowing(
                bundle: bundle, remoteRoot: root, channel: channel,
                cancellation: cancellation, beforePromote: beforePromote)
        } catch let refusal as C02RemoteSFTPRefusal {
            return refusal.outcome
        } catch let error as SSHSFTPError {
            return map(error)
        } catch is CancellationError {
            return .unconfirmed(detail: "cancelled")
        } catch {
            return .unconfirmed(detail: "transport")
        }
    }

    // MARK: Implementation

    private static func stageThrowing(
        bundle: SkillStagingBundle,
        remoteRoot: String,
        channel: any SSHSFTPChannel,
        cancellation: CancellationToken,
        beforePromote: (@Sendable () async throws -> Void)?
    ) async throws -> C02RemoteSFTPStageOutcome {
        // Canonical fence at the root: the resolved root must name the same
        // directory lexically and canonically. A symlinked or redirected root
        // can never receive bytes.
        let canonicalRoot = try await channel.canonicalPath(remoteRoot)
        guard canonicalRoot == remoteRoot else {
            throw C02RemoteSFTPRefusal(outcome: .refused(reason: "pathFence"))
        }
        let reservedRoot = try await ensureDirectory(
            path: remoteRoot + "/" + SkillWorkspaceResourceStager.reservedComponents.joined(separator: "/"),
            underRoot: remoteRoot,
            channel: channel,
            cancellation: cancellation)
        let leaf = "\(bundle.skillID)@\(bundle.digest)"
        let leafPath = reservedRoot + "/" + leaf
        let stagedFiles = bundle.files.map { (relativePath: $0.relativePath, data: $0.data) }
        try throwIfCancelled(cancellation)

        // Adopt an existing final ONLY by full byte-for-byte equality; a
        // foreign, damaged, symlinked or partial tree fails closed and stays
        // exactly as found (the historical partial-publication boundary).
        if let existing = try await statIfPresent(leafPath, channel: channel) {
            guard existing.isDirectory, !existing.isSymbolicLink else {
                throw C02RemoteSFTPRefusal(outcome: .refused(reason: "reservedConflict"))
            }
            guard try await verifyTree(
                at: leafPath, files: stagedFiles,
                channel: channel, cancellation: cancellation) else {
                throw C02RemoteSFTPRefusal(outcome: .refused(reason: "pathBlocked"))
            }
            return .applied(uploaded: 0, reused: bundle.files.count)
        }

        // Stage the complete bundle in a UNIQUE sibling directory and verify
        // it before anything is committed. Only this tree is ever removed by
        // this operation.
        let stagingPath = reservedRoot + "/" + SkillWorkspaceResourceStager.stagingPrefix
            + UUID().uuidString.lowercased()
        do {
            try await channel.createDirectory(path: stagingPath)
            for file in bundle.files {
                try throwIfCancelled(cancellation)
                let finalPath = stagingPath + "/" + file.relativePath
                try await ensureDirectory(
                    path: parentPath(of: finalPath), underRoot: remoteRoot,
                    channel: channel, cancellation: cancellation)
                try await writeVerifiedFile(file, at: finalPath, channel: channel,
                                            cancellation: cancellation)
            }
            // Whole-tree verification (exact shape, no extra entry, every
            // byte equal) BEFORE any authority is re-checked or byte tree is
            // committed.
            guard try await verifyTree(
                at: stagingPath, files: stagedFiles,
                channel: channel, cancellation: cancellation) else {
                throw C02RemoteSFTPRefusal(outcome: .refused(reason: "pathBlocked"))
            }
        } catch {
            // Any upload/verification failure: remove ONLY our staging tree.
            // The final path does not exist yet and is never created here.
            try? await removeTree(stagingPath, channel: channel)
            throw error
        }

        // Pre-commit authority recheck: binding, scoped approval, epoch and
        // cancellation are re-proven AFTER the verified stage and BEFORE the
        // commit. A revocation here removes only the staging tree.
        if let beforePromote {
            do {
                try await beforePromote()
                try throwIfCancelled(cancellation)
            } catch let refusal as C02RemotePromotionRefusal {
                try? await removeTree(stagingPath, channel: channel)
                throw C02RemoteSFTPRefusal(outcome: .refused(reason: refusal.code))
            } catch is CancellationError {
                try? await removeTree(stagingPath, channel: channel)
                throw CancellationError()
            } catch {
                try? await removeTree(stagingPath, channel: channel)
                throw C02RemoteSFTPRefusal(outcome: .refused(reason: "promotionRefused"))
            }
        } else {
            try throwIfCancelled(cancellation)
        }

        // Absence fence immediately before the commit: a concurrently
        // committed final is adopted by full equality, never overwritten.
        if let appeared = try await statIfPresent(leafPath, channel: channel) {
            let adopted: Bool
            if appeared.isDirectory && !appeared.isSymbolicLink {
                adopted = (try? await verifyTree(at: leafPath, files: stagedFiles,
                                                 channel: channel, cancellation: cancellation)) == true
            } else {
                adopted = false
            }
            try? await removeTree(stagingPath, channel: channel)
            if adopted {
                return .applied(uploaded: 0, reused: bundle.files.count)
            }
            throw C02RemoteSFTPRefusal(outcome: .refused(reason: "pathBlocked"))
        }

        do {
            try await channel.rename(from: stagingPath, to: leafPath)
        } catch {
            // Uncertain commit: `SSH_FXP_RENAME` may or may not have landed
            // (server overwrite semantics differ). Clean ONLY the uniquely
            // owned staging tree (best effort; it is gone if the rename
            // landed), then adopt a verified final. The final path is NEVER
            // deleted after an uncertain commit.
            try? await removeTree(stagingPath, channel: channel)
            if let committed = try await statIfPresent(leafPath, channel: channel),
               committed.isDirectory, !committed.isSymbolicLink,
               (try? await verifyTree(at: leafPath, files: stagedFiles,
                                      channel: channel, cancellation: cancellation)) == true {
                return .applied(uploaded: bundle.files.count, reused: 0)
            }
            throw error
        }

        // Post-commit verification over the SAME channel. A mismatch means
        // the commit is uncertain: report honestly and LEAVE the final path
        // exactly as committed (never delete it).
        guard try await verifyTree(
            at: leafPath, files: stagedFiles,
            channel: channel, cancellation: cancellation) else {
            return .unconfirmed(detail: "verifyFailed")
        }
        return .applied(uploaded: bundle.files.count, reused: 0)
    }

    // MARK: File write + read-back verification

    /// Writes one file inside OUR private staging tree (no reader observes
    /// partial bundle content there) and verifies the bytes by read-back
    /// over the same channel.
    private static func writeVerifiedFile(
        _ file: SkillStagingBundle.File,
        at path: String,
        channel: any SSHSFTPChannel,
        cancellation: CancellationToken
    ) async throws {
        let handle = try await channel.openWrite(path: path, createNew: true)
        do {
            var offset: UInt64 = 0
            while offset < UInt64(file.data.count) {
                try throwIfCancelled(cancellation)
                let end = min(offset + UInt64(transferChunkBytes), UInt64(file.data.count))
                try await handle.write(file.data.subdata(in: Int(offset)..<Int(end)), at: offset)
                offset = end
            }
            try await handle.close()
        } catch {
            try? await handle.close()
            throw error
        }
        let readBack = try await readAll(path, channel: channel, limit: file.data.count)
        guard readBack == file.data else {
            throw C02RemoteSFTPRefusal(outcome: .refused(reason: "pathBlocked"))
        }
    }

    // MARK: Tree verification (reuse/adoption is granted only by equality)

    private static func verifyTree(
        at path: String,
        files: [(relativePath: String, data: Data)],
        channel: any SSHSFTPChannel,
        cancellation: CancellationToken
    ) async throws -> Bool {
        try throwIfCancelled(cancellation)
        var immediate: [String: [(rem: String, data: Data)]] = [:]
        for file in files {
            let parts = file.relativePath.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, !first.isEmpty else { return false }
            let rem = parts.count == 2 ? String(parts[1]) : ""
            immediate[String(first), default: []].append((rem, file.data))
        }
        // The bounded listing returns at most immediate.count + 1 entries; a
        // fuller directory means foreign content.
        let entries = try await channel.listDirectory(at: path, maxEntries: max(1, immediate.count))
        guard entries.count <= immediate.count else { return false }
        for (name, children) in immediate {
            guard let entry = entries.first(where: { $0.name == name }) else { return false }
            let attributes = entry.attributes
            guard !attributes.isSymbolicLink else { return false }
            let childPath = path + "/" + name
            let subFiles = children.filter { !$0.rem.isEmpty }
            let direct = children.filter { $0.rem.isEmpty }
            guard !subFiles.isEmpty || direct.count == 1,
                  !(subFiles.isEmpty && direct.isEmpty) else { return false }
            if !subFiles.isEmpty {
                guard attributes.isDirectory else { return false }
                let nested = subFiles.map { (relativePath: $0.rem, data: $0.data) }
                guard try await verifyTree(
                    at: childPath, files: nested,
                    channel: channel, cancellation: cancellation) else { return false }
            } else {
                guard !attributes.isDirectory,
                      attributes.size == Int64(direct[0].data.count),
                      try await readAll(childPath, channel: channel, limit: direct[0].data.count) == direct[0].data else {
                    return false
                }
            }
        }
        return true
    }

    // MARK: Rooted directory creation

    /// Walks the components under `underRoot`, validating every existing
    /// component as a real non-symlink directory whose canonical path equals
    /// its lexical path, and creating missing ones. A planted symlink, a
    /// redirected component or a type conflict refuses; nothing is ever
    /// written outside the canonical root.
    private static func ensureDirectory(
        path: String,
        underRoot: String,
        channel: any SSHSFTPChannel,
        cancellation: CancellationToken
    ) async throws -> String {
        guard path.hasPrefix(underRoot + "/") else {
            throw C02RemoteSFTPRefusal(outcome: .refused(reason: "pathFence"))
        }
        let relative = path.dropFirst(underRoot.count + 1)
        var current = underRoot
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            try throwIfCancelled(cancellation)
            current += "/" + component
            if let existing = try await statIfPresent(current, channel: channel) {
                guard existing.isDirectory, !existing.isSymbolicLink else {
                    throw C02RemoteSFTPRefusal(outcome: .refused(reason: "reservedConflict"))
                }
                let canonical = try await channel.canonicalPath(current)
                guard canonical == current else {
                    throw C02RemoteSFTPRefusal(outcome: .refused(reason: "pathFence"))
                }
            } else {
                do {
                    try await channel.createDirectory(path: current)
                } catch let error as SSHSFTPError {
                    if case .alreadyExists = error {
                        guard let raced = try await statIfPresent(current, channel: channel),
                              raced.isDirectory, !raced.isSymbolicLink else {
                            throw C02RemoteSFTPRefusal(outcome: .refused(reason: "reservedConflict"))
                        }
                    } else {
                        throw error
                    }
                }
                let canonical = try await channel.canonicalPath(current)
                guard canonical == current else {
                    throw C02RemoteSFTPRefusal(outcome: .refused(reason: "pathFence"))
                }
            }
        }
        return current
    }

    // MARK: Cleanup of uniquely owned staging trees only

    /// Best-effort recursive removal of ONE directory this operation created.
    /// Every entry removed is beneath `path`; symlinks are removed without
    /// being followed; all failures are swallowed (cleanup never masks the
    /// original outcome). The final digest path is NEVER passed here after a
    /// commit attempt.
    private static func removeTree(
        _ path: String,
        channel: any SSHSFTPChannel
    ) async throws {
        guard let entries = try? await channel.listDirectory(
            at: path, maxEntries: removalEntryCeiling) else { return }
        for entry in entries {
            let child = path + "/" + entry.name
            if entry.attributes.isDirectory, !entry.attributes.isSymbolicLink {
                try? await removeTree(child, channel: channel)
            } else {
                try? await channel.removeFile(path: child)
            }
        }
        try? await channel.removeDirectory(path: path)
    }

    // MARK: Small helpers

    private static func statIfPresent(
        _ path: String,
        channel: any SSHSFTPChannel
    ) async throws -> SSHSFTPAttributes? {
        do {
            return try await channel.stat(path: path)
        } catch let error as SSHSFTPError where error == .notFound {
            return nil
        }
    }

    private static func readAll(
        _ path: String,
        channel: any SSHSFTPChannel,
        limit: Int
    ) async throws -> Data {
        let handle = try await channel.openRead(path: path)
        var data = Data()
        var offset: UInt64 = 0
        do {
            while data.count <= limit {
                let chunk = try await handle.read(at: offset, maxBytes: transferChunkBytes)
                if chunk.isEmpty { break }
                data.append(chunk)
                offset += UInt64(chunk.count)
            }
            await handle.close()
        } catch {
            await handle.close()
            throw error
        }
        return data
    }

    private static func parentPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        let parent = String(path[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    private static func throwIfCancelled(_ cancellation: CancellationToken) throws {
        if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
    }

    /// Deterministic mapping from the bounded transport vocabulary. Refusals
    /// are terminal facts; connection-class errors stay unconfirmed.
    static func map(_ error: SSHSFTPError) -> C02RemoteSFTPStageOutcome {
        switch error {
        case .cancelled:
            return .unconfirmed(detail: "cancelled")
        case .permissionDenied:
            return .refused(reason: "permissionDenied")
        case .notFound:
            return .unconfirmed(detail: "notFound")
        case .alreadyExists:
            return .refused(reason: "conflict")
        case .isDirectory, .notDirectory:
            return .refused(reason: "typeMismatch")
        case .invalidPath:
            return .refused(reason: "invalidPath")
        case .fileHandleInvalid:
            return .unconfirmed(detail: "fileHandleInvalid")
        case .connectionLost:
            return .unconfirmed(detail: "connectionLost")
        case .timeout:
            return .unconfirmed(detail: "timeout")
        case .protocolFailure:
            return .refused(reason: "protocolFailure")
        case .unsupportedByServer:
            return .refused(reason: "unsupportedByServer")
        case .notConnected:
            return .unconfirmed(detail: "notConnected")
        case .transport:
            return .unconfirmed(detail: "transport")
        case .status(let code, _):
            return .refused(reason: "status_\(code)")
        }
    }
}

// MARK: - Production run-bound publisher

/// One staged-then-promoted publication request over the publisher's SFTP
/// seam. `beforePromote` is the pre-commit authority recheck the stager
/// executes after the verified stage and before the commit rename.
public struct C02RemoteSFTPStageRequest: Sendable {
    public var bundle: SkillStagingBundle
    public var authorization: C02SSHExecutionAuthorization
    public var cancellation: CancellationToken
    public var beforePromote: (@Sendable () async throws -> Void)?

    public init(
        bundle: SkillStagingBundle,
        authorization: C02SSHExecutionAuthorization,
        cancellation: CancellationToken,
        beforePromote: (@Sendable () async throws -> Void)? = nil
    ) {
        self.bundle = bundle
        self.authorization = authorization
        self.cancellation = cancellation
        self.beforePromote = beforePromote
    }
}

/// The trusted-host `SkillRemoteResourcePublishing` implementation. The
/// authority seams are injected as closures so the focused suite can drive
/// the REAL publisher with scripted authorities (no real host connection);
/// production fills them from the C02 execution-target domain and the C02
/// SSH execution adapter.
public struct C02RemoteSkillResourcePublisher: SkillRemoteResourcePublishing {
    /// Re-proves the destination against the authoritative execution-target
    /// store (fresh pin + target readback, exact fact comparison) and mints
    /// the fresh run-bound write authorization. Any mismatch or missing
    /// approval throws.
    public var reproveAndAuthorize: @Sendable (
        SkillRemoteStagingDestination, UUID
    ) async throws -> C02SSHExecutionAuthorization
    /// Re-checks the CURRENT authoritative run binding, the scoped approval,
    /// the epoch and cancellation directly before the commit rename. Throws
    /// on any loss (the publisher wraps the failure in a bounded
    /// `C02RemotePromotionRefusal`).
    public var revalidatePromotion: @Sendable (
        SkillRemoteStagingDestination, UUID, C02SSHExecutionAuthorization
    ) async throws -> Void
    /// One exclusive typed SFTP operation over a dedicated connection owned
    /// by this call end to end.
    public var stageOverSFTP: @Sendable (
        C02RemoteSFTPStageRequest
    ) async throws -> C02RemoteSFTPStageOutcome
    public var liveEpoch: @Sendable () -> UInt64?
    public var acceptedEpoch: UInt64

    public init(
        reproveAndAuthorize: @escaping @Sendable (
            SkillRemoteStagingDestination, UUID
        ) async throws -> C02SSHExecutionAuthorization,
        revalidatePromotion: @escaping @Sendable (
            SkillRemoteStagingDestination, UUID, C02SSHExecutionAuthorization
        ) async throws -> Void = { _, _, _ in },
        stageOverSFTP: @escaping @Sendable (
            C02RemoteSFTPStageRequest
        ) async throws -> C02RemoteSFTPStageOutcome,
        liveEpoch: @escaping @Sendable () -> UInt64?,
        acceptedEpoch: UInt64
    ) {
        self.reproveAndAuthorize = reproveAndAuthorize
        self.revalidatePromotion = revalidatePromotion
        self.stageOverSFTP = stageOverSFTP
        self.liveEpoch = liveEpoch
        self.acceptedEpoch = acceptedEpoch
    }

    public static func production(
        domain: C02ExecutionTargetDomain,
        adapter: C02SSHExecutionAdapter,
        acceptedEpoch: UInt64
    ) -> C02RemoteSkillResourcePublisher {
        C02RemoteSkillResourcePublisher(
            reproveAndAuthorize: { destination, runID in
                // Binding re-proof from the authoritative store: every fact
                // the resolver handed the stager must still be the run's
                // ACTUAL pinned target before a fresh authority is minted.
                guard let pin = try await domain.runTargetPin(runID: runID) else {
                    throw C02ExecutionTargetError.runTargetMissing
                }
                guard let target = try await domain.executionTarget(taskID: pin.taskID) else {
                    throw C02ExecutionTargetError.targetNotFound
                }
                guard pin.matches(target), target.kind == .ssh,
                      pin.rootEpoch == target.rootEpoch else {
                    throw C02ExecutionTargetError.staleRevision(
                        expected: pin.targetRevision, actual: target.revision)
                }
                guard let remote = target.remote,
                      remote.hostID == destination.hostID,
                      remote.remoteRootPath == destination.remoteWorkspaceRoot,
                      remote.runtimeGeneration == destination.runtimeGeneration,
                      target.environmentID == destination.environmentID,
                      target.taskID == destination.taskID,
                      target.revision == destination.targetRevision,
                      target.rootEpoch == destination.rootEpoch else {
                    throw C02ExecutionTargetError.workspaceOwnershipMismatch
                }
                // The explicit run-bound remote workspace write authority:
                // the SAME gate the remote shell passes (policy, ownership,
                // migration, host, fresh run pin). No approval → no bytes.
                let authorization = try await domain.authorizeSSHExecution(
                    taskID: target.taskID, runID: runID)
                guard authorization.target == target,
                      authorization.targetRevision == target.revision else {
                    throw C02ExecutionTargetError.staleRevision(
                        expected: target.revision, actual: authorization.targetRevision)
                }
                return authorization
            },
            revalidatePromotion: { destination, runID, authorization in
                // Directly before the commit: the CURRENT authoritative
                // binding, the scoped approval (pin + expiry via the SAME
                // validation the adapter runs), the epoch and cancellation.
                if Task.isCancelled { throw CancellationError() }
                guard let pin = try await domain.runTargetPin(runID: runID) else {
                    throw C02ExecutionTargetError.runTargetMissing
                }
                guard let target = try await domain.executionTarget(taskID: pin.taskID) else {
                    throw C02ExecutionTargetError.targetNotFound
                }
                guard pin.matches(target), target.kind == .ssh,
                      pin.rootEpoch == target.rootEpoch else {
                    throw C02ExecutionTargetError.staleRevision(
                        expected: pin.targetRevision, actual: target.revision)
                }
                guard let remote = target.remote,
                      remote.hostID == destination.hostID,
                      remote.remoteRootPath == destination.remoteWorkspaceRoot,
                      remote.runtimeGeneration == destination.runtimeGeneration,
                      target.environmentID == destination.environmentID,
                      target.taskID == destination.taskID,
                      target.revision == destination.targetRevision,
                      target.rootEpoch == destination.rootEpoch else {
                    throw C02ExecutionTargetError.workspaceOwnershipMismatch
                }
                // The scoped approval itself: the SAME validation the adapter
                // runs before any remote effect (expiry, pin match, epoch).
                try authorization.validate(now: Date(), pin: pin)
                guard G02NativeRootEpoch.readback() == authorization.rootEpoch else {
                    throw C02ExecutionTargetError.rootEpochUnavailable
                }
            },
            stageOverSFTP: { request in
                try await adapter.withExclusiveSFTPChannel(
                    authorization: request.authorization) { channel in
                    guard let remote = request.authorization.target.remote else {
                        throw C02SSHAdapterError.targetMismatch
                    }
                    return await C02RemoteSkillSFTPStager.stage(
                        bundle: request.bundle,
                        remoteRootPath: remote.remoteRootPath,
                        channel: channel,
                        cancellation: request.cancellation,
                        beforePromote: request.beforePromote)
                }
            },
            liveEpoch: { G02NativeRootEpoch.readback() },
            acceptedEpoch: acceptedEpoch)
    }

    public func publishStagedBundle(
        _ bundle: SkillStagingBundle,
        to destination: SkillRemoteStagingDestination,
        runID: UUID,
        conversationID: UUID?,
        cancellation: CancellationToken
    ) async -> SkillRemotePublishOutcome {
        guard !cancellation.isCancelled, !Task.isCancelled,
              acceptedEpoch > 0, liveEpoch() == acceptedEpoch else {
            return .unconfirmed(detail: nil)
        }
        let authorization: C02SSHExecutionAuthorization
        do {
            authorization = try await reproveAndAuthorize(destination, runID)
        } catch let error as C02ExecutionTargetError {
            return .refused(reason: Self.boundedCode(error.code))
        } catch {
            return .refused(reason: "authorizationRefused")
        }
        guard !cancellation.isCancelled, !Task.isCancelled,
              liveEpoch() == acceptedEpoch else {
            return .unconfirmed(detail: nil)
        }
        let request = C02RemoteSFTPStageRequest(
            bundle: bundle,
            authorization: authorization,
            cancellation: cancellation,
            beforePromote: { [revalidatePromotion] in
                do {
                    try await revalidatePromotion(destination, runID, authorization)
                } catch let error as C02RemotePromotionRefusal {
                    throw error
                } catch let error as C02ExecutionTargetError {
                    throw C02RemotePromotionRefusal(code: Self.boundedCode(error.code))
                } catch let error as C02SSHAdapterError {
                    throw C02RemotePromotionRefusal(code: Self.boundedCode(error.code))
                } catch let error as CancellationError {
                    throw error
                } catch {
                    throw C02RemotePromotionRefusal(code: "promotionRefused")
                }
            })
        do {
            let outcome = try await stageOverSFTP(request)
            guard !cancellation.isCancelled, !Task.isCancelled,
                  liveEpoch() == acceptedEpoch else {
                return .unconfirmed(detail: nil)
            }
            switch outcome {
            case .applied:
                return .applied
            case .refused(let reason):
                return .refused(reason: reason)
            case .unconfirmed(let detail):
                return .unconfirmed(detail: detail)
            }
        } catch let refusal as C02RemotePromotionRefusal {
            return .refused(reason: refusal.code)
        } catch let error as C02SSHAdapterError {
            if case .cancelled = error {
                return .unconfirmed(detail: "cancelled")
            }
            return .refused(reason: Self.boundedCode(error.code))
        } catch let error as SSHSFTPError {
            // Channel-open and transport-class failures share the SFTP
            // vocabulary mapping (a refused server stays refused).
            switch C02RemoteSkillSFTPStager.map(error) {
            case .applied:
                return .unconfirmed(detail: "transport")
            case .refused(let reason):
                return .refused(reason: reason)
            case .unconfirmed(let detail):
                return .unconfirmed(detail: detail)
            }
        } catch {
            return .unconfirmed(detail: "transport")
        }
    }

    /// One bounded printable token (≤48 bytes, printable ASCII) from an
    /// authority/adapter code; anything else collapses to a closed default so
    /// the model-facing reason can never smuggle a path or free text.
    static func boundedCode(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 48,
              trimmed.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            return "authorizationRefused"
        }
        return trimmed
    }
}

// FloeTools — Stable per-run user-output snapshot publisher/resolver (S3-D).
//
// Every `RunOutputFile` receipt must reference bytes that live in the owned
// canonical namespace `RunOutputs/<runID>/<outputID>/<displayName>` inside
// the Floe artifact store. A receipt never points at a live workspace file:
// the workspace original may be edited or deleted afterwards, while the
// snapshot keeps the exact bytes the run produced.
//
// Ownership model:
// - `publish` is called by a trusted producer AT its real commit boundary,
//   with the commit-time digest/size it measured and the runtime-issued
//   `ToolContext`. Publication requires a real call/task binding: a context
//   without a concrete tool-call identity and conversation identity fails
//   honestly. There is no random or host-fallback provenance.
// - `seal` is called by the runtime before persistence. It VALIDATES that
//   the draft matches the runtime's authoritative run/call/tool binding
//   (identity is never laundered from a foreign or mismatched receipt),
//   re-derives the stable output identity from (runID, real call id, slot),
//   requires the canonical snapshot path to already match that identity, and
//   fills only a genuinely-absent (nil) task field from the authoritative
//   context (the environmentID is always the run's frozen binding).
// - `verify` re-validates a stored snapshot at retrieval: canonical shape,
//   identity re-derivation from the receipt's own sealed run/call/slot,
//   lexical containment (every namespace component is lstat-walked as a real
//   directory — an in-root symlink alias is rejected), not a symlink or
//   hardlink file, exact size and streaming SHA-256. Missing or changed
//   bytes are reported as such.
//
// Durability rules: snapshot copies are streamed (bounded buffer, per-chunk
// cancellation and cap) into this store's staging, verified against the
// trusted commit digest/size, then committed with one never-overwrite move.
// A failure deletes only THIS operation's uncommitted staging — never
// committed snapshot bytes and never the original. Re-publishing the same
// output identity requires the FULL publication metadata (display name,
// slot, MIME type, UTI, size, digest) to be equal — proven durably by the
// run's bounded publication ledger (`manifest.json`) or, when the ledger
// entry is absent (crash before the ledger write), by the output identity's
// own publication record written BEFORE the never-overwrite move — for an
// idempotent replay. Committed bytes without a provable full-metadata
// record are never adopted under new metadata: the bytes are preserved and
// the retry conflicts honestly. Anything else (different bytes, renamed
// output, retyped output, or a recorded publication whose bytes went
// missing) is likewise a conflict that never overwrites or re-commits.
// Publications for one run are serialized in-process so concurrent
// publishers cannot exceed the per-run caps or race the same identity.
//
// ANDROID MIRROR DELTA (FloeAndroid/shared, D04 producer batch,
// job-3135f83ef97c4a21): ported byte-for-byte from iOS main 8f185ac
// blob edb6b8ddd801acd99f1d71b757c7e8bbd2e1608a except for artifact-root
// resolution. On Apple platforms the default remains
// `FloeArtifactStore.root()` (Application Support authority). Android has
// NO implicit Application Support authority: the Foundation default can
// resolve below `$HOME`, which is not an app-owned persistent root, so
// publication and retrieval REQUIRE the explicit trusted artifact root the
// runtime composition binds through `RuntimeFacadeRunOutput`
// (RuntimeStorageRoot-derived, the same owned persistent root as the DB).
// Absent that binding the store fails closed — never a HOME or temporary
// fallback, never the first project. Caps, identity derivation, ledger,
// staging, CAS/never-overwrite semantics and the seal are unchanged.

import Foundation
import FloeCore
import FloeModels
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif

/// Byte/count ceilings for one run's snapshot publication. `standard` carries
/// the S3-D contract caps: 256 MiB per file, 1 GiB and 32 files per run.
public struct RunOutputCaps: Sendable, Hashable {
    public var perFileBytes: Int
    public var perRunBytes: Int
    public var perRunFiles: Int

    public init(perFileBytes: Int, perRunBytes: Int, perRunFiles: Int) {
        self.perFileBytes = max(0, perFileBytes)
        self.perRunBytes = max(0, perRunBytes)
        self.perRunFiles = max(0, perRunFiles)
    }

    /// The authorized production limits. Over-cap is always an explicit
    /// error — never a silent truncation or a partial success.
    public static let standard = RunOutputCaps(
        perFileBytes: 256 * 1024 * 1024,
        perRunBytes: 1024 * 1024 * 1024,
        perRunFiles: 32
    )
}

/// Trusted commit identity captured by a producer at its real commit
/// boundary. `sha256`/`byteCount` must describe the exact bytes currently at
/// `sourceURL`; publication streams a copy, re-measures it and fails
/// honestly if the commit identity is stale.
public struct RunOutputCommit: Sendable, Hashable {
    /// Absolute local file URL of the committed bytes (regular file, not a
    /// symlink, not inside this run's own snapshot tree).
    public var sourceURL: URL
    /// Commit-time SHA-256 (case-insensitive on input; stored lowercase).
    public var sha256: String
    /// Commit-time byte count.
    public var byteCount: Int
    /// Display basename for the snapshot (validated, ≤255 UTF-8 bytes).
    public var displayName: String
    public var mimeType: String
    /// Optional uniform type identifier for downstream `IntentFile` typing.
    public var uti: String?

    public init(
        sourceURL: URL,
        sha256: String,
        byteCount: Int,
        displayName: String,
        mimeType: String,
        uti: String? = nil
    ) {
        self.sourceURL = sourceURL
        self.sha256 = sha256
        self.byteCount = byteCount
        self.displayName = displayName
        self.mimeType = mimeType
        self.uti = uti
    }
}

/// One publication request: explicit trusted producer identity plus the
/// logical output slot and the real commit bytes.
public struct RunOutputSnapshotRequest: Sendable {
    /// Catalog name of the producing tool. The runtime seal requires it to
    /// match the real approved call; it exists so direct (non-runtime-bound)
    /// callers still produce a well-formed draft.
    public var producerTool: String
    /// Stable logical output slot within this call (e.g. "image", "document",
    /// "page-2", "audio"). Retries of the SAME call with the SAME slot reuse
    /// the same identity; different outputs of one call must use different
    /// slots. Bounded, control-character-free.
    public var slot: String
    public var commit: RunOutputCommit

    public init(producerTool: String, slot: String, commit: RunOutputCommit) {
        self.producerTool = producerTool
        self.slot = slot
        self.commit = commit
    }
}

/// Typed publication failures. Messages are path-free so they can enter
/// tool summaries and logs without leaking absolute locations.
public enum RunOutputSnapshotError: Error, Equatable, LocalizedError {
    /// The context has no real runtime call/task binding, or an identity
    /// field is malformed. Publication always fails honestly.
    case bindingMissing(String)
    /// A run-level policy refuses durable output (temporary ephemeral runs).
    case policyRefused(String)
    /// The commit identity itself (digest/size/name/type) is malformed.
    case identityInvalid(String)
    /// The source is absent or not a plain regular file, or it aliases this
    /// run's own snapshot namespace.
    case sourceUnavailable(String)
    /// The real bytes no longer match the claimed commit identity (the
    /// source changed at or after commit). No snapshot is advertised.
    case commitIdentityStale(String)
    /// The same stable output identity already holds different content or
    /// different publication metadata (name/type/size/digest), or a recorded
    /// publication's bytes went missing, or committed bytes exist without a
    /// provable original full-metadata record, or two receipts in one result
    /// claim one identity inconsistently. Deterministic conflict; nothing is
    /// overwritten or re-committed under it.
    case conflict(displayName: String)
    /// A bounded cap was exceeded. Named so the caller can explain which.
    case overCap(cap: String)
    /// An existing snapshot or its namespace has been aliased (symlink or
    /// multi-link) — treated as tampering, never silently replaced.
    case snapshotAliased(String)
    /// A filesystem or publication-ledger operation failed; message is
    /// path-sanitized. Committed snapshots are retained even when the
    /// ledger write behind them fails.
    case ioFailure(String)
}

/// The durable bounded publication record one output identity carries.
/// Equality across retries is defined on this FULL metadata, not only on
/// the current filename's bytes: the same slot replayed under a different
/// display name, MIME type, UTI, size or digest is a conflict.
public struct RunOutputPublicationEntry: Sendable, Codable, Hashable {
    public var displayName: String
    public var slot: String
    public var mimeType: String
    public var uti: String?
    public var byteCount: Int
    public var sha256: String

    public init(
        displayName: String,
        slot: String,
        mimeType: String,
        uti: String?,
        byteCount: Int,
        sha256: String
    ) {
        self.displayName = displayName
        self.slot = slot
        self.mimeType = mimeType
        self.uti = uti
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    init(receipt: RunOutputFile) {
        self.init(
            displayName: receipt.displayName,
            slot: receipt.slot,
            mimeType: receipt.mimeType,
            uti: receipt.uti,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256
        )
    }
}

/// Outcome of re-validating a stored snapshot against its receipt. The
/// reader/Intent package maps these to user-facing outcomes; core never
/// converts a missing/changed snapshot into success.
public enum RunOutputSnapshotVerification: Sendable, Equatable {
    /// Snapshot present, contained, and byte-identical to the receipt.
    case verified(url: URL)
    /// No snapshot at the canonical path (deleted or never committed).
    case missing(displayName: String)
    /// Snapshot exists but size or SHA-256 differs from the receipt.
    case changed(displayName: String)
    /// Snapshot exceeds the per-file cap — never hashed unboundedly.
    case oversized(displayName: String)
    /// Receipt is not a canonical run-owned reference, or the path is a
    /// symlink/hardlink alias, directory or otherwise unsafe.
    case rejected(reason: String)
}

/// Publisher/resolver for the canonical `RunOutputs` snapshot namespace.
public enum RunOutputSnapshotStore {
    /// Hidden staging prefix owned by this store inside the run namespace.
    /// Staging files always carry it and are counted against the caps.
    public static let stagingPrefix = ".floe-staging-"
    /// Bounded per-run publication ledger (store bookkeeping, NOT a
    /// snapshot). Records the full metadata of every published identity so
    /// retries conflict or stay idempotent by contract, never by filename
    /// coincidence.
    public static let publicationLedgerName = "manifest.json"
    /// Durable per-output publication record (store bookkeeping, never a
    /// snapshot and never a legal display name — it is hidden). Written to
    /// the output identity directory BEFORE the never-overwrite move so a
    /// crash between the move and the ledger write still leaves the
    /// original FULL metadata provable for an honest adoption or conflict.
    public static let publicationRecordName = ".floe-publication.json"
    /// Ledger files larger than this are refused as corrupted.
    public static let publicationLedgerMaxBytes = 64 * 1024

    // MARK: - Publication

    /// Publishes the committed bytes as this run's immutable snapshot and
    /// returns the well-formed draft receipt for
    /// `ToolExecutionOutput.outputFiles`. The runtime seal is still required
    /// before anything is treated as durable ownership.
    ///
    /// Fails honestly when the real call/task binding is missing. One
    /// publication per run is serialized in-process: a byte- and
    /// metadata-identical replay of the same identity is idempotent (no
    /// rewrite, concurrent equal retries all resolve to the same result);
    /// any difference in the recorded publication metadata — different bytes,
    /// display name, MIME type, UTI, size or digest — is a conflict that
    /// never touches the existing snapshot. On any pre-commit failure only
    /// this operation's staging is removed; committed snapshots and the
    /// original are preserved even when the ledger write fails afterwards.
    @discardableResult
    public static func publish(
        _ request: RunOutputSnapshotRequest,
        using context: ToolContext,
        caps: RunOutputCaps = .standard,
        artifactRoot: URL? = nil
    ) throws -> RunOutputFile {
        // 1. Real call/task binding — never fabricated.
        let callID = (context.toolCallID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callID.isEmpty else {
            throw RunOutputSnapshotError.bindingMissing(
                "run-output publication requires the real tool-call binding"
            )
        }
        guard context.conversationID != nil else {
            throw RunOutputSnapshotError.bindingMissing(
                "run-output publication requires the real task binding"
            )
        }
        guard !context.temporaryReadOnly else {
            throw RunOutputSnapshotError.policyRefused(
                "temporary (ephemeral) runs cannot publish durable run outputs"
            )
        }
        try context.cancellation.throwIfCancelled()

        // 2. Validate the logical slot and producer identity fields.
        guard RunOutputFile.isValidBoundedField(
            request.slot, maximumCharacters: RunOutputFile.maximumSlotCharacters
        ) else {
            throw RunOutputSnapshotError.identityInvalid("output slot is empty or unbounded")
        }
        guard RunOutputFile.isValidBoundedField(
            request.producerTool, maximumCharacters: RunOutputFile.maximumProducerToolCharacters
        ) else {
            throw RunOutputSnapshotError.identityInvalid("producer tool identity is empty or unbounded")
        }
        guard RunOutputFile.isValidBoundedField(
            callID, maximumCharacters: RunOutputFile.maximumProducerCallIDCharacters
        ) else {
            throw RunOutputSnapshotError.identityInvalid("tool-call binding exceeds the bounded length")
        }

        // 3. Validate the commit identity itself.
        let commit = request.commit
        let digest = commit.sha256.lowercased()
        guard RunOutputFile.isValidSHA256Hex(digest) else {
            throw RunOutputSnapshotError.identityInvalid("commit digest is not lowercase 64-hex SHA-256")
        }
        guard commit.byteCount >= 0 else {
            throw RunOutputSnapshotError.identityInvalid("commit byte count is negative")
        }
        guard commit.byteCount <= caps.perFileBytes else {
            throw RunOutputSnapshotError.overCap(cap: "run output files are limited to \(caps.perFileBytes) bytes each")
        }
        guard RunOutputFile.isValidDisplayName(commit.displayName) else {
            throw RunOutputSnapshotError.identityInvalid("display name is not a safe single filename component")
        }
        guard RunOutputFile.isValidBoundedField(commit.mimeType, maximumCharacters: RunOutputFile.maximumMimeTypeCharacters) else {
            throw RunOutputSnapshotError.identityInvalid("MIME type is empty or unbounded")
        }
        if let uti = commit.uti,
           !RunOutputFile.isValidBoundedField(uti, maximumCharacters: RunOutputFile.maximumUTICharacters) {
            throw RunOutputSnapshotError.identityInvalid("UTI is unbounded")
        }

        // 4. The source must be real committed bytes, plain and unaliased.
        let fileManager = FileManager.default
        let sourceURL = commit.sourceURL
        var sourceInfo = stat()
        guard lstat(sourceURL.path, &sourceInfo) == 0 else {
            throw RunOutputSnapshotError.sourceUnavailable("committed source file is unavailable")
        }
        guard Self.isRegularFile(sourceInfo) else {
            // Symlinks, directories, FIFOs and devices are never trusted
            // commit bytes: the snapshot must come from a plain regular file.
            throw RunOutputSnapshotError.sourceUnavailable("committed source must be a regular file")
        }
        let sourceSize = Int(sourceInfo.st_size)
        guard sourceSize == commit.byteCount else {
            throw RunOutputSnapshotError.commitIdentityStale(
                "committed source size changed (claimed \(commit.byteCount), found \(sourceSize))"
            )
        }
        guard sourceSize <= caps.perFileBytes else {
            throw RunOutputSnapshotError.overCap(cap: "run output files are limited to \(caps.perFileBytes) bytes each")
        }

        let base = try Self.resolveArtifactRoot(given: artifactRoot)
        let runNamespace = base
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
            .appendingPathComponent(context.runID.uuidString, isDirectory: true)
        guard !resolvedPath(sourceURL).hasPrefix(resolvedPath(runNamespace) + "/"),
              resolvedPath(sourceURL) != resolvedPath(runNamespace) else {
            // A snapshot of this run's own snapshot is aliasing, and the
            // producer could otherwise rewrite history through itself.
            throw RunOutputSnapshotError.sourceUnavailable(
                "committed source already lives inside this run's snapshot namespace"
            )
        }

        // 5. Deterministic stable identity (no random fallback).
        let outputID = RunOutputFile.derivedOutputID(
            runID: context.runID, producerCallID: callID, slot: request.slot
        )
        let snapshotDirectory = runNamespace.appendingPathComponent(outputID, isDirectory: true)
        let destination = snapshotDirectory.appendingPathComponent(commit.displayName)

        // The run namespace is owned: every existing component must be a
        // real directory, never a symlink that could escape the store.
        try assertOwnedNamespace(from: base, upTo: snapshotDirectory)

        let receipt = RunOutputFile(
            outputID: outputID,
            slot: request.slot,
            runID: context.runID,
            taskID: context.conversationID,
            environmentID: context.environmentID,
            producerCallID: callID,
            producerTool: request.producerTool,
            relativePath: RunOutputFile.canonicalRelativePath(
                runID: context.runID, outputID: outputID, displayName: commit.displayName
            ),
            displayName: commit.displayName,
            mimeType: commit.mimeType,
            uti: commit.uti,
            byteCount: commit.byteCount,
            sha256: digest,
            role: .userFile
        )
        // Self-check: the store must never hand out a non-canonical draft.
        guard receipt.isCanonicalForCurrentRun else {
            throw RunOutputSnapshotError.identityInvalid("internal: drafted receipt is not canonical")
        }
        let entry = RunOutputPublicationEntry(receipt: receipt)

        // 6. From here the whole decision + commit for this run is
        // serialized in-process: caps, ledger and never-overwrite move are
        // one critical section, so concurrent publishers cannot jointly
        // exceed the caps or race the same identity into two outcomes.
        return try Self.withRunPublicationLock(key: resolvedPath(runNamespace)) {
            let ledgerURL = runNamespace.appendingPathComponent(Self.publicationLedgerName)
            var ledger = try loadLedger(at: ledgerURL, caps: caps)

            if let recorded = ledger[outputID] {
                // The identity was already published: full-metadata equality
                // is REQUIRED, and the recorded bytes must still be present
                // and intact. Missing/changed/aliased recorded snapshots are
                // conflicts — never a silent re-commit that would hide the
                // loss, and never an overwrite.
                guard recorded == entry else {
                    throw RunOutputSnapshotError.conflict(displayName: recorded.displayName)
                }
                if case .verified = verify(receipt, caps: caps, artifactRoot: base) {
                    return receipt // deterministic idempotent replay
                }
                throw RunOutputSnapshotError.conflict(displayName: commit.displayName)
            }

            // No ledger entry: crash/ledger-loss recovery. Committed bytes
            // alone cannot prove the ORIGINAL MIME type, UTI or slot, so an
            // adoption is only allowed from the durable per-output
            // publication record that was written before this identity's
            // never-overwrite move. Any other committed file under the
            // identity conflicts; committed bytes WITHOUT a provable record
            // preserve the bytes and conflict honestly — new metadata is
            // never silently blessed.
            let committed = try committedSnapshotFiles(in: snapshotDirectory)
            if !committed.isEmpty {
                guard committed.count == 1, committed[0].lastPathComponent == commit.displayName else {
                    throw RunOutputSnapshotError.conflict(
                        displayName: committed.first?.lastPathComponent ?? commit.displayName
                    )
                }
                guard Self.loadPublicationRecord(in: snapshotDirectory) == entry,
                      case .verified = verify(receipt, caps: caps, artifactRoot: base) else {
                    throw RunOutputSnapshotError.conflict(displayName: commit.displayName)
                }
                ledger[outputID] = entry
                try writeLedger(ledger, to: ledgerURL, caps: caps)
                return receipt
            }

            // 7. Per-run caps, counting ALL owned snapshots including
            // retained incomplete staging. Over-cap is an explicit error.
            try enforceRunCaps(
                runNamespace: runNamespace,
                addingBytes: commit.byteCount,
                caps: caps
            )

            // 8. Stream a capped, cancellable copy into this operation's
            // staging, verify it against the trusted commit identity, then
            // one never-overwrite move. Only this staging is removed on
            // failure; committed bytes are never touched.
            let staging = snapshotDirectory.appendingPathComponent(
                Self.stagingPrefix + UUID().uuidString
            )
            do {
                try fileManager.createDirectory(
                    at: snapshotDirectory,
                    withIntermediateDirectories: true
                )
                try context.cancellation.throwIfCancelled()
                try streamCopy(
                    from: sourceURL,
                    to: staging,
                    expectedBytes: commit.byteCount,
                    maxBytes: caps.perFileBytes,
                    cancellation: context.cancellation
                )
                let stagedDigest = try streamDigest(of: staging, cancellation: context.cancellation)
                guard stagedDigest == digest else {
                    throw RunOutputSnapshotError.commitIdentityStale(
                        "snapshot bytes diverged from the commit digest (source changed at commit)"
                    )
                }
                try context.cancellation.throwIfCancelled()
                // Never overwrite: a concurrent publisher that just committed
                // the same identity wins and this operation fails as conflict.
                var destinationInfo = stat()
                if lstat(destination.path, &destinationInfo) == 0 {
                    throw RunOutputSnapshotError.conflict(displayName: commit.displayName)
                }
                // Durable full-metadata claim recorded BEFORE the bytes
                // commit: from this point on any committed identity always
                // carries a provable original publication record, even if
                // the process dies before the run-ledger write below.
                try writePublicationRecord(entry, in: snapshotDirectory)
                try fileManager.moveItem(at: staging, to: destination)
            } catch let error as RunOutputSnapshotError {
                try? fileManager.removeItem(at: staging)
                throw error
            } catch let error as FloeError where error == .cancelled {
                try? fileManager.removeItem(at: staging)
                throw error
            } catch is CancellationError {
                try? fileManager.removeItem(at: staging)
                throw FloeError.cancelled
            } catch {
                try? fileManager.removeItem(at: staging)
                let ns = error as NSError
                throw RunOutputSnapshotError.ioFailure(
                    "snapshot publication failed (\(ns.domain) \(ns.code))"
                )
            }

            // 9. Record the publication. If this write fails the committed
            // snapshot is RETAINED (never rolled back for another receipt's
            // durability uncertainty) and the failure is surfaced honestly;
            // a retry adopts the committed bytes back through this output's
            // durable pre-move publication record.
            ledger[outputID] = entry
            do {
                try writeLedger(ledger, to: ledgerURL, caps: caps)
            } catch {
                throw RunOutputSnapshotError.ioFailure(
                    "snapshot committed but its publication ledger could not be written; the snapshot is retained"
                )
            }
            return receipt
        }
    }

    // MARK: - Retrieval validation

    /// Re-validates a receipt's snapshot at retrieval: canonical shape,
    /// identity re-derivation, LEXICAL namespace containment (no symlinked
    /// or aliased component anywhere above the file, even an in-root
    /// alias), plain unaliased single-link file, exact size and streaming
    /// SHA-256. Deleted and tampered bytes are reported accurately; nothing
    /// is silently repaired and the file is never read past the cap.
    public static func verify(
        _ receipt: RunOutputFile,
        caps: RunOutputCaps = .standard,
        artifactRoot: URL? = nil
    ) -> RunOutputSnapshotVerification {
        guard receipt.isCanonicalForCurrentRun else {
            return .rejected(reason: "receipt is not a canonical run-owned snapshot reference")
        }
        // The canonical path shape alone never validates `outputID`: a
        // copied receipt can be canonical for its own claims while its
        // identity does not re-derive from its sealed run/call/slot. Reject
        // that before touching any path.
        guard receipt.hasRuntimeConsistentIdentity else {
            return .rejected(reason: "output identity does not re-derive from its sealed run, call and slot")
        }
        do {
            let base = try Self.resolveArtifactRoot(given: artifactRoot)
            let components = [
                ArtifactNamespace.runOutputs.rawValue,
                receipt.runID.uuidString,
                receipt.outputID,
                receipt.displayName
            ]
            var url = base
            for component in components {
                url = url.appendingPathComponent(component)
            }
            // Lexical containment: resolving symlinks first would fold an
            // in-root alias (e.g. a symlinked `RunOutputs` or identity
            // directory pointing elsewhere inside the artifact store) into a
            // contained-looking resolved path. Instead every existing
            // namespace component is walked with `lstat` from the LEXICAL
            // artifact root down and must be a real directory.
            let container = base.standardizedFileURL.path
            let target = url.standardizedFileURL.path
            guard target.hasPrefix(container + "/") else {
                return .rejected(reason: "snapshot path escapes the artifact store")
            }
            var walk = container
            for component in target.dropFirst(container.count + 1).split(separator: "/").dropLast() {
                walk = (walk as NSString).appendingPathComponent(String(component))
                var ancestorInfo = stat()
                guard lstat(walk, &ancestorInfo) == 0 else {
                    return .missing(displayName: receipt.displayName)
                }
                guard Self.isDirectory(ancestorInfo) else {
                    return .rejected(reason: "snapshot namespace component '\(component)' is not a plain directory")
                }
            }
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                return .missing(displayName: receipt.displayName)
            }
            guard Self.isRegularFile(info), info.st_nlink == 1 else {
                return .rejected(reason: "snapshot is not a plain single-link regular file")
            }
            let size = Int(info.st_size)
            guard size <= caps.perFileBytes else {
                return .oversized(displayName: receipt.displayName)
            }
            guard size == receipt.byteCount else {
                return .changed(displayName: receipt.displayName)
            }
            let actual = try FloeDigest.sha256Hex(ofFileAt: url)
            guard actual == receipt.sha256 else {
                return .changed(displayName: receipt.displayName)
            }
            return .verified(url: url)
        } catch {
            return .rejected(reason: "snapshot verification failed at the storage layer")
        }
    }

    // MARK: - Runtime seal

    /// The runtime's authoritative seal over tool-proposed receipts. A draft
    /// must ALREADY bind this exact run/call/tool (as `publish` recorded from
    /// the real `ToolContext`): the output identity is re-derived from
    /// (runID, real call id, slot) and the canonical path is required to
    /// match its own identity — a foreign or mismatched canonical receipt is
    /// REJECTED, never relabeled into current ownership (no laundering).
    /// Only a genuinely nil task field is filled from the authoritative
    /// context, and the sealed environmentID is always the run's frozen
    /// binding. Equal duplicates collapse idempotently; a slot
    /// claimed twice with different metadata rejects the whole batch — a
    /// forged or inconsistent receipt never persists as success.
    public enum SealOutcome: Sendable, Equatable {
        case sealed([RunOutputFile])
        case rejected(reason: String)
    }

    public static func seal(
        drafts: [RunOutputFile],
        runID: UUID,
        taskID: UUID?,
        environmentID: String?,
        callID: String,
        toolName: String,
        caps: RunOutputCaps = .standard
    ) -> SealOutcome {
        guard !drafts.isEmpty else { return .sealed([]) }
        guard RunOutputFile.isValidBoundedField(
            callID, maximumCharacters: RunOutputFile.maximumProducerCallIDCharacters
        ), RunOutputFile.isValidBoundedField(
            toolName, maximumCharacters: RunOutputFile.maximumProducerToolCharacters
        ) else {
            return .rejected(reason: "runtime call binding exceeds the bounded identity length")
        }
        var sealedByID: [String: RunOutputFile] = [:]
        var order: [String] = []
        var totalBytes = 0
        for draft in drafts {
            guard draft.runID == runID else {
                return .rejected(reason: "receipt claims a different run")
            }
            guard draft.producerCallID == callID else {
                return .rejected(reason: "receipt claims a different tool call")
            }
            guard draft.producerTool == toolName else {
                return .rejected(reason: "receipt claims a different producer tool")
            }
            guard draft.role == .userFile else {
                return .rejected(reason: "receipt role is not an explicit user output")
            }
            if let draftTask = draft.taskID, draftTask != taskID {
                return .rejected(reason: "receipt claims a different task")
            }
            // `environmentID` is not an ownership fence here: the sealed
            // value is ALWAYS the run's frozen launch-time binding, even if
            // a routed tool context recorded a resolved layer view of the
            // same environment. That authoritative overwrite cannot launder
            // foreign ownership because run/task/call/tool identity is
            // required to match exactly.
            guard RunOutputFile.isValidBoundedField(
                draft.slot, maximumCharacters: RunOutputFile.maximumSlotCharacters
            ) else {
                return .rejected(reason: "output slot is empty or unbounded")
            }
            // The stable identity must re-derive from the RUNTIME's own
            // run/call plus the draft slot. A copied foreign receipt can
            // never survive this even if it is canonical for its own claims.
            let outputID = RunOutputFile.derivedOutputID(
                runID: runID, producerCallID: callID, slot: draft.slot
            )
            guard draft.outputID == outputID else {
                return .rejected(reason: "output identity does not re-derive from this exact call and slot")
            }
            guard RunOutputFile.isValidDisplayName(draft.displayName) else {
                return .rejected(reason: "output display name is not a safe single filename component")
            }
            // The path must already be canonical for this identity: the seal
            // normalizes nothing, it verifies.
            guard draft.relativePath == RunOutputFile.canonicalRelativePath(
                runID: runID, outputID: outputID, displayName: draft.displayName
            ) else {
                return .rejected(reason: "receipt path is not the canonical snapshot path for its identity")
            }
            guard RunOutputFile.isValidSHA256Hex(draft.sha256) else {
                return .rejected(reason: "output digest is not lowercase 64-hex SHA-256")
            }
            guard draft.byteCount >= 0, draft.byteCount <= caps.perFileBytes else {
                return .rejected(reason: "output byte count is outside the per-file cap")
            }
            guard RunOutputFile.isValidBoundedField(
                draft.mimeType, maximumCharacters: RunOutputFile.maximumMimeTypeCharacters
            ) else {
                return .rejected(reason: "output MIME type is empty or unbounded")
            }
            if let uti = draft.uti,
               !RunOutputFile.isValidBoundedField(uti, maximumCharacters: RunOutputFile.maximumUTICharacters) {
                return .rejected(reason: "output UTI is unbounded")
            }
            // Authoritative identity; only absent (nil) fields are filled.
            let sealed = RunOutputFile(
                outputID: outputID,
                slot: draft.slot,
                runID: runID,
                taskID: draft.taskID ?? taskID,
                environmentID: environmentID,
                producerCallID: callID,
                producerTool: toolName,
                relativePath: draft.relativePath,
                displayName: draft.displayName,
                mimeType: draft.mimeType,
                uti: draft.uti,
                byteCount: draft.byteCount,
                sha256: draft.sha256,
                role: .userFile
            )
            guard sealed.isCanonicalForCurrentRun, sealed.hasRuntimeConsistentIdentity else {
                return .rejected(reason: "sealed receipt failed canonical validation")
            }
            if let existing = sealedByID[outputID] {
                guard existing == sealed else {
                    return .rejected(
                        reason: "output slot '\(draft.slot)' was claimed twice with different metadata"
                    )
                }
                continue // idempotent equal duplicate
            }
            totalBytes += sealed.byteCount
            guard order.count + 1 <= caps.perRunFiles else {
                return .rejected(reason: "run output count exceeds the \(caps.perRunFiles)-file cap")
            }
            guard totalBytes <= caps.perRunBytes else {
                return .rejected(reason: "run output bytes exceed the \(caps.perRunBytes)-byte cap")
            }
            sealedByID[outputID] = sealed
            order.append(outputID)
        }
        return .sealed(order.compactMap { sealedByID[$0] })
    }

    // MARK: - Publication ledger

    /// Loads the bounded per-run publication ledger. Equality is decided on
    /// decoded values (never on byte layout), and a corrupted or over-sized
    /// ledger fails closed rather than re-authoring history.
    private static func loadLedger(
        at url: URL,
        caps: RunOutputCaps
    ) throws -> [String: RunOutputPublicationEntry] {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return [:] }
        guard Self.isRegularFile(info), info.st_nlink == 1,
              Int(info.st_size) <= publicationLedgerMaxBytes else {
            throw RunOutputSnapshotError.ioFailure("run output publication ledger is not a bounded regular file")
        }
        let data: Data
        do {
            data = try Data(floeContentsOf: url)
        } catch {
            throw RunOutputSnapshotError.ioFailure("run output publication ledger could not be read")
        }
        let decoded: [String: RunOutputPublicationEntry]
        do {
            decoded = try JSONDecoder().decode([String: RunOutputPublicationEntry].self, from: data)
        } catch {
            throw RunOutputSnapshotError.ioFailure("run output publication ledger is corrupted")
        }
        guard decoded.count <= max(caps.perRunFiles, 1) else {
            throw RunOutputSnapshotError.ioFailure("run output publication ledger exceeds its bounded entry count")
        }
        for entry in decoded.values where entry.byteCount < 0
            || !RunOutputFile.isValidSHA256Hex(entry.sha256)
            || !RunOutputFile.isValidDisplayName(entry.displayName) {
            throw RunOutputSnapshotError.ioFailure("run output publication ledger contains an invalid record")
        }
        return decoded
    }

    private static func writeLedger(
        _ ledger: [String: RunOutputPublicationEntry],
        to url: URL,
        caps: RunOutputCaps
    ) throws {
        guard ledger.count <= max(caps.perRunFiles, 1) else {
            throw RunOutputSnapshotError.ioFailure("run output publication ledger exceeds its bounded entry count")
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(ledger)
        } catch {
            throw RunOutputSnapshotError.ioFailure("run output publication ledger could not be encoded")
        }
        guard data.count <= publicationLedgerMaxBytes else {
            throw RunOutputSnapshotError.ioFailure("run output publication ledger exceeds its bounded size")
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw RunOutputSnapshotError.ioFailure("run output publication ledger could not be written")
        }
    }

    /// Committed (non-bookkeeping) regular files directly inside one output
    /// identity directory. Hidden entries are this store's staging, its
    /// publication record (or an atomic-write temporary of that record) and
    /// never count as committed publications here.
    private static func committedSnapshotFiles(
        in directory: URL
    ) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            )
        } catch {
            throw RunOutputSnapshotError.ioFailure("snapshot namespace could not be listed")
        }
        var committed: [URL] = []
        for child in children {
            let name = child.lastPathComponent
            if name.hasPrefix(stagingPrefix)
                || name == publicationRecordName
                || name.hasPrefix(publicationRecordName + ".") { continue }
            var info = stat()
            guard lstat(child.path, &info) == 0, Self.isRegularFile(info) else {
                // Anything non-regular under an owned identity is unsafe.
                throw RunOutputSnapshotError.snapshotAliased(name)
            }
            committed.append(child)
        }
        return committed
    }

    /// Reads the durable per-output publication record. A missing, aliased,
    /// oversized or undecodable record returns nil: without it the
    /// ORIGINAL full metadata (MIME type, UTI, slot) is not provable, so
    /// committed bytes must never be adopted under a new claim.
    private static func loadPublicationRecord(
        in directory: URL
    ) -> RunOutputPublicationEntry? {
        let url = directory.appendingPathComponent(publicationRecordName)
        var info = stat()
        guard lstat(url.path, &info) == 0, Self.isRegularFile(info), info.st_nlink == 1,
              Int(info.st_size) <= publicationLedgerMaxBytes else { return nil }
        guard let data = try? Data(floeContentsOf: url),
              let entry = try? JSONDecoder().decode(RunOutputPublicationEntry.self, from: data),
              entry.byteCount >= 0,
              RunOutputFile.isValidSHA256Hex(entry.sha256),
              RunOutputFile.isValidDisplayName(entry.displayName),
              RunOutputFile.isValidBoundedField(
                  entry.slot, maximumCharacters: RunOutputFile.maximumSlotCharacters
              ),
              RunOutputFile.isValidBoundedField(
                  entry.mimeType, maximumCharacters: RunOutputFile.maximumMimeTypeCharacters
              ),
              entry.uti == nil || RunOutputFile.isValidBoundedField(
                  entry.uti ?? "", maximumCharacters: RunOutputFile.maximumUTICharacters
              )
        else { return nil }
        return entry
    }

    /// Commits the durable per-output full-metadata claim. It is called
    /// only while NO committed snapshot exists under this identity, so an
    /// atomic replace of a provisional claim from a crashed earlier attempt
    /// is safe; once bytes are committed, the adoption path above reads
    /// this record and conflicts instead of re-recording under new metadata.
    private static func writePublicationRecord(
        _ entry: RunOutputPublicationEntry,
        in directory: URL
    ) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(entry)
        } catch {
            throw RunOutputSnapshotError.ioFailure("run output publication record could not be encoded")
        }
        guard data.count <= publicationLedgerMaxBytes else {
            throw RunOutputSnapshotError.ioFailure("run output publication record exceeds its bounded size")
        }
        do {
            try data.write(
                to: directory.appendingPathComponent(publicationRecordName),
                options: [.atomic]
            )
        } catch {
            throw RunOutputSnapshotError.ioFailure("run output publication record could not be written")
        }
    }

    // MARK: - Internals

    private static func streamDigest(
        of url: URL,
        cancellation: CancellationToken
    ) throws -> String {
        return try FloeDigest.sha256Hex(
            ofFileAt: url,
            isCancelled: { cancellation.isCancelled }
        )
    }

    /// Bounded chunk copy with per-chunk cancellation and cap enforcement.
    /// Deliberately never loads the whole file: the contract requires a
    /// streaming copy/hash for large outputs, and `FileManager.copyItem`
    /// offers no cancellation checkpoints. The staging destination is
    /// created with `O_EXCL` under this operation's unique name, so staging
    /// ownership is unambiguous and a pre-existing entry is never adopted.
    private static func streamCopy(
        from source: URL,
        to staging: URL,
        expectedBytes: Int,
        maxBytes: Int,
        cancellation: CancellationToken
    ) throws {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android)
        let sourceFD = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard sourceFD >= 0 else {
            throw RunOutputSnapshotError.sourceUnavailable("committed source could not be opened")
        }
        let stagingFD = open(staging.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard stagingFD >= 0 else {
            close(sourceFD)
            throw RunOutputSnapshotError.ioFailure("snapshot staging could not be created")
        }
        // Single close ownership for each descriptor.
        defer { close(sourceFD); close(stagingFD) }
        var openInfo = stat()
        guard fstat(sourceFD, &openInfo) == 0, Self.isRegularFile(openInfo),
              Int(openInfo.st_size) == expectedBytes else {
            // The path swapped between lstat and open (or truncated): the
            // commit identity is no longer current.
            throw RunOutputSnapshotError.commitIdentityStale(
                "committed source size changed while opening"
            )
        }
        let chunkSize = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: chunkSize,
            alignment: MemoryLayout<UInt8>.alignment
        )
        defer { buffer.deallocate() }
        var total = 0
        while true {
            if cancellation.isCancelled { throw FloeError.cancelled }
            let count = read(sourceFD, buffer, chunkSize)
            if count < 0 {
                if errno == EINTR { continue }
                throw RunOutputSnapshotError.ioFailure("snapshot copy read failed")
            }
            if count == 0 { break }
            total += count
            guard total <= maxBytes else {
                throw RunOutputSnapshotError.overCap(
                    cap: "run output files are limited to \(maxBytes) bytes each"
                )
            }
            var written = 0
            while written < count {
                let progress = write(stagingFD, buffer.advanced(by: written), count - written)
                if progress < 0 {
                    if errno == EINTR { continue }
                    throw RunOutputSnapshotError.ioFailure("snapshot copy write failed")
                }
                guard progress > 0 else {
                    throw RunOutputSnapshotError.ioFailure("snapshot copy write stalled")
                }
                written += progress
            }
        }
        guard total == expectedBytes else {
            throw RunOutputSnapshotError.commitIdentityStale(
                "snapshot copy length does not match the commit identity"
            )
        }
        #else
        // Unsupported platform fallback: same bounds and cancellation with
        // Foundation handles, chunked so nothing is loaded whole.
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: source) } catch {
            throw RunOutputSnapshotError.sourceUnavailable("committed source could not be opened")
        }
        defer { try? handle.close() }
        let stagingHandle: FileHandle
        do {
            FileManager.default.createFile(atPath: staging.path, contents: nil)
            stagingHandle = try FileHandle(forWritingTo: staging)
        } catch {
            throw RunOutputSnapshotError.ioFailure("snapshot staging could not be created")
        }
        defer { try? stagingHandle.close() }
        let chunkSize = 1 << 20
        var total = 0
        while true {
            if cancellation.isCancelled { throw FloeError.cancelled }
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            total += chunk.count
            guard total <= maxBytes else {
                throw RunOutputSnapshotError.overCap(
                    cap: "run output files are limited to \(maxBytes) bytes each"
                )
            }
            try stagingHandle.write(contentsOf: chunk)
        }
        guard total == expectedBytes else {
            throw RunOutputSnapshotError.commitIdentityStale(
                "snapshot copy length does not match the commit identity"
            )
        }
        #endif
    }

    /// Sum and count every owned regular file inside the run namespace —
    /// committed snapshots plus this store's retained staging — excluding
    /// ONLY the publication ledger at the exact run-namespace root and this
    /// store's hidden per-output publication records (bookkeeping, not
    /// outputs). A genuine user snapshot may legitimately be named
    /// `manifest.json` inside its identity directory: nested files with
    /// that name are user outputs and always count. The enumeration itself
    /// is bounded.
    private static func enforceRunCaps(
        runNamespace: URL,
        addingBytes: Int,
        caps: RunOutputCaps
    ) throws {
        var existingCount = 0
        var existingBytes = 0
        let fileManager = FileManager.default
        let rootLedgerPath = runNamespace
            .appendingPathComponent(publicationLedgerName)
            .path
        if let enumerator = fileManager.enumerator(
            at: runNamespace,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) {
            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent
                if name == publicationRecordName || name.hasPrefix(publicationRecordName + ".") {
                    continue
                }
                if (fileURL.path as NSString).standardizingPath == rootLedgerPath { continue }
                var info = stat()
                guard lstat(fileURL.path, &info) == 0,
                      Self.isRegularFile(info) else { continue }
                existingCount += 1
                existingBytes += Int(info.st_size)
                if existingCount + 1 > caps.perRunFiles || existingBytes + addingBytes > caps.perRunBytes {
                    break
                }
            }
        }
        guard existingCount + 1 <= caps.perRunFiles else {
            throw RunOutputSnapshotError.overCap(
                cap: "a run owns at most \(caps.perRunFiles) output files"
            )
        }
        guard existingBytes + addingBytes <= caps.perRunBytes else {
            throw RunOutputSnapshotError.overCap(
                cap: "run outputs are limited to \(caps.perRunBytes) bytes total"
            )
        }
    }

    /// Walks the EXISTING part of the run namespace and refuses to publish
    /// through any component that is a symlink or non-directory: the
    /// namespace belongs to this store and must never delegate outside it.
    /// The walk is deliberately LEXICAL (reconstructed from the artifact
    /// root downward, never from `resolvingSymlinksInPath`'s target): a
    /// symlinked component whose TARGET stays inside the artifact root
    /// would otherwise fold into a contained-looking resolved path and the
    /// alias itself would never be checked before writing through it.
    private static func assertOwnedNamespace(from base: URL, upTo directory: URL) throws {
        let container = base.standardizedFileURL.path
        let target = directory.standardizedFileURL.path
        guard target.count > container.count, target.hasPrefix(container + "/") else {
            throw RunOutputSnapshotError.snapshotAliased("snapshot namespace escapes the artifact store")
        }
        var walk = container
        for component in target.dropFirst(container.count + 1).split(separator: "/") {
            walk = (walk as NSString).appendingPathComponent(String(component))
            var info = stat()
            guard lstat(walk, &info) == 0 else { break }
            guard Self.isDirectory(info) else {
                throw RunOutputSnapshotError.snapshotAliased(String(component))
            }
        }
    }

    private static func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// ANDROID MIRROR DELTA (D04 producer batch): resolve the artifact-store
    /// base for one store operation. A caller-supplied root always wins; the
    /// Apple-platform default is unchanged (`FloeArtifactStore.root()`); on
    /// Android the implicit Foundation default is refused because it can land
    /// below `$HOME` — the trusted runtime composition must pass the owned
    /// persistent root explicitly (`RuntimeFacadeRunOutput` binding), and
    /// without it the store fails closed instead of inventing storage.
    private static func resolveArtifactRoot(given explicit: URL?) throws -> URL {
        if let explicit { return explicit }
        #if os(Android)
        throw RunOutputSnapshotError.bindingMissing(
            "run-output publication requires the trusted runtime artifact-root binding"
        )
        #else
        return try FloeArtifactStore.root()
        #endif
    }

    /// `st_mode` and the `S_IF*` masks differ in width across platforms, so
    /// every type test goes through the `mode_t`-typed conversions below.
    private static func isRegularFile(_ info: stat) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func isDirectory(_ info: stat) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    // MARK: - Per-run publication serialization

    /// Serializes publish critical sections per run namespace inside this
    /// process. Different runs never block each other; the lock is held
    /// only for bounded local filesystem work (ledger read/decide, caps
    /// scan, capped copy, move, ledger update). Cross-process writers are
    /// not in scope for the core package (producers run in the app process;
    /// the reader is read-verify only) and the deterministic
    /// never-overwrite move still fails an external race honestly.
    private static let publicationLocks = RunOutputPublicationLocks()

    private static func withRunPublicationLock<T>(
        key: String,
        _ body: () throws -> T
    ) throws -> T {
        let entry = publicationLocks.retain(key)
        entry.lock.lock()
        defer {
            entry.lock.unlock()
            publicationLocks.release(key, entry: entry)
        }
        return try body()
    }
}

/// Refcounted per-key `NSLock` registry so one process serializes
/// publications per run namespace without growing without limit.
private final class RunOutputPublicationLocks: @unchecked Sendable {
    final class Entry: @unchecked Sendable {
        let lock = NSLock()
    }
    private let master = NSLock()
    private var entries: [String: (entry: Entry, holds: Int)] = [:]

    func retain(_ key: String) -> Entry {
        master.lock()
        defer { master.unlock() }
        if let existing = entries[key] {
            entries[key] = (existing.entry, existing.holds + 1)
            return existing.entry
        }
        let created = Entry()
        entries[key] = (created, 1)
        return created
    }

    func release(_ key: String, entry: Entry) {
        master.lock()
        defer { master.unlock() }
        guard let existing = entries[key], existing.entry === entry else { return }
        if existing.holds <= 1 {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = (existing.entry, existing.holds - 1)
        }
    }
}

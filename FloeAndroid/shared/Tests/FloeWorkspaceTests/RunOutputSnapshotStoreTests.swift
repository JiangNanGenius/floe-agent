// FloeWorkspaceTests — S3-D RunOutputSnapshotStore over the REAL filesystem.
// Ported (job-3135f83ef97c4a21) byte-for-byte from iOS main 8f185ac
// FloeAgent/Tests/FloeToolsTests/RunOutputSnapshotStoreTests.swift
// (blob 07691159a185a1646a81776720ded69eef2038cf). The only deltas: the
// suite lives in FloeWorkspaceTests (the shared package's host-runnable
// real-filesystem suite — the Android shared package has no FloeToolsTests
// target, and the G03-R2 precedent puts real-filesystem engine suites
// here), and every call already injects an explicit artifactRoot so the
// Android fail-closed default-root delta (see the store header) is not
// exercised by accident. Assertions untouched: fake-free publication,
// tamper/missing/alias detection, LEXICAL traversal and symlink containment,
// verify-time identity re-derivation, binding honesty, idempotency/conflict
// via the publication ledger, crash/ledger-loss adoption, cancellable
// streaming copy, per-run caps, concurrent publishers and the strict
// no-launder runtime seal.
// No fake harness: real files, real digests, real directories.

import Foundation
import Testing
@testable import FloeTools
@testable import FloeModels
@testable import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private func makeScratchRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FloeRunOutputTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("ArtifactStore", isDirectory: true)
}

private func makeToolContext(
    runID: UUID = UUID(),
    callID: String? = "call-1",
    conversationID: UUID? = nil,
    environmentID: String? = "env-1",
    temporaryReadOnly: Bool = false,
    cancellation: CancellationToken = CancellationToken()
) -> ToolContext {
    let task = conversationID ?? UUID()
    return ToolContext(
        runID: runID,
        toolCallID: callID,
        cancellation: cancellation,
        environmentID: environmentID,
        conversationID: task,
        temporaryReadOnly: temporaryReadOnly
    )
}

private func commitFile(
    in directory: URL,
    name: String,
    content: Data,
    displayName: String? = nil,
    mimeType: String = "application/octet-stream",
    uti: String? = nil
) throws -> RunOutputCommit {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try content.write(to: url)
    return RunOutputCommit(
        sourceURL: url,
        sha256: FloeDigest.sha256Hex(content),
        byteCount: content.count,
        displayName: displayName ?? name,
        mimeType: mimeType,
        uti: uti
    )
}

private func snapshotURL(root: URL, receipt: RunOutputFile) -> URL {
    root.appendingPathComponent(receipt.relativePath)
}

@Suite("FloeTools.RunOutputSnapshotStore")
struct RunOutputSnapshotStoreTests {

    @Test("publish freezes a canonical snapshot and verifies it intact")
    func publishHappyPath() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let source = try commitFile(in: root.appendingPathComponent("workspace"), name: "doc.txt", content: Data("run bytes".utf8))
        let context = makeToolContext()
        let receipt = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(producerTool: "document.createWord", slot: "document", commit: source),
            using: context, artifactRoot: root
        )
        #expect(receipt.isCanonicalForCurrentRun)
        #expect(receipt.hasRuntimeConsistentIdentity)
        #expect(receipt.runID == context.runID)
        #expect(receipt.taskID == context.conversationID)
        #expect(receipt.environmentID == "env-1")
        #expect(receipt.producerCallID == "call-1")
        #expect(receipt.producerTool == "document.createWord")
        #expect(receipt.relativePath.hasPrefix("RunOutputs/\(context.runID.uuidString)/"))
        if case .verified(let url) = RunOutputSnapshotStore.verify(receipt, artifactRoot: root) {
            #expect(try Data(contentsOf: url) == Data("run bytes".utf8))
        } else {
            Issue.record("freshly published snapshot failed verification")
        }
        // The ledger recorded the publication.
        #expect(FileManager.default.fileExists(atPath: root
            .appendingPathComponent("RunOutputs")
            .appendingPathComponent(context.runID.uuidString)
            .appendingPathComponent(RunOutputSnapshotStore.publicationLedgerName).path))
    }

    @Test("later edits and deletion of the workspace original cannot change the run bytes")
    func stableSnapshotAgainstOriginalChanges() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let workspace = root.appendingPathComponent("workspace")
        let source = try commitFile(in: workspace, name: "doc.txt", content: Data("v1".utf8))
        let receipt = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(producerTool: "document.convert", slot: "document", commit: source),
            using: makeToolContext(), artifactRoot: root
        )
        try Data("completely different v2".utf8).write(to: source.sourceURL)
        #expect(RunOutputSnapshotStore.verify(receipt, artifactRoot: root) == .verified(url: snapshotURL(root: root, receipt: receipt)))
        try FileManager.default.removeItem(at: source.sourceURL)
        if case .verified(let url) = RunOutputSnapshotStore.verify(receipt, artifactRoot: root) {
            #expect(try Data(contentsOf: url) == Data("v1".utf8))
        } else {
            Issue.record("snapshot must survive deletion of the original")
        }
    }

    @Test("tampered, deleted and aliased snapshots report accurately")
    func tamperDeletionAlias() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let source = try commitFile(in: root.appendingPathComponent("workspace"), name: "a.bin", content: Data("payload".utf8))
        let receipt = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(producerTool: "network.download", slot: "file", commit: source),
            using: makeToolContext(), artifactRoot: root
        )
        let snapshot = snapshotURL(root: root, receipt: receipt)
        // Tamper: same length, different bytes.
        try Data("tampere".utf8).write(to: snapshot)
        #expect(RunOutputSnapshotStore.verify(receipt, artifactRoot: root) == .changed(displayName: "a.bin"))
        // Size tamper.
        try Data("longer payload".utf8).write(to: snapshot)
        #expect(RunOutputSnapshotStore.verify(receipt, artifactRoot: root) == .changed(displayName: "a.bin"))
        // Delete.
        try FileManager.default.removeItem(at: snapshot)
        #expect(RunOutputSnapshotStore.verify(receipt, artifactRoot: root) == .missing(displayName: "a.bin"))
        // Hardlink alias: recreate the same bytes, then add a second link.
        try Data("payload".utf8).write(to: snapshot)
        try FileManager.default.linkItem(at: snapshot, to: snapshot.appendingPathExtension("mirror"))
        #expect(RunOutputSnapshotStore.verify(receipt, artifactRoot: root)
            == .rejected(reason: "snapshot is not a plain single-link regular file"))
        // A malformed (foreign-path) receipt never reaches the disk layer.
        var foreign = receipt
        foreign.relativePath = "GeneratedImages/stolen.png"
        #expect(RunOutputSnapshotStore.verify(foreign, artifactRoot: root)
            == .rejected(reason: "receipt is not a canonical run-owned snapshot reference"))
    }

    @Test("symlinked sources, unsafe names and symlinked namespace components are refused")
    func containmentAndSymlinks() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let real = workspace.appendingPathComponent("real.bin")
        try Data("bytes".utf8).write(to: real)
        let link = workspace.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let digest = FloeDigest.sha256Hex(Data("bytes".utf8))
        let viaLink = RunOutputCommit(
            sourceURL: link, sha256: digest, byteCount: 5,
            displayName: "snap.bin", mimeType: "application/octet-stream", uti: nil
        )
        // A symlinked "source" is never trusted commit bytes.
        #expect(throws: RunOutputSnapshotError.sourceUnavailable("committed source must be a regular file")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(producerTool: "t", slot: "s", commit: viaLink),
                using: makeToolContext(), artifactRoot: root
            )
        }
        // Traversal / hidden display names are rejected before any path work.
        let unsafeName = RunOutputCommit(
            sourceURL: real, sha256: digest, byteCount: 5,
            displayName: "../escape.bin", mimeType: "application/octet-stream", uti: nil
        )
        #expect(throws: RunOutputSnapshotError.identityInvalid("display name is not a safe single filename component")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(producerTool: "t", slot: "s", commit: unsafeName),
                using: makeToolContext(), artifactRoot: root
            )
        }
        // Publishing this run's own snapshot namespace back into itself is
        // aliasing and is refused as a source.
        let context = makeToolContext()
        let insideOwnRunDir = root
            .appendingPathComponent("RunOutputs")
            .appendingPathComponent(context.runID.uuidString)
        try FileManager.default.createDirectory(at: insideOwnRunDir, withIntermediateDirectories: true)
        let insideOwnRunFile = insideOwnRunDir.appendingPathComponent("prior.bin")
        try Data("bytes".utf8).write(to: insideOwnRunFile)
        let insideOwnRun = RunOutputCommit(
            sourceURL: insideOwnRunFile,
            sha256: digest, byteCount: 5,
            displayName: "out.bin", mimeType: "application/octet-stream", uti: nil
        )
        #expect(throws: RunOutputSnapshotError.sourceUnavailable("committed source already lives inside this run's snapshot namespace")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(producerTool: "t", slot: "s", commit: insideOwnRun),
                using: context, artifactRoot: root
            )
        }
        // A symlinked RunOutputs namespace component is refused as aliasing
        // before anything is written through it.
        let root2 = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root2.deletingLastPathComponent()) }
        let base2 = root2   // artifactRoot = the ArtifactStore URL
        try FileManager.default.createDirectory(at: base2, withIntermediateDirectories: true)
        let outside = root2.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: base2.appendingPathComponent("RunOutputs"),
            withDestinationURL: outside
        )
        let source2 = try commitFile(in: root2.appendingPathComponent("w"), name: "x.bin", content: Data("xy".utf8), displayName: "x.bin")
        #expect(throws: RunOutputSnapshotError.snapshotAliased("RunOutputs")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(producerTool: "t", slot: "s", commit: source2),
                using: makeToolContext(), artifactRoot: base2
            )
        }
        // Nothing may be created at the escaped destination.
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("verify rejects aliased namespace ancestors (even in-root) and identities that do not re-derive")
    func verifyRejectsAncestorAliasesAndForeignIdentity() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let source = try commitFile(
            in: root.appendingPathComponent("workspace"), name: "v.bin", content: Data("verify bytes".utf8)
        )
        let receipt = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(producerTool: "t", slot: "s", commit: source),
            using: makeToolContext(), artifactRoot: root
        )
        #expect(RunOutputSnapshotStore.verify(receipt, artifactRoot: root).isVerified)

        // Replace the identity DIRECTORY with a symlink to a directory that
        // stays INSIDE the artifact root (in-root foreign alias). The file
        // bytes are reachable through the alias; the lexical ancestor walk
        // must still reject it — resolving symlinks first would fold the
        // alias into a contained-looking path.
        let runDir = root
            .appendingPathComponent("RunOutputs")
            .appendingPathComponent(receipt.runID.uuidString, isDirectory: true)
        let identity = runDir.appendingPathComponent(receipt.outputID, isDirectory: true)
        let relocated = runDir.appendingPathComponent("hidden-relocated", isDirectory: true)
        try FileManager.default.moveItem(at: identity, to: relocated)
        try FileManager.default.createSymbolicLink(at: identity, withDestinationURL: relocated)
        let snapshotPath = relocated.appendingPathComponent(receipt.displayName)
        #expect(FileManager.default.fileExists(atPath: snapshotPath.path)) // bytes still reachable via the alias
        switch RunOutputSnapshotStore.verify(receipt, artifactRoot: root) {
        case .rejected(let reason):
            #expect(reason.contains("not a plain directory"))
        default:
            Issue.record("an in-root symlinked identity directory must be rejected, not followed")
        }
        // Restore the real directory and confirm verification passes again.
        try FileManager.default.removeItem(at: identity)
        try FileManager.default.moveItem(at: relocated, to: identity)
        #expect(RunOutputSnapshotStore.verify(receipt, artifactRoot: root).isVerified)

        // A receipt that is canonical for its OWN claims but whose outputID
        // does not re-derive from (runID, producerCallID, slot) is rejected
        // before the path walk.
        var misderived = receipt
        let otherID = RunOutputFile.derivedOutputID(
            runID: receipt.runID, producerCallID: receipt.producerCallID, slot: "other-slot"
        )
        misderived.outputID = otherID
        misderived.relativePath = RunOutputFile.canonicalRelativePath(
            runID: misderived.runID, outputID: otherID, displayName: misderived.displayName
        )
        #expect(misderived.isCanonicalForCurrentRun) // shape-valid — and still not identity-consistent
        #expect(!misderived.hasRuntimeConsistentIdentity)
        #expect(RunOutputSnapshotStore.verify(misderived, artifactRoot: root)
            == .rejected(reason: "output identity does not re-derive from its sealed run, call and slot"))
    }

    @Test("a symlinked run directory inside a real RunOutputs namespace is refused before any write")
    func midNamespaceSymlinkIsRefused() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let context = makeToolContext()
        let runOutputs = root.appendingPathComponent("RunOutputs", isDirectory: true)
        try FileManager.default.createDirectory(at: runOutputs, withIntermediateDirectories: true)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: runOutputs.appendingPathComponent(context.runID.uuidString),
            withDestinationURL: elsewhere
        )
        let source = try commitFile(
            in: root.appendingPathComponent("w"), name: "m.bin", content: Data("mm".utf8), displayName: "m.bin"
        )
        #expect(throws: RunOutputSnapshotError.snapshotAliased(context.runID.uuidString)) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(producerTool: "t", slot: "s", commit: source),
                using: context, artifactRoot: root
            )
        }
        // Nothing may be created through the alias.
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test("publication requires the real call/task binding and refuses temporary runs")
    func bindingHonesty() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let source = try commitFile(in: root.appendingPathComponent("workspace"), name: "x.bin", content: Data("x".utf8))
        let request = RunOutputSnapshotRequest(producerTool: "t", slot: "s", commit: source)
        #expect(throws: RunOutputSnapshotError.bindingMissing("run-output publication requires the real tool-call binding")) {
            try RunOutputSnapshotStore.publish(request, using: makeToolContext(callID: nil), artifactRoot: root)
        }
        #expect(throws: RunOutputSnapshotError.bindingMissing("run-output publication requires the real task binding")) {
            var context = makeToolContext()
            context.conversationID = nil
            return try RunOutputSnapshotStore.publish(request, using: context, artifactRoot: root)
        }
        #expect(throws: RunOutputSnapshotError.policyRefused("temporary (ephemeral) runs cannot publish durable run outputs")) {
            try RunOutputSnapshotStore.publish(
                request, using: makeToolContext(temporaryReadOnly: true), artifactRoot: root
            )
        }
        // Nothing was created for the failed publications.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("RunOutputs").path))
    }

    @Test("cancellation at a phase boundary publishes nothing and leaves nothing behind")
    func cancellationAtBoundaryIsClean() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let source = try commitFile(in: root.appendingPathComponent("workspace"), name: "big.bin", content: Data(repeating: 0x5A, count: 3 << 20))
        let token = CancellationToken()
        token.cancel()
        #expect(throws: FloeError.cancelled) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(producerTool: "t", slot: "s", commit: source),
                using: makeToolContext(cancellation: token), artifactRoot: root
            )
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("RunOutputs").path))
    }

    @Test("an over-cap commit is rejected explicitly and commits nothing")
    func overCapCommitRejectedWithoutSideEffects() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let context = makeToolContext()
        let content = Data(repeating: 0x3C, count: 3 << 20)
        let source = try commitFile(in: root.appendingPathComponent("w"), name: "m.bin", content: content, displayName: "m.bin")
        // The declared commit size (3 MiB) exceeds the injected 2 MiB per-file
        // cap. The copy-time streamed guard (total > maxBytes) is the same
        // explicit overCap error, so a source that grew after the stat
        // pre-check can never commit over the cap either.
        #expect(throws: RunOutputSnapshotError.overCap(cap: "run output files are limited to 2097152 bytes each")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(producerTool: "t", slot: "s", commit: source),
                using: context,
                caps: RunOutputCaps(perFileBytes: 2 << 20, perRunBytes: 1 << 30, perRunFiles: 10),
                artifactRoot: root
            )
        }
        let runOutputs = root.appendingPathComponent("RunOutputs")
        if FileManager.default.fileExists(atPath: runOutputs.path) {
            let leftovers = try collectRegularFiles(in: runOutputs)
            #expect(leftovers.isEmpty)
        }
    }

    @Test("byte-identical retry is idempotent; renames, retypes and different bytes conflict")
    func idempotencyAndMetadataConflict() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let context = makeToolContext()
        let content = Data("same bytes".utf8)
        let first = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(
                producerTool: "t", slot: "doc",
                commit: try commitFile(in: root.appendingPathComponent("w1"), name: "one.bin", content: content, displayName: "one.bin", mimeType: "application/octet-stream", uti: "public.data")
            ),
            using: context, artifactRoot: root
        )
        // Byte- AND metadata-identical replay: idempotent, same receipt.
        let replay = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(
                producerTool: "t", slot: "doc",
                commit: try commitFile(in: root.appendingPathComponent("w2"), name: "one-copy.bin", content: content, displayName: "one.bin", mimeType: "application/octet-stream", uti: "public.data")
            ),
            using: context, artifactRoot: root
        )
        #expect(replay == first)
        // Same bytes under the same slot but a CHANGED display name: conflict,
        // and no second filename may appear under the output identity.
        #expect(throws: RunOutputSnapshotError.conflict(displayName: "one.bin")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(
                    producerTool: "t", slot: "doc",
                    commit: try commitFile(in: root.appendingPathComponent("w3"), name: "three.bin", content: content, displayName: "renamed.bin")
                ),
                using: context, artifactRoot: root
            )
        }
        // Same name/bytes but a changed MIME type: also a conflict.
        #expect(throws: RunOutputSnapshotError.conflict(displayName: "one.bin")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(
                    producerTool: "t", slot: "doc",
                    commit: try commitFile(in: root.appendingPathComponent("w4"), name: "four.bin", content: content, displayName: "one.bin", mimeType: "application/pdf")
                ),
                using: context, artifactRoot: root
            )
        }
        let identityDir = root.appendingPathComponent(first.relativePath).deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: identityDir.path)
        // Only the snapshot plus the store's own hidden publication record
        // may exist under one output identity — never a second filename.
        #expect(Set(names) == ["one.bin", RunOutputSnapshotStore.publicationRecordName])
        // Different bytes under the same slot: conflict.
        #expect(throws: RunOutputSnapshotError.conflict(displayName: "one.bin")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(
                    producerTool: "t", slot: "doc",
                    commit: try commitFile(in: root.appendingPathComponent("w5"), name: "five.bin", content: Data("other bytes".utf8), displayName: "one.bin")
                ),
                using: context, artifactRoot: root
            )
        }
        // A recorded publication whose bytes went missing conflicts instead
        // of silently re-committing under the same identity.
        try FileManager.default.removeItem(at: snapshotURL(root: root, receipt: first))
        #expect(throws: RunOutputSnapshotError.conflict(displayName: "one.bin")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(
                    producerTool: "t", slot: "doc",
                    commit: try commitFile(in: root.appendingPathComponent("w6"), name: "six.bin", content: content, displayName: "one.bin", mimeType: "application/octet-stream", uti: "public.data")
                ),
                using: context, artifactRoot: root
            )
        }
        #expect(!FileManager.default.fileExists(atPath: snapshotURL(root: root, receipt: first).path))
    }

    @Test("ledger-loss adoption is proven only by the durable per-output record; new metadata never blesses committed bytes; a corrupt ledger fails closed")
    func ledgerRepairAndCorruption() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let context = makeToolContext()
        let content = Data("durable".utf8)
        let receipt = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(
                producerTool: "t", slot: "s",
                commit: try commitFile(in: root.appendingPathComponent("w"), name: "s.bin", content: content, displayName: "s.bin")
            ),
            using: context, artifactRoot: root
        )
        let runDir = root.appendingPathComponent("RunOutputs").appendingPathComponent(context.runID.uuidString)
        let ledger = runDir.appendingPathComponent(RunOutputSnapshotStore.publicationLedgerName)
        let record = runDir.appendingPathComponent(receipt.outputID)
            .appendingPathComponent(RunOutputSnapshotStore.publicationRecordName)
        // The pre-move full-metadata claim is durable beside the snapshot.
        #expect(FileManager.default.fileExists(atPath: record.path))
        // Ledger lost (crash window): the identical publication is adopted
        // back, PROVEN by the per-output record.
        try FileManager.default.removeItem(at: ledger)
        let republished = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(
                producerTool: "t", slot: "s",
                commit: try commitFile(in: root.appendingPathComponent("w2"), name: "s2.bin", content: content, displayName: "s.bin")
            ),
            using: context, artifactRoot: root
        )
        #expect(republished == receipt)
        #expect(FileManager.default.fileExists(atPath: ledger.path))
        // Ledger AND record gone: the original MIME/UTI/slot is no longer
        // provable, so the retry conflicts. The bytes are preserved and no
        // ledger is re-authored under the unverifiable claim.
        try FileManager.default.removeItem(at: ledger)
        try FileManager.default.removeItem(at: record)
        #expect(throws: RunOutputSnapshotError.conflict(displayName: "s.bin")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(
                    producerTool: "t", slot: "s",
                    commit: try commitFile(in: root.appendingPathComponent("w3"), name: "s3.bin", content: content, displayName: "s.bin")
                ),
                using: context, artifactRoot: root
            )
        }
        #expect(RunOutputSnapshotStore.verify(receipt, artifactRoot: root).isVerified)
        #expect(!FileManager.default.fileExists(atPath: ledger.path))
        // Record intact but NEW metadata claimed (retyped bytes/name match):
        // conflict, and the record is not rewritten under the new claim —
        // the ORIGINAL metadata adoption still succeeds afterwards.
        let second = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(
                producerTool: "t", slot: "retyped",
                commit: try commitFile(in: root.appendingPathComponent("w4"), name: "r.bin", content: Data("retyped".utf8), displayName: "r.bin", mimeType: "text/plain")
            ),
            using: context, artifactRoot: root
        )
        try FileManager.default.removeItem(at: ledger)
        #expect(throws: RunOutputSnapshotError.conflict(displayName: "r.bin")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(
                    producerTool: "t", slot: "retyped",
                    commit: try commitFile(in: root.appendingPathComponent("w5"), name: "r2.bin", content: Data("retyped".utf8), displayName: "r.bin", mimeType: "application/pdf")
                ),
                using: context, artifactRoot: root
            )
        }
        let reAdopted = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(
                producerTool: "t", slot: "retyped",
                commit: try commitFile(in: root.appendingPathComponent("w6"), name: "r3.bin", content: Data("retyped".utf8), displayName: "r.bin", mimeType: "text/plain")
            ),
            using: context, artifactRoot: root
        )
        #expect(reAdopted == second)
        // Corrupted ledger: fail closed, snapshot untouched.
        try Data("not json".utf8).write(to: ledger)
        #expect(throws: RunOutputSnapshotError.ioFailure("run output publication ledger is corrupted")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(
                    producerTool: "t", slot: "other",
                    commit: try commitFile(in: root.appendingPathComponent("w7"), name: "s4.bin", content: Data("new".utf8), displayName: "s4.bin")
                ),
                using: context, artifactRoot: root
            )
        }
        #expect(RunOutputSnapshotStore.verify(receipt, artifactRoot: root) == .verified(url: snapshotURL(root: root, receipt: receipt)))
    }

    @Test("different slots may share a filename; the same filename under one identity never duplicates")
    func distinctSlotsAllowSameName() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let context = makeToolContext()
        let bytes = Data("same content different slots".utf8)
        let a = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(producerTool: "t", slot: "page-1", commit: try commitFile(in: root.appendingPathComponent("a"), name: "p.bin", content: bytes, displayName: "page.pdf")),
            using: context, artifactRoot: root
        )
        let b = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(producerTool: "t", slot: "page-2", commit: try commitFile(in: root.appendingPathComponent("b"), name: "p.bin", content: bytes, displayName: "page.pdf")),
            using: context, artifactRoot: root
        )
        #expect(a.outputID != b.outputID)
        #expect(a.displayName == b.displayName)
        #expect(RunOutputSnapshotStore.verify(a, artifactRoot: root).isVerified)
        #expect(RunOutputSnapshotStore.verify(b, artifactRoot: root).isVerified)
    }

    @Test("caps are explicit errors and count retained/incomplete snapshots, excluding the ledger")
    func capsEnforcement() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let context = makeToolContext()
        // Declared per-file cap.
        let big = Data(repeating: 7, count: 64)
        let commit = try commitFile(in: root.appendingPathComponent("w"), name: "big.bin", content: big, displayName: "big.bin")
        #expect(throws: RunOutputSnapshotError.overCap(cap: "run output files are limited to 10 bytes each")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(producerTool: "t", slot: "s1", commit: commit),
                using: context,
                caps: RunOutputCaps(perFileBytes: 10, perRunBytes: 1000, perRunFiles: 10),
                artifactRoot: root
            )
        }
        // Per-run count cap; an idempotent replay does not consume a slot.
        let small = try commitFile(in: root.appendingPathComponent("w2"), name: "s.bin", content: Data("ab".utf8), displayName: "s.bin")
        let caps = RunOutputCaps(perFileBytes: 100, perRunBytes: 1000, perRunFiles: 2)
        _ = try RunOutputSnapshotStore.publish(RunOutputSnapshotRequest(producerTool: "t", slot: "one", commit: small), using: context, caps: caps, artifactRoot: root)
        _ = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(producerTool: "t", slot: "two", commit: try commitFile(in: root.appendingPathComponent("w3"), name: "s2.bin", content: Data("cd".utf8), displayName: "s2.bin")),
            using: context, caps: caps, artifactRoot: root
        )
        _ = try RunOutputSnapshotStore.publish(RunOutputSnapshotRequest(producerTool: "t", slot: "one", commit: small), using: context, caps: caps, artifactRoot: root) // idempotent
        #expect(throws: RunOutputSnapshotError.overCap(cap: "a run owns at most 2 output files")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(producerTool: "t", slot: "three", commit: try commitFile(in: root.appendingPathComponent("w4"), name: "s3.bin", content: Data("ef".utf8), displayName: "s3.bin")),
                using: context, caps: caps, artifactRoot: root
            )
        }
        // Per-run byte cap counting a RETAINED incomplete staging file.
        let root2 = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root2.deletingLastPathComponent()) }
        let context2 = makeToolContext()
        _ = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(producerTool: "t", slot: "a", commit: try commitFile(in: root2.appendingPathComponent("w"), name: "a.bin", content: Data(repeating: 1, count: 10), displayName: "a.bin")),
            using: context2, caps: RunOutputCaps(perFileBytes: 100, perRunBytes: 100, perRunFiles: 10), artifactRoot: root2
        )
        let retainedStagingDir = root2.appendingPathComponent("RunOutputs")
            .appendingPathComponent(context2.runID.uuidString)
            .appendingPathComponent("deadbeef", isDirectory: true)
        try FileManager.default.createDirectory(at: retainedStagingDir, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 85).write(to: retainedStagingDir
            .appendingPathComponent(RunOutputSnapshotStore.stagingPrefix + "leftover"))
        #expect(throws: RunOutputSnapshotError.overCap(cap: "run outputs are limited to 100 bytes total")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(producerTool: "t", slot: "b", commit: try commitFile(in: root2.appendingPathComponent("w2"), name: "b.bin", content: Data(repeating: 3, count: 9), displayName: "b.bin")),
                using: context2, caps: RunOutputCaps(perFileBytes: 100, perRunBytes: 100, perRunFiles: 10), artifactRoot: root2
            )
        }
    }

    @Test("a genuine user snapshot named manifest.json under its identity still counts against the run caps")
    func nestedManifestNamedUserFileIsCounted() throws {
        // The ledger-name exemption may only skip the run-namespace ROOT
        // bookkeeping file. A user output legitimately displayed
        // "manifest.json" sits NESTED under an output identity and must be
        // counted for bytes and for file number.
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let context = makeToolContext()
        let caps = RunOutputCaps(perFileBytes: 100, perRunBytes: 40, perRunFiles: 10)
        _ = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(producerTool: "t", slot: "one",
                commit: try commitFile(in: root.appendingPathComponent("w"), name: "src1.bin", content: Data(repeating: 1, count: 34), displayName: "manifest.json")),
            using: context, caps: caps, artifactRoot: root
        )
        #expect(throws: RunOutputSnapshotError.overCap(cap: "run outputs are limited to 40 bytes total")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(producerTool: "t", slot: "two",
                    commit: try commitFile(in: root.appendingPathComponent("w2"), name: "src2.bin", content: Data(repeating: 2, count: 34), displayName: "second.bin")),
                using: context, caps: caps, artifactRoot: root
            )
        }
        // File-count side: three distinct identities all displaying
        // "manifest.json" — the third exceeds a 2-file cap.
        let root2 = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root2.deletingLastPathComponent()) }
        let context2 = makeToolContext()
        let countCaps = RunOutputCaps(perFileBytes: 100, perRunBytes: 100_000, perRunFiles: 2)
        for slot in ["a", "b"] {
            _ = try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(producerTool: "t", slot: slot,
                    commit: try commitFile(in: root2.appendingPathComponent("w-\(slot)"), name: "src-\(slot).bin", content: Data([slot.utf8.first!]), displayName: "manifest.json")),
                using: context2, caps: countCaps, artifactRoot: root2
            )
        }
        #expect(throws: RunOutputSnapshotError.overCap(cap: "a run owns at most 2 output files")) {
            try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(producerTool: "t", slot: "c",
                    commit: try commitFile(in: root2.appendingPathComponent("w-c"), name: "src-c.bin", content: Data([UInt8(99)]), displayName: "manifest.json")),
                using: context2, caps: countCaps, artifactRoot: root2
            )
        }
    }

    @Test("concurrent publishers serialize: equal retries converge, distinct slots stay within caps")
    func concurrentPublications() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let context = makeToolContext()
        let content = Data("concurrent".utf8)
        let commit = try commitFile(in: root.appendingPathComponent("w"), name: "c.bin", content: content, displayName: "c.bin")
        let request = RunOutputSnapshotRequest(producerTool: "t", slot: "doc", commit: commit)
        // Eight simultaneous identical publications: all idempotent-equal.
        let receipts = try await withThrowingTaskGroup(of: RunOutputFile.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try RunOutputSnapshotStore.publish(request, using: context, artifactRoot: root)
                }
            }
            var collected: [RunOutputFile] = []
            for try await value in group { collected.append(value) }
            return collected
        }
        #expect(receipts.count == 8)
        #expect(Set(receipts).count == 1)
        let identityDir = root.appendingPathComponent(receipts[0].relativePath).deletingLastPathComponent()
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: identityDir.path))
            == ["c.bin", RunOutputSnapshotStore.publicationRecordName])

        // Four simultaneous DISTINCT slots with a 3-file cap: exactly three
        // commit; the fourth fails over-cap. Deterministic under the lock.
        let root2 = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root2.deletingLastPathComponent()) }
        let context2 = makeToolContext()
        let caps = RunOutputCaps(perFileBytes: 100, perRunBytes: 1000, perRunFiles: 3)
        let outcomes: [Result<RunOutputFile, Error>] = await withTaskGroup(of: Result<RunOutputFile, Error>.self) { group in
            for index in 0..<4 {
                group.addTask {
                    do {
                        let commit = try commitFile(in: root2.appendingPathComponent("w\(index)"), name: "n\(index).bin", content: Data("x\(index)".utf8), displayName: "n\(index).bin")
                        return .success(try RunOutputSnapshotStore.publish(
                            RunOutputSnapshotRequest(producerTool: "t", slot: "slot-\(index)", commit: commit),
                            using: context2, caps: caps, artifactRoot: root2
                        ))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var collected: [Result<RunOutputFile, Error>] = []
            for await value in group { collected.append(value) }
            return collected
        }
        let successes = outcomes.compactMap { try? $0.get() }
        #expect(successes.count == 3)
        #expect(outcomes.count == 4)
        let runDir = root2.appendingPathComponent("RunOutputs").appendingPathComponent(context2.runID.uuidString)
        let committedFiles = try collectRegularFiles(in: runDir).filter { url in
            let name = url.lastPathComponent
            return name != RunOutputSnapshotStore.publicationLedgerName
                && !name.hasPrefix(RunOutputSnapshotStore.stagingPrefix)
                && !name.hasPrefix(".")
        }
        #expect(committedFiles.count == 3)
    }

    @Test("a multi-megabyte copy streams without diverging from the commit digest")
    func streamingCopyIntegrity() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        var content = Data(capacity: 3 << 20)
        for chunk in 0..<64 { content.append(Data(repeating: UInt8(chunk % 251), count: 48 * 1024)) }
        let commit = try commitFile(in: root.appendingPathComponent("w"), name: "m.bin", content: content, displayName: "movie.bin")
        let receipt = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(producerTool: "video.transcode", slot: "video", commit: commit),
            using: makeToolContext(), artifactRoot: root
        )
        #expect(receipt.byteCount == content.count)
        #expect(receipt.sha256 == FloeDigest.sha256Hex(content))
        if case .verified(let url) = RunOutputSnapshotStore.verify(receipt, artifactRoot: root) {
            #expect(try Data(contentsOf: url) == content)
        } else {
            Issue.record("streamed snapshot failed verification")
        }
    }

    @Test("the runtime seal accepts only receipts bound to the exact authoritative call")
    func sealValidatesRealBindings() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let context = makeToolContext()
        let receipt = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(
                producerTool: "t", slot: "doc",
                commit: try commitFile(in: root.appendingPathComponent("w"), name: "r.bin", content: Data("seal".utf8), displayName: "r.bin")
            ),
            using: context, artifactRoot: root
        )
        // The real producer path: publish's draft survives the seal unchanged.
        if case .sealed(let sealed) = RunOutputSnapshotStore.seal(
            drafts: [receipt], runID: context.runID, taskID: context.conversationID,
            environmentID: "env-1", callID: "call-1", toolName: "t"
        ) {
            #expect(sealed == [receipt])
        } else {
            Issue.record("a genuine publication was rejected by its own seal")
        }
        // A routed context may record a resolved layer environment; the sealed
        // value stays the run's frozen binding — never a laundered claim.
        var routed = receipt
        routed.environmentID = "resolved-layer-view"
        if case .sealed(let sealed) = RunOutputSnapshotStore.seal(
            drafts: [routed], runID: context.runID, taskID: context.conversationID,
            environmentID: "env-1", callID: "call-1", toolName: "t"
        ) {
            #expect(sealed.first?.environmentID == "env-1")
        } else {
            Issue.record("routed environment view should seal to the authoritative value")
        }
        // Foreign canonical receipt (a DIFFERENT run) is rejected, not relabeled.
        let foreignRun = UUID()
        let foreignReceipt = RunOutputFile(
            outputID: RunOutputFile.derivedOutputID(runID: foreignRun, producerCallID: "call-1", slot: "doc"),
            slot: "doc", runID: foreignRun, taskID: context.conversationID, environmentID: "env-1",
            producerCallID: "call-1", producerTool: "t",
            relativePath: RunOutputFile.canonicalRelativePath(
                runID: foreignRun,
                outputID: RunOutputFile.derivedOutputID(runID: foreignRun, producerCallID: "call-1", slot: "doc"),
                displayName: "r.bin"
            ),
            displayName: "r.bin", mimeType: "application/octet-stream", uti: nil,
            byteCount: 4, sha256: FloeDigest.sha256Hex(Data("seal".utf8)), role: .userFile
        )
        #expect(foreignReceipt.isCanonicalForCurrentRun) // canonical — and still foreign
        let foreign = RunOutputSnapshotStore.seal(
            drafts: [foreignReceipt], runID: context.runID, taskID: context.conversationID,
            environmentID: "env-1", callID: "call-1", toolName: "t"
        )
        guard case .rejected(let reason) = foreign else {
            Issue.record("a foreign canonical receipt was laundered into this run"); return
        }
        #expect(reason.contains("different run"))
        // Mismatched call/tool/task/path/digest/slot are all ownership fences.
        let mutations: [(inout RunOutputFile) -> Void] = [
            { $0.producerCallID = "other" },
            { $0.producerTool = "other.tool" },
            { $0.taskID = UUID() },
            { $0.slot = "other" },
            { $0.relativePath = "RunOutputs/" + $0.runID.uuidString + "/x/y.bin" },
            { $0.sha256 = "ZZ" }
        ]
        for mutate in mutations {
            var draft = receipt
            mutate(&draft)
            let result = RunOutputSnapshotStore.seal(
                drafts: [draft], runID: context.runID, taskID: context.conversationID,
                environmentID: "env-1", callID: "call-1", toolName: "t"
            )
            guard case .rejected = result else {
                Issue.record("seal accepted a mutated binding"); return
            }
        }
        // Absent task/environment fields seal to the authoritative values.
        var stripped = receipt
        stripped.taskID = nil
        stripped.environmentID = nil
        if case .sealed(let sealed) = RunOutputSnapshotStore.seal(
            drafts: [stripped], runID: context.runID, taskID: context.conversationID,
            environmentID: "env-authoritative", callID: "call-1", toolName: "t"
        ) {
            #expect(sealed.first?.taskID == context.conversationID)
            #expect(sealed.first?.environmentID == "env-authoritative")
        } else {
            Issue.record("nil task/environment should seal authoritatively")
        }
        // Equal duplicates collapse; same slot with different bytes conflicts.
        let duplicated = RunOutputSnapshotStore.seal(
            drafts: [receipt, receipt, receipt], runID: context.runID, taskID: context.conversationID,
            environmentID: "env-1", callID: "call-1", toolName: "t"
        )
        if case .sealed(let sealed) = duplicated { #expect(sealed.count == 1) } else { Issue.record("equal duplicates must collapse") }
        var differentBytes = receipt
        differentBytes.sha256 = FloeDigest.sha256Hex(Data("other".utf8))
        let conflict = RunOutputSnapshotStore.seal(
            drafts: [receipt, differentBytes], runID: context.runID, taskID: context.conversationID,
            environmentID: "env-1", callID: "call-1", toolName: "t"
        )
        guard case .rejected(let conflictReason) = conflict else {
            Issue.record("same identity with different metadata must conflict"); return
        }
        #expect(conflictReason.contains("different metadata"))
        // Sealing a sealed receipt again is stable (resumed runs re-seal).
        if case .sealed(let once) = RunOutputSnapshotStore.seal(
            drafts: [receipt], runID: context.runID, taskID: context.conversationID,
            environmentID: "env-1", callID: "call-1", toolName: "t"
        ), case .sealed(let twice) = RunOutputSnapshotStore.seal(
            drafts: once, runID: context.runID, taskID: context.conversationID,
            environmentID: "env-1", callID: "call-1", toolName: "t"
        ) {
            #expect(once == twice)
        } else {
            Issue.record("re-sealing a sealed receipt must be stable")
        }
    }
}

extension RunOutputSnapshotVerification {
    var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }
}

private func collectRegularFiles(in directory: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey],
        options: [], errorHandler: { _, _ in true }
    ) else { return [] }
    var files: [URL] = []
    for case let url as URL in enumerator {
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) {
            files.append(url)
        }
    }
    return files
}

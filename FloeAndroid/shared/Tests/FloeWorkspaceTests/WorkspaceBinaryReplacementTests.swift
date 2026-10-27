// FloeAndroid — Guarded binary replacement regressions for
// `WorkspaceFileService.replaceBinaryFile` (job-ddd03f5bdc5b452a, G05-R2
// Office AI "save the original" native bridge). Authored SOURCE ONLY; Main's
// grouped host cohort compiles and executes them.
//
// These run the REAL production service against REAL temporary files and
// REAL digests — no mirrored re-implementation of the service logic:
// byte-exact non-text replacement with the source snapshot kept, the freeze
// gate (early and pre-commit), the required original digest conflict and
// missing-original refusal, input hash/size/budget/source-type refusal,
// cancellation, symlink/path-escape refusal and a late destination change
// caught by the service's own pre-commit verification.

import Foundation
import Testing
import FloeCore
import FloeTools
import FloeWorkspace

/// Same-thread recorder for `mutationGuard` invocations. The gate is always
/// invoked synchronously inside the service transaction, so uncheckedly
/// shared mutable state is safe here and keeps the tests honest about HOW
/// MANY times and against WHICH resolved URL the freeze gate executed.
private final class GateRecorder: @unchecked Sendable {
    private var seen: [URL] = []
    var count: Int { seen.count }
    var lastURL: URL? { seen.last }
    func record(_ url: URL) { seen.append(url) }
}

@Suite("Workspace guarded binary replacement")
struct WorkspaceBinaryReplacementTests {

    // MARK: - Success and receipt honesty

    @Test func byteExactNonTextReplacementKeepsSourceAndReceiptMatchesDisk() throws {
        try fixture { root, source, service in
            let original = binaryBytes(seed: 7, length: 4096)
            _ = try service.createBinaryFile("deck.pptx", data: original, overwrite: false)
            // 1.5 MiB replacement forces multiple 1 MiB streaming chunks.
            let replacement = binaryBytes(seed: 23, length: 1_572_864)
            try replacement.write(to: source)

            let outcome = try service.replaceBinaryFile(
                "deck.pptx", from: source,
                expectedOriginalSHA256: FloeDigest.sha256Hex(original),
                expectedSourceSHA256: FloeDigest.sha256Hex(replacement),
                expectedSourceBytes: replacement.count
            )

            // Real receipt: bytes, digest and mtime of the committed file.
            let committed = try Data(contentsOf: root.appendingPathComponent("deck.pptx"))
            #expect(committed == replacement)
            #expect(committed.contains(0)) // non-text bytes survive untouched
            #expect(outcome.bytesWritten == replacement.count)
            #expect(outcome.sha256 == FloeDigest.sha256Hex(replacement))
            let committedSHA = try FloeDigest.sha256Hex(ofFileAt: root.appendingPathComponent("deck.pptx"))
            #expect(outcome.sha256 == committedSHA)
            #expect(outcome.mtime > 0)
            let diskMtime = try root.appendingPathComponent("deck.pptx")
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            #expect(abs((diskMtime?.timeIntervalSince1970 ?? 0) - outcome.mtime) < 2.0)

            // The recoverable input snapshot is kept intact, and the owned
            // transaction stage leaves no residue in the workspace.
            #expect(try Data(contentsOf: source) == replacement)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["deck.pptx"])
        }
    }

    @Test func officeSizedInputAboveModelTextCapReplacesWhileToolWriteRefuses() throws {
        try fixture { root, source, service in
            // An existing original larger than the guard's model write cap is
            // still a legitimate Office original; write() is a different
            // policy and this service API carries its own bounded budget.
            let original = binaryBytes(seed: 11, length: 5 * 1024 * 1024)
            let originalURL = root.appendingPathComponent("big.docx")
            try original.write(to: originalURL)
            let replacement = binaryBytes(seed: 13, length: 5 * 1024 * 1024 + 17)
            try replacement.write(to: source)

            let outcome = try service.replaceBinaryFile(
                "big.docx", from: source,
                expectedOriginalSHA256: FloeDigest.sha256Hex(original),
                expectedSourceSHA256: FloeDigest.sha256Hex(replacement),
                expectedSourceBytes: replacement.count
            )
            #expect(outcome.bytesWritten == replacement.count)
            #expect(try Data(contentsOf: originalURL) == replacement)

            // The model binary-write cap still refuses the same payload:
            // this API did not relax it.
            #expect(throws: WorkspaceToolError.tooLarge(limit: 4 * 1024 * 1024)) {
                try service.createBinaryFile("copy.docx", data: replacement, overwrite: false)
            }
        }
    }

    // MARK: - Freeze gate (existing policy executes and is rechecked)

    @Test func frozenOriginalIsRefusedBeforeAnyCopyAndBothFilesRemainIntact() throws {
        try fixture { root, source, _ in
            let original = binaryBytes(seed: 3, length: 1024)
            try original.write(to: root.appendingPathComponent("deck.pptx"))
            let replacement = binaryBytes(seed: 5, length: 4096)
            try replacement.write(to: source)

            let recorder = GateRecorder()
            let frozen = WorkspaceFileService(
                guard: WorkspacePathGuard(rootURL: root),
                mutationGuard: { url in
                    recorder.record(url)
                    throw WorkspaceToolError.invalidArguments("frozen original")
                }
            )
            #expect(throws: Error.self) {
                try frozen.replaceBinaryFile(
                    "deck.pptx", from: source,
                    expectedOriginalSHA256: FloeDigest.sha256Hex(original),
                    expectedSourceSHA256: FloeDigest.sha256Hex(replacement),
                    expectedSourceBytes: replacement.count
                )
            }
            // The gate executed with the RESOLVED destination URL and the
            // refusal happened before any staging copy started.
            #expect(recorder.count == 1)
            #expect(recorder.lastURL == resolved(root, "deck.pptx"))
            #expect(try Data(contentsOf: root.appendingPathComponent("deck.pptx")) == original)
            #expect(try Data(contentsOf: source) == replacement)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["deck.pptx"])
        }
    }

    @Test func successfulReplacementRunsTheFreezeGateAgainImmediatelyBeforeCommit() throws {
        try fixture { root, source, _ in
            let original = binaryBytes(seed: 17, length: 1024)
            try original.write(to: root.appendingPathComponent("deck.docx"))
            let replacement = binaryBytes(seed: 19, length: 2048)
            try replacement.write(to: source)

            let recorder = GateRecorder()
            let service = WorkspaceFileService(
                guard: WorkspacePathGuard(rootURL: root),
                mutationGuard: { url in recorder.record(url) }
            )
            _ = try service.replaceBinaryFile(
                "deck.docx", from: source,
                expectedOriginalSHA256: FloeDigest.sha256Hex(original),
                expectedSourceSHA256: FloeDigest.sha256Hex(replacement),
                expectedSourceBytes: replacement.count
            )
            // Early (before the copy) AND again inside the pre-commit
            // verification, closest to the atomic move/replace.
            #expect(recorder.count == 2)
            #expect(recorder.lastURL == resolved(root, "deck.docx"))
        }
    }

    @Test func lateOriginalChangeIsCaughtByTheServicePreCommitRecheck() throws {
        try fixture { root, source, _ in
            let original = binaryBytes(seed: 29, length: 1024)
            let destinationURL = root.appendingPathComponent("deck.pptx")
            try original.write(to: destinationURL)
            let replacement = binaryBytes(seed: 31, length: 2048)
            try replacement.write(to: source)

            let injected = binaryBytes(seed: 37, length: 512)
            let recorder = GateRecorder()
            let service = WorkspaceFileService(
                guard: WorkspacePathGuard(rootURL: root),
                mutationGuard: { url in
                    recorder.record(url)
                    // Simulate a change that slips in after the pre-copy
                    // digest verification: the second gate run happens inside
                    // the pre-commit hook, so mutate right there.
                    if recorder.count == 2 { try? injected.write(to: url) }
                }
            )
            do {
                _ = try service.replaceBinaryFile(
                    "deck.pptx", from: source,
                    expectedOriginalSHA256: FloeDigest.sha256Hex(original),
                    expectedSourceSHA256: FloeDigest.sha256Hex(replacement),
                    expectedSourceBytes: replacement.count
                )
                Issue.record("late-change replacement must not commit")
            } catch let error as WorkspaceToolError {
                guard case .conflict = error else {
                    Issue.record("expected a typed conflict, got \(error)")
                    return
                }
            } catch {
                Issue.record("expected WorkspaceToolError.conflict, got \(error)")
            }
            // The service refused: the late bytes survive untouched instead of
            // being blindly overwritten, the snapshot is kept and no owned
            // staging is left behind.
            #expect(try Data(contentsOf: destinationURL) == injected)
            #expect(try Data(contentsOf: source) == replacement)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["deck.pptx"])
        }
    }

    // MARK: - Required original digest / missing original

    @Test func staleOriginalDigestAndMissingOriginalAndDirectoryTargetAllRefuse() throws {
        try fixture { root, source, service in
            let original = binaryBytes(seed: 41, length: 1024)
            try service.createBinaryFile("deck.pptx", data: original, overwrite: false)
            let replacement = binaryBytes(seed: 43, length: 2048)
            try replacement.write(to: source)
            let sourceSHA = FloeDigest.sha256Hex(replacement)

            // Stale original digest is a typed conflict; nothing is copied
            // and the original stays byte-identical.
            #expect(throws: WorkspaceToolError.self) {
                try service.replaceBinaryFile(
                    "deck.pptx", from: source,
                    expectedOriginalSHA256: String(repeating: "0", count: 64),
                    expectedSourceSHA256: sourceSHA, expectedSourceBytes: replacement.count
                )
            }
            #expect(try Data(contentsOf: root.appendingPathComponent("deck.pptx")) == original)

            // A missing original is a conflict, never a silent create.
            #expect(throws: WorkspaceToolError.self) {
                try service.replaceBinaryFile(
                    "ghost.pptx", from: source,
                    expectedOriginalSHA256: sourceSHA,
                    expectedSourceSHA256: sourceSHA, expectedSourceBytes: replacement.count
                )
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ghost.pptx").path))

            // A directory target is refused as a directory, not replaced.
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
            #expect(throws: WorkspaceToolError.isDirectory("folder")) {
                try service.replaceBinaryFile(
                    "folder", from: source,
                    expectedOriginalSHA256: sourceSHA,
                    expectedSourceSHA256: sourceSHA, expectedSourceBytes: replacement.count
                )
            }
            #expect(try Data(contentsOf: source) == replacement)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["deck.pptx", "folder"])
        }
    }

    // MARK: - Input proof: hash, size, EOF budget, source identity

    @Test func wrongSourceDigestAndDeclaredSizeAndBudgetAndBadDigestsAreRefused() throws {
        try fixture { root, source, service in
            let original = binaryBytes(seed: 53, length: 1024)
            try service.createBinaryFile("deck.pptx", data: original, overwrite: false)
            let replacement = binaryBytes(seed: 59, length: 6000)
            try replacement.write(to: source)
            let originalSHA = FloeDigest.sha256Hex(original)

            // Wrong expected source digest: staged/source proof fails and the
            // original is untouched.
            #expect(throws: WorkspaceToolError.conflict(
                expected: "sha256 \(String(repeating: "a", count: 64))", actual: "source or staged copy changed"
            )) {
                try service.replaceBinaryFile(
                    "deck.pptx", from: source,
                    expectedOriginalSHA256: originalSHA,
                    expectedSourceSHA256: String(repeating: "a", count: 64),
                    expectedSourceBytes: replacement.count
                )
            }
            // Declared size above the actual source size fails the source size
            // proof before the copy starts.
            #expect(throws: WorkspaceToolError.self) {
                try service.replaceBinaryFile(
                    "deck.pptx", from: source,
                    expectedOriginalSHA256: originalSHA,
                    expectedSourceSHA256: FloeDigest.sha256Hex(replacement),
                    expectedSourceBytes: replacement.count + 7
                )
            }
            // Empty and over-budget declared inputs are refused up front.
            #expect(throws: WorkspaceToolError.invalidArguments("expectedSourceBytes must be at least 1")) {
                try service.replaceBinaryFile(
                    "deck.pptx", from: source,
                    expectedOriginalSHA256: originalSHA,
                    expectedSourceSHA256: FloeDigest.sha256Hex(replacement),
                    expectedSourceBytes: 0
                )
            }
            #expect(throws: WorkspaceToolError.tooLarge(limit: WorkspaceFileService.officeBinaryReplacementBudget)) {
                try service.replaceBinaryFile(
                    "deck.pptx", from: source,
                    expectedOriginalSHA256: originalSHA,
                    expectedSourceSHA256: FloeDigest.sha256Hex(replacement),
                    expectedSourceBytes: WorkspaceFileService.officeBinaryReplacementBudget + 1
                )
            }
            // Malformed digests never reach the filesystem comparison.
            for bad in ["", "abc", String(repeating: "0", count: 63), String(repeating: "z", count: 64)] {
                #expect(throws: WorkspaceToolError.self) {
                    try service.replaceBinaryFile(
                        "deck.pptx", from: source,
                        expectedOriginalSHA256: bad,
                        expectedSourceSHA256: FloeDigest.sha256Hex(replacement),
                        expectedSourceBytes: replacement.count
                    )
                }
                #expect(throws: WorkspaceToolError.self) {
                    try service.replaceBinaryFile(
                        "deck.pptx", from: source,
                        expectedOriginalSHA256: originalSHA,
                        expectedSourceSHA256: bad,
                        expectedSourceBytes: replacement.count
                    )
                }
            }
            // The snapshot must not be the original itself (it would consume
            // the recoverable input).
            #expect(throws: WorkspaceToolError.self) {
                try service.replaceBinaryFile(
                    "deck.pptx",
                    from: root.appendingPathComponent("deck.pptx"),
                    expectedOriginalSHA256: originalSHA,
                    expectedSourceSHA256: originalSHA, expectedSourceBytes: original.count
                )
            }
            // A missing source is notFound.
            #expect(throws: WorkspaceToolError.self) {
                try service.replaceBinaryFile(
                    "deck.pptx", from: baseChild(source, "missing-snapshot.bin"),
                    expectedOriginalSHA256: originalSHA,
                    expectedSourceSHA256: FloeDigest.sha256Hex(replacement),
                    expectedSourceBytes: replacement.count
                )
            }
            #expect(try Data(contentsOf: root.appendingPathComponent("deck.pptx")) == original)
            #expect(try Data(contentsOf: source) == replacement)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["deck.pptx"])
        }
    }

    @Test func emptyAndSymlinkedSourceSnapshotsAreRefused() throws {
        try fixture { root, source, service in
            let original = binaryBytes(seed: 61, length: 512)
            try service.createBinaryFile("deck.pptx", data: original, overwrite: false)

            // Empty snapshot: declared bytes can never match an empty file
            // under the >=1 input budget; both paths are refusals, not copies.
            let empty = baseChild(source, "empty.bin")
            try Data().write(to: empty)
            #expect(throws: WorkspaceToolError.self) {
                try service.replaceBinaryFile(
                    "deck.pptx", from: empty,
                    expectedOriginalSHA256: FloeDigest.sha256Hex(original),
                    expectedSourceSHA256: FloeDigest.sha256Hex(Data()),
                    expectedSourceBytes: 0
                )
            }

            // A symlinked snapshot is refused: the replacement must follow
            // exactly the declared regular file, no link targets.
            let link = baseChild(source, "link-snapshot")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            try binaryBytes(seed: 67, length: 256).write(to: source)
            #expect(throws: WorkspaceToolError.self) {
                try service.replaceBinaryFile(
                    "deck.pptx", from: link,
                    expectedOriginalSHA256: FloeDigest.sha256Hex(original),
                    expectedSourceSHA256: try FloeDigest.sha256Hex(ofFileAt: source),
                    expectedSourceBytes: 256
                )
            }
            #expect(try Data(contentsOf: root.appendingPathComponent("deck.pptx")) == original)
        }
    }

    // MARK: - Cancellation and path safety

    @Test func cancellationPreservesOriginalAndSourceAndLeavesNoStage() throws {
        try fixture { root, source, service in
            let original = binaryBytes(seed: 71, length: 1024)
            try service.createBinaryFile("deck.pptx", data: original, overwrite: false)
            let replacement = binaryBytes(seed: 73, length: 4096)
            try replacement.write(to: source)
            let token = CancellationToken()
            token.cancel()
            #expect(throws: FloeError.self) {
                try service.replaceBinaryFile(
                    "deck.pptx", from: source,
                    expectedOriginalSHA256: FloeDigest.sha256Hex(original),
                    expectedSourceSHA256: FloeDigest.sha256Hex(replacement),
                    expectedSourceBytes: replacement.count,
                    cancellation: token
                )
            }
            #expect(try Data(contentsOf: root.appendingPathComponent("deck.pptx")) == original)
            #expect(try Data(contentsOf: source) == replacement)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["deck.pptx"])
        }
    }

    @Test func symlinkedAndEscapingAndSecretDestinationsAreRefusedWithoutTouchingTargets() throws {
        try fixture { root, source, service in
            let replacement = binaryBytes(seed: 79, length: 1024)
            try replacement.write(to: source)
            let sourceSHA = FloeDigest.sha256Hex(replacement)

            // Real target reached through a symlinked final component.
            let realBytes = binaryBytes(seed: 83, length: 512)
            let realURL = root.appendingPathComponent("real.bin")
            try realBytes.write(to: realURL)
            let linkURL = root.appendingPathComponent("link.bin")
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realURL)
            #expect(throws: WorkspaceToolError.self) {
                try service.replaceBinaryFile(
                    "link.bin", from: source,
                    expectedOriginalSHA256: FloeDigest.sha256Hex(realBytes),
                    expectedSourceSHA256: sourceSHA, expectedSourceBytes: replacement.count
                )
            }

            // Existing file under a symlinked ancestor directory.
            let dir = root.appendingPathComponent("realdir")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let inside = dir.appendingPathComponent("inner.bin")
            try realBytes.write(to: inside)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: dir)
            #expect(throws: WorkspaceToolError.escapesRoot("alias/inner.bin")) {
                try service.replaceBinaryFile(
                    "alias/inner.bin", from: source,
                    expectedOriginalSHA256: FloeDigest.sha256Hex(realBytes),
                    expectedSourceSHA256: sourceSHA, expectedSourceBytes: replacement.count
                )
            }

            // Path traversal and secret files fail at the guard itself.
            #expect(throws: WorkspaceToolError.self) {
                try service.replaceBinaryFile(
                    "../outside.bin", from: source,
                    expectedOriginalSHA256: sourceSHA,
                    expectedSourceSHA256: sourceSHA, expectedSourceBytes: replacement.count
                )
            }
            let secret = root.appendingPathComponent("server.pem")
            try realBytes.write(to: secret)
            #expect(throws: WorkspaceToolError.self) {
                try service.replaceBinaryFile(
                    "server.pem", from: source,
                    expectedOriginalSHA256: FloeDigest.sha256Hex(realBytes),
                    expectedSourceSHA256: sourceSHA, expectedSourceBytes: replacement.count
                )
            }

            // None of the escape attempts wrote anything: every bystander
            // file is byte-identical and no staging leaked.
            #expect(try Data(contentsOf: realURL) == realBytes)
            #expect(try Data(contentsOf: inside) == realBytes)
            #expect(try Data(contentsOf: secret) == realBytes)
            #expect(try Data(contentsOf: source) == replacement)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
                    == ["real.bin", "link.bin", "realdir", "alias", "server.pem"])
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent("../outside.bin").standardizedFileURL.path))
        }
    }

    // MARK: - Helpers

    /// Deterministic pseudo-random-looking non-text bytes (always contains
    /// zero bytes, so text policies and `looksLikeText` treat it as binary).
    private func binaryBytes(seed: UInt64, length: Int) -> Data {
        var state = seed &* 0x9E3779B97F4A7C15
        var bytes = [UInt8](repeating: 0, count: length)
        for index in bytes.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
        // Guarantee NUL presence for the non-text assertion.
        if !bytes.isEmpty { bytes[bytes.count / 2] = 0 }
        return Data(bytes)
    }

    /// Mirrors the guard's own resolution transform so gate-URL assertions
    /// compare like-for-like with what `resolve` handed to the service.
    private func resolved(_ root: URL, _ name: String) -> URL {
        root.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(name)
    }

    private func baseChild(_ url: URL, _ name: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(name)
    }

    private func fixture(_ body: (URL, URL, WorkspaceFileService) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("binary-replace-" + UUID().uuidString)
        let root = base.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(root, base.appendingPathComponent("snapshot.bin"),
                 WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
    }
}

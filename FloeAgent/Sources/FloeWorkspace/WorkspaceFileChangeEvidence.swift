// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloeTools


enum WorkspaceFileChangeEvidence {
    enum Change: String { case created, modified, unchanged, saved }

    enum Baseline {
        case missing, existing(String), verifiedSHA256(String), unavailable

        var previewText: String? {
            switch self {
            case .missing: ""
            case .existing(let text): text
            case .verifiedSHA256, .unavailable: nil
            }
        }

        func change(saving text: String) -> Change {
            switch self {
            case .missing: .created
            case .existing(let original): original.utf8.elementsEqual(text.utf8) ? .unchanged : .modified
            case .verifiedSHA256(let digest): WorkspaceFileService.sha256Hex(of: Data(text.utf8)) == digest.lowercased() ? .unchanged : .modified
            case .unavailable: .saved
            }
        }

        func afterSuccessfulCAS(expectedSHA256: String?) -> Self {
            if case .unavailable = self, let expectedSHA256 { return .verifiedSHA256(expectedSHA256) }
            return self
        }
    }

    struct WrittenFile {
        let outcome: WriteOutcome
        let baseline: Baseline
        let content: String
        let path: String?
    }

    /// Keep paths readable by the existing redactor. JSON also preserves names
    /// containing spaces, newlines or strings that look like summary fields.
    static func paths(_ path: String?, from: String? = nil, kind: String? = nil, change: Change? = nil) -> String {
        guard let path else { return " paths={}" }
        var fields = ["path": path]
        fields["from"] = from
        fields["kind"] = kind
        fields["change"] = change?.rawValue
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return " paths={}"
        }
        return " paths=" + String(decoding: data, as: UTF8.self)
    }

    static func networkPath(_ route: NetworkWorkspaceMountRegistry.Route) -> String? {
        var components = [Substring]()
        for component in route.relativePath.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                guard components.popLast() != nil else { return nil }
            default: components.append(component)
            }
        }
        return ([route.mount.virtualRoot] + components.map(String.init)).joined(separator: "/")
    }

    /// Use the same byte-based line boundaries for generated diffs and
    /// applied patches, including CRLF and a missing newline at EOF.
    static func diff(original: String, modified: String, label: String) -> String? {
        guard !original.utf8.elementsEqual(modified.utf8) else { return "" }
        func units(_ text: String) -> [String] {
            WorkspaceFileService.patchLines(text).map { $0.text + $0.ending }
        }
        let old = units(original), new = units(modified)
        // The incumbent LCS is quadratic. An optional comparison must not
        // allocate an unbounded table after a successful file commit.
        guard old.count <= 20_000, new.count <= 20_000,
              old.count * new.count <= 2_000_000 else { return nil }
        let hunks = WorkspaceFileService.diffHunks(old: old, new: new, context: 3)
        let name = label.replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        var out = "--- a/\(name)\n+++ b/\(name)\n"
        for hunk in hunks {
            out += "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\n"
            for body in hunk.body {
                if body.utf8.last == 10 { out += body }
                else { out += body + "\n\\ No newline at end of file\n" }
            }
        }
        return out
    }

    static func artifacts(original: String?, modified: String, path: String, runID: UUID) throws -> [ToolArtifactReference] {
        let reason: WorkspaceFileChangePreview.Comparison
        if let original {
            if let diff = diff(original: original, modified: modified, label: path) {
                if let artifact = try WorkspaceToolSupport.changeArtifact(diff: diff, runID: runID) { return [artifact] }
                reason = diff.isEmpty ? .unchanged : .comparisonTooLarge
            } else { reason = .comparisonTooLarge }
        } else { reason = .baselineUnavailable }
        let bytes = Data(modified.utf8), text = String(modified.prefix(24_000))
        let document = WorkspaceFileChangePreview(version: 1, path: path, byteCount: bytes.count,
            sha256: WorkspaceFileService.sha256Hex(of: bytes), text: text, truncated: text != modified, comparison: reason)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(document)
        guard data.count <= 512 * 1024 else { throw WorkspaceToolError.tooLarge(limit: 512 * 1024) }
        let digest = WorkspaceFileService.sha256Hex(of: data)
        let root = try FloeArtifactStore.root()
        let relative = "ChangeArtifacts/\(runID.uuidString)/\(digest).preview.json"
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            guard try Data(contentsOf: file) == data else {
                throw WorkspaceToolError.invalidArguments("Saved file preview no longer matches its receipt")
            }
        } else { try data.write(to: file, options: [.atomic]) }
        return [.init(id: UUID(), relativePath: relative, mimeType: "application/vnd.floe.file-preview+json", byteCount: data.count, sha256: digest)]
    }

    /// Run only AFTER an acknowledged commit. Optional presentation failures
    /// must not turn a saved mutation into a retryable write failure.
    static func savedOutput(_ summary: String, path: String?, change: Change,
                            artifactBuilder: () throws -> [ToolArtifactReference]) -> ToolExecutionOutput {
        let receipt = summary + paths(path) + " change=\(change.rawValue) saved=true"
        do {
            let artifacts = try artifactBuilder()
            return WorkspaceToolSupport.output(receipt + " preview=\(artifacts.isEmpty ? "unavailable" : "available")", artifacts: artifacts)
        } catch {
            return WorkspaceToolSupport.output(receipt + " preview=unavailable\nThe file is saved. Its optional preview is unavailable; do not repeat the write.")
        }
    }

    static func savedOutput(_ summary: String, baseline: Baseline, modified: String, path: String?,
                            requestedPath: String, runID: UUID) -> ToolExecutionOutput {
        savedOutput(summary, path: path, change: baseline.change(saving: modified)) {
            let original: String?
            if case .missing = baseline, modified.isEmpty {
                // No earlier file existed. Its preview must not say that
                // the saved empty file is identical to a previous version.
                original = nil
            } else { original = baseline.previewText }
            return try artifacts(original: original, modified: modified, path: path ?? requestedPath, runID: runID)
        }
    }

    /// Called inside the existing recursive mutation lock. A failed optional
    /// baseline is explicit comparison-unavailable; cancellation still wins.
    static func localBaseline(service: WorkspaceFileService, path: String, cancellation: CancellationToken) throws -> Baseline {
        do { return .existing(try service.readFileForEditing(path, cancellation: cancellation).text) }
        catch let error as WorkspaceToolError {
            try cancellation.throwIfCancelled()
            if case .notFound = error { return .missing }
            return .unavailable
        } catch {
            try cancellation.throwIfCancelled()
            return .unavailable
        }
    }

    static func remoteBaseline(bytes: Data, before: NetworkWorkspaceFileMetadata,
                               after: NetworkWorkspaceFileMetadata) -> String? {
        remoteChangeBaseline(bytes: bytes, before: before, after: after).previewText
    }

    static func remoteChangeBaseline(bytes: Data, before: NetworkWorkspaceFileMetadata,
                                     after: NetworkWorkspaceFileMetadata) -> Baseline {
        guard let tag = before.entityTag, !tag.isEmpty, tag == after.entityTag,
              before.byteCount == after.byteCount, before.byteCount == bytes.count,
              !before.isDirectory, !after.isDirectory else { return .unavailable }
        if let text = WorkspaceTextPolicy.decodeUTF8(bytes) { return .existing(text) }
        return .verifiedSHA256(WorkspaceFileService.sha256Hex(of: bytes))
    }
}

extension WorkspaceFileService {
    /// Convert the guard's resolved local URL back to its workspace or virtual
    /// mount namespace. Never include a host filesystem path in a receipt.
    func receiptPath(_ path: String, resolved: URL? = nil) -> String? {
        guard let url = resolved ?? (try? guardResolver.resolve(path)) else { return nil }
        let components = Self.normalizedRelativePath(path).split(separator: "/")
        if components.count >= 2, components[0] == "Mounts" {
            let prefix = components.prefix(2).joined(separator: "/")
            if let mount = try? guardResolver.resolve(prefix) {
                if url.path == mount.path { return prefix }
                if url.path.hasPrefix(mount.path + "/") {
                    return prefix + "/" + Self.relativePath(of: url.path, under: mount.path)
                }
            }
        }
        let root = guardResolver.rootURL.path
        guard url.path.hasPrefix(root + "/") else { return nil }
        return Self.relativePath(of: url.path, under: root)
    }

    /// Capture identity while the ordinary move/copy/delete owns the same
    /// recursive lock. Optional stat information never makes a mutation fail.
    func managedFileOutput(_ summary: String, from: String? = nil, path: String,
                           mutation: () throws -> Void) throws -> ToolExecutionOutput {
        let lock = WorkspaceMutationLocks.lock(for: guardResolver.rootURL)
        lock.lock(); defer { lock.unlock() }
        let target = try? guardResolver.resolve(path)
        let relativePath = target.flatMap { receiptPath(path, resolved: $0) }
        let sourcePath = from.flatMap { receiptPath($0) }
        func kind() -> String? {
            guard let target, let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
                  let type = attributes[.type] as? FileAttributeType else { return nil }
            switch type {
            case .typeRegular: return "file"
            case .typeDirectory: return "directory"
            default: return nil
            }
        }
        // The deletion target disappears at commit. For transfers inspect
        // the destination once the transaction (including companions) succeeded.
        let deletedKind = from == nil ? kind() : nil
        try mutation()
        let itemKind = from == nil ? deletedKind : kind()
        return WorkspaceToolSupport.output(summary + WorkspaceFileChangeEvidence.paths(relativePath, from: sourcePath, kind: itemKind))
    }

    /// Hold the shared mutation lock across the full baseline and original
    /// guarded writer. Existing conflict, freeze, size and cancellation
    /// checks remain in the original create/write implementations.
    func createFileWithChangeBaseline(_ path: String, content: String, overwrite: Bool,
                                     cancellation: CancellationToken) throws -> WorkspaceFileChangeEvidence.WrittenFile {
        let lock = WorkspaceMutationLocks.lock(for: guardResolver.rootURL)
        lock.lock(); defer { lock.unlock() }
        let baseline = overwrite ? try WorkspaceFileChangeEvidence.localBaseline(service: self, path: path, cancellation: cancellation) : .missing
        let canonical = receiptPath(path)
        let outcome = try createFile(path, content: content, overwrite: overwrite, cancellation: cancellation)
        return .init(outcome: outcome, baseline: baseline, content: content, path: canonical)
    }
    func writeFileWithChangeBaseline(_ path: String, content: String, expectedMtime: Double?, expectedSHA256: String?,
                                    cancellation: CancellationToken, knownBaseline: WorkspaceFileChangeEvidence.Baseline? = nil) throws -> WorkspaceFileChangeEvidence.WrittenFile {
        let lock = WorkspaceMutationLocks.lock(for: guardResolver.rootURL)
        lock.lock(); defer { lock.unlock() }
        let baseline = try knownBaseline ?? WorkspaceFileChangeEvidence.localBaseline(service: self, path: path, cancellation: cancellation)
        let canonical = receiptPath(path)
        let outcome = try writeFile(path, content: content, expectedMtime: expectedMtime, expectedSHA256: expectedSHA256, cancellation: cancellation)
        return .init(outcome: outcome, baseline: baseline.afterSuccessfulCAS(expectedSHA256: expectedSHA256), content: content, path: canonical)
    }

    /// Verify the real on-disk digest as well as the decoded text. An encoding
    /// that does not round-trip byte-exactly is rejected, never normalized.
    func verifiedSourceText(_ path: String, expectedSHA256: String, cancellation: CancellationToken) throws -> String {
        try cancellation.throwIfCancelled()
        try Task.checkCancellation()
        let text = try readFileForEditing(path, cancellation: cancellation).text
        let current = try metadata(path)
        let digest = Self.sha256Hex(of: Data(text.utf8))
        guard current.size == text.utf8.count, current.sha256 == digest else {
            throw WorkspaceToolError.conflict(expected: "stable byte-exact UTF-8 source", actual: "source changed or encoding does not round-trip")
        }
        try WorkspaceTextEdit.check(expectedSHA256, actual: current.sha256)
        try cancellation.throwIfCancelled()
        return text
    }

    /// Finalize a verified local/mounted draft without a second model-sized
    /// JSON body. The source remains intact. The existing shared recursive
    /// mutation lock and target writer retain CAS, freeze, path and size checks.
    func writeFileFromSourceWithChangeBaseline(
        _ path: String, sourcePath: String, expectedSourceSHA256: String,
        expectedMtime: Double?, expectedSHA256: String?, cancellation: CancellationToken
    ) throws -> WorkspaceFileChangeEvidence.WrittenFile {
        let lock = WorkspaceMutationLocks.lock(for: guardResolver.rootURL)
        lock.lock(); defer { lock.unlock() }
        try cancellation.throwIfCancelled()
        guard try guardResolver.resolve(path) != guardResolver.resolve(sourcePath) else {
            throw WorkspaceToolError.invalidArguments("sourcePath and path must identify different files")
        }
        let content = try verifiedSourceText(sourcePath, expectedSHA256: expectedSourceSHA256, cancellation: cancellation)
        let canonical = receiptPath(path)
        let compareExisting = expectedMtime != nil || expectedSHA256 != nil
        let prior = compareExisting ? try WorkspaceFileChangeEvidence.localBaseline(service: self, path: path, cancellation: cancellation) : .missing
        // Revalidate after optional baseline I/O and before the target writer.
        _ = try verifiedSourceText(sourcePath, expectedSHA256: expectedSourceSHA256, cancellation: cancellation)
        try cancellation.throwIfCancelled()
        try Task.checkCancellation()
        let outcome: WriteOutcome
        if compareExisting {
            outcome = try writeFile(path, content: content, expectedMtime: expectedMtime,
                expectedSHA256: expectedSHA256, cancellation: cancellation)
        } else {
            // No target precondition means create-only for source finalization.
            // A retry cannot replace a target whose version was never observed.
            outcome = try createFile(path, content: content, overwrite: false, cancellation: cancellation)
        }
        return .init(outcome: outcome, baseline: prior.afterSuccessfulCAS(expectedSHA256: expectedSHA256), content: content, path: canonical)
    }

}

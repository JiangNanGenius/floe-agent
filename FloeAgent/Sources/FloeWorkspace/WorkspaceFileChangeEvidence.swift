// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloeTools


enum WorkspaceFileChangeEvidence {
    /// Preserve the legacy patch engine. Presentation uses its same real
    /// hunk grouping, with actual line units (empty files have zero lines,
    /// and newline-at-EOF changes do not become phantom blank lines).
    static func diff(original: String, modified: String, label: String) -> String? {
        guard original != modified else { return "" }
        func units(_ text: String) -> [String] {
            guard !text.isEmpty else { return [] }
            var parts = text.components(separatedBy: "\n")
            let terminated = text.hasSuffix("\n")
            if terminated { parts.removeLast() }
            return parts.enumerated().map { index, content in
                content + (index < parts.count - 1 || terminated ? "\n" : "")
            }
        }
        let old = units(original), new = units(modified)
        // The incumbent LCS is quadratic. An optional comparison must not
        // allocate an unbounded table after a successful file commit.
        guard old.count <= 20_000, new.count <= 20_000,
              old.count * new.count <= 2_000_000 else { return nil }
        let hunks = WorkspaceFileService.diffHunks(old: old, new: new, context: 3)
        guard !hunks.isEmpty else { return "" }
        let name = label.replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        var out = "--- a/\(name)\n+++ b/\(name)\n"
        for hunk in hunks {
            out += "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\n"
            for body in hunk.body {
                if body.hasSuffix("\n") { out += body }
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

    /// Called inside the existing recursive mutation lock. A failed optional
    /// baseline is explicit comparison-unavailable; cancellation still wins.
    static func localBaseline(service: WorkspaceFileService, path: String, cancellation: CancellationToken) throws -> String? {
        do { return try service.readFileForEditing(path, cancellation: cancellation).text }
        catch let error as WorkspaceToolError {
            try cancellation.throwIfCancelled()
            if case .notFound = error { return "" }
            return nil
        } catch {
            try cancellation.throwIfCancelled()
            return nil
        }
    }

    static func remoteBaseline(bytes: Data, before: NetworkWorkspaceFileMetadata,
                               after: NetworkWorkspaceFileMetadata) -> String? {
        guard let tag = before.entityTag, !tag.isEmpty, tag == after.entityTag,
              before.byteCount == after.byteCount, before.byteCount == bytes.count,
              !bytes.contains(0) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}

extension WorkspaceFileService {
    /// Hold the shared mutation lock across the full baseline and original
    /// guarded writer. Existing conflict, freeze, size and cancellation
    /// checks remain in the original create/write implementations.
    func createFileWithChangeBaseline(_ path: String, content: String, overwrite: Bool,
                                     cancellation: CancellationToken) throws -> (WriteOutcome, String?) {
        let lock = WorkspaceMutationLocks.lock(for: guardResolver.rootURL)
        lock.lock(); defer { lock.unlock() }
        let baseline = overwrite ? try WorkspaceFileChangeEvidence.localBaseline(service: self, path: path, cancellation: cancellation) : ""
        return (try createFile(path, content: content, overwrite: overwrite, cancellation: cancellation), baseline)
    }
    func writeFileWithChangeBaseline(_ path: String, content: String, expectedMtime: Double?, expectedSHA256: String?,
                                    cancellation: CancellationToken) throws -> (WriteOutcome, String?) {
        let lock = WorkspaceMutationLocks.lock(for: guardResolver.rootURL)
        lock.lock(); defer { lock.unlock() }
        let baseline = try WorkspaceFileChangeEvidence.localBaseline(service: self, path: path, cancellation: cancellation)
        return (try writeFile(path, content: content, expectedMtime: expectedMtime, expectedSHA256: expectedSHA256, cancellation: cancellation), baseline)
    }
}

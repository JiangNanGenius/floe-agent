import Foundation
import FloeCore
import FloeTools

/// Shared read/modify/write path: never applies a transformation to a partial
/// read, and binds the write to the exact bytes used by the transformation.
enum WorkspaceTextEdit {
    static func apply(
        path: String, expectedSHA256: String?, environment: WorkspaceToolEnvironment,
        context: ToolContext, transform: (String) throws -> String
    ) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try WorkspaceToolSupport.rejectHostScope(context.scope)
        try context.authorizeWorkspacePath(path)
        let service = try environment.makeService(context: context)
        if let route = try await environment.networkRoute(path: path, context: context) {
            let metadata = try await route.adapter.metadata(path: route.relativePath)
            guard !metadata.isDirectory else { throw WorkspaceToolError.isDirectory(path) }
            guard metadata.byteCount <= environment.maxWriteBytes else {
                throw WorkspaceToolError.tooLarge(limit: environment.maxWriteBytes)
            }
            let bytes = try await route.adapter.read(path: route.relativePath, offset: 0, limit: environment.maxWriteBytes + 1)
            guard bytes.count == metadata.byteCount else {
                throw WorkspaceToolError.invalidArguments("Incomplete read; refresh the file before editing")
            }
            let original = try decode(bytes)
            let digest = WorkspaceFileService.sha256Hex(of: bytes)
            try check(expectedSHA256, actual: digest)
            let updated = try transform(original)
            let data = Data(updated.utf8)
            guard data.count <= environment.maxWriteBytes else {
                throw WorkspaceToolError.tooLarge(limit: environment.maxWriteBytes)
            }
            guard let entityTag = metadata.entityTag else {
                throw WorkspaceToolError.invalidArguments("Remote server has no revision token; exact edits require conditional writes")
            }
            _ = try await route.adapter.write(path: route.relativePath, data: data, expectedEntityTag: entityTag)
            return WorkspaceToolSupport.output("edited=\(path) bytes=\(data.count) sha256=\(WorkspaceFileService.sha256Hex(of: data)) network=true")
        }
        let original = try service.readFileForEditing(path, cancellation: context.cancellation).text
        let digest = WorkspaceFileService.sha256Hex(of: Data(original.utf8))
        try check(expectedSHA256, actual: digest)
        let updated = try transform(original)
        let outcome = try service.writeFile(path, content: updated, expectedSHA256: digest, cancellation: context.cancellation)
        let artifact = try WorkspaceToolSupport.changeArtifact(
            diff: service.diff(original: original, modified: updated, label: path), runID: context.runID
        )
        return WorkspaceToolSupport.output(
            "edited=\(path) bytes=\(outcome.bytesWritten) sha256=\(outcome.sha256) mtime=\(outcome.mtime)",
            artifacts: artifact.map { [$0] } ?? []
        )
    }

    static func decode(_ data: Data) throws -> String {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceToolError.invalidArguments("Expected a UTF-8 text file; use a dedicated document or media tool for binary files")
        }
        return text
    }

    static func check(_ expected: String?, actual: String) throws {
        if let expected, expected.lowercased() != actual {
            throw WorkspaceToolError.conflict(expected: expected, actual: actual)
        }
    }
}

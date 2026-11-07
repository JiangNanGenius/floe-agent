// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A real host supplies a context-bound editor instance and owns its lease.
/// A model can name an indexed project, never its directory, owner or hooks.
public struct HeavyEditorModelLease: Sendable {
    public let controller: HeavyEditorController
    public let release: @Sendable () async -> Void
    public init(controller: HeavyEditorController, release: @escaping @Sendable () async -> Void) {
        self.controller = controller; self.release = release
    }
}

public enum HeavyEditorToolOperation: String, Codable, Sendable { case describe, query, invoke, export }
public struct HeavyEditorModelRequest: Codable, Sendable {
    public let projectID: UUID
    public let baseRevision: UInt64?
    public let command: String?
    public let arguments: EditorJSON?
    public init(projectID: UUID, baseRevision: UInt64? = nil, command: String? = nil, arguments: EditorJSON? = nil) {
        self.projectID = projectID; self.baseRevision = baseRevision; self.command = command; self.arguments = arguments
    }
}

public enum HeavyEditorModelCalls {
    public static func execute(_ operation: HeavyEditorToolOperation, kind: HeavyEditorKind,
                               request: HeavyEditorModelRequest, lease: HeavyEditorModelLease) async throws -> EditorJSON {
        do {
            let result = try await run(operation, kind: kind, request: request, lease: lease)
            await lease.release(); return result
        } catch {
            await lease.release(); throw error
        }
    }
    @MainActor private static func run(_ operation: HeavyEditorToolOperation, kind: HeavyEditorKind,
                                      request: HeavyEditorModelRequest, lease: HeavyEditorModelLease) async throws -> EditorJSON {
        let controller = lease.controller
        guard controller.document.id == request.projectID, controller.descriptor.kind == kind else { throw HeavyEditorError.wrongDocument }
        try await controller.waitUntilReady()
        if operation == .describe { return try await controller.describe() }
        guard let revision = request.baseRevision, let command = request.command else { throw HeavyEditorError.invalidCommand }
        let metadata = try await controller.commandMetadata(command)
        let access = metadata["access"].string
        if operation == .export {
            guard access == HeavyEditorAccess.exportFile.rawValue else { throw HeavyEditorError.invalidCommand }
        } else if operation == .query {
            guard access == HeavyEditorAccess.read.rawValue, metadata["sideEffecting"] != .bool(true) else { throw HeavyEditorError.invalidCommand }
        } else {
            // File imports require the host's file/attachment resolver; models
            // cannot smuggle arbitrary base64 files through an editing command.
            guard access == HeavyEditorAccess.read.rawValue || access == HeavyEditorAccess.edit.rawValue else { throw HeavyEditorError.invalidCommand }
        }
        let response = try await controller.execute(command, arguments: request.arguments ?? .object([:]), expectedRevision: revision)
        let result = response["result"]
        let bounded: EditorJSON
        if try result.data().count <= 512 * 1024 { bounded = result }
        else { bounded = .object(["truncated": .bool(true), "message": .string("Use a narrower query or export the result through the authorized file service.")]) }
        return .object(["projectID": .string(request.projectID.uuidString), "baseRevision": .number(Double(controller.document.revision)),
                        "result": bounded, "exports": response["exports"]])
    }
}

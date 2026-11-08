// SPDX-License-Identifier: MPL-2.0
import Foundation

/// This closure belongs to one queued operation, never the visible controller.
public typealias HeavyEditorOperationAuthorizer = @Sendable (HeavyEditorAccessRequest) async throws -> Void
public struct HeavyEditorDiscoveryPage: Codable, Sendable {
    public var query: String
    public var offset: Int
    public var limit: Int
    public init(query: String = "", offset: Int = 0, limit: Int = 40) {
        self.query = query; self.offset = offset; self.limit = limit
    }
    private enum CodingKeys: String, CodingKey { case query, offset, limit }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        query = try values.decodeIfPresent(String.self, forKey: .query) ?? ""
        offset = try values.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        limit = try values.decodeIfPresent(Int.self, forKey: .limit) ?? 40
    }
}

/// A real host supplies a context-bound editor instance and owns its lease.
/// A model can name an indexed project, never its directory, owner or hooks.
public struct HeavyEditorModelLease: Sendable {
    public let controller: HeavyEditorController
    public let authorize: HeavyEditorOperationAuthorizer?
    public let release: @Sendable () async -> Void
    public init(controller: HeavyEditorController, authorize: HeavyEditorOperationAuthorizer? = nil, release: @escaping @Sendable () async -> Void) {
        self.controller = controller; self.authorize = authorize; self.release = release
    }
}

public enum HeavyEditorToolOperation: String, Codable, Sendable { case describe, query, invoke, export }
public struct HeavyEditorModelRequest: Codable, Sendable {
    public let projectID: UUID
    public let baseRevision: UInt64?
    public let command: String?
    public let arguments: EditorJSON?
    public let discovery: HeavyEditorDiscoveryPage?
    public init(projectID: UUID, baseRevision: UInt64? = nil, command: String? = nil, arguments: EditorJSON? = nil, discovery: HeavyEditorDiscoveryPage? = nil) {
        self.projectID = projectID; self.baseRevision = baseRevision; self.command = command; self.arguments = arguments; self.discovery = discovery
    }
}

public enum HeavyEditorModelCalls {
    /// Publication finishes before exactly one host lease release, including
    /// failures. The host may still verify its original and output receipts.
    public static func withLease<Value: Sendable>(_ lease: HeavyEditorModelLease,
        operation: @Sendable (HeavyEditorModelLease) async throws -> Value) async throws -> Value {
        do { let result = try await operation(lease); await lease.release(); return result }
        catch { await lease.release(); throw error }
    }
    public static func execute(_ operation: HeavyEditorToolOperation, kind: HeavyEditorKind,
                               request: HeavyEditorModelRequest, lease: HeavyEditorModelLease) async throws -> EditorJSON {
        try await withLease(lease) { try await run(operation, kind: kind, request: request, lease: $0) }
    }
    @MainActor public static func run(_ operation: HeavyEditorToolOperation, kind: HeavyEditorKind,
                                      request: HeavyEditorModelRequest, lease: HeavyEditorModelLease) async throws -> EditorJSON {
        let controller = lease.controller
        guard controller.document.id == request.projectID, controller.descriptor.kind == kind else { throw HeavyEditorError.wrongDocument }
        try await controller.waitUntilReady()
        if operation == .describe {
            if let revision = request.baseRevision, revision != controller.document.revision { throw HeavyEditorError.revisionConflict }
            return try await controller.describe(command: request.command, arguments: request.arguments ?? .object([:]), discovery: request.discovery ?? .init(), authorization: lease.authorize)
        }
        guard let revision = request.baseRevision, let command = request.command else { throw HeavyEditorError.invalidCommand }
        let metadata = try await controller.commandMetadata(command)
        let access = metadata["access"].string
        guard metadata["hidden"] != .bool(true) else { throw HeavyEditorError.invalidCommand }
        if operation == .export {
            guard access == HeavyEditorAccess.exportFile.rawValue else { throw HeavyEditorError.invalidCommand }
        } else if operation == .query {
            guard access == HeavyEditorAccess.read.rawValue, metadata["sideEffecting"] != .bool(true) else { throw HeavyEditorError.invalidCommand }
        } else {
            // File imports require the host's file/attachment resolver; models
            // cannot smuggle arbitrary base64 files through an editing command.
            guard access == HeavyEditorAccess.read.rawValue || access == HeavyEditorAccess.edit.rawValue else { throw HeavyEditorError.invalidCommand }
        }
        let response = try await controller.execute(command, arguments: request.arguments ?? .object([:]), expectedRevision: revision, authorization: lease.authorize)
        let result = response["result"]
        let bounded: EditorJSON
        if try result.data().count <= 512 * 1024 { bounded = result }
        else { bounded = .object(["truncated": .bool(true), "message": .string("Use a narrower query or export the result through the authorized file service.")]) }
        return .object(["projectID": .string(request.projectID.uuidString), "baseRevision": .number(Double(controller.document.revision)),
                        "result": bounded, "exports": response["exports"]])
    }
}

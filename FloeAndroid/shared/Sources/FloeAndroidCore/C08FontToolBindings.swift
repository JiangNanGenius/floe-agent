// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
import FloeWorkspace
import FloeAndroidWebTools
import FloeAndroidDataExchange

private struct FontRequest: Encodable {
    let method: String
    let taskID: String
    let runID: String
    var id: String? = nil
    var inputID: String? = nil
    var sha256: String? = nil
    var byteCount: Int64? = nil
    var cursor: String? = nil
}
private func fontRequest(_ method: String, context: ToolContext) throws -> FontRequest {
    guard !context.temporaryReadOnly, let task = context.conversationID else {
        throw FloeError.validationFailed("A saved task is required for the font library")
    }
    return FontRequest(method: method, taskID: task.uuidString.lowercased(),
                       runID: context.runID.uuidString.lowercased())
}
private func fontOutput(epoch: UInt64, request: FontRequest,
                        context: ToolContext) async throws -> ToolExecutionOutput {
    guard AndroidRuntimeBootstrap.notesBinding(epoch: epoch, ownerToken: nil) != nil else {
        throw FloeError.invalidConfiguration("Font library runtime has retired")
    }
    let result = try await FontHostMailbox.shared.submit(epoch: epoch,
        request: JSONEncoder().encode(request), cancellation: context.cancellation)
    let object = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any]
    let passed = (object?["ok"] as? Bool) == true
    let summary = String(decoding: result, as: UTF8.self)
    return ToolExecutionOutput(digesting: summary, exitStatus: passed ? 0 : 1)
}
public struct FontListTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public var cursor: String? }
    public static let name = "font.list"
    public static let toolDescription = "List Floe-global imported fonts and stable per-face references usable in media projects. Pass nextCursor to read more. These are App fonts, not automatic Linux guest or system font installation."
    public static let parametersJSON = #"{"type":"object","properties":{"cursor":{"type":"string","maxLength":96}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    let epoch: UInt64
    public func validate(_ args: Arguments) throws {
        if let cursor = args.cursor, cursor.utf8.count > 96 { throw FloeError.validationFailed("Invalid font cursor") }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var request = try fontRequest("list", context: context); request.cursor = args.cursor
        return try await fontOutput(epoch: epoch, request: request, context: context)
    }
}
public struct FontInstallTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public var url: String?; public var path: String? }
    public static let name = "font.install"
    public static let toolDescription = "Install one validated TTF/OTF/TTC/OTC into the shared Floe font library from exactly one public HTTPS URL or authorized workspace-relative path, at most32MiB. Private/LAN targets, credentials, unsafe redirects and non-font data are refused. Office uses changes on next engine startup. Returns actual font identity and face references."
    public static let parametersJSON = #"{"type":"object","properties":{"url":{"type":"string","maxLength":4096},"path":{"type":"string","maxLength":1024}},"additionalProperties":false,"oneOf":[{"required":["url"]},{"required":["path"]}]}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .readsFiles, .writesFiles]
    public static let isSideEffecting = true
    let epoch: UInt64
    public func validate(_ args: Arguments) throws {
        let hasURL = !(args.url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasPath = !(args.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard hasURL != hasPath, (args.url?.utf8.count ?? 0) <= 4096,
              (args.path?.utf8.count ?? 0) <= 1024 else {
            throw FloeError.validationFailed("Provide exactly one font URL or workspace path")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        var request = try fontRequest("install", context: context)
        guard FontHostMailbox.shared.isReady(epoch: epoch),
              let root = AndroidRuntimeBootstrap.notesBinding(epoch: epoch, ownerToken: nil) else {
            throw FloeError.invalidConfiguration("Font library host is unavailable")
        }
        let bytes: Data?
        let sourcePath = args.path?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw = args.url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let url = URL(string: raw) else { throw FloeError.validationFailed("Invalid font URL") }
            bytes = try await HTTPRequestService.boundedPublicData(url: url,
                maxBytes: 32 * 1024 * 1024, cancellation: context.cancellation)
        } else {
            guard let path = sourcePath, let workspace = context.workspaceRootURL else {
                throw FloeError.invalidConfiguration("Task workspace unavailable")
            }
            try context.authorizeWorkspacePath(path)
            _ = try WorkspacePathGuard(rootURL: workspace, maxReadBytes: 32 * 1024 * 1024).resolve(path)
            bytes = nil
        }
        try context.cancellation.throwIfCancelled()
        guard AndroidRuntimeBootstrap.notesBinding(epoch: epoch, ownerToken: nil) != nil else { throw FloeError.cancelled }
        let inputID = UUID().uuidString.lowercased()
        let dataDir = URL(fileURLWithPath: root.path).deletingLastPathComponent().deletingLastPathComponent()
        let directory = dataDir.appendingPathComponent("files/FontIncomingV1/" + inputID, isDirectory: true)
        var created = false
        defer { if created { try? FileManager.default.removeItem(at: directory) } }
        let receipt = try C07RootedFileIO.withExclusiveDirectory(at: directory) { owned in
            created = true
            if let bytes {
                return try C07RootedFileIO.writeFile(bytes, destinationRoot: directory,
                    destinationRelativePath: "font.bin", destinationDirectory: owned)
            }
            guard let workspace = context.workspaceRootURL, let path = sourcePath else { throw FloeError.cancelled }
            return try C07RootedFileIO.copyFile(sourceRoot: workspace, sourceRelativePath: path,
                destinationRoot: directory, destinationRelativePath: "font.bin",
                maximum: 32 * 1024 * 1024, destinationDirectory: owned,
                shouldCancel: { context.cancellation.isCancelled })
        }
        request.inputID = inputID; request.sha256 = receipt.sha256; request.byteCount = receipt.byteCount
        return try await fontOutput(epoch: epoch, request: request, context: context)
    }
}
public struct FontRemoveTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public var id: String }
    public static let name = "font.remove"
    public static let toolDescription = "Remove a font from the global Floe library after normal deletion approval. Affects every workspace; active documents retain already loaded fonts. Recovery bytes are retained safely rather than deleting active consumers."
    public static let parametersJSON = #"{"type":"object","properties":{"id":{"type":"string","pattern":"^[0-9a-fA-F]{64}$"}},"required":["id"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.deletesFiles]
    public static let isSideEffecting = true
    let epoch: UInt64
    public func validate(_ args: Arguments) throws {
        guard args.id.utf8.count == 64, args.id.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw FloeError.validationFailed("Invalid font identity")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        var request = try fontRequest("remove", context: context); request.id = args.id.lowercased()
        return try await fontOutput(epoch: epoch, request: request, context: context)
    }
}
public func registerC08FontTools(epoch: UInt64, registry: ToolRunnerRegistry) {
    let available: @Sendable () -> Bool = {
        FontHostMailbox.shared.isReady(epoch: epoch) && AndroidRuntimeBootstrap.notesBinding(epoch: epoch, ownerToken: nil) != nil
    }
    ToolCatalog.register(FontListTool.self)
    registry.register(AnyAgentTool(FontListTool(epoch: epoch)).withAvailability(available))
    ToolCatalog.register(FontInstallTool.self)
    registry.register(AnyAgentTool(FontInstallTool(epoch: epoch)).withAvailability(available))
    ToolCatalog.register(FontRemoveTool.self)
    registry.register(AnyAgentTool(FontRemoveTool(epoch: epoch)).withAvailability(available))
}

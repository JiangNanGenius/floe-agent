// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloeSecurity
import FloeBiologyCore
import FloeBiologyEngine

typealias BiologyJSON = FloeBiologyCore.JSONValue

/// Captured by a compiled native Execute/Run callback, never decoded from
/// arguments or project content. Root validates the same payload/run/target
/// before persisting the native user's exact single-use approval.
struct BiologyNativeUIIntent: Sendable {
    enum Source: Sendable, Equatable { case console, analysis, imageRegion }
    let source: Source
    let projectID: UUID
    let requestID: String
    let payloadDigest: String
}
typealias BiologyNativeApprovalResolver = @MainActor @Sendable
    (ProposedAction, ToolContext, ToolCatalog.Descriptor, BiologyNativeUIIntent) async throws -> ApprovalGrant

enum BiologyHostError: Error, LocalizedError {
    case unavailable, changed, readOnly, missingRuntime, workerNotStopped, unsupportedCopy
    var errorDescription: String? {
        switch self {
        case .unavailable: IDELanguageRunText.t("请打开原生物项目及其助手后重试。", "Open the original biology project and its assistant, then try again.")
        case .changed: IDELanguageRunText.t("项目或授权已改变，请刷新后重试。", "The project or its authorization changed. Refresh and try again.")
        case .readOnly: IDELanguageRunText.t("当前任务只能查看这个项目。", "This task can only read this project.")
        case .missingRuntime: IDELanguageRunText.t("请先选择并授权这个任务的计算环境。", "Select and authorize this task's compute environment first.")
        case .workerNotStopped: IDELanguageRunText.t("计算尚未确认停止，原件会保留。请在任务中处理运行状态后重试。", "The calculation has not confirmed that it stopped. The original is kept. Resolve its task status before trying again.")
        case .unsupportedCopy: IDELanguageRunText.t("请在生物工作台中导出。大文件引用需要单独授权，工程文件不等于完整素材包。", "Export from the biology workbench. Large-file references need their own authorization; a project file is not a complete material archive.")
        }
    }
}

/// Only the native runtime may construct this value. It is never Codable and
/// cannot be supplied by a model, imported project, or tool-argument object.
struct BiologyNativeAuthorization: Sendable {
    let context: ToolContext
    let binding: RuntimeAuthorityBinding
    let finish: @MainActor @Sendable () async -> Void
}

/// Root implements this through the normal durable-task/environment/approval
/// path. No operation below creates a ToolContext from page state or JSON.
@MainActor protocol BiologyNativeRuntime: AnyObject {
    func consoleOwner(projectID: UUID) async throws -> BiologyExecutionOwner
    func authorizeTool(projectID: UUID, toolName: String, arguments: Data, requestID: String) async throws -> BiologyNativeAuthorization
    func authorizeScientificLaunch(projectID: UUID, assetID: UUID, assetRevision: UInt64) async throws -> BiologyNativeAuthorization
    func authorizeAnalysis(projectID: UUID, arguments: Data, requestID: String, source: BiologyNativeUIIntent.Source) async throws -> BiologyNativeAuthorization
    func closeConsoleOwner(projectID: UUID) async
}

enum BiologyLibraryMutation: Sendable {
    case delete(projectID: UUID)
    case restore(projectID: UUID)
}

/// These callbacks run inside the Library owner's existing usage barrier.
/// Root must commit native and wrapper lifecycle together, retaining recovery
/// when either half fails. No callback grants authority from document metadata.
struct BiologyLibraryHooks: Sendable {
    let attachCreated: @MainActor @Sendable (UUID, ToolContext) async throws -> Void
    let lifecycle: @MainActor @Sendable (BiologyLibraryMutation, ToolContext,
        @escaping @Sendable () async throws -> ToolExecutionOutput) async throws -> ToolExecutionOutput
}

struct BiologyHostCallScope: Sendable {
    let context: ToolContext?
    let projects: Set<UUID>
    let canCreate: Bool
    let lifecycle: Bool
    let recoveringNativeWorkers: Bool
}

enum BiologyHostOperation {
    @TaskLocal static var scope: BiologyHostCallScope?
}
#endif

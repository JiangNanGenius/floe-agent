// FloeExecution — narrow model-facing actions for the Linux cache-cleanup task.
//
// These tools do not execute model-authored commands. They validate a small
// category surface and call the service-owned bundled script through the
// existing exec.shell/background-job route. The persisted purpose profile and
// the runtime dispatch gate independently narrow the catalog, so a call from
// an ordinary task cannot reach them.

import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeTools

private struct LinuxCacheCleanupToolSupport: Sendable {
    let service: LinuxCacheCleanupService
    let profiles: LinuxCacheCleanupTaskStore

    func requireProfile(_ context: ToolContext) async throws -> LinuxCacheCleanupTaskProfile {
        guard let conversationID = context.conversationID,
              let environmentID = context.environmentID,
              let profile = try await profiles.profile(conversationID: conversationID),
              profile.isValid,
              profile.conversationID == conversationID,
              profile.environmentID == environmentID,
              profile.backend == .linuxVM else {
            throw FloeError.unauthorized
        }
        return profile
    }

    func cleanupContext(
        _ context: ToolContext,
        profile: LinuxCacheCleanupTaskProfile
    ) throws -> LinuxCacheCleanupContext {
        guard let conversationID = context.conversationID,
              let environmentID = context.environmentID,
              environmentID == profile.environmentID else {
            throw FloeError.unauthorized
        }
        return LinuxCacheCleanupContext(
            runID: context.runID,
            conversationID: conversationID,
            environmentID: environmentID,
            workspaceRootURL: context.workspaceRootURL,
            allowedWorkspacePaths: context.allowedWorkspacePaths,
            cancellation: context.cancellation
        )
    }
}

public struct LinuxCacheCleanupInspectTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var categories: [String]?
        public var includeScratch: Bool?
        public init(categories: [String]? = nil, includeScratch: Bool? = nil) {
            self.categories = categories
            self.includeScratch = includeScratch
        }
    }

    public static let name = LinuxCacheCleanupScope.inspectToolName
    public static let toolDescription = "Inspect the shared Linux guest's known cache categories without deleting anything. Returns real category bytes and guest free space. Accepts only category ids (apt, pip, npm, no scratch) and never a path, command or arbitrary directory."
    public static let parametersJSON = #"{"type":"object","properties":{"categories":{"type":"array","items":{"type":"string","enum":["apt","pip","npm"]},"description":"Known regenerable caches. Omit for apt,pip,npm. Unknown scratch is always retained."}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .executesLocalCode]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let executionBoundary: ToolExecutionBoundary = .any

    private let support: LinuxCacheCleanupToolSupport
    public init(service: LinuxCacheCleanupService, profiles: LinuxCacheCleanupTaskStore) {
        support = LinuxCacheCleanupToolSupport(service: service, profiles: profiles)
    }

    public func validate(_ args: Arguments) throws {
        guard let categories = LinuxCacheCleanupToolArguments.resolve(args.categories, includeScratch: args.includeScratch),
              !categories.isEmpty else {
            throw FloeError.validationFailed(
                "categories must contain only apt, pip or npm (no duplicates); omit it for apt,pip,npm")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let profile = try await support.requireProfile(context)
        let cleanup = try support.cleanupContext(context, profile: profile)
        let categories = LinuxCacheCleanupToolArguments.resolve(args.categories, includeScratch: args.includeScratch) ?? []
        let receipt = try await support.service.inspect(context: cleanup, categories: categories)
        return ToolExecutionOutput(
            digesting: receipt.modelSummary,
            exitStatus: 0,
            capturedOutput: receipt.jsonString
        )
    }
}

public struct LinuxCacheCleanupCleanTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var categories: [String]?
        public var includeScratch: Bool?
        public init(categories: [String]? = nil, includeScratch: Bool? = nil) {
            self.categories = categories
            self.includeScratch = includeScratch
        }
    }

    public static let name = LinuxCacheCleanupScope.cleanToolName
    public static let toolDescription = "Clean only known regenerable caches inside the shared Linux guest: apt downloaded archives (through the real package-manager lock), pip download/wheel cache, npm content cache. It uses the app's bundled trusted script through the existing Linux job route and accepts no path, command, environment or arbitrary directory. It never removes projects, documents, installed packages/toolchains/models, user configuration/credentials or unrelated services. It waits for the actual terminal result and reports guest available bytes before/after; guest deletion may not shrink outer iPad storage."
    public static let parametersJSON = #"{"type":"object","properties":{"categories":{"type":"array","items":{"type":"string","enum":["apt","pip","npm"]},"description":"Known regenerable caches. Omit for apt,pip,npm. Unknown scratch is always retained."}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.executesLocalCode, .readsFiles, .writesFiles, .deletesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let executionBoundary: ToolExecutionBoundary = .any

    private let support: LinuxCacheCleanupToolSupport
    public init(service: LinuxCacheCleanupService, profiles: LinuxCacheCleanupTaskStore) {
        support = LinuxCacheCleanupToolSupport(service: service, profiles: profiles)
    }

    public func validate(_ args: Arguments) throws {
        guard let categories = LinuxCacheCleanupToolArguments.resolve(args.categories, includeScratch: args.includeScratch),
              !categories.isEmpty else {
            throw FloeError.validationFailed(
                "categories must contain only apt, pip or npm (no duplicates); omit it for apt,pip,npm")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let profile = try await support.requireProfile(context)
        let cleanup = try support.cleanupContext(context, profile: profile)
        let categories = LinuxCacheCleanupToolArguments.resolve(args.categories, includeScratch: args.includeScratch) ?? []
        let receipt = try await support.service.clean(context: cleanup, categories: categories)
        return ToolExecutionOutput(
            digesting: receipt.modelSummary,
            exitStatus: receipt.state == "failed" ? 1 : 0,
            capturedOutput: receipt.jsonString
        )
    }
}

public struct LinuxCacheCleanupStatusTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var jobID: String
        public init(jobID: String) { self.jobID = jobID }
    }

    public static let name = LinuxCacheCleanupScope.statusToolName
    public static let toolDescription = "Read the actual status/result of a Linux cleanup job started by this cleanup task (or by a sibling task in the same explicit environment). Use this after a failed/interrupted/duplicate job before retrying; it reports the real state, categories and error, and marks the output as inspected."
    public static let parametersJSON = #"{"type":"object","properties":{"jobID":{"type":"string","description":"UUID returned by linux.cache.clean or linux.cache.inspect"}},"required":["jobID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let support: LinuxCacheCleanupToolSupport
    public init(service: LinuxCacheCleanupService, profiles: LinuxCacheCleanupTaskStore) {
        support = LinuxCacheCleanupToolSupport(service: service, profiles: profiles)
    }

    public func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.jobID) != nil else {
            throw FloeError.validationFailed("jobID must be a UUID returned by a cleanup tool")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let profile = try await support.requireProfile(context)
        let cleanup = try support.cleanupContext(context, profile: profile)
        guard let jobID = UUID(uuidString: args.jobID) else {
            throw FloeError.validationFailed("jobID must be a UUID")
        }
        let receipt = try await support.service.status(context: cleanup, jobID: jobID)
        return ToolExecutionOutput(
            digesting: receipt.modelSummary,
            exitStatus: receipt.state == "failed" ? 1 : 0,
            capturedOutput: receipt.jsonString
        )
    }
}

public struct LinuxCacheCleanupCancelTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var jobID: String
        public init(jobID: String) { self.jobID = jobID }
    }

    public static let name = LinuxCacheCleanupScope.cancelToolName
    public static let toolDescription = "Request stop of a Linux cleanup job owned by this task and wait for the real processor acknowledgment. Cancellation is not complete until the job is terminal. Never start another cleanup while a stop is still in progress."
    public static let parametersJSON = #"{"type":"object","properties":{"jobID":{"type":"string","description":"UUID returned by this task's cleanup tool"}},"required":["jobID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let support: LinuxCacheCleanupToolSupport
    public init(service: LinuxCacheCleanupService, profiles: LinuxCacheCleanupTaskStore) {
        support = LinuxCacheCleanupToolSupport(service: service, profiles: profiles)
    }

    public func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.jobID) != nil else {
            throw FloeError.validationFailed("jobID must be a UUID returned by this task's cleanup tool")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let profile = try await support.requireProfile(context)
        let cleanup = try support.cleanupContext(context, profile: profile)
        guard let jobID = UUID(uuidString: args.jobID) else {
            throw FloeError.validationFailed("jobID must be a UUID")
        }
        let receipt = try await support.service.cancel(context: cleanup, jobID: jobID)
        return ToolExecutionOutput(
            digesting: receipt.modelSummary,
            exitStatus: 0,
            capturedOutput: receipt.jsonString
        )
    }
}

private enum LinuxCacheCleanupToolArguments {
    static func resolve(
        _ raw: [String]?,
        includeScratch: Bool?
    ) -> [LinuxCacheCleanupCategory]? {
        // Decode the legacy field only to reject stale callers explicitly;
        // it is absent from the offered schemas and cannot grant deletion.
        guard includeScratch == nil else { return nil }
        if let raw {
            return LinuxCacheCleanupCategory.validated(rawValues: raw)
        }
        return LinuxCacheCleanupCategory.defaultSafe
    }
}

@discardableResult
public func registerLinuxCacheCleanupTools(
    service: LinuxCacheCleanupService,
    profiles: LinuxCacheCleanupTaskStore,
    registry: ToolRunnerRegistry = .shared
) -> Bool {
    ToolCatalog.register(LinuxCacheCleanupInspectTool.self)
    ToolCatalog.register(LinuxCacheCleanupCleanTool.self)
    ToolCatalog.register(LinuxCacheCleanupStatusTool.self)
    ToolCatalog.register(LinuxCacheCleanupCancelTool.self)
    registry.register(LinuxCacheCleanupInspectTool(service: service, profiles: profiles))
    registry.register(LinuxCacheCleanupCleanTool(service: service, profiles: profiles))
    registry.register(LinuxCacheCleanupStatusTool(service: service, profiles: profiles))
    registry.register(LinuxCacheCleanupCancelTool(service: service, profiles: profiles))
    return true
}

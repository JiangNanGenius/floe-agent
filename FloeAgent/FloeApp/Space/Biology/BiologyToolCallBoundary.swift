// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeTools
import FloeBiologyCore
import FloeBiologyEngine

/// Decorates the real adapter runner rather than defining another executor.
/// Tests can exercise the same boundary with genuine scoped stores/registry.
@MainActor final class BiologyToolCallBoundary {
    let access: BiologyHostAccess
    let hooks: BiologyLibraryHooks
    private let didMutate: @MainActor @Sendable (Set<UUID>, String) async throws -> Void
    init(access: BiologyHostAccess, hooks: BiologyLibraryHooks,
         didMutate: @escaping @MainActor @Sendable (Set<UUID>, String) async throws -> Void = { _, _ in }) {
        self.access = access; self.hooks = hooks; self.didMutate = didMutate
    }
    func wrap(_ original: AnyAgentTool) -> AnyAgentTool {
        var result = original
        result.run = { [self] data, context in try await execute(original, data: data, context: context) }
        return result
    }
    private func execute(_ tool: AnyAgentTool, data: Data, context: ToolContext) async throws -> ToolExecutionOutput {
        try tool.validateArguments(data)
        let value = try JSONDecoder().decode(BiologyJSON.self, from: data)
        let targets = try await access.validateTargets(value, name: tool.descriptor.name, context: context)
        let grant = try await access.grant(context)
        let mutation: BiologyLibraryMutation?
        if let id = value["projectID"]?.string.flatMap(UUID.init(uuidString:)), tool.descriptor.name == "biology.deleteProject" { mutation = .delete(projectID: id) }
        else if let id = value["projectID"]?.string.flatMap(UUID.init(uuidString:)), tool.descriptor.name == "biology.restoreDeleted" { mutation = .restore(projectID: id) }
        else { mutation = nil }
        let scope = BiologyHostCallScope(context: context, projects: grant.projects,
            canCreate: grant.canCreate, lifecycle: mutation != nil, recoveringNativeWorkers: false)
        if let mutation {
            let output = try await BiologyHostOperation.$scope.withValue(scope) {
                try await hooks.lifecycle(mutation, context) { try await tool.run(data, context) }
            }
            if output.exitStatus == 0 { try await didMutate(targets, tool.descriptor.name) }
            return output
        }
        let leases = try await access.acquire(targets)
        defer { for lease in leases { lease.release() } }
        let output = try await BiologyHostOperation.$scope.withValue(scope) { try await tool.run(data, context) }
        if output.exitStatus == 0, !BiologyToolSchemas.readOnlyNames.contains(tool.descriptor.name) {
            var changed = Set<UUID>()
            if let id = value["projectID"]?.string.flatMap(UUID.init(uuidString:)) { changed.insert(id) }
            if ["biology.create", "biology.importProject"].contains(tool.descriptor.name),
               let text = output.capturedOutput ?? (output.summary.isEmpty ? nil : output.summary),
               let result = try? JSONDecoder().decode(BiologyJSON.self, from: Data(text.utf8)),
               let created = result["id"]?.string.flatMap(UUID.init(uuidString:)) { changed.insert(created) }
            // A read-only sourceProjectID is not a modified target.
            try await didMutate(changed, tool.descriptor.name)
        }
        return output
    }
}
#endif

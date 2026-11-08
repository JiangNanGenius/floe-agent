#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeEnvironments
import FloeExecution
import FloeModels
import FloePersistence
import FloeSkills
import FloeSync
import FloeTools

extension AppEnvironment {
    func makeNativeExternalOAuthIntegration() -> NativeExternalOAuthAppIntegration {
        let registry = environmentRegistry
        let connections = linuxGuestService.map { workers in
            NativeExternalOAuthConnections(configuration: skillConfigurationService,
                runtimes: skillRuntimeComponents, workers: workers,
                managementLease: { [weak self] id, cancellation in
                    guard let self else { throw FloeError.unauthorized }
                    // Hold the actual management lease through preparation,
                    // browser/refresh and confirmed worker termination.
                    let lease = try await self.executionManagementLease(id, cancellation: cancellation)
                    do {
                        guard let record = await registry.record(id: id), record.effectiveExecutionBackend == .linuxVM else {
                            throw FloeError.unauthorized
                        }
                        let target = try await self.taskExecutionEnvironments.target(record)
                        try await self.prepareExecutionTarget(target, cancellation: cancellation)
                        try cancellation.throwIfCancelled()
                        return lease
                    } catch { await lease.finish(); throw error }
                }, authority: { [weak self] id in
                    await self?.skillsCenter.runtimeComponentAuthorization(skillID: id)
                }, environmentCheck: { id in
                    guard let record = await registry.record(id: id) else { return false }
                    return record.effectiveExecutionBackend == .linuxVM && record.kind.isWritableLayer
                        && record.state == .active && !record.requiresRebuild && record.pendingRuntimeResetID == nil
                })
        }
        let authorizer = NativeExternalOAuthAccessAuthorizer(skills: skillStore,
            configuration: skillConfigurationService, runtimeAuthority: { [weak self] id in
                await self?.skillsCenter.runtimeComponentAuthorization(skillID: id)
            }, requirements: { try SkillConfigurationTool.requirements(from: $0) })
        let integration = NativeExternalOAuthAppIntegration(services: .init(configuration: skillConfigurationService,
            connections: connections, authorize: { request in
                try await authorizer.authorize(request)
            }, environments: {
                let records = await registry.all().filter {
                    $0.effectiveExecutionBackend == .linuxVM && $0.kind.isWritableLayer && $0.state == .active
                        && !$0.requiresRebuild && $0.pendingRuntimeResetID == nil
                }
                return records.map { record in
                    NativeExternalOAuthAppIntegration.EnvironmentChoice(id: record.id,
                        title: record.name ?? NativeExternalOAuthCopy.text(
                            record.kind == .project ? "Project environment" : "Task environment",
                            record.kind == .project ? "项目环境" : "任务环境"))
                }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }))
        integration.onBindingChanged = { [weak self] in await self?.refreshNativeMailOAuthConnections() }
        return integration
    }

    func makeNativeMailOAuthConsumer() -> NativeMailOAuthConsumer {
        .init(makeReader: { [weak self] reference, use in
            guard let self else { throw FloeError.unauthorized }
            return try await self.nativeExternalOAuthIntegration.makeReader(reference: reference, validateConsumer: { [weak self] in
                guard let self else { throw FloeError.unauthorized }
                try await self.validateNativeMailOAuthUse(use)
            })
        }, validateUse: { [weak self] reference, use in
            guard let self else { throw FloeError.unauthorized }
            try await self.nativeExternalOAuthIntegration.validateReference(reference, validateConsumer: { [weak self] in
                guard let self else { throw FloeError.unauthorized }
                try await self.validateNativeMailOAuthUse(use)
            })
        }, quietRefresh: { [weak self] reference, use in
            guard let self else { throw FloeError.unauthorized }
            try await self.nativeExternalOAuthIntegration.quietRefresh(reference: reference, validateConsumer: { [weak self] in
                guard let self else { throw FloeError.unauthorized }
                try await self.validateNativeMailOAuthUse(use)
            })
        })
    }

    private func validateNativeMailOAuthUse(_ use: NativeMailOAuthUse) async throws {
        try use.validate()
        if use.operation == .settingsTest {
            // Only the existing native Test button constructs this path. It
            // has no agent context, worker grant or model-decoded authority.
            guard use.toolContext == nil, use.runID == nil, use.conversationID == nil,
                  use.approvalGrantID == nil else { throw FloeError.unauthorized }
            return
        }
        guard let context = use.toolContext,
              context.runID == use.runID, context.conversationID == use.conversationID,
              context.approvalGrantID == use.approvalGrantID,
              !context.temporaryReadOnly, !context.publicWebOnly,
              let name = context.executionToolName,
              context.allowedToolNames?.contains(name) != false,
              context.frozenEffectiveCatalogNames?.contains(name) != false else { throw FloeError.unauthorized }
        let expected: Set<String>
        switch use.operation {
        case .read: expected = ["mail.read", "mail.search", "mail.download"]
        case .modify: expected = ["mail.setRead", "mail.move"]
        case .send: expected = ["mail.send"]
        case .settingsTest: throw FloeError.unauthorized
        }
        guard expected.contains(name) else { throw FloeError.unauthorized }
        try context.cancellation.throwIfCancelled()
        let owner = context.childExecution?.identity.parentRunID ?? context.runID
        guard let run = try await runStore.run(id: owner), run.endedAt == nil,
              run.conversationID == context.conversationID,
              conversationCenter.hasLiveOwnerForEnvironmentMigration(runID: owner),
              let conversation = try await conversationStore.conversation(id: run.conversationID),
              conversation.purpose == .ordinary else { throw FloeError.unauthorized }
        let policy = try await SQLiteWorkspaceStore(database: database).taskPolicy(conversationID: run.conversationID)
        guard policy.credentialsAllowed != false, policy.networkAllowed != false else { throw FloeError.unauthorized }
        try use.validate()
    }

    func installNativeMailOAuth() {
        MailSettingsCenter.shared.configureOAuth(consumer: nativeMailOAuthConsumer, connections: [])
        MailSettingsCenter.shared.refreshOAuthConnections = { [weak self] in await self?.refreshNativeMailOAuthConnections() }
        Task { [weak self] in await self?.refreshNativeMailOAuthConnections() }
    }

    private func refreshNativeMailOAuthConnections() async {
        let generation = UUID()
        nativeMailOAuthRefreshGeneration = generation
        var requests = Set<SkillConfigurationConnectionRequest>()
        for id in ["floe-google-auth", "floe-microsoft-auth"] {
            requests.insert(.init(skillID: id, scope: .init(profile: "default", target: SkillConfigurationTargets.localLinux),
                fieldKey: "connection", connectionKind: NativeExternalOAuthAppIntegration.connectionKind))
        }
        for account in MailSettingsCenter.shared.accounts {
            if let reference = account.oauthConnection {
                requests.insert(.init(skillID: reference.skillID, scope: .init(profile: reference.profile, target: reference.target),
                    fieldKey: "connection", connectionKind: NativeExternalOAuthAppIntegration.connectionKind))
            }
        }
        var choices = [NativeMailOAuthConnectionChoice]()
        for request in requests {
            if let saved = try? await nativeExternalOAuthIntegration.saved(request) {
                let provider = request.skillID == "floe-google-auth" ? "Google" : "Microsoft"
                choices.append(.init(reference: saved.details.reference,
                    title: request.scope.profile == "default" ? provider : provider + " · " + request.scope.profile))
            }
        }
        guard nativeMailOAuthRefreshGeneration == generation, !Task.isCancelled else { return }
        choices.sort { $0.id < $1.id }
        let current = MailSettingsCenter.shared.oauthConnections
        // An unchanged binding must not fence a cached read or quiet refresh.
        guard current.map(\.id) != choices.map(\.id) || current.map(\.title) != choices.map(\.title) else { return }
        MailSettingsCenter.shared.configureOAuth(consumer: nativeMailOAuthConsumer, connections: choices)
    }

    func requiresExternalOAuthConnection(_ skill: PersistedSkill) -> Bool {
        guard ["floe-google-auth", "floe-microsoft-auth"].contains(skill.id),
              let manifest = try? JSONDecoder().decode(SkillManifest.self, from: Data(skill.manifestJSON.utf8)) else { return false }
        return manifest.configuration?.fields.contains {
            $0.key == "connection" && $0.kind == .connection && $0.connectionKind == NativeExternalOAuthAppIntegration.connectionKind
        } == true
    }
}
#endif

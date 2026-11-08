#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSkills
import FloeSync
import FloeTools
import FloeExecution
import FloeEnvironments

enum SkillConfigurationTargets {
    static let localIOS = "local-ios"
    static let localLinux = "local-linux"
    static let localMac = "local-mac"

    static func name(for target: TaskExecutionTarget) throws -> String {
        switch target.backend {
        case .linuxVM: return localLinux
        case .macBridge:
            guard LocalBridgePlatform.current.supportsMacBridge else { throw FloeError.unauthorized }
            return localMac
        case .remoteSSH:
            guard let host = target.remoteHostID else { throw FloeError.unauthorized }
            return "ssh:" + host.uuidString.lowercased()
        }
    }
}

/// The service authorizer resolves native run records; neither a model's
/// skillID nor activeSkillIDs alone grants access to stored credentials.
struct AppSkillRuntimeUseAuthorizer: SkillRuntimeUseAuthorizing {
    private let check: @Sendable (SkillRuntimeUseRequest) async -> SkillRuntimeUseDecision

    @MainActor init(environment: AppEnvironment) {
        check = { [weak environment] request in
            guard let environment else { return .denied("The task service is unavailable.") }
            return await environment.authorizeSkillConfigurationUse(request)
        }
    }

    func authorize(_ request: SkillRuntimeUseRequest) async -> SkillRuntimeUseDecision {
        await check(request)
    }
}

extension AppEnvironment {
    func makeSkillConfigurationStore() -> SkillConfigurationStore {
        SkillConfigurationStore(database: database, officialSources: skillConfigurationOfficialSources)
    }

    private var skillConfigurationOfficialSources: [SkillOfficialSource] {
        [
            .init(owner: OfficialSkillHub.owner, repository: OfficialSkillHub.repository,
                  publisher: CuratedSkillHub.publisher),
            .init(owner: CuratedSkillHub.owner, repository: CuratedSkillHub.repository,
                  publisher: CuratedSkillHub.publisher)
        ]
    }

    func makeSkillConfigurationService() -> SkillConfigurationService {
        SkillConfigurationService(
            store: skillConfigurationStore, vault: credentialVault,
            validators: [IOSBridgeSkillConnectionValidator(), NativeExternalOAuthConnectionValidator(authorize: { [weak self] request, payload in
                guard let self else { throw FloeError.unauthorized }
                try await self.nativeExternalOAuthIntegration.validateValidationRequest(request, payload: payload)
            })],
            runtimeUseAuthorizer: AppSkillRuntimeUseAuthorizer(environment: self)
        )
    }

    var skillConfigurationTargetResolver: SkillConfigurationTargetResolver {
        { [weak self] skill, context, requested in
            guard let self else { throw FloeError.unauthorized }
            return try await self.configurationTarget(for: skill, context: context, requested: requested)
        }
    }

    private func requiresLocalIOSConnection(_ skill: PersistedSkill) throws -> Bool {
        let manifest = try JSONDecoder().decode(SkillManifest.self, from: Data(skill.manifestJSON.utf8))
        return manifest.configuration?.fields.contains {
            $0.kind == .connection && $0.connectionKind == "ios.bridge.local"
        } == true
    }

    func configurationTarget(for skill: PersistedSkill, context: ToolContext, requested: String?) async throws -> String {
        let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        if try requiresLocalIOSConnection(skill) {
            guard LocalBridgePlatform.current.supportsIOSAutomation,
                  requested == nil || requested == "default" || requested == "current"
                    || requested == SkillConfigurationTargets.localIOS else { throw FloeError.unauthorized }
            return SkillConfigurationTargets.localIOS
        }
        if let requested, !requested.isEmpty, requested != "default", requested != "current" {
            // Saving a named profile does not authorize using it on that
            // machine. resolve/readSecret verify the actual run target.
            return requested
        }
        guard let run = try await runStore.run(id: context.childExecution?.identity.parentRunID ?? context.runID),
              let pin = run.executionBinding,
              context.environmentID == pin.target.environmentID,
              context.executionBindingGeneration == nil || context.executionBindingGeneration == pin.generation else {
            throw FloeError.invalidConfiguration("Select this task's execution location before configuring its Skill environment.")
        }
        return try SkillConfigurationTargets.name(for: pin.target)
    }

    func skillConfigurationUIScope(for skill: PersistedSkill) -> SkillConfigurationUIScope {
        if requiresExternalOAuthConnection(skill) {
            return .init(profile: "default", target: SkillConfigurationTargets.localLinux)
        }
        if (try? requiresLocalIOSConnection(skill)) == true {
            return .init(profile: "default", target: SkillConfigurationTargets.localIOS)
        }
        if case .host(let id) = settingsCenter.execution.target {
            return .init(profile: "default", target: "ssh:" + id.uuidString.lowercased())
        }
        let target = LocalBridgePlatform.current.supportsMacBridge && MacBridgeRoutingPreferences.preferMacForNewTasks
            ? SkillConfigurationTargets.localMac : SkillConfigurationTargets.localLinux
        return .init(profile: "default", target: target)
    }

    var skillConfigurationUIAccess: SkillConfigurationUIAccess {
        SkillConfigurationUIAccess(
            service: skillConfigurationService, credentials: credentialStore,
            configurations: skillConfigurationStore,
            scope: { [weak self] skill in self?.skillConfigurationUIScope(for: skill) ?? .init(target: "unavailable") },
            connectionKinds: Set([NativeExternalOAuthAppIntegration.connectionKind])
                .union(LocalBridgePlatform.current.supportsIOSAutomation ? ["ios.bridge.local"] : []),
            supportsNativeNavigation: true,
            beginMutation: { [weak self] skillID, fields in
                guard let self else { throw FloeError.unauthorized }
                return try await self.nativeExternalOAuthIntegration.beginMutation(skillID: skillID, fields: fields)
            },
            configurationMutated: { [weak self] skillID, fields in
                await self?.nativeExternalOAuthIntegration.configurationDidMutate(skillID: skillID, fields: fields)
                await self?.iosBridgeIntegration.skillConfigurationDidMutate(skillID: skillID, fieldKeys: fields)
            },
            uninstall: { [weak self] skill, scope, disposition in
                guard let self else { throw FloeError.unauthorized }
                try await self.uninstallConfiguredSkill(skill, scope: scope, disposition: disposition)
            }
        )
    }

    private func uninstallConfiguredSkill(
        _ skill: PersistedSkill, scope: SkillConfigurationUIScope,
        disposition: SkillConfigurationUninstallDisposition
    ) async throws {
        if let current = try await skillStore.skill(id: skill.id) {
            guard current.rewrittenDigest == skill.rewrittenDigest, current.createdAt == skill.createdAt else {
                throw SkillStoreConflict.changedOrMissing
            }
            _ = try await skillsCenter.manageSkill(.init(action: .remove, id: skill.id, expectedDigest: skill.rewrittenDigest))
            await skillsCenter.load()
        }
        guard case .deleteCurrentProfile = disposition else { return }
        do {
            let manifest = try JSONDecoder().decode(SkillManifest.self, from: Data(skill.manifestJSON.utf8))
            let requirements = try SkillConfigurationTool.requirements(from: manifest.configuration ?? .init())
            let snapshot = try await skillConfigurationStore.snapshot(
                skillID: skill.id, profile: scope.profile, target: scope.target)
            guard let profile = snapshot.profile else { return }
            let installation = SkillInstallationIdentity.derive(
                skillID: skill.id, sourceURL: skill.sourceURL,
                reviewedDigest: skill.rewrittenDigest, sourceDigest: skill.sourceDigest,
                sourceTrackingJSON: skill.sourceTrackingJSON, rewriteModelID: skill.rewriteModelID,
                officialSources: skillConfigurationOfficialSources)
            guard profile.installationID == installation.installationID else {
                throw SkillConfigurationUninstallError.cleanupPending
            }
            let result = try await skillConfigurationService.unconfigure(
                skillID: skill.id, profile: scope.profile, target: scope.target, requirements: requirements,
                expectedRevision: profile.revision, expectedProfileID: profile.id)
            guard result.warnings.isEmpty else { throw SkillConfigurationUninstallError.cleanupPending }
            // Credential deletion has its own durable retry queue. Shared
            // references and companion RemotePairing records are untouched.
            await credentialVault.drainDeletionQueue()
        } catch {
            throw SkillConfigurationUninstallError.cleanupPending
        }
    }

    private func hasRunningSkillJob(run: RunRecord, skillID: String) async throws -> Bool {
        guard let pin = run.executionBinding else { return false }
        let jobs = try await BackgroundJobStore(database: database).activeJobs(environmentID: pin.target.environmentID)
        return jobs.contains { job in
            guard job.runID == run.id, job.conversationID == run.conversationID,
                  job.kind == .tool, job.state == .running, job.targetTool == "exec.shell",
                  let arguments = try? JSONSerialization.jsonObject(with: job.payloadJSON) as? [String: Any] else { return false }
            return arguments["skillID"] as? String == skillID
        }
    }

    func authorizeSkillConfigurationUse(_ request: SkillRuntimeUseRequest) async -> SkillRuntimeUseDecision {
        do {
            guard let run = try await runStore.run(id: request.runID),
                  let skill = try await skillStore.skill(id: request.skillID), skill.status == "enabled" else {
                return .denied("The owning task or enabled Skill is no longer available.")
            }
            let hasLiveRun = run.endedAt == nil && conversationCenter.hasLiveOwnerForEnvironmentMigration(runID: run.id)
            let hasLiveJob = try await hasRunningSkillJob(run: run, skillID: request.skillID)
            guard hasLiveRun || hasLiveJob else { return .denied("The task has no live owner for this configuration use.") }
            let policy = try await SQLiteWorkspaceStore(database: database).taskPolicy(conversationID: run.conversationID)
            let snapshot = try await skillConfigurationStore.snapshot(
                skillID: request.skillID, profile: request.profile, target: request.target)
            guard snapshot.currentInstallation?.installationID == request.installationID,
                  snapshot.currentInstallation?.configurationAllowed == true,
                  !snapshot.sourceChanged, snapshot.profile?.revision == request.revision else {
                return .denied("The installed Skill or configuration changed.")
            }
            if !snapshot.bindings.isEmpty, policy.credentialsAllowed == false {
                return .denied("Credential access is disabled for this task.")
            }
            let manifest = try JSONDecoder().decode(SkillManifest.self, from: Data(skill.manifestJSON.utf8))
            let grants = try await skillStore.allowedCapabilities(skillID: skill.id)
            guard Set(manifest.capabilities).isSubset(of: grants) else {
                return .denied("The Skill's required access is no longer granted.")
            }
            if request.target == SkillConfigurationTargets.localIOS {
                guard LocalBridgePlatform.current.supportsIOSAutomation,
                      try requiresLocalIOSConnection(skill) else { return .denied("This is not a local iOS connection.") }
                return .allowed
            }
            guard let pin = run.executionBinding,
                  request.bindingGeneration == pin.generation,
                  let current = try await TaskExecutionBindingStore(database: database).binding(conversationID: run.conversationID),
                  current.generation == pin.generation, current.target == pin.target,
                  let record = await environmentRegistry.record(id: pin.target.environmentID),
                  record.state == .active, !record.requiresRebuild,
                  try await taskExecutionEnvironments.ownsConfigurationLocation(conversationID: run.conversationID,
                      environmentID: pin.target.environmentID),
                  try SkillConfigurationTargets.name(for: pin.target) == request.target else {
                return .denied("The task's authorized execution location changed.")
            }
            if pin.target.backend == .remoteSSH, policy.remoteExecutionAllowed == false {
                return .denied("Remote execution is disabled for this task.")
            }
            return .allowed
        } catch {
            return .denied("The current task, configuration or credential permission could not be verified.")
        }
    }
}

struct AppSkillProcessConfigurationProvider: SkillProcessConfigurationProviding {
    private let resolve: @Sendable (String, ToolContext) async throws -> SkillProcessConfiguration

    @MainActor init(environment: AppEnvironment) {
        resolve = { [weak environment] skillID, context in
            guard let environment else { throw FloeError.unauthorized }
            return try await environment.processConfiguration(skillID: skillID, context: context)
        }
    }

    func processConfiguration(skillID: String, context: ToolContext) async throws -> SkillProcessConfiguration {
        try await resolve(skillID, context)
    }
}

extension AppEnvironment {
    func processConfiguration(skillID: String, context: ToolContext) async throws -> SkillProcessConfiguration {
        try context.cancellation.throwIfCancelled()
        guard context.approvalGrantID != nil, !context.temporaryReadOnly, !context.publicWebOnly else {
            throw FloeError.unauthorized
        }
        let selected = try await skillsCenter.configurationInvocation(skillID: skillID, runID: context.runID)
        let declarations = try SkillConfigurationTool.requirements(from: selected.manifest.configuration ?? .init())
        let target = try await configurationTarget(for: selected.skill, context: context, requested: nil)
        let request = SkillConfigurationResolutionRequest(
            skillID: skillID, target: target, bindingGeneration: context.executionBindingGeneration)
        // This exact selected installation was verified and pinned natively,
        // including an approved installation performed during this run.
        let provenance = SkillRuntimeProvenance(runID: context.runID, activeSkillIDs: [skillID])
        let service = skillConfigurationService
        let saved = try await skillConfigurationStore.snapshot(skillID: skillID, target: target)
        let effective = try await service.effectiveRequirements(skillID: skillID, target: target, requirements: declarations)
        if saved.profile == nil {
            let missing = effective.fields.filter { $0.required && ($0.kind != .variable || $0.defaultValue == nil) }.map(\.key)
            guard missing.isEmpty else { throw SkillConfigurationError.incompleteConfiguration(missing) }
            // Existing dependency-aware Skills need no artificial empty DB
            // profile. Manifest defaults are ordinary values, never secrets.
            var defaults: [String: String] = [:]
            for mapping in effective.environment {
                guard let field = effective.field(mapping.fieldKey), field.kind == .variable,
                      let value = field.defaultValue else { continue }
                defaults[mapping.name] = value
            }
            let expectedDigest = selected.skill.rewrittenDigest
            return SkillProcessConfiguration(
                environment: defaults, sensitiveEnvironment: nil,
                configuredEnvironmentNames: Set(defaults.keys),
                revalidate: { [weak self] in
                    try context.cancellation.throwIfCancelled()
                    guard let self else { throw FloeError.unauthorized }
                    let current = try await self.skillsCenter.configurationInvocation(skillID: skillID, runID: context.runID)
                    let currentTarget = try await self.configurationTarget(for: current.skill, context: context, requested: nil)
                    let currentProfile = try await self.skillConfigurationStore.snapshot(skillID: skillID, target: target)
                    guard current.skill.rewrittenDigest == expectedDigest, currentTarget == target,
                          currentProfile.profile == nil else { throw SkillConfigurationError.configurationChanged }
                },
                sanitizeOutput: { $0 }
            )
        }
        let resolved = try await service.resolve(request: request, provenance: provenance, requirements: declarations)
        var secrets: [String: String] = [:]
        for mapping in resolved.secretEnvironment {
            let bytes = try await service.readSecret(mapping.fieldKey, in: resolved)
            guard let value = String(data: bytes, encoding: .utf8), secrets[mapping.name] == nil else {
                throw FloeError.validationFailed("A Skill environment value is invalid.")
            }
            secrets[mapping.name] = value
        }
        let sensitive = secrets.isEmpty ? nil : try SensitiveProcessEnvironment(secrets)
        let redactor = SensitiveValueRedactor(values: Array(secrets.values))
        return SkillProcessConfiguration(
            environment: resolved.environment, sensitiveEnvironment: sensitive,
            configuredEnvironmentNames: Set(resolved.environment.keys).union(secrets.keys),
            revalidate: { [weak self] in
                try context.cancellation.throwIfCancelled()
                guard let self else { throw FloeError.unauthorized }
                let current = try await service.resolve(request: request, provenance: provenance, requirements: declarations)
                guard current.installationID == resolved.installationID, current.revision == resolved.revision,
                      await self.authorizeSkillConfigurationUse(.init(
                        runID: context.runID, skillID: skillID, installationID: current.installationID,
                        profile: current.profile, target: current.target, revision: current.revision,
                        bindingGeneration: context.executionBindingGeneration, operation: .resolve, fieldKey: nil)) == .allowed else {
                    throw FloeError.unauthorized
                }
            },
            sanitizeOutput: { redactor.redactComplete($0) }
        )
    }
}
#endif

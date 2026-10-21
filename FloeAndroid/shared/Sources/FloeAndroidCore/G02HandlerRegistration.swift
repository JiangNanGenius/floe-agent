// SPDX-License-Identifier: MPL-2.0
//
// G02 production composition — handler registration for every
// non-self-installing ORDINARY-base command in the frozen 87/19 matrix
// (84 before the goal-core batch; the three additive run-control tuples
// self-install with RB4).
//
// Self-installing lanes keep their own binder (RB1 system/effect/event,
// RB4 runs via RunDomainFacade.install, attachment staging via
// AttachmentStagingFacade.install). This file registers:
//
//   * RB2  config providers/models/catalog/preferences/websearch (11)
//   * RB6  capability.tools.list / skills.* / mcp.* (7)
//   * RB3  conversation list/search/create/get/rename/archive/delete/
//          messagePage + conversationLifecycle content.read (9)
//   * RB3b memory.* (14), personalization.* (7), usage.statistics.get (1)
//   * P6   config.defaults.get/save (2)
//   * shared applicationConfiguration content.read (conversations |
//          personalization) (1 key, label-dispatched)
//
// Temporary/privacy commands stay UNREGISTERED until their real
// G02DomainExtension binds (their successor owns those keys); until then
// the frozen fail-closed runtimeUnavailable refusal answers them and the
// 84/19 matrix counts are unchanged.
//
// Every processor re-reads the strict envelope fields, calls exactly one
// real domain method, and settles through the typed value/page carrier.
// Domain errors keep their exact frozen wire codes in the value body.
//
// This source is NOT compiled/executed by the authoring package.
import Foundation

extension G02InstalledComposition {

    /// Registers every ordinary handler and returns the EXACT key list this
    /// registration bound (the caller re-checks its full-owner claim after
    /// registration and unregisters exactly these keys on a lost claim —
    /// late cleanup can never touch a newer owner's handlers).
    @discardableResult
    func registerAllDomainHandlers(gen: AndroidRuntimeBootstrap.Generation) -> [String] {
        registerModelConfigurationCommands(gen: gen)
        registerCapabilitiesSkillsMcpCommands(gen: gen)
        registerHistoryCommands(gen: gen)
        registerMemoryCommands(gen: gen)
        registerPersonalizationCommands(gen: gen)
        registerDefaultsUsageCommands(gen: gen)
        registerSharedContentRead(gen: gen)
        return registeredHandlerKeys
    }

    /// Registers submit handler + async processor for one matrix command
    /// and records the key for retirement.
    private func bind(_ gen: AndroidRuntimeBootstrap.Generation,
                      scope: BridgeV3.Scope, command: String,
                      configurationScope: String?,
                      body: @escaping @Sendable (RuntimeCommandEnvelopeJob) async -> RuntimeCommandResult) {
        G02DomainBinder.registerSubmitHandler(scope: scope, command: command,
                                              configurationScope: configurationScope)
        let key = BridgeV3.handlerKey(scope: scope, command: command)
        G02DomainBinder.registerProcessor(gen.registry, handlerKey: key, body: body)
        registeredHandlerKeys.append(key)
    }

    // MARK: - RB2 model/provider configuration (11)

    private func registerModelConfigurationCommands(
        gen: AndroidRuntimeBootstrap.Generation) {
        let router = modelConfigurationRouter
        for command in ModelConfigurationCommand.allCases {
            let name = command.rawValue
            let label: String
            switch command {
            case .providersList, .providerSave, .providerDelete, .providerProbe:
                label = "providers"
            case .modelsList, .modelSave:
                label = "models"
            case .catalogSearch:
                label = "catalog"
            case .preferencesGet, .preferencesSave:
                label = "preferences"
            case .websearchGet, .websearchSave:
                label = "settings.websearch"
            }
            bind(gen, scope: .applicationConfiguration, command: name,
                 configurationScope: label) { job in
                guard let envelope = G02DomainBinder.parseObject(job.envelope) else {
                    return G02DomainBinder.internalError()
                }
                let reply = await router.handle(command: name, envelope: envelope)
                return G02DomainBinder.resultFromRouterReply(reply)
            }
        }
    }

    // MARK: - RB6 capabilities / skills / MCP (7)

    private func registerCapabilitiesSkillsMcpCommands(
        gen: AndroidRuntimeBootstrap.Generation) {
        let capsRouter = capabilitiesRouter
        bind(gen, scope: .applicationConfiguration, command: "capability.tools.list",
             configurationScope: "capabilities") { job in
            guard let envelope = G02DomainBinder.parseObject(job.envelope) else {
                return G02DomainBinder.internalError()
            }
            return G02DomainBinder.resultFromRouterReply(
                await capsRouter.handle(command: "capability.tools.list", envelope: envelope))
        }
        let skRouter = skillsRouter
        bind(gen, scope: .applicationConfiguration, command: "skills.list",
             configurationScope: "skills") { job in
            guard let envelope = G02DomainBinder.parseObject(job.envelope) else {
                return G02DomainBinder.internalError()
            }
            return G02DomainBinder.resultFromRouterReply(
                await skRouter.handle(command: "skills.list", envelope: envelope))
        }
        bind(gen, scope: .applicationConfiguration, command: "skills.install",
             configurationScope: "skills") { job in
            guard let envelope = G02DomainBinder.parseObject(job.envelope) else {
                return G02DomainBinder.internalError()
            }
            return G02DomainBinder.resultFromRouterReply(
                await skRouter.handle(command: "skills.install", envelope: envelope))
        }
        bind(gen, scope: .applicationConfiguration, command: "skills.uninstall",
             configurationScope: "skills") { job in
            guard let envelope = G02DomainBinder.parseObject(job.envelope) else {
                return G02DomainBinder.internalError()
            }
            return G02DomainBinder.resultFromRouterReply(
                await skRouter.handle(command: "skills.uninstall", envelope: envelope))
        }
        let mcp = mcpRouter
        bind(gen, scope: .applicationConfiguration, command: "mcp.servers.list",
             configurationScope: "mcp") { job in
            guard let envelope = G02DomainBinder.parseObject(job.envelope) else {
                return G02DomainBinder.internalError()
            }
            return G02DomainBinder.resultFromRouterReply(
                await mcp.handle(command: "mcp.servers.list", envelope: envelope))
        }
        bind(gen, scope: .applicationConfiguration, command: "mcp.connect",
             configurationScope: "mcp") { job in
            guard let envelope = G02DomainBinder.parseObject(job.envelope) else {
                return G02DomainBinder.internalError()
            }
            return G02DomainBinder.resultFromRouterReply(
                await mcp.handle(command: "mcp.connect", envelope: envelope))
        }
        bind(gen, scope: .applicationConfiguration, command: "mcp.disconnect",
             configurationScope: "mcp") { job in
            guard let envelope = G02DomainBinder.parseObject(job.envelope) else {
                return G02DomainBinder.internalError()
            }
            return G02DomainBinder.resultFromRouterReply(
                await mcp.handle(command: "mcp.disconnect", envelope: envelope))
        }
    }

    // MARK: - RB3 conversation history (9)

    private func registerHistoryCommands(gen: AndroidRuntimeBootstrap.Generation) {
        let domain = conversationDomain
        bind(gen, scope: .applicationConfiguration, command: "conversation.list",
             configurationScope: "conversations") { job in
            do {
                let reply = try await domain.list(
                    payload: G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedWireObject(reply.wireObject)
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "conversation.search",
             configurationScope: "conversations") { job in
            do {
                let reply = try await domain.search(
                    payload: G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedWireObject(reply.wireObject)
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .launch, command: "conversation.create",
             configurationScope: nil) { job in
            do {
                let reply = try await domain.create(
                    payload: G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedWireObject(reply.wireObject)
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .conversationLifecycle, command: "conversation.get",
             configurationScope: nil) { job in
            guard let taskID = G02DomainBinder.taskID(job) else {
                return G02DomainBinder.wireError("invalidEnvelope",
                                                 reason: "missingTaskIdentity")
            }
            // Additive CLOSED detail variant (Main decision 2026-10-21):
            // absent `detail` keeps the legacy reply byte-identical; a
            // malformed detail is a typed envelope refusal BEFORE any read.
            let detail: ConversationDetailQuery?
            do {
                detail = try ConversationDetailQuery.parse(G02DomainBinder.settingsPayload(job))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
            do {
                let reply = try await domain.get(conversationID: taskID)
                guard let detail else {
                    return G02DomainBinder.completedWireObject(reply.wireObject)
                }
                var object = reply.wireObject
                let wire = try await domain.conversationDetail(conversationID: taskID,
                                                               query: detail)
                let fitted = try domain.fittingDetailPage(baseObject: object, wire: wire)
                object["detail"] = fitted.wireObject
                return G02DomainBinder.completedWireObject(object)
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .conversationLifecycle, command: "conversation.rename",
             configurationScope: nil) { job in
            guard let taskID = G02DomainBinder.taskID(job),
                  let revision = G02DomainBinder.baseRevision(job) else {
                return G02DomainBinder.wireError("invalidEnvelope",
                                                 reason: "missingRevisionForStatefulCommand")
            }
            do {
                let reply = try await domain.rename(
                    conversationID: taskID, revision: revision,
                    payload: G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedWireObject(reply.wireObject)
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .conversationLifecycle, command: "conversation.archive",
             configurationScope: nil) { job in
            guard let taskID = G02DomainBinder.taskID(job),
                  let revision = G02DomainBinder.baseRevision(job) else {
                return G02DomainBinder.wireError("invalidEnvelope",
                                                 reason: "missingRevisionForStatefulCommand")
            }
            do {
                let reply = try await domain.archive(
                    conversationID: taskID, revision: revision,
                    payload: G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedWireObject(reply.wireObject)
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .conversationLifecycle, command: "conversation.delete",
             configurationScope: nil) { job in
            guard let taskID = G02DomainBinder.taskID(job),
                  let revision = G02DomainBinder.baseRevision(job) else {
                return G02DomainBinder.wireError("invalidEnvelope",
                                                 reason: "missingRevisionForStatefulCommand")
            }
            do {
                let reply = try await domain.delete(conversationID: taskID,
                                                    revision: revision)
                return G02DomainBinder.completedWireObject(reply.wireObject)
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .conversationLifecycle, command: "conversation.messagePage",
             configurationScope: nil) { job in
            guard let taskID = G02DomainBinder.taskID(job) else {
                return G02DomainBinder.wireError("invalidEnvelope",
                                                 reason: "missingTaskIdentity")
            }
            do {
                let reply = try await domain.messagePage(
                    conversationID: taskID,
                    payload: G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedWireObject(reply.wireObject)
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .conversationLifecycle, command: "content.read",
             configurationScope: nil) { job in
            guard let taskID = G02DomainBinder.taskID(job) else {
                return G02DomainBinder.wireError("invalidEnvelope",
                                                 reason: "missingTaskIdentity")
            }
            do {
                let reply = try await domain.readContent(
                    conversationID: taskID,
                    payload: G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedWireObject(reply.wireObject)
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
    }

    // MARK: - Shared applicationConfiguration content.read (1 key, 2 labels)

    private func registerSharedContentRead(gen: AndroidRuntimeBootstrap.Generation) {
        // ONE binder key, TWO scoped processors (current RB1 registry API):
        // an unregistered label fails closed with the unchanged
        // runtimeUnavailable refusal — never a cross-domain read.
        let key = BridgeV3.handlerKey(scope: .applicationConfiguration,
                                      command: "content.read")
        G02DomainBinder.registerSubmitHandler(scope: .applicationConfiguration,
                                              command: "content.read",
                                              configurationScope: nil)
        let history = conversationDomain
        let reader = memoryContentReader
        G02DomainBinder.registerScopedProcessor(gen.registry, handlerKey: key,
                                                configurationScope: "conversations") { job in
            do {
                let reply = try await history.readContentFromConversationsLabel(
                    configurationScope: "conversations",
                    payload: G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedWireObject(reply.wireObject)
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode,
                                                 reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        G02DomainBinder.registerScopedProcessor(gen.registry, handlerKey: key,
                                                configurationScope: "personalization") { job in
            do {
                let outcome = try await reader.read(
                    configurationScope: "personalization",
                    payload: G02DomainBinder.settingsPayload(job) ?? .object([:]))
                switch outcome {
                case .personalizationChunk(let chunk):
                    return G02DomainBinder.completedEncodable(chunk)
                case .conversationsWireObject(let object):
                    return G02DomainBinder.completedValue(object)
                }
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode,
                                                 reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        registeredHandlerKeys.append(key)
    }

    // MARK: - RB3b memory (14)

    private func registerMemoryCommands(gen: AndroidRuntimeBootstrap.Generation) {
        let memory = memoryAdapter
        let organizer = memoryOrganizer
        @Sendable func revision(_ job: RuntimeCommandEnvelopeJob) -> String? {
            G02DomainBinder.baseRevision(job)?.version
        }
        bind(gen, scope: .applicationConfiguration, command: "memory.list",
             configurationScope: "memory") { job in
            do {
                let request = try MemoryListWireRequest.parse(
                    G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedEncodable(
                    try await memory.list(request))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "memory.get",
             configurationScope: "memory") { job in
            do {
                // The configuration scope forbids an owner; the entry id is
                // the closed payload `{"id": "<uuid>"}`.
                guard let object = G02DomainBinder.parseObject(job.envelope),
                      let payload = object["payload"] as? [String: Any],
                      let idString = payload["id"] as? String,
                      let id = UUID(uuidString: idString) else {
                    return G02DomainBinder.wireError("invalidEnvelope",
                                                     reason: "unknownMemoryField")
                }
                return G02DomainBinder.completedEncodable(
                    try await memory.get(id: id))
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "memory.add",
             configurationScope: "memory") { job in
            do {
                let request = try MemoryAddRequest.parse(
                    G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedEncodable(
                    try await memory.add(request))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "memory.update",
             configurationScope: "memory") { job in
            do {
                guard let version = revision(job) else {
                    return G02DomainBinder.wireError("missingRevisionForStatefulCommand",
                                                     reason: "revisionAbsent")
                }
                let request = try MemoryUpdateRequest.parse(
                    G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedEncodable(
                    try await memory.update(expectedRevision: version, request: request))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "memory.delete",
             configurationScope: "memory") { job in
            do {
                guard let version = revision(job) else {
                    return G02DomainBinder.wireError("missingRevisionForStatefulCommand",
                                                     reason: "revisionAbsent")
                }
                // The configuration scope forbids an owner; the entry id is
                // the closed payload `{"id": "<uuid>"}` (memory.get parity).
                guard let object = G02DomainBinder.parseObject(job.envelope),
                      let payload = object["payload"] as? [String: Any],
                      let idString = payload["id"] as? String,
                      let id = UUID(uuidString: idString) else {
                    return G02DomainBinder.wireError("invalidEnvelope",
                                                     reason: "unknownMemoryField")
                }
                return G02DomainBinder.completedEncodable(
                    try await memory.delete(expectedRevision: version, id: id))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "memory.delete.bulk",
             configurationScope: "memory") { job in
            do {
                let request = try MemoryBulkDeleteRequest.parse(
                    G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedEncodable(
                    try await memory.deleteBulk(request))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "memory.search",
             configurationScope: "memory") { job in
            do {
                let request = try MemorySearchWireRequest.parse(
                    G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedEncodable(
                    try await memory.search(request))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "memory.candidates.list",
             configurationScope: "memory") { job in
            do {
                let request = try MemoryCandidatesListRequest.parse(
                    G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedEncodable(
                    try await memory.candidatesPage(request))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "memory.candidate.resolve",
             configurationScope: "memory") { job in
            do {
                guard let version = revision(job) else {
                    return G02DomainBinder.wireError("missingRevisionForStatefulCommand",
                                                     reason: "revisionAbsent")
                }
                // Owner-less configuration scope: the candidate id rides the
                // closed payload (the App sends `{"id","activate"}`), exactly
                // like memory.get/delete — never the envelope owner.
                guard let object = G02DomainBinder.parseObject(job.envelope),
                      let payload = object["payload"] as? [String: Any],
                      let idString = payload["id"] as? String,
                      let id = UUID(uuidString: idString) else {
                    return G02DomainBinder.wireError("invalidEnvelope",
                                                     reason: "unknownMemoryField")
                }
                let activate = payload["activate"] as? Bool ?? true
                return G02DomainBinder.completedEncodable(
                    try await memory.resolveCandidate(expectedRevision: version,
                                                      id: id, activate: activate))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "memory.organize.start",
             configurationScope: "memory") { job in
            do {
                guard let payload = G02DomainBinder.settingsPayload(job) else {
                    return G02DomainBinder.wireError("invalidEnvelope",
                                                     reason: "invalidPayload")
                }
                // Closed P0 grammar was validated pre-dispatch; extract the
                // two authorized fields for the organizer start.
                var mode: SettingsDomainV1.OrganizeMode = .reviewFirst
                if case .object(let object) = payload,
                   case .string(let raw)? = object["mode"],
                   let parsed = SettingsDomainV1.OrganizeMode(rawValue: raw) {
                    mode = parsed
                }
                let includeSemantic = (G02DomainBinder.parseObject(job.envelope)?["payload"]
                    as? [String: Any])?["includeSemantic"] as? Bool ?? true
                // Carry the REAL typed effect: the proposal handle and the
                // scanned count the App needs for its proposal surface
                // (an identifier-only .accepted() made every start look
                // malformed although the scan ran).
                return G02DomainBinder.completedEncodable(
                    try await organizer.start(mode: mode, includeSemantic: includeSemantic,
                                              operationReceiptID: job.receipt))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "memory.organize.proposal.read",
             configurationScope: "memory") { job in
            do {
                let request = try MemoryProposalReadRequest.parse(
                    G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedEncodable(
                    try await organizer.proposalPage(request))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "memory.organize.apply",
             configurationScope: "memory") { job in
            do {
                let request = try MemoryOrganizeApplyRequest.parse(
                    G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedEncodable(
                    try await organizer.apply(request))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "memory.organize.cancel",
             configurationScope: "memory") { job in
            let reply = await organizer.cancel(operationReceiptID: job.receipt)
            if let reply {
                return G02DomainBinder.completedEncodable(reply)
            }
            return G02DomainBinder.wireError("operationReceiptUnknown",
                                             reason: "effectReceiptNotFound")
        }
    }

    // MARK: - RB3b personalization (7)

    private func registerPersonalizationCommands(gen: AndroidRuntimeBootstrap.Generation) {
        let adapter = personalizationAdapter
        let generate = personalizationGenerate
        bind(gen, scope: .applicationConfiguration, command: "personalization.get",
             configurationScope: "personalization") { job in
            do {
                let request = try PersonalizationGetRequest.parse(
                    G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedEncodable(
                    try await adapter.read(request))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "personalization.revision.read",
             configurationScope: "personalization") { job in
            do {
                let request = try PersonalizationRevisionReadRequest.parse(
                    G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedEncodable(
                    try await adapter.revisionRead(request))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "personalization.save",
             configurationScope: "personalization") { job in
            do {
                guard let token = G02DomainBinder.baseRevision(job)?.version else {
                    return G02DomainBinder.wireError("missingRevisionForStatefulCommand",
                                                     reason: "revisionAbsent")
                }
                let request = try PersonalizationSaveRequest.parse(
                    G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedEncodable(
                    try await adapter.save(expectedActiveToken: token, request: request))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "personalization.rollback",
             configurationScope: "personalization") { job in
            do {
                guard let token = G02DomainBinder.baseRevision(job)?.version else {
                    return G02DomainBinder.wireError("missingRevisionForStatefulCommand",
                                                     reason: "revisionAbsent")
                }
                let request = try PersonalizationRollbackRequest.parse(
                    G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedEncodable(
                    try await adapter.rollback(expectedActiveToken: token, request: request))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "personalization.automatic.set",
             configurationScope: "personalization") { job in
            do {
                guard let token = G02DomainBinder.baseRevision(job)?.version else {
                    return G02DomainBinder.wireError("missingRevisionForStatefulCommand",
                                                     reason: "revisionAbsent")
                }
                let request = try PersonalizationAutomaticRequest.parse(
                    G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedEncodable(
                    try await adapter.setAutomatic(expectedCursorToken: token,
                                                   request: request))
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "personalization.generate",
             configurationScope: "personalization") { job in
            do {
                guard let payload = G02DomainBinder.parseObject(job.envelope)?["payload"]
                        as? [String: Any],
                      let kindRaw = payload["kind"] as? String,
                      let kind = SettingsDomainV1.PersonalizationKind(rawValue: kindRaw) else {
                    return G02DomainBinder.wireError("invalidEnvelope",
                                                     reason: "invalidPayload")
                }
                let workspaceID = (payload["workspaceID"] as? String).flatMap(UUID.init(uuidString:))
                try await generate.generate(kind: kind, workspaceID: workspaceID,
                                            operationReceiptID: job.receipt)
                return .accepted()
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as MemoryAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as PersonalizationAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "personalization.generate.cancel",
             configurationScope: "personalization") { job in
            let reply = await generate.cancel(operationReceiptID: job.receipt)
            if let reply {
                return G02DomainBinder.completedEncodable(reply)
            }
            return G02DomainBinder.wireError("operationReceiptUnknown",
                                             reason: "effectReceiptNotFound")
        }
    }

    // MARK: - P6 defaults / usage (3)

    private func registerDefaultsUsageCommands(gen: AndroidRuntimeBootstrap.Generation) {
        let defaults = defaultsAdapter
        let usage = usageAdapter
        bind(gen, scope: .applicationConfiguration, command: "config.defaults.get",
             configurationScope: "settings.defaults") { _ in
            do {
                return G02DomainBinder.completedEncodable(try await defaults.read())
            } catch let error as SettingsDefaultsAdapterError {
                return G02DomainBinder.wireError(error.wireCode,
                                                 reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "config.defaults.save",
             configurationScope: "settings.defaults") { job in
            do {
                guard let version = G02DomainBinder.baseRevision(job)?.version else {
                    return G02DomainBinder.wireError("missingRevisionForStatefulCommand",
                                                     reason: "revisionAbsent")
                }
                let payload = G02DomainBinder.settingsPayload(job) ?? .object([:])
                try await defaults.save(expectedRevision: version, payload: payload)
                return .accepted()
            } catch let error as SettingsDefaultsAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bind(gen, scope: .applicationConfiguration, command: "usage.statistics.get",
             configurationScope: "usage") { job in
            do {
                let request = try UsageStatisticsRequest.parse(
                    G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedEncodable(try await usage.page(request))
            } catch let error as UsageStatisticsAdapterError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
    }
}

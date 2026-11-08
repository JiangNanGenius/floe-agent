#if canImport(UIKit)
import Foundation
import UIKit
import FloeExecution
import FloeSync

enum NativeExternalOAuthAppFailure: Error { case unavailable, changed, cancelled, stopUnconfirmed }

/// AppEnvironment owns one instance. Native pages and approved native
/// consumers reuse this composition; it is never an AgentTool/token endpoint.
@MainActor
final class NativeExternalOAuthAppIntegration {
    static let connectionKind = "oauth.external"
    struct Access: Sendable {
        let installationID: String
        let requirements: SkillConfigRequirements
        let authority: SkillRuntimeComponentAuthority
    }
    struct EnvironmentChoice: Sendable, Identifiable {
        let id: String
        let title: String
    }
    struct Services: Sendable {
        let configuration: SkillConfigurationService
        let connections: NativeExternalOAuthConnections?
        let authorize: @MainActor @Sendable (SkillConfigurationConnectionRequest) async throws -> Access
        let environments: @Sendable () async -> [EnvironmentChoice]
    }
    struct Saved: Sendable {
        let details: NativeExternalOAuthConnections.ConnectionDetails
        let status: NativeExternalOAuthLocalGrant.Status
    }
    private struct Operation {
        let ticket: NativeExternalOAuthLifecycle.Ticket
        let session: SystemOAuthAuthenticationSession
        let task: Task<Void, Error>
    }
    private let services: Services
    private let lifecycle = NativeExternalOAuthLifecycle()
    private var pages: [SkillConfigurationConnectionRequest: NativeExternalOAuthConnectionCenter] = [:]
    private var operation: Operation?
    /// Root may update native consumer choices after a binding changes. An
    /// in-place quiet refresh deliberately does not fire this callback.
    var onBindingChanged: (@MainActor @Sendable () async -> Void)?

    init(services: Services) { self.services = services }

    static func supports(_ request: SkillConfigurationConnectionRequest) -> Bool {
        request.connectionKind == connectionKind && request.fieldKey == "connection"
            && request.scope.target == "local-linux"
            && ["floe-google-auth", "floe-microsoft-auth"].contains(request.skillID)
    }

    func connectionCenter(for request: SkillConfigurationConnectionRequest) -> NativeExternalOAuthConnectionCenter? {
        guard Self.supports(request) else { return nil }
        if let page = pages[request] { return page }
        let page = NativeExternalOAuthConnectionCenter(request: request, integration: self)
        pages[request] = page
        return page
    }

    func environments() async -> [EnvironmentChoice] { await services.environments() }

    private func access(_ request: SkillConfigurationConnectionRequest) async throws -> Access {
        guard Self.supports(request), await lifecycle.allowsUse(skillID: request.skillID) else {
            throw NativeExternalOAuthAppFailure.changed
        }
        let value = try await services.authorize(request)
        guard await lifecycle.allowsUse(skillID: request.skillID) else { throw NativeExternalOAuthAppFailure.changed }
        return value
    }

    private func persistence(_ request: SkillConfigurationConnectionRequest, access expected: Access,
                             validateConsumer: @escaping @Sendable () async throws -> Void) -> SkillConfigurationOAuthVault {
        SkillConfigurationOAuthVault(service: services.configuration, skillID: request.skillID,
            installationID: expected.installationID, profile: request.scope.profile, target: request.scope.target,
            requirements: expected.requirements, validateAccess: { [weak self] in
                try await validateConsumer()
                guard let self else { throw NativeExternalOAuthAppFailure.cancelled }
                let current = try await self.access(request)
                guard current.installationID == expected.installationID, current.authority == expected.authority,
                      current.requirements == expected.requirements else { throw NativeExternalOAuthAppFailure.changed }
                try await validateConsumer()
            })
    }

    func saved(_ request: SkillConfigurationConnectionRequest) async throws -> Saved? {
        let authority = try await access(request)
        let snapshot = try await persistence(request, access: authority, validateConsumer: {}).snapshot()
        guard let payload = snapshot.payload else { return nil }
        guard let grant = try ExternalOAuthSavedGrant.decode(payload),
              case .linuxEnvironment(let environmentID) = grant.location,
              let credentialID = snapshot.credentialID, let revision = snapshot.revision else {
            throw NativeExternalOAuthAppFailure.changed
        }
        let state = try NativeExternalOAuthLocalGrant.inspect(payload, skillID: request.skillID,
            installationID: authority.installationID, profile: request.scope.profile, target: request.scope.target, now: Date())
        let reference = ExternalOAuthConnectionReference(skillID: request.skillID, installationID: authority.installationID,
            profile: request.scope.profile, target: request.scope.target, accountID: grant.accountID,
            credentialID: credentialID, revision: revision, partition: grant.partition)
        return .init(details: .init(reference: reference, client: grant.clientProfile, environmentID: environmentID), status: state)
    }

    func connect(_ request: SkillConfigurationConnectionRequest, draft: NativeExternalOAuthDraft,
                 session: SystemOAuthAuthenticationSession, anchor: UIWindow, ownerID: UUID) async throws {
        let client = try draft.profile()
        let previous = try await saved(request)
        try await execute(request, client: client, environmentID: draft.environmentID,
            accountID: previous?.details.reference.accountID ?? UUID(),
            clientSecret: draft.clientSecret.isEmpty ? nil : Data(draft.clientSecret.utf8),
            mode: .authorize, session: session, anchor: anchor, ownerID: ownerID, validateConsumer: {})
        try await validateSaved(request)
        await onBindingChanged?()
    }

    /// The same immutable binding is refreshed in place. This never calls
    /// signIn, reconfigures a Mail consumer, or chooses another environment.
    func quietRefresh(reference: ExternalOAuthConnectionReference,
                      validateConsumer: @escaping @Sendable () async throws -> Void, ownerID: UUID = UUID()) async throws {
        let request = Self.request(reference)
        try await validateConsumer()
        guard let saved = try await saved(request), saved.details.reference == reference else {
            throw NativeExternalOAuthAppFailure.changed
        }
        try await execute(request, client: saved.details.client, environmentID: saved.details.environmentID,
            accountID: reference.accountID, clientSecret: nil, mode: .refresh,
            session: SystemOAuthAuthenticationSession(), anchor: nil, ownerID: ownerID, validateConsumer: validateConsumer)
        try await validateReference(reference, validateConsumer: validateConsumer)
        try await validateSaved(request)
    }

    private func execute(_ request: SkillConfigurationConnectionRequest, client: ExternalOAuthClientProfile,
                         environmentID: String, accountID: UUID, clientSecret: Data?,
                         mode: ExternalOAuthVaultAdapter.Operation, session: SystemOAuthAuthenticationSession,
                         anchor: UIWindow?, ownerID: UUID, validateConsumer: @escaping @Sendable () async throws -> Void) async throws {
        guard let connections = services.connections else { throw NativeExternalOAuthAppFailure.unavailable }
        try Task.checkCancellation()
        let authority = try await access(request)
        let ticket = try await lifecycle.begin(.init(skillID: request.skillID, profile: request.scope.profile, target: request.scope.target), ownerID: ownerID)
        let task = Task { [self] in
            var failure: (any Error)?
            do {
                let input = NativeExternalOAuthConnections.Input(ownerID: ticket.id, skillID: request.skillID, profile: request.scope.profile,
                    target: request.scope.target, environmentID: environmentID, accountID: accountID,
                    client: client, clientSecret: clientSecret, requirements: authority.requirements,
                    validateUse: { [lifecycle] in
                        try await validateConsumer()
                        guard await lifecycle.isCurrent(ticket) else { throw NativeExternalOAuthAppFailure.cancelled }
                    })
                let prepared = try await connections.prepare(input, operation: mode)
                try await validateConsumer()
                guard await lifecycle.isCurrent(ticket), !Task.isCancelled else { throw NativeExternalOAuthAppFailure.cancelled }
                let started: Bool
                switch mode {
                case .authorize:
                    guard let anchor else { throw NativeExternalOAuthAppFailure.unavailable }
                    started = session.signIn(context: prepared.context, transport: prepared.transport, anchor: anchor)
                case .refresh:
                    started = session.refresh(context: prepared.context, transport: prepared.transport)
                }
                guard started else { throw NativeExternalOAuthAppFailure.unavailable }
                let state = await withTaskCancellationHandler {
                    await session.waitUntilFinished()
                } onCancel: {
                    Task { @MainActor in await session.cancelAndJoin() }
                }
                if case .failed(let reason) = state { throw reason }
                try await validateConsumer()
                guard state == .connected, await lifecycle.isCurrent(ticket), !Task.isCancelled else {
                    throw NativeExternalOAuthAppFailure.cancelled
                }
            } catch { failure = error }
            await session.cancelAndJoin()
            let stopped = await connections.finish(skillID: request.skillID, ownerID: ticket.id)
            guard await lifecycle.retire(ticket, stopped: stopped) else { throw NativeExternalOAuthAppFailure.stopUnconfirmed }
            if operation?.ticket == ticket { operation = nil }
            if let failure { throw failure }
        }
        operation = Operation(ticket: ticket, session: session, task: task)
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func stop(_ request: SkillConfigurationConnectionRequest? = nil, skillID: String? = nil, ownerID: UUID? = nil) async -> Bool {
        guard let owned = operation else { return true }
        if let ownerID, owned.ticket.id != ownerID { return true }
        if let request, owned.ticket.scope != .init(skillID: request.skillID, profile: request.scope.profile, target: request.scope.target) { return true }
        if let skillID, owned.ticket.scope.skillID != skillID { return true }
        owned.task.cancel()
        await owned.session.cancelAndJoin()
        _ = await owned.task.result
        // A previous unconfirmed cleanup leaves the exact ticket and lease
        // retained. A later Cancel retries it; stale pages cannot stop a new one.
        guard operation?.ticket == owned.ticket else { return true }
        let stopped = await services.connections?.finish(skillID: owned.ticket.scope.skillID, ownerID: owned.ticket.id) ?? true
        guard await lifecycle.retire(owned.ticket, stopped: stopped) else { return false }
        if operation?.ticket == owned.ticket { operation = nil }
        return true
    }

    func beginMutation(skillID: String, fields: Set<String>?) async throws -> SkillConfigurationMutationLease? {
        guard ["floe-google-auth", "floe-microsoft-auth"].contains(skillID),
              fields == nil || fields!.contains(where: { $0.lowercased() == "connection" }) else { return nil }
        let id = await lifecycle.beginMutation(skillID: skillID)
        guard await stop(skillID: skillID) else {
            await lifecycle.finishMutation(skillID: skillID, id: id)
            throw NativeExternalOAuthAppFailure.stopUnconfirmed
        }
        return .init(finish: { [lifecycle] in await lifecycle.finishMutation(skillID: skillID, id: id) })
    }

    func disconnect(_ request: SkillConfigurationConnectionRequest) async throws {
        let access = try await access(request)
        let mutation = try await beginMutation(skillID: request.skillID, fields: ["connection"])
        do {
            try Task.checkCancellation()
            let status = try await services.configuration.inspect(skillID: request.skillID, profile: request.scope.profile,
                target: request.scope.target, requirements: access.requirements)
            let outcome = try await services.configuration.unconfigure(skillID: request.skillID, profile: request.scope.profile,
                target: request.scope.target, fieldKeys: ["connection"], requirements: access.requirements, expectedRevision: status.revision)
            await mutation?.finish()
            guard outcome.warnings.isEmpty else { throw NativeExternalOAuthAppFailure.changed }
            await onBindingChanged?()
        } catch { await mutation?.finish(); throw error }
    }

    func configurationDidMutate(skillID: String, fields: Set<String>?) async {
        guard ["floe-google-auth", "floe-microsoft-auth"].contains(skillID),
              fields == nil || fields!.contains(where: { $0.lowercased() == "connection" }) else { return }
        for (request, page) in pages where request.skillID == skillID { await page.reload(restoreDraft: false) }
        await onBindingChanged?()
    }

    func validateSaved(_ request: SkillConfigurationConnectionRequest) async throws {
        let value = try await access(request)
        _ = try await services.configuration.validate(skillID: request.skillID, profile: request.scope.profile,
            target: request.scope.target, requirements: value.requirements, fieldKeys: ["connection"])
    }

    func validateValidationRequest(_ request: SkillConfigurationValidationRequest, payload: Data?) async throws {
        let route = SkillConfigurationConnectionRequest(skillID: request.skillID,
            scope: .init(profile: request.profile, target: request.target), fieldKey: request.fieldKey, connectionKind: request.connectionKind)
        let value = try await access(route)
        let current = try await services.configuration.readConnectionPayload(skillID: request.skillID,
            profile: request.profile, target: request.target, fieldKey: "connection", connectionKind: Self.connectionKind,
            requirements: value.requirements)
        guard value.installationID == request.installationID, current.installationID == request.installationID,
              current.revision == request.revision, payload == nil || current.payload == payload else {
            throw NativeExternalOAuthAppFailure.changed
        }
    }

    func validateReference(_ reference: ExternalOAuthConnectionReference,
                           validateConsumer: @escaping @Sendable () async throws -> Void) async throws {
        try await validateConsumer()
        guard let current = try await saved(Self.request(reference)), current.details.reference == reference else {
            throw NativeExternalOAuthAppFailure.changed
        }
        try await validateConsumer()
    }

    func makeReader(reference: ExternalOAuthConnectionReference,
                    validateConsumer: @escaping @Sendable () async throws -> Void) async throws -> ExternalOAuthNativeTokenReader {
        try await validateReference(reference, validateConsumer: validateConsumer)
        let request = Self.request(reference)
        let value = try await access(request)
        let validate: @Sendable () async throws -> Void = { [weak self] in
            guard let self else { throw NativeExternalOAuthAppFailure.cancelled }
            try await self.validateReference(reference, validateConsumer: validateConsumer)
        }
        return .init(persistence: persistence(request, access: value, validateConsumer: validate), validateConsumer: validate)
    }

    private static func request(_ reference: ExternalOAuthConnectionReference) -> SkillConfigurationConnectionRequest {
        .init(skillID: reference.skillID, scope: .init(profile: reference.profile, target: reference.target),
              fieldKey: "connection", connectionKind: connectionKind)
    }
}
#endif

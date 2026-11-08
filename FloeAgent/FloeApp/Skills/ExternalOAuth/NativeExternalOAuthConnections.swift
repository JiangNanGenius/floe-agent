#if canImport(UIKit)
import Foundation
import FloeCore
import FloeEnvironments
import FloeExecution
import FloeSkills
import FloeSync
import FloeTools

/// App-owned composition for the existing native connection page. All
/// dependencies come from AppEnvironment; constructing it starts no worker.
actor NativeExternalOAuthConnections {
    typealias ManagementLease = @Sendable (String, CancellationToken) async throws -> ToolEnvironmentLease
    typealias Authority = @Sendable (String) async -> SkillRuntimeComponentAuthority?
    typealias EnvironmentCheck = @Sendable (String) async -> Bool

    struct Input: Sendable {
        let ownerID: UUID
        let skillID: String
        let profile: String
        let target: String
        let environmentID: String
        let accountID: UUID
        let client: ExternalOAuthClientProfile
        let clientSecret: Data?
        let requirements: SkillConfigRequirements
        let validateUse: @Sendable () async throws -> Void
    }
    struct Prepared: Sendable {
        let operationID: UUID
        let context: ExternalOAuthCredentialContext
        let transport: OrtieOAuthPluginTransport
    }
    struct ConnectionDetails: Sendable {
        let reference: ExternalOAuthConnectionReference
        let client: ExternalOAuthClientProfile
        let environmentID: String
    }
    private struct Entry {
        let reservation: UUID
        let lifetime: NativeExternalOAuthLifetime
        let task: Task<Prepared, Error>
    }
    private let configuration: SkillConfigurationService
    private let runtimes: SkillRuntimeComponentCenter
    private let workers: any LinuxGuestOAuthPrivateWorkerManaging
    private let managementLease: ManagementLease
    private let authority: Authority
    private let environmentCheck: EnvironmentCheck
    private var entry: Entry?

    init(configuration: SkillConfigurationService, runtimes: SkillRuntimeComponentCenter,
         workers: any LinuxGuestOAuthPrivateWorkerManaging,
         managementLease: @escaping ManagementLease, authority: @escaping Authority,
         environmentCheck: @escaping EnvironmentCheck) {
        self.configuration = configuration; self.runtimes = runtimes; self.workers = workers
        self.managementLease = managementLease; self.authority = authority; self.environmentCheck = environmentCheck
    }

    /// Native settings restore the validated client/environment and opaque
    /// binding without exposing either token or client secret to the view.
    /// A stopped Linux guest is not required for this native read.
    func connectionDetails(skillID: String, profile: String, target: String,
                           requirements: SkillConfigRequirements) async throws -> ConnectionDetails {
        guard target == "local-linux", ["floe-google-auth", "floe-microsoft-auth"].contains(skillID),
              let expectedAuthority = await authority(skillID) else { throw ExternalOAuthFailure.invalidAuthorization }
        let status = try await configuration.inspect(skillID: skillID, profile: profile, target: target, requirements: requirements)
        guard let installation = status.installation, status.installed, !status.sourceChanged,
              installation.configurationAllowed else { throw ExternalOAuthFailure.storageUnavailable }
        let persistence = SkillConfigurationOAuthVault(service: configuration, skillID: skillID,
            installationID: installation.installationID, profile: profile, target: target, requirements: requirements,
            validateAccess: { [authority] in
                guard await authority(skillID) == expectedAuthority else { throw ExternalOAuthFailure.invalidAuthorization }
            })
        let snapshot = try await persistence.snapshot()
        guard let grant = try ExternalOAuthSavedGrant.decode(snapshot.payload),
              case .linuxEnvironment(let environmentID) = grant.location,
              let credentialID = snapshot.credentialID, let revision = snapshot.revision,
              skillID == (grant.clientProfile.provider == .google ? "floe-google-auth" : "floe-microsoft-auth") else {
            throw ExternalOAuthFailure.storageUnavailable
        }
        let context = try ExternalOAuthCredentialContext(connectorID: skillID, installationID: installation.installationID,
            profile: profile, accountID: grant.accountID, location: grant.location, client: grant.clientProfile)
        guard context.vaultPartition == grant.partition else { throw ExternalOAuthFailure.storageUnavailable }
        return .init(reference: .init(skillID: skillID, installationID: installation.installationID, profile: profile,
            target: target, accountID: grant.accountID, credentialID: credentialID, revision: revision, partition: grant.partition),
            client: grant.clientProfile, environmentID: environmentID)
    }

    /// Foreground connect and quiet refresh share one owner. A refresh never
    /// displaces an in-progress sign-in. Reconnect first awaits finish().
    func prepare(_ input: Input, operation: ExternalOAuthVaultAdapter.Operation) async throws -> Prepared {
        guard entry == nil else { throw ExternalOAuthFailure.pluginUnavailable }
        let lifetime = NativeExternalOAuthLifetime(input: input, operation: operation,
            configuration: configuration, runtimes: runtimes, workers: workers,
            managementLease: managementLease, authority: authority, environmentCheck: environmentCheck)
        let reservation = UUID()
        let task = Task { try await lifetime.prepare() }
        entry = Entry(reservation: reservation, lifetime: lifetime, task: task)
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: {
                task.cancel()
                lifetime.cancellation.cancel()
            }
        } catch {
            let closed = await lifetime.close()
            if closed, entry?.reservation == reservation { entry = nil }
            throw error as? ExternalOAuthFailure ?? .pluginUnavailable
        }
    }

    /// Call after SystemOAuthAuthenticationSession.waitUntilFinished(), and
    /// before leaving/reconnect/unconfigure/uninstall/disable. False retains
    /// the lease and blocks replacement; it must not be reported as stopped.
    func finish(skillID: String? = nil, ownerID: UUID? = nil) async -> Bool {
        guard let owned = entry else { return true }
        if let skillID, owned.lifetime.skillID != skillID { return true }
        if let ownerID, owned.lifetime.ownerID != ownerID { return true }
        owned.lifetime.cancellation.cancel(); owned.task.cancel()
        _ = await owned.task.result
        let closed = await owned.lifetime.close()
        if closed, entry?.reservation == owned.reservation { entry = nil }
        return closed
    }
}

private actor NativeExternalOAuthLifetime {
    nonisolated let cancellation = CancellationToken()
    nonisolated let skillID: String
    nonisolated let ownerID: UUID
    private let input: NativeExternalOAuthConnections.Input
    private let operation: ExternalOAuthVaultAdapter.Operation
    private let configuration: SkillConfigurationService
    private let runtimes: SkillRuntimeComponentCenter
    private let workers: any LinuxGuestOAuthPrivateWorkerManaging
    private let managementLease: NativeExternalOAuthConnections.ManagementLease
    private let authorityProvider: NativeExternalOAuthConnections.Authority
    private let environmentCheck: NativeExternalOAuthConnections.EnvironmentCheck
    private var lease: ToolEnvironmentLease?
    private var authority: SkillRuntimeComponentAuthority?
    private var installationID: String?
    private var nativeOperation: SkillRuntimeComponentCenter.OAuthNativeOperation?
    private var prepared: SkillRuntimeComponentCenter.OAuthPrepared?
    private var vault: ExternalOAuthVaultAdapter?
    private var transport: OrtieOAuthPluginTransport?
    private var ownershipKey: String?
    private var active = true
    private var closing: Task<Bool, Never>?
    private var cancellationWatch: Task<Void, Never>?

    init(input: NativeExternalOAuthConnections.Input, operation: ExternalOAuthVaultAdapter.Operation,
         configuration: SkillConfigurationService, runtimes: SkillRuntimeComponentCenter,
         workers: any LinuxGuestOAuthPrivateWorkerManaging,
         managementLease: @escaping NativeExternalOAuthConnections.ManagementLease,
         authority: @escaping NativeExternalOAuthConnections.Authority,
         environmentCheck: @escaping NativeExternalOAuthConnections.EnvironmentCheck) {
        self.input = input; skillID = input.skillID; ownerID = input.ownerID; self.operation = operation; self.configuration = configuration
        self.runtimes = runtimes; self.workers = workers; self.managementLease = managementLease
        authorityProvider = authority; self.environmentCheck = environmentCheck
    }

    func prepare() async throws -> NativeExternalOAuthConnections.Prepared {
        guard active, !cancellation.isCancelled, input.target == "local-linux",
              input.skillID == (input.client.provider == .google ? "floe-google-auth" : "floe-microsoft-auth"),
              let authority = await authorityProvider(input.skillID),
              let manifestBytes = authority.packageFiles["floe.json"],
              let manifest = try? JSONDecoder().decode(SkillManifest.self, from: manifestBytes),
              manifest.id == input.skillID,
              let declaration = manifest.configuration, declaration.fields.count == 1,
              declaration.fields[0].key == "connection", declaration.fields[0].kind == .connection,
              declaration.fields[0].connectionKind == "oauth.external",
              input.requirements.fields.count == 1,
              input.requirements.field("connection")?.kind == .connection,
              input.requirements.field("connection")?.connectionKind == "oauth.external",
              input.requirements.environment.isEmpty else { throw ExternalOAuthFailure.invalidAuthorization }
        _ = try input.requirements.validated()
        self.authority = authority
        let acquired = try await managementLease(input.environmentID, cancellation)
        lease = acquired
        cancellationWatch = Task { [weak self, cancellation] in
            while !cancellation.isCancelled && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            if !Task.isCancelled { _ = await self?.close() }
        }
        guard acquired.context.environmentID == input.environmentID,
              acquired.context.environment?.id == input.environmentID else { throw ExternalOAuthFailure.invalidAuthorization }
        let status = try await configuration.inspect(skillID: input.skillID, profile: input.profile,
            target: input.target, requirements: input.requirements)
        guard let installation = status.installation, status.installed, !status.sourceChanged,
              installation.configurationAllowed else { throw ExternalOAuthFailure.storageUnavailable }
        installationID = installation.installationID
        let operation = SkillRuntimeComponentCenter.OAuthNativeOperation(operationID: acquired.context.runID,
            environmentID: input.environmentID, cancellation: cancellation,
            isCurrentAndApproved: { [weak self] id, environmentID, authority, token in
                guard let self, !token.isCancelled else { return false }
                return await self.isCurrent(id: id, environmentID: environmentID, authority: authority)
            })
        nativeOperation = operation
        // Serializes a binding even if rekey changes account/client/env.
        let key = FloeDigest.sha256Hex(try JSONEncoder().encode([
            input.skillID, installation.installationID, input.profile, input.target, "connection"]))
        ownershipKey = key
        try await validateBinding()
        let probe = SkillOAuthRuntimeMCPProbe.make(opener: workers) { [input] request in
            .init(environmentID: input.environmentID, ownershipKey: key,
                  executablePath: request.executableGuestPath, executableSHA256: request.executableSHA256,
                  account: "floe", configurationTOML: try OrtieOAuthPluginTransport.configuration(client: input.client, redirect: nil),
                  readToken: { nil }, writeToken: { _ in throw ExternalOAuthFailure.invalidAuthorization },
                  invalidateAndJoin: {})
        }
        let runtime = try await runtimes.prepareOAuthRuntime(authority: authority, nativeOperation: operation, probe: probe)
        prepared = runtime
        try await validateCredentialAccess()
        let context = try ExternalOAuthCredentialContext(connectorID: input.skillID,
            installationID: installation.installationID, profile: input.profile, accountID: input.accountID,
            location: .linuxEnvironment(input.environmentID), client: input.client)
        let persistence = SkillConfigurationOAuthVault(service: configuration, skillID: input.skillID,
            installationID: installation.installationID, profile: input.profile, target: input.target,
            requirements: input.requirements, validateAccess: { [weak self] in
                guard let self else { throw ExternalOAuthFailure.cancelled }
                try await self.validateCredentialAccess()
            })
        let vault = try ExternalOAuthVaultAdapter(context: context, persistence: persistence,
            operation: self.operation, clientSecret: input.clientSecret)
        self.vault = vault
        let bridge = LinuxOrtieWorkerBridge(service: workers, environmentID: input.environmentID,
            executablePath: runtime.executableGuestPath, executableSHA256: runtime.descriptor.artifact.sha256,
            validateAuthority: { [weak self] in
                guard let self else { throw ExternalOAuthFailure.cancelled }
                try await self.validateCredentialAccess()
            })
        let transport = try OrtieOAuthPluginTransport(context: context, vault: vault,
            opener: bridge, ownershipKey: key, handshake: runtime.metadata.handshakeBytes)
        self.transport = transport
        return .init(operationID: acquired.context.runID, context: context, transport: transport)
    }

    private func isCurrent(id: UUID, environmentID: String, authority: SkillRuntimeComponentAuthority) async -> Bool {
        guard lease?.context.runID == id, input.environmentID == environmentID, self.authority == authority else { return false }
        do { try await validateBinding(); return true } catch { return false }
    }

    private func validateBinding() async throws {
        try await input.validateUse()
        guard active, !cancellation.isCancelled, !Task.isCancelled,
              let lease, lease.context.environmentID == input.environmentID,
              let authority, await authorityProvider(input.skillID) == authority,
              await environmentCheck(input.environmentID), let installationID else {
            throw ExternalOAuthFailure.cancelled
        }
        let status = try await configuration.inspect(skillID: input.skillID, profile: input.profile,
            target: input.target, requirements: input.requirements)
        guard active, !cancellation.isCancelled, status.installed, !status.sourceChanged,
              status.installation?.installationID == installationID,
              status.installation?.configurationAllowed == true else { throw ExternalOAuthFailure.storageUnavailable }
        try await input.validateUse()
        // The vault adapter additionally compares the current revision,
        // credentialID AND payload on every read/write; save/refresh use the
        // existing service's revision/binding CAS, never a second store.
    }

    private func validateCredentialAccess() async throws {
        try await validateBinding()
        guard let prepared, let nativeOperation else { throw ExternalOAuthFailure.pluginUnavailable }
        try await runtimes.validateOAuthPreparedForUse(prepared, operation: nativeOperation)
        try await validateBinding()
    }

    func close() async -> Bool {
        if let closing { return await closing.value }
        active = false; cancellation.cancel()
        cancellationWatch?.cancel(); cancellationWatch = nil
        let task = Task { () -> Bool in
            if let nativeOperation { await runtimes.cancelOAuthRuntimeOperation(nativeOperation.operationID) }
            await vault?.invalidateAndJoin()
            if let transport, !(await transport.stopAndConfirm()) { return false }
            if let ownershipKey, !(await workers.stopOAuthPrivateWorkers(environmentID: input.environmentID, ownershipKey: ownershipKey)) {
                return false
            }
            await lease?.finish()
            lease = nil; vault = nil; transport = nil; prepared = nil
            return true
        }
        closing = task
        let result = await task.value
        if !result { closing = nil }
        return result
    }
}
#endif

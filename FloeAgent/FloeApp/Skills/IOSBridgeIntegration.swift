// FloeApp — optional local iOS Bridge automation integration.
//
// This is the App-owned seam between the compiled `FloeIOSAutomation` client,
// the generic Skill configuration/credential service and the task lifecycle.
// It owns exactly one native client per installed profile so persistent device
// input ownership is shared by the tool surface and the connection page. It
// creates no second vault, no second approval store and no shell/MCP fallback.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import UIKit
import FloeCore
import FloePersistence
import FloeSecurity
import FloeSkills
import FloeSync
import FloeTools
import FloeIOSAutomation

/// Package-declared activation facts for the optional local automation Skill.
struct IOSBridgeSkillActivation: Sendable, Equatable {
    var installed: Bool
    var enabled: Bool
    var grantsAllowed: Bool
    var configurationAllowed: Bool
    var sourceChanged: Bool
    var hasConnectionField: Bool
    var readiness: SkillConfigurationReadiness
}

/// Pure projection of which compiled surfaces are actually usable. It is a
/// discoverability hint only: every execute path re-reads the live state and
/// the canonical task authority.
struct IOSBridgeToolAvailability: Sendable, Equatable {
    var status: Bool
    var pair: Bool
    var observeControl: Bool
}

/// Credential-reference policy for `ios.bridge.control` `type.text`.
///
/// Ordinary text (including a raw user-supplied password) is passed through
/// unchanged. A `⟨credential:id⟩` reference is different: it must be either
/// the exact per-call capture this run's normalizer produced for the control
/// tool's `text` field, or an explicit ordinary vault card the user created.
/// It must never resolve a Skill-bound connection credential (including the
/// local Bridge pairing key), a device-bound secret, a host-bound credential,
/// a capture from another run/tool/path, or a malformed reference.
enum IOSBridgeTextCredentialPolicy {
    static let textFieldPath = "text"
    static let inputCompatibleKinds: Set<CredentialKind> = [
        .websitePassword, .genericToken, .providerAPIKey
    ]

    static func allows(
        record: CredentialRecord,
        runID: UUID,
        bindingCount: Int
    ) -> Bool {
        guard bindingCount == 0,
              !record.deviceBound,
              record.hostID == nil else { return false }
        if CredentialCaptureReference.isAuthorizedCapture(
            record,
            runID: runID,
            toolName: IOSBridgeToolNames.control,
            fieldPath: textFieldPath
        ) {
            return true
        }
        guard record.owner == .vault,
              inputCompatibleKinds.contains(record.kind) else { return false }
        guard let origin = record.origin else { return true }
        if origin.hasPrefix(CredentialCaptureReference.originPrefix) { return false }
        if origin.hasPrefix("skill-connection:") || origin.hasPrefix("skill-config:") {
            return false
        }
        return true
    }
}

@MainActor
final class IOSBridgeIntegration {
    nonisolated static let skillID = "floe-ios-automation"
    nonisolated static let connectionFieldKey = "bridge"
    nonisolated static let connectionKind = "ios.bridge.local"
    nonisolated static let validatorIdentifier = "ios.bridge.local.rpc.v1"
    nonisolated static let defaultProfile = "default"
    nonisolated static let nativeTarget = SkillConfigurationTargets.localIOS

    private unowned let environment: AppEnvironment
    private var clients: [String: IOSBridgeClient] = [:]
    private var connectionCenters: [String: IOSBridgeConnectionCenter] = [:]
    /// Most recent real status probe used only for catalog discovery. Tool
    /// execution always performs its own live check.
    private var readinessCache: (ready: Bool, checkedAt: Date)?
    /// Native-only task/generation bookkeeping for the persistent device-input
    /// owner. Values never come from model arguments.
    private var activeRunGenerations: [UUID: [String: UInt64]] = [:]
    /// Bounded background hold expiry. Foreground has no timer.
    nonisolated(unsafe) private var backgroundExpiryTask: Task<Void, Never>?
    nonisolated(unsafe) private var protectedDataObserver: NSObjectProtocol?

    init(environment: AppEnvironment) {
        self.environment = environment
        // The device-bound Keychain item is unreadable while protected data is
        // unavailable. Fence every in-flight callback immediately: a mutation
        // that already reached Bridge is reported unknown, never retried.
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fenceAll(reason: "device-locked")
            }
        }
    }

    deinit {
        backgroundExpiryTask?.cancel()
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(protectedDataObserver)
        }
    }

    // MARK: - Clients / connection centers

    /// One actor per exact profile. Device input ownership is actor-local, so
    /// tools and the configuration page MUST share this instance.
    func client(profile: String = IOSBridgeIntegration.defaultProfile) -> IOSBridgeClient? {
        if let existing = clients[profile] { return existing }
        guard LocalBridgePlatform.current.supportsIOSAutomation,
              let store = try? IOSBridgePairingStoreAdapter(
                service: environment.skillConfigurationService,
                configurations: environment.skillConfigurationStore,
                skillStore: environment.skillStore,
                profile: profile
              ) else {
            return nil
        }
        let client = IOSBridgeClient(configuration: .init(
            store: store,
            platformAllowsLocalAutomation: LocalBridgePlatform.current.supportsIOSAutomation,
            pairingHandle: store.handle,
            transport: IOSBridgeURLSessionTransport(),
            // The per-call context always supplies the real task authority.
            // This client-wide value is the fail-closed default for reads.
            authority: ReadOnlyIOSAutomationAuthority(),
            // Released Bridge 1.0 has no URL scheme. Unknown presence is
            // honest; a refused socket alone is not proof of absence.
            companionProbe: nil,
            policy: Self.protectionPolicy(floeBundleIdentifier: Bundle.main.bundleIdentifier)
        ))
        clients[profile] = client
        return client
    }

    static func protectionPolicy(floeBundleIdentifier: String?) -> IOSAutomationProtectionPolicy {
        var policy = IOSAutomationProtectionPolicy.default
        if let identifier = floeBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !identifier.isEmpty {
            policy.protectedMutationBundleIdentifiers.insert(identifier.lowercased())
        }
        return policy
    }

    func connectionCenter(
        for request: SkillConfigurationConnectionRequest
    ) -> IOSBridgeConnectionCenter? {
        guard request.skillID == Self.skillID,
              request.connectionKind == Self.connectionKind,
              request.scope.target == Self.nativeTarget,
              LocalBridgePlatform.current.supportsIOSAutomation,
              let client = client(profile: request.scope.profile) else {
            return nil
        }
        let key = "\(request.scope.profile)|\(request.scope.target)"
        if let existing = connectionCenters[key] { return existing }
        let center = IOSBridgeConnectionCenter(client: client)
        connectionCenters[key] = center
        return center
    }

    var defaultClientName: String {
        IOSBridgeConnectionCenter.defaultClientName
    }

    // MARK: - Skill activation / requirements

    func requirements() async throws -> SkillConfigRequirements {
        try await IOSBridgeSkillManifest.requirements(
            skillID: Self.skillID,
            skillStore: environment.skillStore
        )
    }

    func skillActivation() async -> IOSBridgeSkillActivation? {
        guard let skill = try? await environment.skillStore.skill(id: Self.skillID) else {
            return nil
        }
        let manifest = try? IOSBridgeSkillManifest.manifest(for: skill)
        let grants = (try? await environment.skillStore.allowedCapabilities(skillID: Self.skillID))
            ?? []
        let grantsAllowed = manifest.map {
            Set($0.capabilities).isSubset(of: grants)
        } ?? false
        let requirements = try? IOSBridgeSkillManifest.requirements(for: skill)
        let hasConnectionField = requirements?.field(Self.connectionFieldKey).map {
            $0.kind == .connection && $0.connectionKind == Self.connectionKind
        } ?? false
        let configuration = try? await environment.skillConfigurationService.inspect(
            skillID: Self.skillID,
            profile: Self.defaultProfile,
            target: Self.nativeTarget,
            requirements: requirements ?? SkillConfigRequirements()
        )
        return IOSBridgeSkillActivation(
            installed: true,
            enabled: skill.status == "enabled",
            grantsAllowed: grantsAllowed,
            configurationAllowed: configuration?.installation?.configurationAllowed == true,
            sourceChanged: configuration?.sourceChanged == true,
            hasConnectionField: hasConnectionField,
            readiness: configuration?.readiness ?? .needsSetup
        )
    }

    nonisolated static func toolAvailability(
        for activation: IOSBridgeSkillActivation
    ) -> IOSBridgeToolAvailability {
        let status = activation.installed && activation.enabled
        let pair = status
            && activation.grantsAllowed
            && activation.configurationAllowed
            && !activation.sourceChanged
            && activation.hasConnectionField
        return IOSBridgeToolAvailability(
            status: status,
            pair: pair,
            observeControl: pair && activation.readiness == .ready
        )
    }

    // MARK: - Discovery

    /// Returns the FULL current executable catalog set minus the local Bridge
    /// names that are not actually usable. `ToolRunnerRegistry` already
    /// filters its own unavailable dynamic sources; this method only narrows
    /// `ios.bridge.*` and never grants authority.
    func discoverableToolNames(from allNames: Set<String>) async -> Set<String> {
        var available = allNames
        available.subtract(IOSBridgeToolNames.all)
        guard LocalBridgePlatform.current.supportsIOSAutomation,
              let activation = await skillActivation() else {
            return available
        }
        let usability = Self.toolAvailability(for: activation)
        if usability.status, allNames.contains(IOSBridgeToolNames.status) {
            available.insert(IOSBridgeToolNames.status)
        }
        if usability.pair, allNames.contains(IOSBridgeToolNames.pair) {
            available.insert(IOSBridgeToolNames.pair)
        }
        if usability.observeControl,
           allNames.contains(IOSBridgeToolNames.observe),
           allNames.contains(IOSBridgeToolNames.control),
           await bridgeIsReady() {
            available.insert(IOSBridgeToolNames.observe)
            available.insert(IOSBridgeToolNames.control)
        }
        return available
    }

    func bridgeIsReady(
        profile: String = IOSBridgeIntegration.defaultProfile,
        force: Bool = false
    ) async -> Bool {
        let now = Date()
        if !force,
           let readinessCache,
           now.timeIntervalSince(readinessCache.checkedAt) < 5 {
            return readinessCache.ready
        }
        guard let client = client(profile: profile) else { return false }
        let snapshot = await client.status()
        let ready = snapshot.status == .ready
        readinessCache = (ready, now)
        return ready
    }

    func deviceSurfaceIsCurrentlyEnabled(
        _ surface: IOSAutomationToolSurface
    ) async -> Bool {
        guard surface == .observe || surface == .control else { return false }
        guard let activation = await skillActivation() else { return false }
        return Self.toolAvailability(for: activation).observeControl
    }

    func configurationStatus(
        profile: String = IOSBridgeIntegration.defaultProfile
    ) async -> SkillConfigurationStatus? {
        guard let requirements = try? await requirements() else { return nil }
        return try? await environment.skillConfigurationService.inspect(
            skillID: Self.skillID,
            profile: profile,
            target: Self.nativeTarget,
            requirements: requirements
        )
    }

    /// Runs the registered native validator against the current revision.
    /// This is a real loopback config RPC; an unreachable/engine-not-ready
    /// Bridge is never recorded as valid.
    @discardableResult
    func validateBridgeConnection(
        profile: String = IOSBridgeIntegration.defaultProfile
    ) async -> SkillConfigurationStatus? {
        readinessCache = nil
        guard let requirements = try? await requirements() else { return nil }
        guard let outcome = try? await environment.skillConfigurationService.validate(
            skillID: Self.skillID,
            profile: profile,
            target: Self.nativeTarget,
            requirements: requirements
        ) else {
            return nil
        }
        return outcome.status
    }

    // MARK: - Task lifecycle

    func recordRunBinding(
        runID: UUID,
        profile: String = IOSBridgeIntegration.defaultProfile,
        generation: UInt64
    ) {
        activeRunGenerations[runID, default: [:]][profile] = generation
    }

    /// Terminal/suspended run: release ONLY this run's persistent device-input
    /// ownership. It never cancels another task's in-flight call.
    func runDidFinish(runID: UUID) {
        releaseRun(runID: runID, cancelInFlightIfLast: false)
    }

    func suspendRun(runID: UUID) {
        releaseRun(runID: runID, cancelInFlightIfLast: false)
    }

    /// Explicit cancel: release this run immediately. When it was the only
    /// tracked Bridge user, also fence the client so a mutation that was
    /// already dispatched is reported unknown instead of being replayed.
    func cancelRun(runID: UUID) {
        releaseRun(runID: runID, cancelInFlightIfLast: true)
    }

    private func releaseRun(runID: UUID, cancelInFlightIfLast: Bool) {
        guard let entries = activeRunGenerations.removeValue(forKey: runID) else { return }
        if cancelInFlightIfLast, activeRunGenerations.isEmpty {
            fenceAll(reason: "run-cancelled")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for (profile, generation) in entries {
                guard let client = self.clients[profile] else { continue }
                await client.releaseTaskOwnership(taskID: runID, generation: generation)
            }
        }
    }

    /// The universal Skill mutation boundary calls this on disable/remove/
    /// configuration reset. Fence every cached client and drop native
    /// ownership; stale schemas cannot execute against a disabled Skill.
    func skillStateDidChange(skillID: String) async {
        let normalized = skillID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized == Self.skillID else { return }
        await invalidateBridgeClients(reason: "skill-state-changed")
    }

    /// Whether a generic configuration mutation can touch the native bridge
    /// connection. `nil` and an empty set both mean the whole profile was
    /// reset in `SkillConfigurationService`.
    nonisolated static func configurationMutationAffectsBridge(
        fieldKeys: Set<String>?
    ) -> Bool {
        // Only a nonempty set that excludes the bridge field is a no-op.
        guard let fieldKeys, !fieldKeys.isEmpty else { return true }
        return fieldKeys.contains(connectionFieldKey)
    }

    /// Generic `skill.config` / UI configuration mutation callback. The tool
    /// calls it after the attempt succeeds or fails (a partial multi-field
    /// commit must fence too); the UI calls it after a successful mutation.
    /// The client never retains key bytes across calls (the adapter re-reads the current opaque binding),
    /// but a generic unbind/rebind must still fence an in-flight call and
    /// clear persistent ownership. No second service or vault is created.
    func skillConfigurationDidMutate(
        skillID: String,
        fieldKeys: Set<String>?
    ) async {
        let normalized = skillID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized == Self.skillID else { return }
        guard Self.configurationMutationAffectsBridge(fieldKeys: fieldKeys) else { return }
        await invalidateBridgeClients(reason: "bridge-configuration-changed")
    }

    private func invalidateBridgeClients(reason: String) async {
        readinessCache = nil
        backgroundExpiryTask?.cancel()
        backgroundExpiryTask = nil
        activeRunGenerations.removeAll()
        let clients = Array(clients.values)
        for client in clients {
            await client.invalidate(reason: reason)
        }
        // Best-effort UI truth refresh so a cached connection page does not
        // keep showing a removed/replaced pairing after the mutation.
        let centers = Array(connectionCenters.values)
        for center in centers {
            Task { await center.refresh() }
        }
    }

    // MARK: - Execution window / background authority

    func currentExecutionWindow() -> IOSAutomationExecutionWindow {
        environment.backgroundRunCoordinator.iosAutomationExecutionWindow()
    }

    /// Reconciles the client's bounded background authority with the current
    /// scene/lease/continued-processing facts. A foreground scene cancels the
    /// timer; a real bounded hold keeps the client usable until its deadline;
    /// no hold fences immediately.
    func backgroundExecutionWindowChanged() {
        backgroundExpiryTask?.cancel()
        backgroundExpiryTask = nil
        let window = environment.backgroundRunCoordinator.iosAutomationExecutionWindow()
        guard window.source == .backgroundRun else {
            // Foreground is the ordinary unbounded user-visible window.
            return
        }
        guard let deadline = window.deadline, deadline > Date() else {
            fenceAll(reason: "background-window-expired")
            return
        }
        let interval = max(0, deadline.timeIntervalSinceNow)
        backgroundExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fenceAll(reason: "background-window-expired")
        }
    }

    func foregroundEntered() {
        backgroundExpiryTask?.cancel()
        backgroundExpiryTask = nil
        readinessCache = nil
    }

    private func fenceAll(reason: String) {
        backgroundExpiryTask?.cancel()
        backgroundExpiryTask = nil
        readinessCache = nil
        activeRunGenerations.removeAll()
        let clients = Array(clients.values)
        Task {
            for client in clients {
                await client.invalidate(reason: reason)
            }
        }
    }

    // MARK: - Sensitive text input

    /// Resolves an exact normalized vault reference used as `type.text`.
    /// Never resolves a reference embedded in other prose: a literal
    /// placeholder must never be typed into a secure field. The actual
    /// Bridge sensitive-input grant remains authoritative.
    func prepareParameters(
        _ arguments: IOSBridgeToolArguments,
        context: ToolContext
    ) async throws -> IOSBridgeJSONValue {
        var params = arguments.params
        guard arguments.action == .type,
              let text = params["text"]?.stringValue,
              text.contains("⟨credential:") else {
            return .object(params)
        }
        guard let credentialID = SecretIngressScanner.credentialID(from: text),
              context.scope == .local,
              !context.temporaryReadOnly,
              context.approvalGrantID != nil,
              context.allowedToolNames?.contains(IOSBridgeToolNames.control) != false else {
            throw FloeError.validationFailed(
                "A credential reference must be the entire text value and is available only to an authorized local control call."
            )
        }
        // A model-typed UUID is never sufficient. Resolve only metadata first
        // and apply the exact capture / ordinary unbound card policy BEFORE the
        // vault read, so a Skill-bound connection credential (or the local
        // Bridge pairing key) can never be typed into another app.
        let record: CredentialRecord
        do {
            guard let resolved = try await environment.credentialStore.record(id: credentialID) else {
                throw FloeError.validationFailed(
                    "The saved credential is no longer available. Nothing was typed."
                )
            }
            record = resolved
        } catch let error as FloeError {
            throw error
        } catch {
            throw FloeError.validationFailed(
                "The saved credential is unavailable. Nothing was typed."
            )
        }
        let bindingCount: Int
        do {
            bindingCount = try await environment.skillConfigurationStore
                .bindingReferences(credentialID: credentialID).count
        } catch {
            throw FloeError.validationFailed(
                "The credential reference could not be verified for device text input. Nothing was typed."
            )
        }
        guard IOSBridgeTextCredentialPolicy.allows(
            record: record,
            runID: context.runID,
            bindingCount: bindingCount
        ) else {
            throw FloeError.validationFailed(
                "This credential reference cannot be used as device text input. Only the exact capture for this control call or an ordinary unbound vault credential card is allowed. Skill connection and device-pairing credentials are never typed."
            )
        }
        let bytes = try await environment.credentialVault.resolveForApprovedUse(
            CredentialHandle(id: credentialID)
        )
        guard let value = String(data: bytes, encoding: .utf8), !value.isEmpty else {
            throw FloeError.validationFailed("The saved credential cannot be used as text input.")
        }
        params["text"] = .string(value)
        return .object(params)
    }
}

extension AppEnvironment {
    /// Runtime-provided current catalog availability for the model-input
    /// layer. It MUST return non-iOS names too: callers intersect this with
    /// the frozen task ceiling, so an omitted ordinary tool would disappear.
    func iosBridgeDiscoverableToolNames() async -> Set<String> {
        let all = Set(ToolRunnerRegistry.shared.allDescriptors.map(\.name))
        guard LocalBridgePlatform.current.supportsIOSAutomation else { return all }
        return await iosBridgeIntegration.discoverableToolNames(from: all)
    }
}
#endif

// SPDX-License-Identifier: MPL-2.0
//
// G02 production composition — REAL per-domain readiness (ordinary base).
//
// Readiness is computed from actual composition/registry state, never from
// source-file or port-presence optimism:
//   * a domain is `ready` ONLY when its ACTUAL handler keys are present in
//     the live generation's `RuntimeDomainRegistry.boundHandlerKeys` AND the
//     owning constructors ran for the CURRENT epoch;
//   * the readback reports the ACTUAL BOUND-KEY INTERSECTION (never the
//     expected set — an unbound optional domain must not look installed);
//   * a domain is `blocked` with its typed missing dependencies otherwise;
//   * everything retires together on RootStop.
//
// First-provider configuration availability: `providerConfigurationDomain`
// becomes ready at store-open — configuring the FIRST provider does not
// require an already-configured model, so bootstrap is not circularly
// blocked by `ordinaryReady`. Ordinary run admission is still honest: the
// run domain refuses start with typed needsConfiguration/
// credentialUnavailable/transportUnavailable when the model/secret/
// transport gate is missing — readiness is never manufactured to enable
// Send.
//
// Optional domains (temporary, privacy): `blocked` with precise missing
// dependencies (`temporaryExtensionNotIntegrated` /
// `privacyExtensionNotIntegrated`, or `...AttachFailed` after a failed
// attach) until their real G02DomainExtension binds — never ready, never
// advertised, and never gating the ordinary base.
import Foundation

/// Closed G02 domain vocabulary. Keys intentionally mirror both the Swift
/// `AndroidRuntimeBootstrap.MissingBinding` cases and the Kotlin
/// `RuntimeBootstrapCoordinator.STATIC_MISSING_BINDINGS` list so the App
/// mapping is a direct identity translation. The vocabulary NEVER widens.
public enum G02DomainKey: String, Sendable, CaseIterable {
    case providerConfigurationDomain
    case credentialVaultAdapter
    case credentialArgumentNormalizer
    case conversationDomain
    case runDomain
    case temporaryDomain
    case skillsMcpDiscovery
    case hostAttachmentStaging
    case transportDeviceQualification
    case settingsDefaults
    case settingsMemory
    case settingsPersonalization
    case settingsUsage
    case settingsPrivacy
    /// G04 accepted additive (Main decisions D12/D14, 2026-10-24): the real
    /// file/editor domain. Like the settings/privacy additions before it,
    /// this KEY is additive to the readback vocabulary; every pre-existing
    /// key, state, handler family and the RB1 missing-binding barrier stay
    /// byte-identical. It becomes ready ONLY through the real workspace
    /// extension attachment — never from source presence.
    case workspaceDomain
}

public enum G02DomainState: String, Sendable {
    case ready
    case blocked
    case retired
}

public struct G02DomainReadiness: Sendable, Equatable {
    public let domain: G02DomainKey
    public let state: G02DomainState
    /// The ACTUAL bound handler keys for this domain (the intersection with
    /// the live registry) — never the expected set for an unbound domain.
    public let handlerKeys: [String]
    public let missingDependencies: [String]

    public init(domain: G02DomainKey, state: G02DomainState,
                handlerKeys: [String], missingDependencies: [String]) {
        self.domain = domain
        self.state = state
        self.handlerKeys = handlerKeys
        self.missingDependencies = missingDependencies
    }
}

public enum G02Readiness {

    /// The exact handler-key expectation per ordinary domain, derived from
    /// the frozen matrix (BridgeV3.handlerKey(scope:command:)). Temporary
    /// and privacy expectations live behind their extension: the ordinary
    /// base reports them as unbound until a real extension attaches.
    public static func expectedHandlerKeys(for domain: G02DomainKey) -> [String] {
        func key(_ scope: BridgeV3.Scope, _ command: String) -> String {
            BridgeV3.handlerKey(scope: scope, command: command)
        }
        switch domain {
        case .providerConfigurationDomain:
            return ModelConfigurationCommand.allCases.map { $0.bridgeV3HandlerKey }
        case .credentialVaultAdapter:
            // The vault is programmatic (no wire commands): readiness is
            // constructor state, keyed by an empty handler set.
            return []
        case .credentialArgumentNormalizer:
            return []
        case .conversationDomain:
            return [
                key(.applicationConfiguration, "conversation.list"),
                key(.applicationConfiguration, "conversation.search"),
                key(.launch, "conversation.create"),
                key(.conversationLifecycle, "conversation.get"),
                key(.conversationLifecycle, "conversation.rename"),
                key(.conversationLifecycle, "conversation.archive"),
                key(.conversationLifecycle, "conversation.delete"),
                key(.conversationLifecycle, "conversation.messagePage"),
                key(.conversationLifecycle, "conversation.messageSearch"),
                key(.conversationLifecycle, "conversation.messageWindow"),
                key(.conversationLifecycle, "question.pending"),
                key(.conversationLifecycle, "question.answer"),
                key(.conversationLifecycle, "question.cancel"),
            ]
        case .runDomain:
            return RunDomainHandlerPlan.bindings.map { $0.handlerKey }
        case .temporaryDomain:
            // FROZEN RB5 family (self-installing temporary lane) — the
            // required family stays frozen regardless of extension
            // availability; readiness reports the ACTUAL bound intersection
            // separately and can never be certified by a substitute subset.
            return [
                key(.launch, "temp.start"),
                key(.conversationLifecycle, "temp.keep"),
                key(.conversationLifecycle, "temp.end"),
            ]
        case .skillsMcpDiscovery:
            return [
                key(.applicationConfiguration, "capability.tools.list"),
                key(.applicationConfiguration, "skills.list"),
                key(.applicationConfiguration, "skills.install"),
                key(.applicationConfiguration, "skills.uninstall"),
                key(.applicationConfiguration, "mcp.servers.list"),
                key(.applicationConfiguration, "mcp.connect"),
                key(.applicationConfiguration, "mcp.disconnect"),
            ]
        case .hostAttachmentStaging:
            // Staging owns the 4 applicationConfiguration commands plus the
            // 3 conversationLifecycle attachment commands.
            return [
                key(.applicationConfiguration, "attachment.stage"),
                key(.applicationConfiguration, "attachment.staging.read"),
                key(.applicationConfiguration, "attachment.staging.cancel"),
                key(.applicationConfiguration, "attachment.staging.discard"),
                key(.conversationLifecycle, "attachment.commit"),
                key(.conversationLifecycle, "attachment.read"),
                key(.conversationLifecycle, "attachment.cancel"),
            ]
        case .transportDeviceQualification:
            return []
        case .settingsDefaults:
            return [
                key(.applicationConfiguration, "config.defaults.get"),
                key(.applicationConfiguration, "config.defaults.save"),
            ]
        case .settingsMemory:
            return [
                key(.applicationConfiguration, "memory.list"),
                key(.applicationConfiguration, "memory.get"),
                key(.applicationConfiguration, "memory.add"),
                key(.applicationConfiguration, "memory.update"),
                key(.applicationConfiguration, "memory.delete"),
                key(.applicationConfiguration, "memory.delete.bulk"),
                key(.applicationConfiguration, "memory.search"),
                key(.applicationConfiguration, "memory.candidates.list"),
                key(.applicationConfiguration, "memory.candidate.resolve"),
                key(.applicationConfiguration, "memory.organize.start"),
                key(.applicationConfiguration, "memory.organize.proposal.read"),
                key(.applicationConfiguration, "memory.organize.apply"),
                key(.applicationConfiguration, "memory.organize.cancel"),
                key(.applicationConfiguration, "content.read"), // personalization label
            ]
        case .settingsPersonalization:
            return [
                key(.applicationConfiguration, "personalization.get"),
                key(.applicationConfiguration, "personalization.revision.read"),
                key(.applicationConfiguration, "personalization.save"),
                key(.applicationConfiguration, "personalization.rollback"),
                key(.applicationConfiguration, "personalization.automatic.set"),
                key(.applicationConfiguration, "personalization.generate"),
                key(.applicationConfiguration, "personalization.generate.cancel"),
            ]
        case .settingsUsage:
            return [key(.applicationConfiguration, "usage.statistics.get")]
        case .settingsPrivacy:
            // FROZEN privacy family — same frozen-family rule as temporary.
            return [
                key(.applicationConfiguration, "privacy.summary.get"),
                key(.applicationConfiguration, "privacy.history.clear"),
                key(.applicationConfiguration, "privacy.modelConfiguration.clear"),
            ]
        case .workspaceDomain:
            // G04 accepted additive family (Main decisions D12/D14): the
            // closed workspace read/write/activate keys. Same frozen-family
            // rule as temporary/privacy — readiness comes ONLY from the real
            // root-owned facade binding all three actual keys; the old
            // 87-rule barrier and every other domain are unchanged.
            return [
                key(.conversationLifecycle, "workspace.read"),
                key(.conversationLifecycle, "workspace.write"),
                key(.conversationLifecycle, "workspace.activate"),
            ]
        }
    }

    /// Computes the ACTUAL readiness report for one epoch. `boundKeys` is
    /// the live registry's real bound set; `installed` is the composition
    /// retained for the epoch (nil after retirement). The reported
    /// `handlerKeys` are the ACTUAL bound intersection per domain.
    public static func report(epoch: UInt64,
                              boundKeys: Set<String>,
                              installed: G02InstalledComposition?,
                              transportQualified: Bool) -> [G02DomainReadiness] {
        G02DomainKey.allCases.map { domain in
            // The required family is ALWAYS the frozen matrix family (even
            // for not-yet-integrated optional domains); the readback reports
            // the ACTUAL bound intersection — never a substitute subset.
            let expected = expectedHandlerKeys(for: domain)
            let id: G02DomainExtensionID? = switch domain {
            case .temporaryDomain: G02DomainExtensionKey.temporary
            case .settingsPrivacy: G02DomainExtensionKey.privacy
            case .workspaceDomain: G02DomainExtensionKey.workspace
            default: nil
            }
            let boundIntersection = expected.filter { boundKeys.contains($0) }
            let keysPresent = !expected.isEmpty && boundIntersection.count == expected.count
            var state = G02DomainState.blocked
            var missing: [String] = []
            switch domain {
            case .providerConfigurationDomain:
                if installed != nil, keysPresent { state = .ready }
                else if installed == nil {
                    missing = ["ownedStoreReady"]
                } else {
                    missing = ["configHandlers"]
                }
            case .credentialVaultAdapter:
                if installed?.vaultEpoch == epoch { state = .ready }
                else { missing = ["vaultJoin"] }
            case .credentialArgumentNormalizer:
                // Bound into the run components at construction.
                if installed != nil { state = .ready }
                else { missing = ["runComponents"] }
            case .conversationDomain, .runDomain,
                 .skillsMcpDiscovery, .hostAttachmentStaging:
                if installed != nil, keysPresent { state = .ready }
                else if installed == nil { missing = ["ownedStoreReady"] }
                else { missing = ["\(domain.rawValue)Handlers"] }
            case .temporaryDomain, .settingsPrivacy:
                // Optional extensions: ready ONLY when a real extension is
                // attached AND its actual keys are bound. Never ready by
                // default; never a fake persistence fallback.
                if let installed, let id,
                   installed.attachedExtensions[id] != nil, keysPresent {
                    state = .ready
                } else if let installed, let id,
                          installed.attachedExtensions[id] != nil {
                    missing = ["\(domain.rawValue)Handlers"]
                } else {
                    missing = [domain == .temporaryDomain
                        ? "temporaryExtensionNotIntegrated"
                        : "privacyExtensionNotIntegrated"]
                }
            case .workspaceDomain:
                // G04 optional extension (Main decisions D12/D14): ready ONLY
                // when the REAL root-owned workspace facade attached AND its
                // three actual keys are bound. Never ready from source
                // presence, never a stub, and it never gates the ordinary
                // base or the old G02 missing-binding/run readiness.
                if let installed, let id,
                   installed.attachedExtensions[id] != nil, keysPresent {
                    state = .ready
                } else if let installed, let id,
                          installed.attachedExtensions[id] != nil {
                    missing = ["workspaceDomainHandlers"]
                } else {
                    missing = ["workspaceExtensionNotIntegrated"]
                }
            case .transportDeviceQualification:
                if transportQualified { state = .ready }
                else { missing = ["transportQualified", "tlsQualified"] }
            case .settingsDefaults, .settingsMemory, .settingsPersonalization,
                 .settingsUsage:
                if installed != nil, keysPresent { state = .ready }
                else if installed == nil { missing = ["ownedStoreReady"] }
                else { missing = ["\(domain.rawValue)Handlers"] }
            }
            if state == .blocked, installed == nil {
                state = .retired
                missing = []
            }
            return G02DomainReadiness(domain: domain, state: state,
                                      handlerKeys: boundIntersection,
                                      missingDependencies: missing)
        }
    }

    /// Compact readback JSON for the trusted host. Contains ONLY epoch,
    /// per-domain state, the ACTUAL bound handler-key lists and the closed
    /// secure ingress subject vocabulary — never a root path, owner token
    /// or secret.
    ///
    /// `secureIngressSubjects` is the ACTUAL compiled `SubjectKind`
    /// vocabulary (a later qualified successor adds `webSearchSave` only
    /// when its vault parse rule + handler are live), so the App binder can
    /// call `webSearch.bindSecureSaveCapability("webSearchSave", contains)`
    /// truthfully from the readback — and ONLY together with the actual
    /// providerConfigurationDomain readiness + actual configured secure
    /// subject (expected-key presence alone never enables availability).
    public static func reportJSON(epoch: UInt64,
                                  boundKeys: Set<String>,
                                  installed: G02InstalledComposition?,
                                  transportQualified: Bool) -> String {
        let report = report(epoch: epoch, boundKeys: boundKeys,
                            installed: installed,
                            transportQualified: transportQualified)
        let object: [String: Any] = [
            "version": 1,
            "epoch": epoch,
            "nativeRootEpoch": epoch,
            "secureIngressSubjects": SubjectKind.allCases.map { $0.rawValue },
            "domains": report.map {
                [
                    "domain": $0.domain.rawValue,
                    "state": $0.state.rawValue,
                    "handlerKeys": $0.handlerKeys,
                    "missing": $0.missingDependencies,
                ] as [String: Any]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"readiness_encoding\"}"
        }
        return string
    }
}

// MARK: - Trusted-host native readback (narrow, clearly identified; NOT a
// v3 wire command and NOT the public status frame)

private func g02ReadinessCopy(_ value: String, buffer: UnsafeMutablePointer<CChar>?,
                              capacity: Int32) -> Int32 {
    guard capacity >= 0, let buffer else { return RuntimeFacadeStatus.invalidArguments }
    let bytes = Array(value.utf8)
    guard bytes.count + 1 <= Int(capacity) else { return RuntimeFacadeStatus.bufferTooSmall }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}

/// The live domain-readiness snapshot. No generation installed -> typed
/// `notInstalled` (the host must treat that as unknown, never ready).
@_cdecl("floe_g02_domain_readiness")
public func floeG02DomainReadiness(_ buffer: UnsafeMutablePointer<CChar>?,
                                   _ capacity: Int32) -> Int32 {
    guard let installed = G02RuntimeComposition.shared.installedComposition
    else {
        return RuntimeFacadeStatus.notInstalled
    }
    let json = G02Readiness.reportJSON(
        epoch: installed.epoch,
        boundKeys: Set(installed.registry.boundHandlerKeys),
        installed: installed,
        transportQualified: G02RuntimeComposition.shared.transportGate.admitsCloudNetwork)
    return g02ReadinessCopy(json, buffer: buffer, capacity: capacity)
}

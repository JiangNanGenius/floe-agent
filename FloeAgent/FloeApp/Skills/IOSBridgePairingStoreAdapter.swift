// FloeApp — local iOS Bridge pairing store over the shared Skill configuration
// credential lane.
//
// The generic Skill configuration service owns the only device-bound Keychain
// namespace and revision/binding bookkeeping. This adapter never creates a
// second vault: it stores exactly `IOSBridgePairingRecord.encodedSecretPayload`
// as the opaque connection value and translates the service's locked/missing/
// unavailable outcomes into the native client contract.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloePersistence
import FloeSecurity
import FloeSkills
import FloeSync
import FloeIOSAutomation

/// How a new pairing record relates to the record already installed for the
/// same profile. Same token/key is a timestamp-only refresh and must keep the
/// existing credential/revision (and any successful validation). A new key is
/// a rekey and must install a new credential/revision.
enum IOSBridgePairingUpdate: Sendable, Equatable {
    case initialSetup
    case rekey
    case refresh
}

/// Shared manifest projection used by the adapter, the integration and the
/// validator. The installed package's own declaration is the only shape
/// source; no model-supplied field name or connection kind is consulted.
enum IOSBridgeSkillManifest {
    static func manifest(for skill: PersistedSkill) throws -> SkillManifest {
        do {
            return try JSONDecoder().decode(
                SkillManifest.self,
                from: Data(skill.manifestJSON.utf8)
            )
        } catch {
            throw SkillConfigurationError.invalidRequirements(
                "The installed local automation Skill manifest is unreadable."
            )
        }
    }

    static func requirements(for skill: PersistedSkill) throws -> SkillConfigRequirements {
        let manifest = try manifest(for: skill)
        guard let configuration = manifest.configuration else {
            throw SkillConfigurationError.invalidRequirements(
                "The installed local automation Skill does not declare configuration."
            )
        }
        return try SkillConfigurationTool.requirements(from: configuration)
    }

    static func requirements(
        skillID: String,
        skillStore: SQLiteSkillStore
    ) async throws -> SkillConfigRequirements {
        guard let skill = try await skillStore.skill(id: skillID) else {
            throw SkillConfigurationError.installationNotInstalled(skillID)
        }
        return try requirements(for: skill)
    }
}

/// `IOSBridgePairingStore` over the shared Skill configuration service.
///
/// The service APIs are intentionally opaque: payload bytes are never decoded
/// or logged here except to distinguish a timestamp-only refresh from a new
/// token identity. A failed save leaves the previous binding intact (the
/// service writes a new credential before releasing the old one).
struct IOSBridgePairingStoreAdapter: IOSBridgePairingStore {
    let service: SkillConfigurationService
    let configurations: SkillConfigurationStore
    let skillStore: SQLiteSkillStore
    let skillID: String
    let profile: String
    let target: String
    let fieldKey: String
    let connectionKind: String
    let handle: IOSBridgePairingHandle

    init(
        service: SkillConfigurationService,
        configurations: SkillConfigurationStore,
        skillStore: SQLiteSkillStore,
        skillID: String = IOSBridgeIntegration.skillID,
        profile: String,
        target: String = IOSBridgeIntegration.nativeTarget,
        fieldKey: String = IOSBridgeIntegration.connectionFieldKey,
        connectionKind: String = IOSBridgeIntegration.connectionKind
    ) throws {
        guard let handle = IOSBridgePairingHandle.skillConnection(profileID: profile) else {
            throw IOSBridgePairingStoreError.unavailable(
                "The local automation profile identifier is not valid."
            )
        }
        self.service = service
        self.configurations = configurations
        self.skillStore = skillStore
        self.skillID = skillID
        self.profile = profile
        self.target = target
        self.fieldKey = fieldKey
        self.connectionKind = connectionKind
        self.handle = handle
    }

    // MARK: - Decision

    static func updateDecision(
        existing: IOSBridgePairingRecord?,
        new: IOSBridgePairingRecord
    ) -> IOSBridgePairingUpdate {
        guard let existing else { return .initialSetup }
        return new.hasSamePairingIdentity(as: existing) ? .refresh : .rekey
    }

    // MARK: - IOSBridgePairingStore

    func availability(for handle: IOSBridgePairingHandle) async -> IOSBridgeCredentialAvailability {
        guard handle == self.handle else {
            return .unavailable(reason: "This connection handle belongs to another profile.")
        }
        do {
            _ = try await readPayload()
            return .available
        } catch {
            switch Self.map(error) {
            case .locked:
                return .locked(reason: "Unlock this device to read the saved Bridge connection.")
            case .missing:
                return .missing
            case .unavailable(let reason):
                return .unavailable(reason: reason)
            case .corrupt, .verificationFailed:
                return .unavailable(reason: "The saved Bridge connection is invalid.")
            }
        }
    }

    func load(_ handle: IOSBridgePairingHandle) async throws -> IOSBridgePairingRecord {
        guard handle == self.handle else {
            throw IOSBridgePairingStoreError.unavailable(
                "This connection handle belongs to another profile."
            )
        }
        let payload: SkillConfigurationService.NativeConnectionPayload
        do {
            payload = try await readPayload()
        } catch {
            throw Self.map(error)
        }
        do {
            return try IOSBridgePairingRecord.decodeSecretPayload(payload.payload)
        } catch {
            throw IOSBridgePairingStoreError.corrupt
        }
    }

    func save(
        _ record: IOSBridgePairingRecord,
        for handle: IOSBridgePairingHandle
    ) async throws {
        guard handle == self.handle else {
            throw IOSBridgePairingStoreError.unavailable(
                "This connection handle belongs to another profile."
            )
        }
        let encoded: Data
        do {
            encoded = try record.encodedSecretPayload()
        } catch {
            throw IOSBridgePairingStoreError.corrupt
        }
        let requirements: SkillConfigRequirements
        do {
            requirements = try await IOSBridgeSkillManifest.requirements(
                skillID: skillID,
                skillStore: skillStore
            )
        } catch {
            throw Self.map(error)
        }
        let bindingPresent = await hasBinding()
        var existing: SkillConfigurationService.NativeConnectionPayload?
        do {
            existing = try await readPayload(requirements: requirements)
        } catch {
            switch Self.map(error) {
            case .missing where bindingPresent:
                // The binding exists but its opaque bytes are gone. Do not
                // leave a permanently unrecoverable reference: release the
                // dead binding and install the new record as a first setup.
                // Locked/unavailable stores never take this path.
                do {
                    _ = try await service.unconfigure(
                        skillID: skillID,
                        profile: profile,
                        target: target,
                        fieldKeys: [fieldKey],
                        requirements: requirements
                    )
                } catch {
                    throw Self.map(error)
                }
                existing = nil
            case .missing:
                existing = nil
            default:
                throw Self.map(error)
            }
        }

        do {
            if let existing {
                let oldRecord = try? IOSBridgePairingRecord.decodeSecretPayload(existing.payload)
                switch Self.updateDecision(existing: oldRecord, new: record) {
                case .refresh:
                    _ = try await service.refreshConnectionPayload(
                        skillID: skillID,
                        profile: profile,
                        target: target,
                        fieldKey: fieldKey,
                        connectionKind: connectionKind,
                        payload: encoded,
                        requirements: requirements,
                        expectedCredentialID: existing.credentialID,
                        expectedRevision: existing.revision
                    )
                case .rekey, .initialSetup:
                    // A binding with unreadable old bytes is still a rekey:
                    // replace its credential and revision rather than writing
                    // a second unrelated binding.
                    _ = try await service.saveConnectionPayload(
                        skillID: skillID,
                        profile: profile,
                        target: target,
                        fieldKey: fieldKey,
                        connectionKind: connectionKind,
                        payload: encoded,
                        reason: .rekey,
                        requirements: requirements,
                        expectedCredentialID: existing.credentialID,
                        expectedRevision: existing.revision
                    )
                }
            } else {
                _ = try await service.saveConnectionPayload(
                    skillID: skillID,
                    profile: profile,
                    target: target,
                    fieldKey: fieldKey,
                    connectionKind: connectionKind,
                    payload: encoded,
                    reason: .initialSetup,
                    requirements: requirements
                )
            }
        } catch {
            throw Self.map(error)
        }
    }

    func delete(_ handle: IOSBridgePairingHandle) async throws {
        guard handle == self.handle else {
            throw IOSBridgePairingStoreError.unavailable(
                "This connection handle belongs to another profile."
            )
        }
        let requirements: SkillConfigRequirements
        do {
            requirements = try await IOSBridgeSkillManifest.requirements(
                skillID: skillID,
                skillStore: skillStore
            )
        } catch SkillConfigurationError.installationNotInstalled(_) {
            // The Skill row is gone; its install/uninstall cleanup owns any
            // residual profile. There is no reachable local connection left.
            return
        } catch {
            throw Self.map(error)
        }
        do {
            _ = try await service.unconfigure(
                skillID: skillID,
                profile: profile,
                target: target,
                fieldKeys: [fieldKey],
                requirements: requirements
            )
        } catch {
            throw Self.map(error)
        }
        // The binding is gone only when the exact payload is no longer
        // readable. A warning during Keychain cleanup does not keep it bound.
        if (try? await readPayload(requirements: requirements)) != nil {
            throw IOSBridgePairingStoreError.verificationFailed
        }
    }

    // MARK: - Service helpers

    private func readPayload(
        requirements provided: SkillConfigRequirements? = nil
    ) async throws -> SkillConfigurationService.NativeConnectionPayload {
        let requirements: SkillConfigRequirements
        if let provided {
            requirements = provided
        } else {
            requirements = try await IOSBridgeSkillManifest.requirements(
                skillID: skillID,
                skillStore: skillStore
            )
        }
        return try await service.readConnectionPayload(
            skillID: skillID,
            profile: profile,
            target: target,
            fieldKey: fieldKey,
            connectionKind: connectionKind,
            requirements: requirements
        )
    }

    private func hasBinding() async -> Bool {
        guard let snapshot = try? await configurations.snapshot(
            skillID: skillID,
            profile: profile,
            target: target
        ) else {
            return false
        }
        return snapshot.binding(fieldKey) != nil
    }

    private static func map(_ error: Error) -> IOSBridgePairingStoreError {
        if let error = error as? IOSBridgePairingStoreError { return error }
        if let keychain = error as? KeychainStoreError {
            switch keychain {
            case .interactionNotAllowed:
                return .locked
            case .itemNotFound:
                return .missing
            case .duplicateItem, .unexpectedStatus(_):
                return .unavailable("The device Keychain could not save the Bridge connection.")
            }
        }
        guard let skill = error as? SkillConfigurationError else {
            return .unavailable("The saved Bridge connection is unavailable.")
        }
        switch skill {
        case .credentialLocked:
            return .locked
        case .credentialMissing, .installationNotInstalled:
            return .missing
        case .credentialUnavailable:
            return .unavailable("The saved Bridge connection is temporarily unavailable.")
        case .credentialNotAllowed, .connectionBindingChanged, .configurationChanged:
            return .unavailable("The saved Bridge connection changed. Re-read it before retrying.")
        case .sourceUnverified, .sourceChanged:
            return .unavailable("The installed local automation Skill source is not verified.")
        case .fieldNotConfigurable, .undeclaredField, .invalidRequirements, .noConfigurationDeclared:
            return .unavailable("The installed Skill does not declare a usable local Bridge connection.")
        default:
            return .unavailable("The saved Bridge connection is unavailable.")
        }
    }
}

/// Isolated in-memory store used ONLY by the stateless validation callback.
/// It holds the already authorized payload for the duration of one real
/// loopback status check and never persists or logs it.
actor IOSBridgeValidatorPairingStore: IOSBridgePairingStore {
    private let handle: IOSBridgePairingHandle
    private var record: IOSBridgePairingRecord?

    init(record: IOSBridgePairingRecord, handle: IOSBridgePairingHandle) {
        self.record = record
        self.handle = handle
    }

    func availability(
        for handle: IOSBridgePairingHandle
    ) async -> IOSBridgeCredentialAvailability {
        guard handle == self.handle, record != nil else { return .missing }
        return .available
    }

    func load(_ handle: IOSBridgePairingHandle) async throws -> IOSBridgePairingRecord {
        guard handle == self.handle, let record else {
            throw IOSBridgePairingStoreError.missing
        }
        return record
    }

    func save(
        _ record: IOSBridgePairingRecord,
        for handle: IOSBridgePairingHandle
    ) async throws {
        guard handle == self.handle else {
            throw IOSBridgePairingStoreError.unavailable(
                "The validation store owns a different connection handle."
            )
        }
        self.record = record
    }

    func delete(_ handle: IOSBridgePairingHandle) async throws {
        guard handle == self.handle else {
            throw IOSBridgePairingStoreError.unavailable(
                "The validation store owns a different connection handle."
            )
        }
        guard record != nil else { throw IOSBridgePairingStoreError.missing }
        record = nil
    }
}

/// Stateless native connection validator. The service supplies the exact
/// current revision's opaque payload through `readSecret`; this type makes a
/// temporary in-memory client and performs a REAL loopback status/config RPC.
/// It never calls the Skill configuration service back and never fabricates a
/// valid result.
struct IOSBridgeSkillConnectionValidator: SkillConfigurationValidating {
    let supportedConnectionKind = IOSBridgeIntegration.connectionKind
    let identifier = IOSBridgeIntegration.validatorIdentifier

    init() {}

    func validate(
        _ request: SkillConfigurationValidationRequest
    ) async throws -> SkillConfigurationValidationResult {
        guard request.connectionKind == supportedConnectionKind,
              request.skillID == IOSBridgeIntegration.skillID,
              request.fieldKey == IOSBridgeIntegration.connectionFieldKey else {
            return .unsupported(
                reason: "This connection is not the built-in local iOS Bridge automation connection."
            )
        }
        guard LocalBridgePlatform.current.supportsIOSAutomation else {
            return .unsupported(reason: "Local device automation is unavailable on this platform.")
        }
        guard let handle = IOSBridgePairingHandle.skillConnection(profileID: request.profile) else {
            return .invalid(message: "The local automation profile identifier is not valid.")
        }
        let payload: Data
        do {
            payload = try await request.readSecret()
        } catch {
            return .invalid(
                message: "The saved connection could not be read. It was not deleted; unlock the device and try again."
            )
        }
        let record: IOSBridgePairingRecord
        do {
            record = try IOSBridgePairingRecord.decodeSecretPayload(payload)
        } catch {
            return .invalid(message: "The saved connection is invalid. Pair again.")
        }
        let store = IOSBridgeValidatorPairingStore(record: record, handle: handle)
        let client = IOSBridgeClient(configuration: .init(
            store: store,
            platformAllowsLocalAutomation: LocalBridgePlatform.current.supportsIOSAutomation,
            pairingHandle: handle,
            authority: ReadOnlyIOSAutomationAuthority(),
            companionProbe: nil,
            policy: .default
        ))
        let snapshot = await client.status()
        await client.shutdown()
        switch snapshot.status {
        case .ready:
            return .valid(message: "The local Bridge companion is reachable, paired and ready.")
        case .unsupportedPlatform:
            return .unsupported(reason: "Local device automation is unavailable on this platform.")
        case .needsPairing:
            return .invalid(message: "The saved pairing is missing. Pair again.")
        case .lockedCredentials:
            return .invalid(message: "Unlock this device and validate again; the saved connection was not deleted.")
        case .credentialsUnavailable:
            return .invalid(message: "The saved connection is temporarily unavailable. It was not deleted.")
        case .pairingRecordInvalid:
            return .invalid(message: "The saved connection is invalid. Pair again.")
        case .expired, .revoked:
            return .invalid(message: "The pairing expired or was revoked in Bridge. Pair again.")
        case .companionMissing, .companionPresenceUnknown, .serviceOff, .serviceUnavailable:
            return .invalid(message: "Bridge is not reachable on this device. Open Bridge and validate again.")
        case .incompatibleBridge(let version):
            return .invalid(message: "Bridge protocol version \(version) is not supported.")
        case .engineNotReady:
            return .invalid(
                message: "Bridge is reachable and paired, but its automation engine is not ready."
            )
        case .pairingInProgress, .waitingForOwnerApproval:
            return .invalid(message: "Finish the current pairing before validating.")
        case .unknown:
            return .invalid(message: "The Bridge connection could not be verified.")
        }
    }
}
#endif

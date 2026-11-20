#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import SwiftUI
import FloeCore
import FloePersistence
import FloeSecurity
import FloeSkills
import FloeSync

struct SkillConfigurationUIScope: Sendable, Hashable {
    var profile = "default"
    var target = "default"
}

struct SkillConfigurationConnectionRequest: Sendable, Hashable {
    let skillID: String
    let scope: SkillConfigurationUIScope
    let fieldKey: String
    let connectionKind: String
}

enum SkillConfigurationUninstallDisposition: Sendable {
    case retain
    case deleteCurrentProfile
}

enum SkillConfigurationUninstallError: Error {
    /// The skill is gone, but its selected profile still needs cleanup.
    /// The injected action must allow an idempotent retry in this state.
    case cleanupPending
}

/// App-owned services; no view creates a database, vault or global singleton.
/// Connection pages and ordered uninstall cleanup remain native integrations.
struct SkillConfigurationUIAccess: Sendable {
    let service: SkillConfigurationService
    let credentials: CredentialStore
    let configurations: SkillConfigurationStore
    var scope: @MainActor @Sendable (PersistedSkill) -> SkillConfigurationUIScope = { _ in .init() }
    var connectionKinds: Set<String> = []
    var supportsNativeNavigation = false
    var beginMutation: (@MainActor @Sendable (String, Set<String>?) async throws -> SkillConfigurationMutationLease?)?
    var configurationMutated: (@MainActor @Sendable (String, Set<String>?) async -> Void)?
    var openConnection: (@MainActor @Sendable (SkillConfigurationConnectionRequest) -> Void)?
    /// Must uninstall first, then clean the selected dormant profile. A failed
    /// uninstall preserves configuration; shared references are only detached.
    var uninstall: (@MainActor @Sendable (PersistedSkill, SkillConfigurationUIScope, SkillConfigurationUninstallDisposition) async throws -> Void)?
}

private struct SkillConfigurationUIAccessKey: EnvironmentKey {
    static let defaultValue: SkillConfigurationUIAccess? = nil
}

extension EnvironmentValues {
    var skillConfigurationAccess: SkillConfigurationUIAccess? {
        get { self[SkillConfigurationUIAccessKey.self] }
        set { self[SkillConfigurationUIAccessKey.self] = newValue }
    }
}

struct SkillConfigurationCredentialChoice: Identifiable, Sendable {
    let card: SecureCredentialCard
    let bindingCount: Int
    var id: UUID { card.id }
}

@MainActor @Observable
final class SkillConfigurationCenter {
    let skill: PersistedSkill
    let scope: SkillConfigurationUIScope
    private(set) var requirements = SkillConfigRequirements()
    private(set) var localDeclarations: [SkillConfigurationLocalDeclaration] = []
    private(set) var status: SkillConfigurationStatus?
    private(set) var credentials: [SkillConfigurationCredentialChoice] = []
    private(set) var boundCredentials: [String: SecureCredentialCard] = [:]
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var installationChanged = false
    private(set) var needsReload = false
    private(set) var errorMessage: String?
    private(set) var notice: String?
    var values: [String: String] = [:]
    @ObservationIgnored private let access: SkillConfigurationUIAccess
    @ObservationIgnored private var loaded = false
    /// Only package-authored requirements go into service methods. The
    /// service merges local declarations itself; feeding the effective list
    /// back as a manifest would incorrectly report every local field as a
    /// package conflict.
    @ObservationIgnored private var manifestRequirements = SkillConfigRequirements()

    init(skill: PersistedSkill, access: SkillConfigurationUIAccess) {
        self.skill = skill
        self.access = access
        self.scope = access.scope(skill)
    }

    static func declaration(for skill: PersistedSkill) throws -> SkillConfigurationRequirements? {
        let manifest = try JSONDecoder().decode(SkillManifest.self, from: Data(skill.manifestJSON.utf8))
        try manifest.configuration?.validate()
        return manifest.configuration
    }

    var hasChanges: Bool {
        requirements.fields.filter { $0.kind == .variable }.contains {
            (values[$0.key] ?? "") != savedValue($0.key)
        }
    }

    var canEdit: Bool {
        guard let status, !isLoading, !installationChanged, !needsReload else { return false }
        switch status.readiness {
        case .notInstalled, .sourceUnverified, .locked: return false
        default: return !isMutating
        }
    }

    func fieldStatus(_ key: String) -> SkillConfigurationFieldStatus? {
        status?.fields.first { $0.key == key }
    }

    private func savedValue(_ key: String) -> String {
        fieldStatus(key)?.value ?? requirements.field(key)?.defaultValue ?? ""
    }

    func load(force: Bool = false) async {
        guard !isLoading, !isMutating, force || !loaded else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let declaration = try Self.declaration(for: skill) {
                manifestRequirements = try SkillConfigurationTool.requirements(from: declaration)
            } else {
                manifestRequirements = .init()
            }
            status = try await access.service.inspect(skillID: skill.id, profile: scope.profile,
                target: scope.target, requirements: manifestRequirements)
            try await refreshDeclarations()
            updateInstallationState()
            await refreshBoundMetadata()
            loaded = true
            errorMessage = nil
        } catch is CancellationError { }
        catch { errorMessage = Self.safeError(error) }
    }

    /// Refreshes service facts after a native connection handoff without
    /// replacing ordinary unsaved field drafts.
    func refreshStatus() async {
        guard loaded, !isLoading, !isMutating else { return }
        let unsaved = values.filter { $0.value != savedValue($0.key) }
        isLoading = true
        defer { isLoading = false }
        do {
            status = try await access.service.inspect(skillID: skill.id, profile: scope.profile,
                target: scope.target, requirements: manifestRequirements)
            try await refreshDeclarations()
            for (key, value) in unsaved where requirements.field(key)?.kind == .variable {
                values[key] = value
            }
            updateInstallationState()
            await refreshBoundMetadata()
        } catch is CancellationError { }
        catch { errorMessage = Self.safeError(error) }
    }

    func saveValues() async -> Bool {
        guard canEdit else { return false }
        guard hasChanges else { return true }
        isMutating = true
        defer { isMutating = false }
        let changed = requirements.fields.filter { $0.kind == .variable && (values[$0.key] ?? "") != savedValue($0.key) }
        do {
            let outcome = try await access.service.saveValues(skillID: skill.id, profile: scope.profile,
                target: scope.target, values: Dictionary(uniqueKeysWithValues: changed.map { ($0.key, values[$0.key] ?? "") }),
                requirements: manifestRequirements, expectedRevision: status?.revision)
            accept(outcome)
            // The service canonicalizes numbers, URLs and whitespace.
            for field in requirements.fields where field.kind == .variable { values[field.key] = savedValue(field.key) }
            if outcome.warnings.isEmpty { notice = FloeL10n.l("app.skill_configuration_center.saved") }
            return true
        } catch { errorMessage = Self.safeError(error); return false }
    }

    func loadCredentials(for field: SkillConfigFieldRequirement) async {
        errorMessage = nil
        do {
            var choices: [SkillConfigurationCredentialChoice] = []
            for record in try await access.credentials.records(owner: .vault) {
                guard field.allowedCredentialKinds.isEmpty || field.allowedCredentialKinds.contains(record.kind) else { continue }
                // A native connection key is not a general script credential.
                guard !record.deviceBound else { continue }
                let count = try await access.configurations.bindingCount(credentialID: record.id)
                choices.append(.init(card: SecureCredentialCard(record: record), bindingCount: count))
            }
            credentials = choices.sorted { $0.card.label.localizedStandardCompare($1.card.label) == .orderedAscending }
        } catch { errorMessage = Self.safeError(error) }
    }

    func bind(field: SkillConfigFieldRequirement, secret: String?, credentialID: UUID?, share: Bool) async -> Bool {
        guard canEdit, field.kind == .secret else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            let outcome = try await access.service.bind(skillID: skill.id, profile: scope.profile,
                target: scope.target, inputs: [.init(fieldKey: field.key, secret: secret,
                    credentialID: credentialID, shareExisting: share)], requirements: manifestRequirements,
                runID: UUID(), expectedRevision: status?.revision)
            accept(outcome)
            await access.configurationMutated?(skill.id, [field.key])
            await refreshBoundMetadata()
            return true
        } catch { errorMessage = Self.safeError(error); return false }
    }

    func clear(_ field: SkillConfigFieldRequirement) async {
        guard canEdit else { return }
        isMutating = true
        defer { isMutating = false }
        var mutation: SkillConfigurationMutationLease?
        do {
            mutation = try await access.beginMutation?(skill.id, [field.key])
            accept(try await access.service.unconfigure(skillID: skill.id, profile: scope.profile,
                target: scope.target, fieldKeys: [field.key], requirements: manifestRequirements,
                expectedRevision: status?.revision))
            await mutation?.finish()
            await access.configurationMutated?(skill.id, [field.key])
            await refreshBoundMetadata()
        } catch { await mutation?.finish(); errorMessage = Self.safeError(error) }
    }

    func validateConnections() async {
        guard canEdit, !hasChanges else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            accept(try await access.service.validate(skillID: skill.id, profile: scope.profile,
                target: scope.target, requirements: manifestRequirements))
        } catch { errorMessage = Self.safeError(error) }
    }

    /// Local declarations never change package bytes or grant execution.
    /// The value is filled later through the existing parameter/secret UI.
    func addEnvironmentField(name: String, label: String, secret: Bool) async -> Bool {
        guard canEdit, !hasChanges else { return false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // This native form adds fields; it must not silently rename/update an
        // existing declaration. The model tool has its own explicit updates.
        guard !localDeclarations.contains(where: {
            $0.environmentName.caseInsensitiveCompare(name) == .orderedSame
        }), !requirements.environment.contains(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            errorMessage = FloeL10n.l("app.skill_configuration_center.this_environment_variable_already_exists")
            return false
        }
        isMutating = true
        defer { isMutating = false }
        do {
            let title = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let outcome = try await access.service.declareField(skillID: skill.id,
                profile: scope.profile, target: scope.target,
                draft: .init(fieldKey: name, kind: secret ? .secret : .variable,
                    title: title.isEmpty ? nil : title, environmentName: name),
                requirements: manifestRequirements, expectedRevision: status?.revision)
            accept(outcome)
            do {
                try await refreshDeclarations()
                notice = FloeL10n.l("app.skill_configuration_center.variable_added_set_its_value")
            } catch {
                // The declaration is already committed. Do not invite a
                // duplicate creation because a subsequent read failed.
                needsReload = true
                errorMessage = FloeL10n.l("app.skill_configuration_center.the_variable_was_added_reload")
            }
            return true
        } catch { errorMessage = Self.safeError(error); return false }
    }

    func removeLocalField(_ key: String) async {
        guard canEdit, !hasChanges,
              localDeclarations.contains(where: { $0.fieldKey == key }) else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            accept(try await access.service.removeField(skillID: skill.id,
                profile: scope.profile, target: scope.target, fieldKey: key,
                requirements: manifestRequirements, expectedRevision: status?.revision))
            values.removeValue(forKey: key)
            do { try await refreshDeclarations() }
            catch {
                needsReload = true
                errorMessage = FloeL10n.l("app.skill_configuration_center.the_variable_was_deleted_reload")
            }
            await refreshBoundMetadata()
        } catch { errorMessage = Self.safeError(error) }
    }

    private func refreshDeclarations() async throws {
        requirements = try await access.service.effectiveRequirements(skillID: skill.id,
            profile: scope.profile, target: scope.target, requirements: manifestRequirements)
        localDeclarations = try await access.service.localDeclarations(skillID: skill.id,
            profile: scope.profile, target: scope.target)
        values = Dictionary(uniqueKeysWithValues: requirements.fields.filter { $0.kind == .variable }.map { field in
            (field.key, savedValue(field.key))
        })
        needsReload = false
    }

    private func refreshBoundMetadata() async {
        var cards: [String: SecureCredentialCard] = [:]
        for field in status?.fields ?? [] {
            guard let reference = field.credentialReference,
                  let id = SecretIngressScanner.credentialID(from: reference),
                  let record = try? await access.credentials.record(id: id) else { continue }
            cards[field.key] = SecureCredentialCard(record: record)
        }
        boundCredentials = cards
    }

    func canOpenConnection(_ field: SkillConfigFieldRequirement) -> Bool {
        guard let kind = field.connectionKind,
              status?.installed == true,
              status?.installation?.configurationAllowed == true else { return false }
        return access.connectionKinds.contains(kind) && (access.supportsNativeNavigation || access.openConnection != nil)
    }

    func connectionRequest(_ field: SkillConfigFieldRequirement) -> SkillConfigurationConnectionRequest {
        .init(skillID: skill.id, scope: scope, fieldKey: field.key, connectionKind: field.connectionKind ?? "")
    }

    func openConnection(_ field: SkillConfigFieldRequirement) {
        guard canOpenConnection(field), let kind = field.connectionKind else { return }
        access.openConnection?(.init(skillID: skill.id, scope: scope, fieldKey: field.key, connectionKind: kind))
    }

    private func accept(_ outcome: SkillConfigurationMutationOutcome) {
        status = outcome.status
        updateInstallationState()
        errorMessage = nil
        notice = outcome.warnings.isEmpty ? nil : FloeL10n.l("app.skill_configuration_center.saved_some_cleanup_needs_attention")
    }

    private func updateInstallationState() {
        installationChanged = status?.installation.map {
            $0.reviewedDigest.caseInsensitiveCompare(skill.rewrittenDigest) != .orderedSame
        } ?? false
    }

    static func safeError(_ error: Error) -> String {
        if let keychainError = error as? KeychainStoreError, keychainError == .interactionNotAllowed {
            return FloeL10n.l("app.skill_configuration_center.unlock_this_device_and_try")
        }
        if let error = error as? SkillConfigurationError {
            switch error {
            case .credentialLocked:
                return FloeL10n.l("app.skill_configuration_center.unlock_this_device_and_try")
            case .configurationChanged:
                return FloeL10n.l("app.skill_configuration_center.configuration_changed_elsewhere_reload_before")
            case .requiresExplicitSharing:
                return FloeL10n.l("app.skill_configuration_center.confirm_sharing_to_reuse_this")
            case .invalidValue:
                return FloeL10n.l("app.skill_configuration_center.check_the_field_s_format")
            case .sourceUnverified:
                return FloeL10n.l("app.skill_configuration_center.verify_this_skill_s_source")
            default: break
            }
        }
        if let error = error as? SkillConfigurationStoreError {
            switch error {
            case .invalidLocalField, .localFieldConflict:
                return FloeL10n.l("app.skill_configuration_center.this_variable_name_is_invalid")
            case .staleRevision:
                return FloeL10n.l("app.skill_configuration_center.configuration_changed_elsewhere_reload_before")
            default: break
            }
        }
        // Never render arbitrary service/parser errors: those may quote input.
        return FloeL10n.l("app.skill_configuration_center.the_change_could_not_be")
    }
}

enum SkillConfigurationCopy {
    static func text(_ en: String, _ zh: String) -> String { FloeL10n.bilingual(chinese: zh, english: en) }

    static func capabilityTitle(_ capability: String) -> String {
        switch capability {
        case "credentials": FloeL10n.l("app.skill_configuration_center.use_saved_credentials")
        case "device.observe": FloeL10n.l("app.skill_configuration_center.read_this_device_s_screen")
        case "device.interact": FloeL10n.l("app.skill_configuration_center.control_apps_on_this_device")
        default: capability
        }
    }
    static var title: String { FloeL10n.l("app.skill_configuration_center.configuration_environment") }
    static var configure: String { FloeL10n.l("providers.service_offers.configure") }
    static var save: String { FloeL10n.l("voice.cloud.profile.save") }
    static var cancel: String { FloeL10n.l("cad.scene.cancel") }
    static var done: String { FloeL10n.l("help.done") }
    static var credentials: String { FloeL10n.l("app.skill_configuration_center.credentials_accounts") }
    static var parameters: String { FloeL10n.l("cad.versions.section.parameters") }
    static var connections: String { FloeL10n.l("app.skill_configuration_center.connections") }

    static func readiness(_ state: SkillConfigurationReadiness) -> String {
        switch state {
        case .notInstalled: FloeL10n.l("app.skill_configuration_center.not_installed")
        case .sourceUnverified: FloeL10n.l("app.skill_configuration_center.source_needs_verification")
        case .needsReconfirmation: FloeL10n.l("app.skill_configuration_center.source_changed_setup_required")
        case .needsSetup: FloeL10n.l("app.skill_configuration_center.installed_setup_required")
        case .needsValidation: FloeL10n.l("app.skill_configuration_center.validation_pending")
        case .invalid: FloeL10n.l("app.skill_configuration_center.validation_failed")
        case .configured: FloeL10n.l("app.skill_configuration_center.configured_validation_pending")
        case .ready: FloeL10n.l("background.location.state.ready")
        case .locked: FloeL10n.l("app.skill_configuration_center.unlock_to_continue")
        }
    }

    static func fieldState(_ state: SkillConfigurationFieldState) -> String {
        switch state {
        case .missing, .missingSecret: FloeL10n.l("voice.assistant.cloud.not_ready")
        case .configured: FloeL10n.l("cad.host.saved")
        case .locked: FloeL10n.l("app.skill_configuration_center.locked")
        case .validationRequired: FloeL10n.l("app.skill_configuration_center.validation_pending")
        case .validated: FloeL10n.l("app.skill_configuration_center.verified")
        case .invalid: FloeL10n.l("app.skill_configuration_center.validation_failed")
        case .unsupported: FloeL10n.l("app.skill_configuration_center.connection_check_unavailable")
        }
    }
}
#endif

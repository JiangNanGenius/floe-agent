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
            if outcome.warnings.isEmpty { notice = SkillConfigurationCopy.text("Saved.", "已保存。") }
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
        do {
            accept(try await access.service.unconfigure(skillID: skill.id, profile: scope.profile,
                target: scope.target, fieldKeys: [field.key], requirements: manifestRequirements,
                expectedRevision: status?.revision))
            await access.configurationMutated?(skill.id, [field.key])
            await refreshBoundMetadata()
        } catch { errorMessage = Self.safeError(error) }
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
            errorMessage = SkillConfigurationCopy.text("This environment variable already exists.", "此环境变量已存在。")
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
                notice = SkillConfigurationCopy.text(
                    "Variable added. Set its value or choose a credential below.",
                    "变量已添加，可在下方填写内容或选择凭据。")
            } catch {
                // The declaration is already committed. Do not invite a
                // duplicate creation because a subsequent read failed.
                needsReload = true
                errorMessage = SkillConfigurationCopy.text(
                    "The variable was added. Reload to show the latest configuration.",
                    "变量已添加，请重新载入以显示最新配置。")
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
                errorMessage = SkillConfigurationCopy.text(
                    "The variable was deleted. Reload to show the latest configuration.",
                    "变量已删除，请重新载入以显示最新配置。")
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
        notice = outcome.warnings.isEmpty ? nil : SkillConfigurationCopy.text(
            "Saved. Some cleanup needs attention; retry from this page.", "已保存，部分清理尚未完成，可在此页面重试。")
    }

    private func updateInstallationState() {
        installationChanged = status?.installation.map {
            $0.reviewedDigest.caseInsensitiveCompare(skill.rewrittenDigest) != .orderedSame
        } ?? false
    }

    static func safeError(_ error: Error) -> String {
        if let keychainError = error as? KeychainStoreError, keychainError == .interactionNotAllowed {
            return SkillConfigurationCopy.text("Unlock this device and try again. Your saved credentials were kept.", "请解锁此设备后重试，已保存的凭据仍保留。")
        }
        if let error = error as? SkillConfigurationError {
            switch error {
            case .credentialLocked:
                return SkillConfigurationCopy.text("Unlock this device and try again. Your saved credentials were kept.", "请解锁此设备后重试，已保存的凭据仍保留。")
            case .configurationChanged:
                return SkillConfigurationCopy.text("Configuration changed elsewhere. Reload before saving.", "配置已在其他位置更改，请重新载入后保存。")
            case .requiresExplicitSharing:
                return SkillConfigurationCopy.text("Confirm sharing to reuse this credential.", "请确认共享后再复用此凭据。")
            case .invalidValue:
                return SkillConfigurationCopy.text("Check the field's format and try again.", "请检查字段格式后重试。")
            case .sourceUnverified:
                return SkillConfigurationCopy.text("Verify this skill's source before configuring it.", "请先确认此技能的来源，再进行配置。")
            default: break
            }
        }
        if let error = error as? SkillConfigurationStoreError {
            switch error {
            case .invalidLocalField, .localFieldConflict:
                return SkillConfigurationCopy.text(
                    "This variable name is invalid, reserved or already in use. Choose another name.",
                    "此变量名格式不正确、被保留或已被使用，请更换名称。")
            case .staleRevision:
                return SkillConfigurationCopy.text("Configuration changed elsewhere. Reload before saving.", "配置已在其他位置更改，请重新载入后保存。")
            default: break
            }
        }
        // Never render arbitrary service/parser errors: those may quote input.
        return SkillConfigurationCopy.text("The change could not be completed. Your saved configuration was kept; try again.", "未能完成更改，已保存的配置仍保留，请重试。")
    }
}

enum SkillConfigurationCopy {
    static func text(_ en: String, _ zh: String) -> String { FloeL10n.isChinese ? zh : en }

    static func capabilityTitle(_ capability: String) -> String {
        switch capability {
        case "credentials": text("Use saved credentials", "使用已保存的凭据")
        case "device.observe": text("Read this device’s screen and state", "读取本机屏幕和状态")
        case "device.interact": text("Control apps on this device", "操作本机应用")
        default: capability
        }
    }
    static var title: String { text("Configuration & environment", "配置与环境变量") }
    static var configure: String { text("Configure", "配置") }
    static var save: String { text("Save", "保存") }
    static var cancel: String { text("Cancel", "取消") }
    static var done: String { text("Done", "完成") }
    static var credentials: String { text("Credentials & accounts", "凭据与账户") }
    static var parameters: String { text("Parameters", "参数") }
    static var connections: String { text("Connections", "关联连接") }

    static func readiness(_ state: SkillConfigurationReadiness) -> String {
        switch state {
        case .notInstalled: text("Not installed", "尚未安装")
        case .sourceUnverified: text("Source needs verification", "来源待确认")
        case .needsReconfirmation: text("Source changed · setup required", "来源已更改，需重新配置")
        case .needsSetup: text("Installed · setup required", "已安装，待配置")
        case .needsValidation: text("Validation pending", "待验证")
        case .invalid: text("Validation failed", "验证失败")
        case .configured: text("Configured · validation pending", "已配置，待验证")
        case .ready: text("Ready", "已就绪")
        case .locked: text("Unlock to continue", "解锁后继续")
        }
    }

    static func fieldState(_ state: SkillConfigurationFieldState) -> String {
        switch state {
        case .missing, .missingSecret: text("Not configured", "未配置")
        case .configured: text("Saved", "已保存")
        case .locked: text("Locked", "已锁定")
        case .validationRequired: text("Validation pending", "待验证")
        case .validated: text("Verified", "已验证")
        case .invalid: text("Validation failed", "验证失败")
        case .unsupported: text("Connection check unavailable", "暂不支持检查此连接")
        }
    }
}
#endif

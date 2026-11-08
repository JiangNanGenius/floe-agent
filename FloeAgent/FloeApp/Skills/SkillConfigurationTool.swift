#if canImport(UIKit)
import Foundation
import FloeCore
import FloePersistence
import FloeSkills
import FloeSync
import FloeTools

/// App-owned resolver that maps an omitted/default/current target to the
/// actual canonical task target (for example `local-ios`, `local-linux`,
/// `local-mac` or `ssh:<hostUUID>`). Production always injects the trusted
/// registry/binding resolver; a model-provided environment label is never
/// trusted on its own.
typealias SkillConfigurationTargetResolver =
    @Sendable (PersistedSkill, ToolContext, String?) async throws -> String

/// Skill configuration lifecycle for the model. Values and secret references
/// live in the native configuration store and vault; this tool never returns
/// a secret value. Declarations come from the installed skill's own manifest,
/// never from model-provided arguments.
struct SkillConfigurationTool: AgentTool {
    struct ValueInput: Decodable, Sendable {
        var text: String

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                text = value
                return
            }
            if let value = try? container.decode(Bool.self) {
                text = value ? "true" : "false"
                return
            }
            if let value = try? container.decode(Int64.self) {
                text = String(value)
                return
            }
            if let value = try? container.decode(Double.self) {
                text = String(value)
                return
            }
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected a string, number or boolean value.")
            )
        }
    }

    struct BindingInput: Decodable, Sendable {
        var field: String
        var secret: String?
        var credentialID: String?
        var share: Bool?
    }

    struct Arguments: Decodable, Sendable {
        var action: String
        var skillID: String
        var profile: String?
        var target: String?
        var values: [String: ValueInput]?
        var cleared: [String]?
        var bindings: [BindingInput]?
        var fields: [String]?
        var revision: Int?
        /// Local supplemental ENV declaration (declare/remove-field).
        var field: String?
        var kind: String?
        var valueType: String?
        var title: String?
        var detail: String?
        var required: Bool?
        var environment: String?
        var allowedValues: [String]?
    }

    static let name = "skill.config"
    static let toolDescription = "Inspect and configure an installed skill through its declared configuration fields, and add user-local ENV fields for skills that only mention variables in their instructions. Actions: inspect (requirements and current state, secret-free), save (ordinary variables; empty string clears), bind (one or more fields with a one-time raw secret or an existing credentialID), validate (run the registered native connection check for the current revision), unconfigure (remove selected fields or the whole profile), declare (add or update a local ordinary/secret ENV field), remove-field (delete a local declaration and its value). Secrets are stored in the device Keychain; only opaque ⟨credential:id⟩ references are returned. Installed-but-needs-setup is reported separately from actually validated readiness. Local declarations never grant a capability, script execution, native connection or access to an unrelated stored secret."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["inspect","save","bind","validate","unconfigure","declare","remove-field"]},"skillID":{"type":"string","maxLength":128},"profile":{"type":"string","maxLength":64},"target":{"type":"string","maxLength":64},"values":{"type":"object","additionalProperties":{}},"cleared":{"type":"array","maxItems":32,"items":{"type":"string"}},"bindings":{"type":"array","maxItems":16,"items":{"type":"object","properties":{"field":{"type":"string"},"secret":{"type":"string","description":"One-time raw value or run-bound ⟨credential:id⟩ reference"},"credentialID":{"type":"string","description":"Existing vault credential UUID"},"share":{"type":"boolean","description":"Explicitly reuse a credential already bound to another profile"}},"required":["field"],"additionalProperties":false}},"fields":{"type":"array","maxItems":32,"items":{"type":"string"}},"field":{"type":"string","maxLength":64},"kind":{"type":"string","enum":["variable","secret"]},"valueType":{"type":"string","enum":["string","number","boolean","url","enumeration"]},"title":{"type":"string","maxLength":120},"detail":{"type":"string","maxLength":600},"required":{"type":"boolean"},"environment":{"type":"string","maxLength":64},"allowedValues":{"type":"array","maxItems":64,"items":{"type":"string","maxLength":256}},"revision":{"type":"integer","minimum":1}},"required":["action","skillID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.accessesCredentials, .persistsPersonalData, .networkAccess]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    private let skillStore: SQLiteSkillStore
    private let service: SkillConfigurationService
    private let targetResolver: SkillConfigurationTargetResolver?
    private let beginConfigurationMutation: (@Sendable (String, Set<String>?) async throws -> SkillConfigurationMutationLease?)?
    private let onConfigurationMutated: (@Sendable (String, Set<String>?) async -> Void)?

    init(
        skillStore: SQLiteSkillStore,
        service: SkillConfigurationService,
        targetResolver: SkillConfigurationTargetResolver? = nil,
        beginConfigurationMutation: (@Sendable (String, Set<String>?) async throws -> SkillConfigurationMutationLease?)? = nil,
        onConfigurationMutated: (@Sendable (String, Set<String>?) async -> Void)? = nil
    ) {
        self.skillStore = skillStore
        self.service = service
        self.targetResolver = targetResolver
        self.beginConfigurationMutation = beginConfigurationMutation
        self.onConfigurationMutated = onConfigurationMutated
    }

    func validate(_ args: Arguments) throws {
        let skillID = args.skillID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skillID.isEmpty, skillID.utf8.count <= 128 else {
            throw FloeError.validationFailed("skillID is required")
        }
        guard ["inspect", "save", "bind", "validate", "unconfigure", "declare", "remove-field"].contains(args.action) else {
            throw FloeError.validationFailed("unsupported action")
        }
        if let profile = args.profile, profile.isEmpty || profile.utf8.count > 64 {
            throw FloeError.validationFailed("profile must be 1...64 characters")
        }
        if let target = args.target, target.isEmpty || target.utf8.count > 64 {
            throw FloeError.validationFailed("target must be 1...64 characters")
        }
        if let revision = args.revision, revision < 1 {
            throw FloeError.validationFailed("revision must be positive")
        }
        if args.action == "declare" {
            guard let field = args.field, !field.isEmpty, field.utf8.count <= 64 else {
                throw FloeError.validationFailed("declare requires a field key")
            }
            guard args.kind == "variable" || args.kind == "secret" else {
                throw FloeError.validationFailed("declare kind must be variable or secret")
            }
            if let valueType = args.valueType,
               !["string", "number", "boolean", "url", "enumeration"].contains(valueType) {
                throw FloeError.validationFailed("unsupported valueType")
            }
            if let environment = args.environment, environment.utf8.count > 64 {
                throw FloeError.validationFailed("environment must be at most 64 characters")
            }
        }
        if args.action == "remove-field" {
            guard let field = args.field, !field.isEmpty, field.utf8.count <= 64 else {
                throw FloeError.validationFailed("remove-field requires a field key")
            }
        }
        switch args.action {
        case "save":
            guard args.values?.isEmpty == false || args.cleared?.isEmpty == false else {
                throw FloeError.validationFailed("save requires values and/or cleared fields")
            }
        case "bind":
            guard let bindings = args.bindings, !bindings.isEmpty else {
                throw FloeError.validationFailed("bind requires at least one binding")
            }
            for binding in bindings {
                guard !binding.field.isEmpty else {
                    throw FloeError.validationFailed("each binding requires a field key")
                }
                let hasSecret = binding.secret?.isEmpty == false
                let hasHandle = binding.credentialID?.isEmpty == false
                guard hasSecret != hasHandle else {
                    throw FloeError.validationFailed("each binding requires exactly one of secret or credentialID")
                }
                if let credentialID = binding.credentialID, UUID(uuidString: credentialID) == nil {
                    throw FloeError.validationFailed("credentialID must be a UUID")
                }
            }
        default:
            break
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let notifies = args.action == "bind" || args.action == "unconfigure"
        let fields: Set<String>? = args.action == "bind" ? args.bindings.map { Set($0.map(\.field)) }
            : args.fields.map { Set($0) }
        do {
            let output = try await executeConfiguration(args, context: context)
            if notifies { await onConfigurationMutated?(args.skillID, fields) }
            return output
        } catch {
            // A multi-binding request may commit an earlier field before a
            // later field fails. Fence native work on failure too.
            if notifies { await onConfigurationMutated?(args.skillID, fields) }
            throw error
        }
    }

    private func executeConfiguration(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard context.approvalGrantID != nil else {
            throw FloeError.validationFailed("Skill configuration requires approval")
        }
        let skillID = args.skillID.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = args.profile ?? "default"
        guard let skill = try await skillStore.skill(id: skillID) else {
            if args.action == "inspect" {
                return Self.output(try Self.notInstalledJSON(skillID: skillID))
            }
            throw SkillConfigurationError.installationNotInstalled(skillID)
        }
        // The App resolver owns the default/current target. A model-supplied
        // `target` is only a request; the resolver may map it to the actual
        // canonical task target and its authorization is still rechecked at
        // runtime. Without a resolver the explicit argument (or "default") is
        // used only for generic tests/legacy wiring.
        let target: String
        if let targetResolver {
            target = try await targetResolver(skill, context, args.target)
        } else {
            target = args.target ?? "default"
        }
        guard !target.isEmpty, target.utf8.count <= 64 else {
            throw FloeError.validationFailed("resolved target must be 1...64 characters")
        }
        let requirements: SkillConfigRequirements
        if let configuration = try Self.configuration(from: skill) {
            requirements = try Self.requirements(from: configuration)
        } else {
            requirements = SkillConfigRequirements()
        }
        switch args.action {
        case "inspect":
            let status = try await service.inspect(
                skillID: skillID,
                profile: profile,
                target: target,
                requirements: requirements
            )
            return Self.output(try Self.statusJSON(status))
        case "save":
            let values = (args.values ?? [:]).mapValues(\.text)
            let outcome = try await service.saveValues(
                skillID: skillID,
                profile: profile,
                target: target,
                values: values,
                clearedFields: args.cleared ?? [],
                requirements: requirements,
                expectedRevision: args.revision
            )
            return Self.output(try Self.outcomeJSON(outcome))
        case "bind":
            let inputs = (args.bindings ?? []).enumerated().map { index, binding in
                SkillConfigurationService.BindInput(
                    fieldKey: binding.field,
                    secret: binding.secret,
                    credentialID: binding.credentialID.flatMap(UUID.init(uuidString:)),
                    shareExisting: binding.share ?? false,
                    captureFieldPath: "bindings.\(index).secret"
                )
            }
            let outcome = try await service.bind(
                skillID: skillID,
                profile: profile,
                target: target,
                inputs: inputs,
                requirements: requirements,
                runID: context.runID,
                expectedRevision: args.revision
            )
            return Self.output(try Self.outcomeJSON(outcome))
        case "validate":
            let outcome = try await service.validate(
                skillID: skillID,
                profile: profile,
                target: target,
                requirements: requirements,
                fieldKeys: args.fields
            )
            return Self.output(try Self.outcomeJSON(outcome))
        case "declare":
            guard let field = args.field,
                  let kindValue = args.kind,
                  let kind = kindValue == "secret" ? SkillConfigurationEntryKind.secret
                    : (kindValue == "variable" ? .variable : nil) else {
                throw FloeError.validationFailed("declare requires a field and variable/secret kind")
            }
            let valueType: String
            if let raw = args.valueType {
                guard let parsed = SkillConfigValueType(rawValue: raw) else {
                    throw FloeError.validationFailed("unsupported valueType")
                }
                valueType = parsed.rawValue
            } else {
                valueType = "string"
            }
            let draft = SkillLocalFieldDeclarationDraft(
                fieldKey: field,
                kind: kind,
                valueType: valueType,
                title: args.title,
                detail: args.detail,
                required: args.required ?? false,
                environmentName: args.environment ?? field.uppercased(),
                allowedValues: args.allowedValues ?? []
            )
            let outcome = try await service.declareField(
                skillID: skillID,
                profile: profile,
                target: target,
                draft: draft,
                requirements: requirements,
                expectedRevision: args.revision
            )
            return Self.output(try Self.outcomeJSON(outcome))
        case "remove-field":
            guard let field = args.field else {
                throw FloeError.validationFailed("remove-field requires a field key")
            }
            let outcome = try await service.removeField(
                skillID: skillID,
                profile: profile,
                target: target,
                fieldKey: field,
                requirements: requirements,
                expectedRevision: args.revision
            )
            return Self.output(try Self.outcomeJSON(outcome))
        default:
            let mutation = try await beginConfigurationMutation?(skillID, args.fields.map { Set($0) })
            do {
                try context.cancellation.throwIfCancelled()
                let outcome = try await service.unconfigure(
                    skillID: skillID,
                    profile: profile,
                    target: target,
                    fieldKeys: args.fields,
                    requirements: requirements,
                    expectedRevision: args.revision
                )
                await mutation?.finish()
                return Self.output(try Self.outcomeJSON(outcome))
            } catch { await mutation?.finish(); throw error }
        }
    }

    // MARK: - Manifest adapter

    private static func configuration(from skill: PersistedSkill) throws -> SkillConfigurationRequirements? {
        guard let data = skill.manifestJSON.data(using: .utf8),
              let manifest = try? JSONDecoder().decode(SkillManifest.self, from: data) else {
            throw FloeError.validationFailed("The installed skill manifest is unreadable.")
        }
        return manifest.configuration
    }

    static func requirements(
        from configuration: SkillConfigurationRequirements
    ) throws -> SkillConfigRequirements {
        let languages = [FloeL10n.currentLanguageCode]
        var fields: [SkillConfigFieldRequirement] = []
        for field in configuration.fields {
            let kind: SkillConfigFieldKind
            switch field.kind {
            case .variable: kind = .variable
            case .secret: kind = .secret
            case .connection: kind = .connection
            }
            let valueType: SkillConfigValueType
            switch field.valueType {
            case .string: valueType = .string
            case .number: valueType = .number
            case .boolean: valueType = .boolean
            case .url: valueType = .url
            case .enumeration: valueType = .enumeration
            }
            var credentialKinds: [CredentialKind] = []
            for raw in field.credentialKinds ?? [] {
                guard let credentialKind = CredentialKind(rawValue: raw) else {
                    throw SkillConfigurationError.invalidRequirements(
                        "unknown credential kind '\(raw)' for field '\(field.key)'"
                    )
                }
                credentialKinds.append(credentialKind)
            }
            fields.append(SkillConfigFieldRequirement(
                key: field.key,
                title: field.title?.value(preferredLanguages: languages),
                detail: field.description?.value(preferredLanguages: languages),
                kind: kind,
                valueType: valueType,
                required: field.required,
                sensitive: field.sensitive,
                defaultValue: field.defaultValue,
                allowedValues: field.allowedValues ?? [],
                connectionKind: field.connectionKind,
                allowedCredentialKinds: credentialKinds
            ))
        }
        let environment = configuration.environment.map { mapping in
            SkillConfigEnvironmentRequirement(
                name: mapping.name,
                fieldKey: mapping.field,
                sensitive: configuration.fields.first {
                    $0.key.caseInsensitiveCompare(mapping.field) == .orderedSame
                }?.kind == .secret
            )
        }
        return try SkillConfigRequirements(fields: fields, environment: environment).validated()
    }

    // MARK: - Secret-free projection

    private static func outcomeJSON(_ outcome: SkillConfigurationMutationOutcome) throws -> String {
        var object = try statusObject(outcome.status)
        if !outcome.warnings.isEmpty {
            object["warnings"] = outcome.warnings
        }
        return try json(object)
    }

    private static func statusJSON(_ status: SkillConfigurationStatus) throws -> String {
        try json(statusObject(status))
    }

    private static func statusObject(_ status: SkillConfigurationStatus) throws -> [String: Any] {
        var object: [String: Any] = [
            "status": "ok",
            "skillID": status.skillID,
            "profile": status.profile,
            "target": status.target,
            "installed": status.installed,
            "sourceChanged": status.sourceChanged,
            "readiness": status.readiness.rawValue,
            "configurationDeclared": !status.fields.isEmpty,
            "fields": status.fields.map { field in
                var row: [String: Any] = [
                    "key": field.key,
                    "declaredBy": field.declaredBy.rawValue,
                    "title": field.title,
                    "kind": field.kind.rawValue,
                    "required": field.required,
                    "sensitive": field.sensitive,
                    "state": field.state.rawValue,
                    "usedDefault": field.usedDefault,
                    "environmentNames": field.environmentNames,
                    "secretEnvironmentNames": field.secretEnvironmentNames
                ]
                if let value = field.value { row["value"] = value }
                if let reference = field.credentialReference { row["credentialReference"] = reference }
                if let role = field.bindingRole { row["bindingRole"] = role.rawValue }
                if let connectionKind = field.connectionKind { row["connectionKind"] = connectionKind }
                if let message = field.message { row["message"] = message }
                return row
            },
            "missingRequiredFields": status.missingRequiredFields,
            "environment": status.environmentNames,
            "secretEnvironment": status.secretEnvironment.map { request in
                [
                    "name": request.name,
                    "field": request.fieldKey,
                    "delivery": request.delivery.rawValue,
                    "credentialReference": request.credentialReference
                ] as [String: Any]
            },
            "validation": status.validation.map { validation in
                var row: [String: Any] = [
                    "field": validation.fieldKey,
                    "revision": validation.revision,
                    "status": validation.status.rawValue,
                    "validator": validation.validator
                ]
                if let detail = validation.detail { row["detail"] = detail }
                return row
            },
            "localDeclarationConflicts": status.localDeclarationConflicts.map { conflict in
                [
                    "field": conflict.fieldKey,
                    "environment": conflict.environmentName,
                    "reason": conflict.reason
                ] as [String: Any]
            },
            "nextActions": status.nextActions
        ]
        if let revision = status.revision { object["revision"] = revision }
        if let installation = status.installation {
            var source: [String: Any] = [
                "skillID": installation.skillID,
                "sourceBinding": installation.sourceBinding,
                "trust": installation.trust.rawValue,
                "reviewedDigest": installation.reviewedDigest
            ]
            if let publisher = installation.publisher { source["publisher"] = publisher }
            if let pin = installation.sourcePin { source["sourcePin"] = pin }
            if let digest = installation.sourceDigest { source["sourceDigest"] = digest }
            if let rewriteModelID = installation.rewriteModelID {
                source["rewriteModelID"] = rewriteModelID
            }
            object["installation"] = source
        }
        return object
    }

    private static func notInstalledJSON(skillID: String) throws -> String {
        try json([
            "status": "ok",
            "skillID": skillID,
            "installed": false,
            "readiness": SkillConfigurationReadiness.notInstalled.rawValue,
            "nextActions": ["Install the skill through the reviewed install path before configuring it."]
        ])
    }


    private static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func output(_ text: String) -> ToolExecutionOutput {
        ToolExecutionOutput(digesting: text, exitStatus: 0, maximumSummaryCharacters: 16_384)
    }
}

/// Exact App wiring entry point. Primary calls this from the existing tool
/// registration site after injecting the native connection validators.
@MainActor
func registerSkillConfigurationTool(
    database: DatabaseManager,
    vault: CredentialVaultService,
    validators: [any SkillConfigurationValidating] = [],
    officialSources: [SkillOfficialSource] = [],
    runtimeUseAuthorizer: any SkillRuntimeUseAuthorizing = DenyAllSkillRuntimeUseAuthorizer(),
    targetResolver: SkillConfigurationTargetResolver? = nil,
    registry: ToolRunnerRegistry = .shared
) {
    let store = SkillConfigurationStore(database: database, officialSources: officialSources)
    let service = SkillConfigurationService(
        store: store,
        vault: vault,
        validators: validators,
        runtimeUseAuthorizer: runtimeUseAuthorizer
    )
    ToolCatalog.register(SkillConfigurationTool.self)
    registry.register(SkillConfigurationTool(
        skillStore: SQLiteSkillStore(database: database),
        service: service,
        targetResolver: targetResolver
    ))
}
#endif

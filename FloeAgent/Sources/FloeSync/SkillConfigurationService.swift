import Foundation
import FloeCore
import FloePersistence
import FloeSecurity

// MARK: - Declarations supplied by the App adapter

public enum SkillConfigFieldKind: String, Sendable, Codable, CaseIterable, Hashable {
    case variable
    case secret
    case connection
}

public enum SkillConfigValueType: String, Sendable, Codable, CaseIterable, Hashable {
    case string
    case number
    case boolean
    case url
    case enumeration
}

/// One declared configuration field, mapped by the App adapter from an
/// installed skill's `floe.json`. Only the *shape* is trusted enough to drive
/// the form; values and bindings come from the native store.
public enum SkillConfigFieldOrigin: String, Sendable, Codable, Equatable {
    /// Declared by the installed package manifest.
    case manifest
    /// Added locally by the user for this installation/profile/target.
    case local
}

public struct SkillConfigurationLocalFieldConflict: Sendable, Equatable, Hashable {
    public let fieldKey: String
    public let environmentName: String
    public let reason: String

    public init(fieldKey: String, environmentName: String, reason: String) {
        self.fieldKey = fieldKey
        self.environmentName = environmentName
        self.reason = reason
    }
}

public struct SkillConfigFieldRequirement: Sendable, Equatable, Hashable {
    public var key: String
    public var declaredBy: SkillConfigFieldOrigin
    /// Already-selected display title, or nil to use `key`.
    public var title: String?
    public var detail: String?
    public var kind: SkillConfigFieldKind
    public var valueType: SkillConfigValueType
    public var required: Bool
    public var sensitive: Bool
    public var defaultValue: String?
    public var allowedValues: [String]
    public var connectionKind: String?
    public var allowedCredentialKinds: [CredentialKind]

    public init(
        key: String,
        declaredBy: SkillConfigFieldOrigin = .manifest,
        title: String? = nil,
        detail: String? = nil,
        kind: SkillConfigFieldKind = .variable,
        valueType: SkillConfigValueType = .string,
        required: Bool = false,
        sensitive: Bool = false,
        defaultValue: String? = nil,
        allowedValues: [String] = [],
        connectionKind: String? = nil,
        allowedCredentialKinds: [CredentialKind] = []
    ) {
        self.key = key
        self.declaredBy = declaredBy
        self.title = title
        self.detail = detail
        self.kind = kind
        self.valueType = valueType
        self.required = required
        self.sensitive = sensitive || kind == .secret
        self.defaultValue = defaultValue
        self.allowedValues = allowedValues
        self.connectionKind = connectionKind
        self.allowedCredentialKinds = allowedCredentialKinds
    }
}

/// Declared environment mapping. `sensitive` is derived from the referenced
/// field by `SkillConfigRequirements.validated()`; a secret mapping produces a
/// separate delivery request and is never placed in `environment`.
public struct SkillConfigEnvironmentRequirement: Sendable, Equatable, Hashable {
    public var name: String
    public var fieldKey: String
    public var sensitive: Bool

    public init(name: String, fieldKey: String, sensitive: Bool = false) {
        self.name = name
        self.fieldKey = fieldKey
        self.sensitive = sensitive
    }
}

public struct SkillConfigRequirements: Sendable, Equatable, Hashable {
    public static let maximumFields = 32
    public static let maximumEnvironmentVariables = 64

    public var fields: [SkillConfigFieldRequirement]
    public var environment: [SkillConfigEnvironmentRequirement]

    public init(
        fields: [SkillConfigFieldRequirement] = [],
        environment: [SkillConfigEnvironmentRequirement] = []
    ) {
        self.fields = fields
        self.environment = environment
    }

    public func field(_ key: String) -> SkillConfigFieldRequirement? {
        fields.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }

    public func environmentNames(fieldKey: String) -> [String] {
        environment.filter { $0.fieldKey.caseInsensitiveCompare(fieldKey) == .orderedSame }
            .map(\.name)
    }

    /// Structural revalidation at the service boundary. Declarations are
    /// package metadata, not authority; malformed maps fail closed.
    @discardableResult
    public func validated() throws -> SkillConfigRequirements {
        guard fields.count <= Self.maximumFields else {
            throw SkillConfigurationError.invalidRequirements("too many declared fields")
        }
        var seen = Set<String>()
        for field in fields {
            guard Self.isValidFieldKey(field.key) else {
                throw SkillConfigurationError.invalidRequirements("invalid field key '\(field.key)'")
            }
            guard seen.insert(field.key.lowercased()).inserted else {
                throw SkillConfigurationError.invalidRequirements("duplicate field key '\(field.key)'")
            }
            switch field.kind {
            case .variable:
                guard !field.sensitive,
                      field.connectionKind == nil,
                      field.allowedCredentialKinds.isEmpty else {
                    throw SkillConfigurationError.invalidRequirements(
                        "variable field '\(field.key)' must not declare secret/connection properties"
                    )
                }
            case .secret:
                guard field.valueType == .string,
                      field.defaultValue == nil,
                      field.allowedValues.isEmpty,
                      field.connectionKind == nil else {
                    throw SkillConfigurationError.invalidRequirements(
                        "secret field '\(field.key)' has an invalid declaration"
                    )
                }
            case .connection:
                guard field.valueType == .string,
                      field.defaultValue == nil,
                      field.allowedValues.isEmpty,
                      let kind = field.connectionKind,
                      Self.isValidConnectionKind(kind) else {
                    throw SkillConfigurationError.invalidRequirements(
                        "connection field '\(field.key)' requires a valid connectionKind"
                    )
                }
            }
        }
        guard environment.count <= Self.maximumEnvironmentVariables else {
            throw SkillConfigurationError.invalidRequirements("too many environment mappings")
        }
        var seenEnvironment = Set<String>()
        for mapping in environment {
            guard Self.isValidEnvironmentName(mapping.name),
                  !Self.reservedEnvironmentNames.contains(mapping.name.uppercased()) else {
                throw SkillConfigurationError.invalidRequirements(
                    "invalid or reserved environment variable '\(mapping.name)'"
                )
            }
            guard seenEnvironment.insert(mapping.name.uppercased()).inserted else {
                throw SkillConfigurationError.invalidRequirements(
                    "duplicate environment variable '\(mapping.name)'"
                )
            }
            guard let field = field(mapping.fieldKey) else {
                throw SkillConfigurationError.invalidRequirements(
                    "environment variable '\(mapping.name)' references an unknown field"
                )
            }
            guard field.kind != .connection else {
                throw SkillConfigurationError.invalidRequirements(
                    "connection field '\(field.key)' cannot map to an environment variable"
                )
            }
        }
        return self
    }

    static func isValidFieldKey(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(first),
              value.utf8.count <= 64 else { return false }
        return value.utf8.dropFirst().allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "_")
        }
    }

    static func isValidConnectionKind(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first),
              value.utf8.count <= 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: ".")
                || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "_")
        }
    }

    static func isValidEnvironmentName(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(first),
              value.utf8.count <= 64 else { return false }
        return value.utf8.dropFirst().allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "_")
        }
    }

    static let reservedEnvironmentNames: Set<String> = [
        "PATH", "HOME", "SHELL", "USER", "LOGNAME", "TMPDIR", "PWD",
        "LD_PRELOAD", "LD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH", "PYTHONPATH", "PYTHONHOME", "IFS", "ENV",
        "BASH_ENV", "ZDOTDIR"
    ]
}

// MARK: - Status

public enum SkillConfigurationReadiness: String, Sendable, Codable, Equatable {
    case notInstalled
    case sourceUnverified
    case needsReconfirmation
    case needsSetup
    case needsValidation
    case invalid
    case configured
    case ready
    case locked
}

public enum SkillConfigurationFieldState: String, Sendable, Codable, Equatable {
    case missing
    case configured
    case missingSecret
    case locked
    case validationRequired
    case validated
    case invalid
    case unsupported
}

public enum SkillSecretEnvironmentDelivery: String, Sendable, Codable, Equatable {
    /// The dedicated sensitive-environment lane resolves this opaque
    /// credential reference per authorized child process. The value never
    /// appears in `SkillRuntimeConfiguration.environment`.
    case nativeCredentialReference = "native-credential-reference"
}

public struct SkillSecretEnvironmentRequest: Sendable, Equatable, Hashable {
    public let name: String
    public let fieldKey: String
    public let delivery: SkillSecretEnvironmentDelivery
    public let credentialReference: String

    public init(
        name: String,
        fieldKey: String,
        delivery: SkillSecretEnvironmentDelivery = .nativeCredentialReference,
        credentialReference: String
    ) {
        self.name = name
        self.fieldKey = fieldKey
        self.delivery = delivery
        self.credentialReference = credentialReference
    }
}

public struct SkillConfigurationFieldStatus: Sendable, Equatable {
    public let key: String
    public let declaredBy: SkillConfigFieldOrigin
    public let title: String
    public let kind: SkillConfigFieldKind
    public let required: Bool
    public let sensitive: Bool
    public let state: SkillConfigurationFieldState
    /// Ordinary variable value only; never a secret or connection value.
    public let value: String?
    public let usedDefault: Bool
    public let credentialReference: String?
    public let bindingRole: SkillConfigurationBindingRole?
    public let connectionKind: String?
    public let environmentNames: [String]
    public let secretEnvironmentNames: [String]
    public let message: String?

    public init(
        key: String,
        declaredBy: SkillConfigFieldOrigin,
        title: String,
        kind: SkillConfigFieldKind,
        required: Bool,
        sensitive: Bool,
        state: SkillConfigurationFieldState,
        value: String?,
        usedDefault: Bool,
        credentialReference: String?,
        bindingRole: SkillConfigurationBindingRole?,
        connectionKind: String?,
        environmentNames: [String],
        secretEnvironmentNames: [String],
        message: String?
    ) {
        self.key = key
        self.declaredBy = declaredBy
        self.title = title
        self.kind = kind
        self.required = required
        self.sensitive = sensitive
        self.state = state
        self.value = value
        self.usedDefault = usedDefault
        self.credentialReference = credentialReference
        self.bindingRole = bindingRole
        self.connectionKind = connectionKind
        self.environmentNames = environmentNames
        self.secretEnvironmentNames = secretEnvironmentNames
        self.message = message
    }
}

public struct SkillConfigurationStatus: Sendable, Equatable {
    public let skillID: String
    public let profile: String
    public let target: String
    public let installed: Bool
    public let sourceChanged: Bool
    public let installation: SkillInstallationIdentity?
    public let revision: Int?
    public let readiness: SkillConfigurationReadiness
    public let fields: [SkillConfigurationFieldStatus]
    public let missingRequiredFields: [String]
    public let environmentNames: [String]
    public let secretEnvironment: [SkillSecretEnvironmentRequest]
    public let validation: [SkillConfigurationValidation]
    public let localDeclarationConflicts: [SkillConfigurationLocalFieldConflict]
    public let nextActions: [String]

    public init(
        skillID: String,
        profile: String,
        target: String,
        installed: Bool,
        sourceChanged: Bool,
        installation: SkillInstallationIdentity?,
        revision: Int?,
        readiness: SkillConfigurationReadiness,
        fields: [SkillConfigurationFieldStatus],
        missingRequiredFields: [String],
        environmentNames: [String],
        secretEnvironment: [SkillSecretEnvironmentRequest],
        validation: [SkillConfigurationValidation],
        localDeclarationConflicts: [SkillConfigurationLocalFieldConflict] = [],
        nextActions: [String]
    ) {
        self.skillID = skillID
        self.profile = profile
        self.target = target
        self.installed = installed
        self.sourceChanged = sourceChanged
        self.installation = installation
        self.revision = revision
        self.readiness = readiness
        self.fields = fields
        self.missingRequiredFields = missingRequiredFields
        self.environmentNames = environmentNames
        self.secretEnvironment = secretEnvironment
        self.validation = validation
        self.localDeclarationConflicts = localDeclarationConflicts
        self.nextActions = nextActions
    }
}

public struct SkillConfigurationMutationOutcome: Sendable, Equatable {
    public let status: SkillConfigurationStatus
    public let warnings: [String]

    public init(status: SkillConfigurationStatus, warnings: [String] = []) {
        self.status = status
        self.warnings = warnings
    }
}

// MARK: - Validation callbacks

public struct SkillConfigurationValidationRequest: Sendable {
    public let skillID: String
    public let installationID: String
    public let profile: String
    public let target: String
    public let revision: Int
    public let fieldKey: String
    public let connectionKind: String
    public let variables: [String: String]
    public let environment: [String: String]
    public let secretEnvironment: [SkillSecretEnvironmentRequest]
    /// Reads the exact bound secret through the native vault. Fails if the
    /// configuration revision changes after validation started.
    public let readSecret: @Sendable () async throws -> Data

    public init(
        skillID: String,
        installationID: String,
        profile: String,
        target: String,
        revision: Int,
        fieldKey: String,
        connectionKind: String,
        variables: [String: String],
        environment: [String: String],
        secretEnvironment: [SkillSecretEnvironmentRequest],
        readSecret: @escaping @Sendable () async throws -> Data
    ) {
        self.skillID = skillID
        self.installationID = installationID
        self.profile = profile
        self.target = target
        self.revision = revision
        self.fieldKey = fieldKey
        self.connectionKind = connectionKind
        self.variables = variables
        self.environment = environment
        self.secretEnvironment = secretEnvironment
        self.readSecret = readSecret
    }
}

public enum SkillConfigurationValidationResult: Sendable, Equatable {
    case valid(message: String?)
    case invalid(message: String)
    case unsupported(reason: String)
}

/// A real native connector check. There is deliberately no built-in success
/// implementation: an unregistered connection kind stays `unsupported`.
public protocol SkillConfigurationValidating: Sendable {
    /// Declared connection kind this validator handles (for example
    /// `ios-bridge`). Dispatch uses this, never the provenance identifier.
    var supportedConnectionKind: String { get }
    /// Precise provenance recorded with the validation receipt, for example
    /// `ios-bridge.rpc.v1` or `ssh.banner.v2`.
    var identifier: String { get }
    func validate(
        _ request: SkillConfigurationValidationRequest
    ) async throws -> SkillConfigurationValidationResult
}

// MARK: - Runtime resolution

public struct SkillRuntimeProvenance: Sendable, Hashable {
    public let runID: UUID
    /// Runtime-owned provenance for this run. A model-supplied id cannot add
    /// itself to this set. This is provenance ONLY: the native runtime-use
    /// authorizer below remains the authority.
    public let activeSkillIDs: Set<String>

    public init(runID: UUID, activeSkillIDs: Set<String>) {
        self.runID = runID
        self.activeSkillIDs = activeSkillIDs
    }
}

public enum SkillRuntimeUseOperation: String, Sendable, Codable, Equatable {
    case resolve
    case readSecret = "read-secret"
}

/// Domain DTO for the authoritative native runtime-use check. It deliberately
/// carries no `ToolContext`: the App adapter maps `runID` to the canonical
/// run/task, current generation/lease and grant state, and verifies the real
/// target. A model-supplied skill/profile/target or active-skill provenance
/// alone must never satisfy this callback.
public struct SkillRuntimeUseRequest: Sendable, Equatable {
    public let runID: UUID
    public let skillID: String
    public let installationID: String
    public let profile: String
    public let target: String
    public let revision: Int
    /// Runtime binding generation captured by the caller (never the model).
    public let bindingGeneration: Int64?
    public let operation: SkillRuntimeUseOperation
    public let fieldKey: String?

    public init(
        runID: UUID,
        skillID: String,
        installationID: String,
        profile: String,
        target: String,
        revision: Int,
        bindingGeneration: Int64?,
        operation: SkillRuntimeUseOperation,
        fieldKey: String?
    ) {
        self.runID = runID
        self.skillID = skillID
        self.installationID = installationID
        self.profile = profile
        self.target = target
        self.revision = revision
        self.bindingGeneration = bindingGeneration
        self.operation = operation
        self.fieldKey = fieldKey
    }
}

public enum SkillRuntimeUseDecision: Sendable, Equatable {
    case allowed
    case denied(String)
}

/// Authoritative native runtime-use gate. Implementations must re-check the
/// exact live run/task, trusted installed identity and pinned configuration
/// revision, the authorized real target, and the current generation/lease.
/// The default is deny; the App supplies the real adapter.
public protocol SkillRuntimeUseAuthorizing: Sendable {
    func authorize(_ request: SkillRuntimeUseRequest) async -> SkillRuntimeUseDecision
}

public struct DenyAllSkillRuntimeUseAuthorizer: SkillRuntimeUseAuthorizing {
    public init() {}
    public func authorize(_ request: SkillRuntimeUseRequest) async -> SkillRuntimeUseDecision {
        .denied("No native runtime-use authorizer is configured.")
    }
}

public struct SkillRuntimeSecretBinding: Sendable, Equatable, Hashable {
    public let fieldKey: String
    public let credentialReference: String
    public let role: SkillConfigurationBindingRole
    public let deviceBound: Bool
    public let connectionKind: String?

    public init(
        fieldKey: String,
        credentialReference: String,
        role: SkillConfigurationBindingRole,
        deviceBound: Bool,
        connectionKind: String?
    ) {
        self.fieldKey = fieldKey
        self.credentialReference = credentialReference
        self.role = role
        self.deviceBound = deviceBound
        self.connectionKind = connectionKind
    }
}

struct SkillConfigurationAuthorization: Sendable, Hashable {
    let installationID: String
    let profileID: UUID
    let profileName: String
    let target: String
    let revision: Int
    /// Present only for runtime-resolved payloads. Validation-only reads keep
    /// nil and are authorized by the tool approval instead.
    let runID: UUID?
    let bindingGeneration: Int64?
}

public struct SkillRuntimeConfiguration: Sendable {
    public let skillID: String
    public let installationID: String
    public let profile: String
    public let target: String
    public let revision: Int
    public let variables: [String: String]
    /// Ordinary environment variables only. Secret mappings are returned
    /// exclusively in `secretEnvironment`.
    public let environment: [String: String]
    public let secretEnvironment: [SkillSecretEnvironmentRequest]
    public let secretBindings: [String: SkillRuntimeSecretBinding]
    let authorization: SkillConfigurationAuthorization

    init(
        skillID: String,
        installationID: String,
        profile: String,
        target: String,
        revision: Int,
        variables: [String: String],
        environment: [String: String],
        secretEnvironment: [SkillSecretEnvironmentRequest],
        secretBindings: [String: SkillRuntimeSecretBinding],
        authorization: SkillConfigurationAuthorization
    ) {
        self.skillID = skillID
        self.installationID = installationID
        self.profile = profile
        self.target = target
        self.revision = revision
        self.variables = variables
        self.environment = environment
        self.secretEnvironment = secretEnvironment
        self.secretBindings = secretBindings
        self.authorization = authorization
    }
}

public struct SkillConfigurationResolutionRequest: Sendable, Equatable {
    public var skillID: String
    public var profile: String
    public var target: String
    /// Runtime binding generation supplied by the App executor, never the
    /// model. The authorizer re-checks it before resolve and every read.
    public var bindingGeneration: Int64?

    public init(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        bindingGeneration: Int64? = nil
    ) {
        self.skillID = skillID
        self.profile = profile
        self.target = target
        self.bindingGeneration = bindingGeneration
    }
}

// MARK: - Errors

public enum SkillConfigurationError: Error, Sendable, Equatable, LocalizedError {
    case invalidRequirements(String)
    case noConfigurationDeclared(String)
    case undeclaredField(String)
    case fieldNotConfigurable(String)
    case secretFieldRequiresBind(String)
    case sensitiveFieldMustBeSecret(String)
    case invalidValue(field: String, reason: String)
    case incompleteConfiguration([String])
    case configurationChanged
    case installationNotInstalled(String)
    case sourceUnverified(String)
    case runtimeProvenanceRejectsSkill(String)
    case credentialLocked(String)
    case credentialUnavailable(String)
    case credentialMissing(String)
    case credentialNotAllowed(String)
    case invalidCaptureReference
    case requiresExplicitSharing
    case validationRequired([String])
    case validationFailed([String])
    case runtimeUseDenied(String)
    case localDeclarationUnavailable(String)
    case sourceChanged
    case connectionBindingChanged

    public var errorDescription: String? {
        switch self {
        case .invalidRequirements(let reason):
            "Invalid skill configuration declaration: \(reason)"
        case .noConfigurationDeclared(let id):
            "Skill '\(id)' does not declare any configuration fields."
        case .undeclaredField(let field):
            "The skill does not declare configuration field '\(field)'."
        case .fieldNotConfigurable(let field):
            "Configuration field '\(field)' cannot be used by this action."
        case .secretFieldRequiresBind(let field):
            "Sensitive field '\(field)' must be saved through bind, not as an ordinary value."
        case .sensitiveFieldMustBeSecret(let field):
            "Field '\(field)' looks sensitive; declare it as kind secret instead of saving a raw value."
        case .invalidValue(let field, let reason):
            "Value for '\(field)' is invalid: \(reason)"
        case .incompleteConfiguration(let fields):
            "Configuration still needs: \(fields.joined(separator: ", "))."
        case .configurationChanged:
            "Configuration changed after it was resolved; re-read it before continuing."
        case .installationNotInstalled(let id):
            "Skill '\(id)' is not installed."
        case .sourceUnverified(let id):
            "Skill '\(id)' has no trusted source binding and cannot store configuration or secrets."
        case .runtimeProvenanceRejectsSkill(let id):
            "Skill '\(id)' is not active in this run."
        case .credentialLocked(let field):
            "The stored credential for '\(field)' is temporarily unavailable because the device is locked. It was not deleted; unlock and retry."
        case .credentialUnavailable(let field):
            "The credential store is temporarily unavailable for '\(field)'. No credential was deleted; retry after checking device access."
        case .credentialMissing(let field):
            "The stored credential for '\(field)' is missing. Configure the field again."
        case .credentialNotAllowed(let field):
            "The referenced credential cannot be used for '\(field)'."
        case .invalidCaptureReference:
            "The credential reference was not produced for this run and field; provide the value again."
        case .requiresExplicitSharing:
            "This credential is already used by another skill configuration. Re-run with shareExisting to reuse it explicitly."
        case .validationRequired(let fields):
            "Live validation is required before use: \(fields.joined(separator: ", "))."
        case .validationFailed(let fields):
            "Live validation failed for: \(fields.joined(separator: ", "))."
        case .runtimeUseDenied(let reason):
            "The runtime did not authorize this skill configuration use: \(reason)"
        case .localDeclarationUnavailable(let reason):
            "The local skill configuration field cannot be used: \(reason)"
        case .sourceChanged:
            "The installed skill source changed. Review the new source and configure it again; previous credentials are not reused."
        case .connectionBindingChanged:
            "The connection binding changed (re-paired or reconfigured). Re-read the current connection before retrying."
        }
    }
}

// MARK: - Service

public struct SkillConfigurationService: Sendable {
    public static let toolName = "skill.config"
    public static let maximumSecretBytes = 8_192

    private let store: SkillConfigurationStore
    private let vault: CredentialVaultService
    private let validators: [String: any SkillConfigurationValidating]
    private let runtimeUseAuthorizer: any SkillRuntimeUseAuthorizing

    /// The runtime-use authorizer is REQUIRED (no permissive default):
    /// resolve and runtime secret reads fail closed unless the App supplies
    /// the canonical live run/task/lease check.
    public init(
        store: SkillConfigurationStore,
        vault: CredentialVaultService,
        validators: [any SkillConfigurationValidating] = [],
        runtimeUseAuthorizer: any SkillRuntimeUseAuthorizing
    ) {
        self.store = store
        self.vault = vault
        var registry: [String: any SkillConfigurationValidating] = [:]
        for validator in validators {
            registry[validator.supportedConnectionKind] = validator
        }
        self.validators = registry
        self.runtimeUseAuthorizer = runtimeUseAuthorizer
    }

    /// Registers/replaces a validator without rebuilding the service.
    public func withValidator(_ validator: any SkillConfigurationValidating) -> SkillConfigurationService {
        var copy = validators
        copy[validator.supportedConnectionKind] = validator
        return SkillConfigurationService(
            store: store,
            vault: vault,
            validators: Array(copy.values),
            runtimeUseAuthorizer: runtimeUseAuthorizer
        )
    }

    // MARK: Inspect

    public func inspect(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        requirements: SkillConfigRequirements
    ) async throws -> SkillConfigurationStatus {
        try requirements.validated()
        let snapshot = try await store.snapshot(
            skillID: skillID,
            profile: profile,
            target: target
        )
        let merged = try mergedRequirements(manifest: requirements, snapshot: snapshot)
        return await buildStatus(
            snapshot: snapshot,
            requirements: merged.requirements,
            conflicts: merged.conflicts
        )
    }

    /// UI/read-only projection of the effective declarations for this
    /// profile/target: installed manifest requirements plus persisted local
    /// ENV declarations, with conflicting local fields excluded. The UI uses
    /// this to render local fields without duplicating merge policy.
    public func effectiveRequirements(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        requirements: SkillConfigRequirements
    ) async throws -> SkillConfigRequirements {
        try requirements.validated()
        let snapshot = try await store.snapshot(
            skillID: skillID,
            profile: profile,
            target: target
        )
        return try mergedRequirements(manifest: requirements, snapshot: snapshot).requirements
    }

    // MARK: Ordinary values

    public func saveValues(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        values: [String: String],
        clearedFields: [String] = [],
        requirements: SkillConfigRequirements,
        expectedRevision: Int? = nil
    ) async throws -> SkillConfigurationMutationOutcome {
        try requirements.validated()
        let snapshot = try await store.snapshot(
            skillID: skillID,
            profile: profile,
            target: target
        )
        let merged = try mergedRequirements(manifest: requirements, snapshot: snapshot)
        let effectiveRequirements = merged.requirements
        var canonical: [String: String] = [:]
        var cleared = Set<String>()
        for key in clearedFields {
            guard let field = effectiveRequirements.field(key), field.kind == .variable else {
                throw SkillConfigurationError.fieldNotConfigurable(key)
            }
            cleared.insert(field.key)
        }
        for (rawKey, rawValue) in values {
            guard let field = effectiveRequirements.field(rawKey) else {
                throw SkillConfigurationError.undeclaredField(rawKey)
            }
            guard field.kind == .variable else {
                throw SkillConfigurationError.secretFieldRequiresBind(field.key)
            }
            guard !field.sensitive, !Self.looksSensitiveKey(field.key) else {
                throw SkillConfigurationError.sensitiveFieldMustBeSecret(field.key)
            }
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                cleared.insert(field.key)
                continue
            }
            canonical[field.key] = try Self.canonicalValue(trimmed, for: field)
        }
        try await store.saveVariables(
            skillID: skillID,
            profile: profile,
            target: target,
            values: canonical,
            clearedFields: Array(cleared),
            expectedRevision: expectedRevision
        )
        return try await outcome(
            skillID: skillID,
            profile: profile,
            target: target,
            manifest: requirements
        )
    }

    // MARK: Binding

    public struct BindInput: Sendable, Equatable {
        public var fieldKey: String
        /// Raw user value or a run-bound `⟨credential:id⟩` capture.
        public var secret: String?
        /// Existing vault credential handle.
        public var credentialID: UUID?
        public var shareExisting: Bool
        /// Exact tool-argument path the normalizer used for `secret`
        /// (for example `bindings.0.secret`). Required to authorize a capture
        /// reference; ignored for raw/existing handles.
        public var captureFieldPath: String?

        public init(
            fieldKey: String,
            secret: String? = nil,
            credentialID: UUID? = nil,
            shareExisting: Bool = false,
            captureFieldPath: String? = nil
        ) {
            self.fieldKey = fieldKey
            self.secret = secret
            self.credentialID = credentialID
            self.shareExisting = shareExisting
            self.captureFieldPath = captureFieldPath
        }
    }

    public enum NativeConnectionUpdateReason: String, Sendable, Codable {
        case initialSetup = "initial-setup"
        case rekey
    }

    /// Opaque native connection payload (for example
    /// `IOSBridgePairingRecord.encodedSecretPayload`). It is never returned to
    /// the model and is never handed through `skill.config`; only a registered
    /// native adapter may read it.
    public struct NativeConnectionPayload: Sendable, Equatable {
        public let skillID: String
        public let installationID: String
        public let profile: String
        public let target: String
        public let fieldKey: String
        public let connectionKind: String
        public let credentialID: UUID
        public let revision: Int
        public let deviceBound: Bool
        public let payload: Data

        public init(
            skillID: String,
            installationID: String,
            profile: String,
            target: String,
            fieldKey: String,
            connectionKind: String,
            credentialID: UUID,
            revision: Int,
            deviceBound: Bool,
            payload: Data
        ) {
            self.skillID = skillID
            self.installationID = installationID
            self.profile = profile
            self.target = target
            self.fieldKey = fieldKey
            self.connectionKind = connectionKind
            self.credentialID = credentialID
            self.revision = revision
            self.deviceBound = deviceBound
            self.payload = payload
        }
    }

    public struct NativeConnectionSetupResult: Sendable, Equatable {
        public let credentialID: UUID
        public let revision: Int
        public let created: Bool
        public let replacedCredentialID: UUID?
        public let warnings: [String]

        public init(
            credentialID: UUID,
            revision: Int,
            created: Bool,
            replacedCredentialID: UUID?,
            warnings: [String]
        ) {
            self.credentialID = credentialID
            self.revision = revision
            self.created = created
            self.replacedCredentialID = replacedCredentialID
            self.warnings = warnings
        }
    }

    public struct NativeConnectionRefreshResult: Sendable, Equatable {
        public let credentialID: UUID
        public let revision: Int
        public let byteCount: Int

        public init(credentialID: UUID, revision: Int, byteCount: Int) {
            self.credentialID = credentialID
            self.revision = revision
            self.byteCount = byteCount
        }
    }

    public static let maximumNativeConnectionPayloadBytes = 32 * 1_024

    public func bind(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        inputs: [BindInput],
        requirements: SkillConfigRequirements,
        runID: UUID,
        expectedRevision: Int? = nil
    ) async throws -> SkillConfigurationMutationOutcome {
        try requirements.validated()
        guard !inputs.isEmpty else {
            return try await outcome(
                skillID: skillID,
                profile: profile,
                target: target,
                manifest: requirements
            )
        }
        let initialSnapshot = try await store.snapshot(
            skillID: skillID,
            profile: profile,
            target: target
        )
        let merged = try mergedRequirements(manifest: requirements, snapshot: initialSnapshot)
        var warningList: [String] = []
        var expected = expectedRevision
        for input in inputs {
            guard let field = merged.requirements.field(input.fieldKey) else {
                throw SkillConfigurationError.undeclaredField(input.fieldKey)
            }
            guard field.kind == .secret || field.kind == .connection else {
                throw SkillConfigurationError.fieldNotConfigurable(field.key)
            }
            let hasSecret = input.secret?.isEmpty == false
            let hasHandle = input.credentialID != nil
            guard hasSecret != hasHandle else {
                throw SkillConfigurationError.invalidValue(
                    field: field.key,
                    reason: "provide exactly one of secret or credentialID"
                )
            }
            let snapshot = try await store.snapshot(skillID: skillID, profile: profile, target: target)
            guard snapshot.installed else {
                throw SkillConfigurationError.installationNotInstalled(skillID)
            }
            guard let installation = snapshot.currentInstallation, installation.configurationAllowed else {
                throw SkillConfigurationError.sourceUnverified(skillID)
            }
            let updated: SkillConfigurationProfile
            if let handleID = input.credentialID {
                updated = try await bindExisting(
                    credentialID: handleID,
                    field: field,
                    input: input,
                    snapshot: snapshot,
                    skillID: skillID,
                    profile: profile,
                    target: target,
                    expectedRevision: expected
                )
            } else if let raw = input.secret {
                if CredentialCaptureReference.looksLikeReference(raw) {
                    guard let captureID = CredentialCaptureReference.credentialID(from: raw),
                          let record = try await vault.metadata(CredentialHandle(id: captureID)) else {
                        throw SkillConfigurationError.invalidCaptureReference
                    }
                    if CredentialCaptureReference.isAuthorizedCapture(
                        record,
                        runID: runID,
                        toolName: Self.toolName,
                        fieldPath: input.captureFieldPath
                    ) {
                        updated = try await createOwnedCredential(
                            bytes: try await vault.resolveForApprovedUse(CredentialHandle(id: captureID)),
                            field: field,
                            snapshot: snapshot,
                            skillID: skillID,
                            profile: profile,
                            target: target,
                            expectedRevision: expected
                        )
                        do {
                            try await vault.delete(CredentialHandle(id: captureID))
                        } catch {
                            warningList.append("A temporary credential capture could not be removed.")
                        }
                    } else if record.origin?.hasPrefix(CredentialCaptureReference.originPrefix) == true {
                        // A normalizer capture is never a reusable vault card,
                        // even if its owner happened to be `.vault`. Only the
                        // exact run/tool/field capture is consumable.
                        throw SkillConfigurationError.invalidCaptureReference
                    } else if record.owner == .vault {
                        updated = try await bindExisting(
                            credentialID: captureID,
                            field: field,
                            input: input,
                            snapshot: snapshot,
                            skillID: skillID,
                            profile: profile,
                            target: target,
                            expectedRevision: expected
                        )
                    } else {
                        throw SkillConfigurationError.invalidCaptureReference
                    }
                } else {
                    guard let data = raw.data(using: .utf8),
                          !data.isEmpty,
                          data.count <= Self.maximumSecretBytes,
                          !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else {
                        throw SkillConfigurationError.invalidValue(
                            field: field.key,
                            reason: "secret must be 1...\(Self.maximumSecretBytes) bytes"
                        )
                    }
                    updated = try await createOwnedCredential(
                        bytes: data,
                        field: field,
                        snapshot: snapshot,
                        skillID: skillID,
                        profile: profile,
                        target: target,
                        expectedRevision: expected
                    )
                }
            } else {
                throw SkillConfigurationError.invalidValue(field: field.key, reason: "missing secret")
            }
            expected = updated.revision
        }
        let result = try await outcome(
            skillID: skillID,
            profile: profile,
            target: target,
            manifest: requirements
        )
        return SkillConfigurationMutationOutcome(status: result.status, warnings: warningList)
    }

    private func bindExisting(
        credentialID: UUID,
        field: SkillConfigFieldRequirement,
        input: BindInput,
        snapshot: SkillConfigurationSnapshot,
        skillID: String,
        profile: String,
        target: String,
        expectedRevision: Int?
    ) async throws -> SkillConfigurationProfile {
        guard let record = try await vault.metadata(CredentialHandle(id: credentialID)) else {
            throw SkillConfigurationError.credentialMissing(field.key)
        }
        guard record.owner == .vault else {
            throw SkillConfigurationError.credentialNotAllowed(field.key)
        }
        if !field.allowedCredentialKinds.isEmpty,
           !field.allowedCredentialKinds.contains(record.kind) {
            throw SkillConfigurationError.credentialNotAllowed(field.key)
        }
        if field.kind == .connection, !record.deviceBound || record.synchronizable {
            throw SkillConfigurationError.credentialNotAllowed(field.key)
        }
        let references = try await store.bindingReferences(credentialID: credentialID)
        let profileID = snapshot.profile?.id
        let hasOtherReference = references.contains { reference in
            !(reference.profileID == profileID && reference.fieldKey.caseInsensitiveCompare(field.key) == .orderedSame)
        }
        if hasOtherReference, !input.shareExisting {
            throw SkillConfigurationError.requiresExplicitSharing
        }
        return try await store.bind(
            skillID: skillID,
            profile: profile,
            target: target,
            fieldKey: field.key,
            kind: field.kind == .connection ? .connection : .secret,
            connectionKind: field.connectionKind,
            credentialID: credentialID,
            role: .shared,
            allowedCredentialKinds: field.allowedCredentialKinds,
            expectedRevision: expectedRevision
        )
    }

    private func createOwnedCredential(
        bytes: Data,
        field: SkillConfigFieldRequirement,
        snapshot: SkillConfigurationSnapshot,
        skillID: String,
        profile: String,
        target: String,
        expectedRevision: Int?
    ) async throws -> SkillConfigurationProfile {
        guard let installation = snapshot.currentInstallation else {
            throw SkillConfigurationError.sourceUnverified(skillID)
        }
        let kind = field.allowedCredentialKinds.first ?? .genericToken
        let deviceBound = field.kind == .connection
        let handle = try await vault.capture(
            bytes,
            kind: kind,
            owner: .vault,
            label: "Skill \(skillID) \(field.key) (\(profile)/\(target))",
            id: UUID(),
            hostID: nil,
            origin: "skill-config:\(installation.installationID):\(profile):\(target):\(field.key)",
            deviceBound: deviceBound
        )
        do {
            return try await store.bind(
                skillID: skillID,
                profile: profile,
                target: target,
                fieldKey: field.key,
                kind: field.kind == .connection ? .connection : .secret,
                connectionKind: field.connectionKind,
                credentialID: handle.id,
                role: .owned,
                allowedCredentialKinds: field.allowedCredentialKinds,
                expectedRevision: expectedRevision
            )
        } catch {
            try? await vault.delete(handle)
            throw error
        }
    }

    // MARK: Native connection payloads (native adapter only)

    /// Reads the exact owned, device-bound connection payload for setup or a
    /// native validator. Only a manifest-declared connection field of the
    /// matching kind is eligible. The returned bytes must never be logged,
    /// returned by a tool or placed in an ordinary environment.
    public func readConnectionPayload(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        fieldKey: String,
        connectionKind: String,
        requirements: SkillConfigRequirements
    ) async throws -> NativeConnectionPayload {
        let field = try declaredConnectionField(
            fieldKey: fieldKey,
            connectionKind: connectionKind,
            requirements: requirements
        )
        let snapshot = try await store.snapshot(
            skillID: skillID,
            profile: profile,
            target: target
        )
        try requireInstalledCurrentSource(snapshot, skillID: skillID)
        guard let configurationProfile = snapshot.profile else {
            throw SkillConfigurationError.credentialMissing(field.key)
        }
        guard let binding = snapshot.binding(field.key) else {
            throw SkillConfigurationError.credentialMissing(field.key)
        }
        try validateOwnedConnectionBinding(binding, field: field)
        _ = try await requireAvailableConnectionRecord(binding.credentialID, field: field)
        let payload = try await vault.resolveForApprovedUse(
            CredentialHandle(id: binding.credentialID)
        )
        return NativeConnectionPayload(
            skillID: skillID,
            installationID: configurationProfile.installationID,
            profile: configurationProfile.profile,
            target: configurationProfile.target,
            fieldKey: field.key,
            connectionKind: connectionKind,
            credentialID: binding.credentialID,
            revision: configurationProfile.revision,
            deviceBound: binding.deviceBound,
            payload: payload
        )
    }

    /// Establishes a first connection payload or replaces it for a new
    /// key/token. A replacement installs a NEW credential and binding, bumps
    /// the configuration revision (thereby invalidating the previous live
    /// validation) and releases the old owned credential. A late adapter
    /// holding the old credential id/revision therefore cannot overwrite the
    /// re-paired binding. The native adapter triggers the actual validator
    /// after this returns.
    public func saveConnectionPayload(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        fieldKey: String,
        connectionKind: String,
        payload: Data,
        reason: NativeConnectionUpdateReason,
        requirements: SkillConfigRequirements,
        expectedCredentialID: UUID? = nil,
        expectedRevision: Int? = nil
    ) async throws -> NativeConnectionSetupResult {
        let field = try declaredConnectionField(
            fieldKey: fieldKey,
            connectionKind: connectionKind,
            requirements: requirements
        )
        guard !payload.isEmpty,
              payload.count <= Self.maximumNativeConnectionPayloadBytes else {
            throw SkillConfigurationError.invalidValue(
                field: field.key,
                reason: "native connection payload must be 1...\(Self.maximumNativeConnectionPayloadBytes) bytes"
            )
        }
        let snapshot = try await store.snapshot(
            skillID: skillID,
            profile: profile,
            target: target
        )
        try requireInstalledCurrentSource(snapshot, skillID: skillID)
        guard let installation = snapshot.currentInstallation else {
            throw SkillConfigurationError.sourceUnverified(skillID)
        }
        let existingBinding = snapshot.binding(field.key)
        var replacedCredentialID: UUID?
        var warnings: [String] = []
        if let existingBinding {
            try validateOwnedConnectionBinding(existingBinding, field: field)
            guard expectedCredentialID == existingBinding.credentialID,
                  expectedRevision == snapshot.profile?.revision else {
                throw SkillConfigurationError.connectionBindingChanged
            }
            _ = try await requireAvailableConnectionRecord(
                existingBinding.credentialID,
                field: field
            )
            replacedCredentialID = existingBinding.credentialID
        } else if expectedCredentialID != nil {
            throw SkillConfigurationError.connectionBindingChanged
        }

        let credentialKind = field.allowedCredentialKinds.first ?? .genericToken
        let handle = try await vault.capture(
            payload,
            kind: credentialKind,
            owner: .vault,
            label: "Skill connection \(skillID) \(field.key) (\(profile)/\(target))",
            hostID: nil,
            origin: "skill-connection:\(installation.installationID):\(profile):\(target):\(field.key)",
            deviceBound: true
        )
        let updated: SkillConfigurationProfile
        do {
            updated = try await store.bind(
                skillID: skillID,
                profile: profile,
                target: target,
                fieldKey: field.key,
                kind: .connection,
                connectionKind: connectionKind,
                credentialID: handle.id,
                role: .owned,
                allowedCredentialKinds: field.allowedCredentialKinds,
                expectedRevision: existingBinding == nil ? expectedRevision : snapshot.profile?.revision
            )
        } catch {
            try? await vault.delete(handle)
            throw error
        }
        if let replacedCredentialID {
            do {
                try await vault.delete(CredentialHandle(id: replacedCredentialID))
            } catch {
                warnings.append("The previous connection secret could not be removed.")
            }
        }
        return NativeConnectionSetupResult(
            credentialID: handle.id,
            revision: updated.revision,
            created: existingBinding == nil,
            replacedCredentialID: replacedCredentialID,
            warnings: warnings
        )
    }

    /// Metadata-only RPC refresh (same client/token/key, updated timestamp).
    /// It replaces the payload bytes for the EXISTING credential id and does
    /// not bump the configuration revision, so an already successful live
    /// validation stays valid. The native adapter must have verified the same
    /// client/token/key first. A stale credential id/revision (for example a
    /// late old client after re-pairing) is refused before any write.
    public func refreshConnectionPayload(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        fieldKey: String,
        connectionKind: String,
        payload: Data,
        requirements: SkillConfigRequirements,
        expectedCredentialID: UUID,
        expectedRevision: Int
    ) async throws -> NativeConnectionRefreshResult {
        let field = try declaredConnectionField(
            fieldKey: fieldKey,
            connectionKind: connectionKind,
            requirements: requirements
        )
        guard !payload.isEmpty,
              payload.count <= Self.maximumNativeConnectionPayloadBytes else {
            throw SkillConfigurationError.invalidValue(
                field: field.key,
                reason: "native connection payload must be 1...\(Self.maximumNativeConnectionPayloadBytes) bytes"
            )
        }
        let snapshot = try await store.snapshot(
            skillID: skillID,
            profile: profile,
            target: target
        )
        try requireInstalledCurrentSource(snapshot, skillID: skillID)
        guard let configurationProfile = snapshot.profile,
              configurationProfile.revision == expectedRevision else {
            throw SkillConfigurationError.connectionBindingChanged
        }
        guard let binding = snapshot.binding(field.key),
              binding.credentialID == expectedCredentialID else {
            throw SkillConfigurationError.connectionBindingChanged
        }
        try validateOwnedConnectionBinding(binding, field: field)
        _ = try await requireAvailableConnectionRecord(binding.credentialID, field: field)
        try await vault.replaceSecret(
            CredentialHandle(id: binding.credentialID),
            secret: payload
        )
        // A concurrent re-pair installs a new credential id/revision. If that
        // won the race, report it: this refresh did not reach the active
        // binding (the old credential is now orphaned and never consulted).
        let after = try await store.snapshot(
            skillID: skillID,
            profile: profile,
            target: target
        )
        guard after.profile?.revision == expectedRevision,
              after.binding(field.key)?.credentialID == expectedCredentialID else {
            throw SkillConfigurationError.connectionBindingChanged
        }
        return NativeConnectionRefreshResult(
            credentialID: binding.credentialID,
            revision: expectedRevision,
            byteCount: payload.count
        )
    }

    private func declaredConnectionField(
        fieldKey: String,
        connectionKind: String,
        requirements: SkillConfigRequirements
    ) throws -> SkillConfigFieldRequirement {
        try requirements.validated()
        guard let field = requirements.field(fieldKey),
              field.kind == .connection,
              field.connectionKind == connectionKind,
              SkillConfigRequirements.isValidConnectionKind(connectionKind) else {
            throw SkillConfigurationError.fieldNotConfigurable(fieldKey)
        }
        return field
    }

    private func requireInstalledCurrentSource(
        _ snapshot: SkillConfigurationSnapshot,
        skillID: String
    ) throws {
        guard snapshot.installed else {
            throw SkillConfigurationError.installationNotInstalled(skillID)
        }
        guard let installation = snapshot.currentInstallation,
              installation.configurationAllowed else {
            throw SkillConfigurationError.sourceUnverified(skillID)
        }
        if snapshot.sourceChanged {
            throw SkillConfigurationError.sourceChanged
        }
    }

    private func validateOwnedConnectionBinding(
        _ binding: SkillConfigurationBinding,
        field: SkillConfigFieldRequirement
    ) throws {
        guard binding.role == .owned, binding.deviceBound else {
            throw SkillConfigurationError.credentialNotAllowed(field.key)
        }
        if let connectionKind = field.connectionKind,
           binding.connectionKind != connectionKind {
            throw SkillConfigurationError.credentialNotAllowed(field.key)
        }
    }

    private func requireAvailableConnectionRecord(
        _ credentialID: UUID,
        field: SkillConfigFieldRequirement
    ) async throws -> CredentialRecord {
        guard let record = try await vault.metadata(CredentialHandle(id: credentialID)) else {
            throw SkillConfigurationError.credentialMissing(field.key)
        }
        guard record.owner == .vault, record.deviceBound, !record.synchronizable else {
            throw SkillConfigurationError.credentialNotAllowed(field.key)
        }
        switch await vault.availability(CredentialHandle(id: credentialID)) {
        case .available:
            return record
        case .missing:
            throw SkillConfigurationError.credentialMissing(field.key)
        case .locked:
            throw SkillConfigurationError.credentialLocked(field.key)
        case .failed:
            throw SkillConfigurationError.credentialUnavailable(field.key)
        }
    }

    // MARK: Validation

    public func validate(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        requirements: SkillConfigRequirements,
        fieldKeys: [String]? = nil
    ) async throws -> SkillConfigurationMutationOutcome {
        try requirements.validated()
        let snapshot = try await store.snapshot(skillID: skillID, profile: profile, target: target)
        let merged = try mergedRequirements(manifest: requirements, snapshot: snapshot)
        let effectiveRequirements = merged.requirements
        let status = await buildStatus(
            snapshot: snapshot,
            requirements: effectiveRequirements,
            conflicts: merged.conflicts
        )
        switch status.readiness {
        case .notInstalled, .sourceUnverified, .needsReconfirmation, .needsSetup, .locked:
            return SkillConfigurationMutationOutcome(status: status)
        case .invalid, .needsValidation, .configured, .ready:
            break
        }
        guard let configurationProfile = snapshot.profile,
              let installation = snapshot.currentInstallation else {
            return SkillConfigurationMutationOutcome(status: status)
        }
        var requested = Set<String>()
        if let fieldKeys {
            for key in fieldKeys {
                guard let field = effectiveRequirements.field(key), field.kind == .connection else {
                    throw SkillConfigurationError.fieldNotConfigurable(key)
                }
                requested.insert(field.key)
            }
        }
        let fields = effectiveRequirements.fields.filter { field in
            field.kind == .connection
                && snapshot.binding(field.key) != nil
                && (requested.isEmpty || requested.contains(field.key))
        }
        guard !fields.isEmpty else {
            return SkillConfigurationMutationOutcome(status: status)
        }

        let entries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.fieldKey, $0) })
        var variables: [String: String] = [:]
        for field in effectiveRequirements.fields where field.kind == .variable {
            if let value = entries[field.key]?.value ?? field.defaultValue {
                variables[field.key] = value
            }
        }
        let ordinaryEnvironment = ordinaryEnvironment(
            requirements: effectiveRequirements,
            variableValues: variables
        )
        let secretRequests = secretEnvironmentRequests(
            snapshot: snapshot,
            requirements: effectiveRequirements
        )

        for field in fields {
            guard let connectionKind = field.connectionKind else { continue }
            guard let validator = validators[connectionKind] else {
                try await store.recordValidation(
                    profileID: configurationProfile.id,
                    fieldKey: field.key,
                    revision: configurationProfile.revision,
                    status: .unsupported,
                    validator: "unavailable:\(connectionKind)",
                    detail: "No native connector validator is registered for this connection kind."
                )
                continue
            }
            let authorization = SkillConfigurationAuthorization(
                installationID: installation.installationID,
                profileID: configurationProfile.id,
                profileName: configurationProfile.profile,
                target: configurationProfile.target,
                revision: configurationProfile.revision,
                runID: nil,
                bindingGeneration: nil
            )
            let key = field.key
            let request = SkillConfigurationValidationRequest(
                skillID: skillID,
                installationID: installation.installationID,
                profile: configurationProfile.profile,
                target: configurationProfile.target,
                revision: configurationProfile.revision,
                fieldKey: key,
                connectionKind: connectionKind,
                variables: variables,
                environment: ordinaryEnvironment,
                secretEnvironment: secretRequests,
                readSecret: { [self] in
                    try await readSecret(
                        fieldKey: key,
                        skillID: skillID,
                        authorization: authorization
                    )
                }
            )
            let result: SkillConfigurationValidationResult
            do {
                result = try await validator.validate(request)
            } catch {
                result = .invalid(message: "Native validation callback failed.")
            }
            let recorded: (SkillConfigurationValidationStatus, String, String?)
            switch result {
            case .valid(let message):
                recorded = (.validated, validator.identifier, Self.boundedDetail(message))
            case .invalid(let message):
                recorded = (.invalid, validator.identifier, Self.boundedDetail(message))
            case .unsupported(let reason):
                recorded = (.unsupported, validator.identifier, Self.boundedDetail(reason))
            }
            do {
                try await store.recordValidation(
                    profileID: configurationProfile.id,
                    fieldKey: field.key,
                    revision: configurationProfile.revision,
                    status: recorded.0,
                    validator: recorded.1,
                    detail: recorded.2
                )
            } catch SkillConfigurationStoreError.staleRevision(_, _) {
                throw SkillConfigurationError.configurationChanged
            }
        }
        return try await outcome(
            skillID: skillID,
            profile: profile,
            target: target,
            manifest: requirements
        )
    }

    // MARK: User-local supplemental ENV declarations

    /// Adds or updates a user-owned supplemental ENV field for this exact
    /// installation/profile/target. The declaration is persisted separately
    /// from package bytes and never grants a capability, script execution or
    /// native connection. A secret declaration alone carries no secret: the
    /// user/model must still bind a value explicitly for this field.
    public func declareField(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        draft: SkillLocalFieldDeclarationDraft,
        requirements: SkillConfigRequirements,
        expectedRevision: Int? = nil
    ) async throws -> SkillConfigurationMutationOutcome {
        try requirements.validated()
        var reservedKeys = requirements.fields.map(\.key)
        reservedKeys.append(contentsOf: Self.reservedLocalFieldKeys)
        var reservedEnvironment = requirements.environment.map(\.name)
        reservedEnvironment.append(contentsOf: SkillConfigRequirements.reservedEnvironmentNames)
        _ = try await store.declareLocalField(
            skillID: skillID,
            profile: profile,
            target: target,
            draft: draft,
            reservedFieldKeys: reservedKeys,
            reservedEnvironmentNames: reservedEnvironment,
            expectedRevision: expectedRevision
        )
        return try await outcome(
            skillID: skillID,
            profile: profile,
            target: target,
            manifest: requirements
        )
    }

    /// Removes one user-local declaration and its value/binding. An owned
    /// secret is released; a shared credential is never deleted.
    public func removeField(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        fieldKey: String,
        requirements: SkillConfigRequirements,
        expectedRevision: Int? = nil
    ) async throws -> SkillConfigurationMutationOutcome {
        try requirements.validated()
        let result = try await store.removeLocalField(
            skillID: skillID,
            profile: profile,
            target: target,
            fieldKey: fieldKey,
            expectedRevision: expectedRevision
        )
        var warnings: [String] = []
        for id in Set(result.released.ownedUnreferenced) {
            do {
                try await vault.delete(CredentialHandle(id: id))
            } catch {
                warnings.append("A skill-owned secret could not be removed from the Keychain.")
            }
        }
        let snapshot = try await store.snapshot(skillID: skillID, profile: profile, target: target)
        let merged = try mergedRequirements(manifest: requirements, snapshot: snapshot)
        return SkillConfigurationMutationOutcome(
            status: await buildStatus(
                snapshot: snapshot,
                requirements: merged.requirements,
                conflicts: merged.conflicts
            ),
            warnings: warnings
        )
    }

    /// UI/read-only projection of supplemental declarations (no values).
    public func localDeclarations(
        skillID: String,
        profile: String = "default",
        target: String = "default"
    ) async throws -> [SkillConfigurationLocalDeclaration] {
        try await store.snapshot(skillID: skillID, profile: profile, target: target)
            .localDeclarations
    }

    private static let reservedLocalFieldKeys: Set<String> = [
        "profile", "target", "revision", "environment", "environmentname",
        "field", "credentialid", "credentialreference"
    ]

    private struct MergedRequirements {
        let requirements: SkillConfigRequirements
        let conflicts: [SkillConfigurationLocalFieldConflict]
    }

    /// Runtime resolution always merges the installed manifest declarations
    /// with the declarations persisted for this installation/profile/target.
    /// Conflicts (for example a same-source update adding a field name or ENV
    /// name the local declaration used) are excluded fail-closed and reported,
    /// never silently overridden by either side.
    private func mergedRequirements(
        manifest: SkillConfigRequirements,
        snapshot: SkillConfigurationSnapshot
    ) throws -> MergedRequirements {
        try manifest.validated()
        var fields = manifest.fields
        var environment = manifest.environment
        var conflicts: [SkillConfigurationLocalFieldConflict] = []
        for declaration in snapshot.localDeclarations {
            let key = declaration.fieldKey
            if manifest.fields.contains(where: {
                $0.key.caseInsensitiveCompare(key) == .orderedSame
            }) {
                conflicts.append(SkillConfigurationLocalFieldConflict(
                    fieldKey: key,
                    environmentName: declaration.environmentName,
                    reason: "the installed skill now declares the same field"
                ))
                continue
            }
            if manifest.environment.contains(where: {
                $0.name.caseInsensitiveCompare(declaration.environmentName) == .orderedSame
            }) {
                conflicts.append(SkillConfigurationLocalFieldConflict(
                    fieldKey: key,
                    environmentName: declaration.environmentName,
                    reason: "the installed skill now uses the same environment variable"
                ))
                continue
            }
            if fields.contains(where: {
                $0.key.caseInsensitiveCompare(key) == .orderedSame
            }) {
                conflicts.append(SkillConfigurationLocalFieldConflict(
                    fieldKey: key,
                    environmentName: declaration.environmentName,
                    reason: "another local declaration uses the same field"
                ))
                continue
            }
            guard declaration.kind != .connection,
                  let valueType = SkillConfigValueType(rawValue: declaration.valueType) else {
                conflicts.append(SkillConfigurationLocalFieldConflict(
                    fieldKey: key,
                    environmentName: declaration.environmentName,
                    reason: "the stored local declaration is not a supported ordinary/secret field"
                ))
                continue
            }
            let kind: SkillConfigFieldKind = declaration.kind == .secret ? .secret : .variable
            fields.append(SkillConfigFieldRequirement(
                key: key,
                declaredBy: .local,
                title: declaration.title,
                detail: declaration.detail,
                kind: kind,
                valueType: valueType,
                required: declaration.required,
                sensitive: kind == .secret,
                defaultValue: nil,
                allowedValues: declaration.allowedValues,
                connectionKind: nil,
                allowedCredentialKinds: []
            ))
            environment.append(SkillConfigEnvironmentRequirement(
                name: declaration.environmentName,
                fieldKey: key,
                sensitive: kind == .secret
            ))
        }
        let merged = try SkillConfigRequirements(
            fields: fields,
            environment: environment
        ).validated()
        return MergedRequirements(requirements: merged, conflicts: conflicts)
    }

    // MARK: Unconfigure

    public func unconfigure(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        fieldKeys: [String]? = nil,
        requirements: SkillConfigRequirements,
        expectedRevision: Int? = nil,
        expectedProfileID: UUID? = nil
    ) async throws -> SkillConfigurationMutationOutcome {
        try requirements.validated()
        let snapshot = try await store.snapshot(skillID: skillID, profile: profile, target: target)
        let merged = try mergedRequirements(manifest: requirements, snapshot: snapshot)
        let effectiveRequirements = merged.requirements
        if let expectedProfileID, snapshot.profile?.id != expectedProfileID {
            throw SkillConfigurationError.configurationChanged
        }
        guard snapshot.profile != nil else {
            return SkillConfigurationMutationOutcome(
                status: await buildStatus(
                    snapshot: snapshot,
                    requirements: effectiveRequirements,
                    conflicts: merged.conflicts
                )
            )
        }
        let released: SkillConfigurationReleasedCredentials
        if let fieldKeys, !fieldKeys.isEmpty {
            for key in fieldKeys {
                guard effectiveRequirements.field(key) != nil else {
                    throw SkillConfigurationError.undeclaredField(key)
                }
            }
            released = try await store.unbindFields(
                skillID: skillID, profile: profile, target: target,
                fieldKeys: fieldKeys, expectedRevision: expectedRevision
            ).released
        } else {
            released = try await store.unconfigureProfile(
                skillID: skillID,
                profile: profile,
                target: target,
                expectedRevision: expectedRevision,
                expectedProfileID: expectedProfileID
            )
        }
        var warnings: [String] = []
        for id in Set(released.ownedUnreferenced) {
            do {
                try await vault.delete(CredentialHandle(id: id))
            } catch {
                warnings.append("A skill-owned secret could not be removed from the Keychain.")
            }
        }
        let finalSnapshot = try await store.snapshot(skillID: skillID, profile: profile, target: target)
        let finalMerged = try mergedRequirements(
            manifest: requirements,
            snapshot: finalSnapshot
        )
        return SkillConfigurationMutationOutcome(
            status: await buildStatus(
                snapshot: finalSnapshot,
                requirements: finalMerged.requirements,
                conflicts: finalMerged.conflicts
            ),
            warnings: warnings
        )
    }

    // MARK: Runtime resolution

    public func resolve(
        request: SkillConfigurationResolutionRequest,
        provenance: SkillRuntimeProvenance,
        requirements: SkillConfigRequirements
    ) async throws -> SkillRuntimeConfiguration {
        try requirements.validated()
        guard provenance.activeSkillIDs.contains(request.skillID) else {
            throw SkillConfigurationError.runtimeProvenanceRejectsSkill(request.skillID)
        }
        let snapshot = try await store.snapshot(
            skillID: request.skillID,
            profile: request.profile,
            target: request.target
        )
        let merged = try mergedRequirements(manifest: requirements, snapshot: snapshot)
        let effectiveRequirements = merged.requirements
        let status = await buildStatus(
            snapshot: snapshot,
            requirements: effectiveRequirements,
            conflicts: merged.conflicts
        )
        switch status.readiness {
        case .notInstalled:
            throw SkillConfigurationError.installationNotInstalled(request.skillID)
        case .sourceUnverified:
            throw SkillConfigurationError.sourceUnverified(request.skillID)
        case .needsReconfirmation:
            throw SkillConfigurationError.sourceUnverified(request.skillID)
        case .needsSetup:
            throw SkillConfigurationError.incompleteConfiguration(status.missingRequiredFields)
        case .locked:
            throw SkillConfigurationError.credentialLocked(
                status.fields.first(where: { $0.state == .locked })?.key ?? request.skillID
            )
        case .needsValidation:
            throw SkillConfigurationError.validationRequired(
                status.fields.filter { $0.kind == .connection && $0.state != .validated }.map(\.key)
            )
        case .invalid:
            throw SkillConfigurationError.validationFailed(
                status.fields.filter { $0.state == .invalid }.map(\.key)
            )
        case .configured, .ready:
            break
        }
        guard let profile = snapshot.profile,
              let installation = snapshot.currentInstallation else {
            throw SkillConfigurationError.installationNotInstalled(request.skillID)
        }
        let resolveUse = SkillRuntimeUseRequest(
            runID: provenance.runID,
            skillID: request.skillID,
            installationID: installation.installationID,
            profile: profile.profile,
            target: profile.target,
            revision: profile.revision,
            bindingGeneration: request.bindingGeneration,
            operation: .resolve,
            fieldKey: nil
        )
        switch await runtimeUseAuthorizer.authorize(resolveUse) {
        case .allowed:
            break
        case .denied(let reason):
            throw SkillConfigurationError.runtimeUseDenied(Self.boundedReason(reason))
        }
        let entries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.fieldKey, $0) })
        var variables: [String: String] = [:]
        for field in effectiveRequirements.fields where field.kind == .variable {
            if let value = entries[field.key]?.value ?? field.defaultValue {
                variables[field.key] = value
            }
        }
        let environment = ordinaryEnvironment(
            requirements: effectiveRequirements,
            variableValues: variables
        )
        let secretEnvironment = secretEnvironmentRequests(
            snapshot: snapshot,
            requirements: effectiveRequirements
        )
        var secretBindings: [String: SkillRuntimeSecretBinding] = [:]
        for binding in snapshot.bindings {
            guard effectiveRequirements.field(binding.fieldKey) != nil else { continue }
            secretBindings[binding.fieldKey] = SkillRuntimeSecretBinding(
                fieldKey: binding.fieldKey,
                credentialReference: CapturedSecret.placeholder(for: binding.credentialID),
                role: binding.role,
                deviceBound: binding.deviceBound,
                connectionKind: binding.connectionKind
            )
        }
        let authorization = SkillConfigurationAuthorization(
            installationID: installation.installationID,
            profileID: profile.id,
            profileName: profile.profile,
            target: profile.target,
            revision: profile.revision,
            runID: provenance.runID,
            bindingGeneration: request.bindingGeneration
        )
        return SkillRuntimeConfiguration(
            skillID: request.skillID,
            installationID: installation.installationID,
            profile: profile.profile,
            target: profile.target,
            revision: profile.revision,
            variables: variables,
            environment: environment,
            secretEnvironment: secretEnvironment,
            secretBindings: secretBindings,
            authorization: authorization
        )
    }

    /// Native connector only. Never expose the returned bytes to the model.
    public func readSecret(
        _ fieldKey: String,
        in configuration: SkillRuntimeConfiguration
    ) async throws -> Data {
        try await readSecret(
            fieldKey: fieldKey,
            skillID: configuration.skillID,
            authorization: configuration.authorization
        )
    }

    private func readSecret(
        fieldKey: String,
        skillID: String,
        authorization: SkillConfigurationAuthorization
    ) async throws -> Data {
        let snapshot = try await store.snapshot(
            skillID: skillID,
            profile: authorization.profileName,
            target: authorization.target
        )
        guard snapshot.installed,
              let installation = snapshot.currentInstallation,
              installation.configurationAllowed,
              let profile = snapshot.profile,
              profile.id == authorization.profileID,
              profile.installationID == authorization.installationID,
              profile.target == authorization.target,
              profile.revision == authorization.revision else {
            throw SkillConfigurationError.configurationChanged
        }
        guard let binding = snapshot.binding(fieldKey) else {
            throw SkillConfigurationError.credentialMissing(fieldKey)
        }
        switch await vault.availability(CredentialHandle(id: binding.credentialID)) {
        case .available:
            break
        case .missing:
            throw SkillConfigurationError.credentialMissing(fieldKey)
        case .locked:
            throw SkillConfigurationError.credentialLocked(fieldKey)
        case .failed:
            throw SkillConfigurationError.credentialMissing(fieldKey)
        }
        if let runID = authorization.runID {
            let use = SkillRuntimeUseRequest(
                runID: runID,
                skillID: skillID,
                installationID: installation.installationID,
                profile: profile.profile,
                target: profile.target,
                revision: profile.revision,
                bindingGeneration: authorization.bindingGeneration,
                operation: .readSecret,
                fieldKey: fieldKey
            )
            switch await runtimeUseAuthorizer.authorize(use) {
            case .allowed:
                break
            case .denied(let reason):
                throw SkillConfigurationError.runtimeUseDenied(Self.boundedReason(reason))
            }
        }
        return try await vault.resolveForScopedUse(
            CredentialHandle(id: binding.credentialID),
            use: ScopedCredentialUse(
                credentialID: binding.credentialID,
                purpose: "skill-config:\(authorization.installationID):\(authorization.profileName):\(authorization.target):\(fieldKey)@\(authorization.revision)"
            )
        )
    }

    // MARK: Helpers

    private func outcome(
        skillID: String,
        profile: String,
        target: String,
        manifest: SkillConfigRequirements
    ) async throws -> SkillConfigurationMutationOutcome {
        let snapshot = try await store.snapshot(skillID: skillID, profile: profile, target: target)
        let merged = try mergedRequirements(manifest: manifest, snapshot: snapshot)
        return SkillConfigurationMutationOutcome(
            status: await buildStatus(
                snapshot: snapshot,
                requirements: merged.requirements,
                conflicts: merged.conflicts
            )
        )
    }

    private func buildStatus(
        snapshot: SkillConfigurationSnapshot,
        requirements: SkillConfigRequirements,
        conflicts: [SkillConfigurationLocalFieldConflict] = []
    ) async -> SkillConfigurationStatus {
        let profile = snapshot.profile
        var entries: [String: SkillConfigurationEntry] = [:]
        for entry in snapshot.entries { entries[entry.fieldKey] = entry }
        var bindings: [String: SkillConfigurationBinding] = [:]
        for binding in snapshot.bindings { bindings[binding.fieldKey] = binding }
        var validations: [String: SkillConfigurationValidation] = [:]
        if let revision = profile?.revision {
            for validation in snapshot.validations where validation.revision == revision {
                validations[validation.fieldKey] = validation
            }
        }

        var fields: [SkillConfigurationFieldStatus] = []
        var missingRequired: [String] = []
        var anyLocked = false
        var hasInvalidConnection = false
        var connectionFields: [SkillConfigFieldRequirement] = []

        for field in requirements.fields {
            let ordinaryNames = requirements.environment.filter {
                $0.fieldKey.caseInsensitiveCompare(field.key) == .orderedSame
            }.map(\.name)
            switch field.kind {
            case .variable:
                let entry = entries[field.key]
                let effective = entry?.value ?? field.defaultValue
                let state: SkillConfigurationFieldState = effective == nil ? .missing : .configured
                if field.required, effective == nil { missingRequired.append(field.key) }
                fields.append(SkillConfigurationFieldStatus(
                    key: field.key,
                    declaredBy: field.declaredBy,
                    title: field.title ?? field.key,
                    kind: .variable,
                    required: field.required,
                    sensitive: field.sensitive,
                    state: state,
                    value: effective,
                    usedDefault: entry == nil && field.defaultValue != nil,
                    credentialReference: nil,
                    bindingRole: nil,
                    connectionKind: nil,
                    environmentNames: ordinaryNames,
                    secretEnvironmentNames: [],
                    message: field.required && effective == nil ? "Required value is missing." : nil
                ))
            case .secret:
                let binding = bindings[field.key]
                var state: SkillConfigurationFieldState = .missing
                var message: String?
                if let binding {
                    switch await vault.availability(CredentialHandle(id: binding.credentialID)) {
                    case .available:
                        state = .configured
                    case .missing:
                        state = .missingSecret
                        message = "The saved credential is missing."
                    case .locked:
                        state = .locked
                        anyLocked = true
                        message = "The saved credential is temporarily unavailable while the device is locked."
                    case .failed(let detail):
                        state = .missingSecret
                        message = detail.isEmpty ? "The saved credential is unavailable." : detail
                    }
                }
                if field.required, state == .missing || state == .missingSecret {
                    missingRequired.append(field.key)
                }
                fields.append(SkillConfigurationFieldStatus(
                    key: field.key,
                    declaredBy: field.declaredBy,
                    title: field.title ?? field.key,
                    kind: .secret,
                    required: field.required,
                    sensitive: true,
                    state: state,
                    value: nil,
                    usedDefault: false,
                    credentialReference: binding.map { CapturedSecret.placeholder(for: $0.credentialID) },
                    bindingRole: binding?.role,
                    connectionKind: nil,
                    environmentNames: [],
                    secretEnvironmentNames: ordinaryNames,
                    message: message
                ))
            case .connection:
                connectionFields.append(field)
                let binding = bindings[field.key]
                var state: SkillConfigurationFieldState = .missing
                var message: String?
                if let binding {
                    switch await vault.availability(CredentialHandle(id: binding.credentialID)) {
                    case .available:
                        if let validation = validations[field.key] {
                            switch validation.status {
                            case .validated:
                                state = .validated
                            case .invalid:
                                state = .invalid
                                hasInvalidConnection = true
                                message = validation.detail
                            case .unsupported:
                                state = .unsupported
                                message = validation.detail ?? "No native validator is available."
                            }
                        } else {
                            state = .validationRequired
                            message = "Run the native connection check to validate this configuration."
                        }
                    case .missing:
                        state = .missingSecret
                        message = "The saved connection credential is missing."
                    case .locked:
                        state = .locked
                        anyLocked = true
                        message = "The saved connection credential is temporarily unavailable while the device is locked."
                    case .failed(let detail):
                        state = .missingSecret
                        message = detail.isEmpty ? "The saved connection credential is unavailable." : detail
                    }
                }
                if field.required, state == .missing || state == .missingSecret {
                    missingRequired.append(field.key)
                }
                fields.append(SkillConfigurationFieldStatus(
                    key: field.key,
                    declaredBy: field.declaredBy,
                    title: field.title ?? field.key,
                    kind: .connection,
                    required: field.required,
                    sensitive: false,
                    state: state,
                    value: nil,
                    usedDefault: false,
                    credentialReference: binding.map { CapturedSecret.placeholder(for: $0.credentialID) },
                    bindingRole: binding?.role,
                    connectionKind: field.connectionKind,
                    environmentNames: [],
                    secretEnvironmentNames: [],
                    message: message
                ))
            }
        }

        let configuredConnections = connectionFields.filter { bindings[$0.key] != nil }
        let requiredConnections = connectionFields.filter(\.required)
        let allConfiguredConnectionsValidated = configuredConnections.allSatisfy {
            validations[$0.key]?.status == .validated
        }
        let locked = anyLocked
        let readiness: SkillConfigurationReadiness
        if !snapshot.installed {
            readiness = .notInstalled
        } else if let installation = snapshot.currentInstallation, !installation.configurationAllowed {
            readiness = .sourceUnverified
        } else if snapshot.sourceChanged {
            readiness = .needsReconfirmation
        } else if profile == nil {
            readiness = .needsSetup
        } else if !missingRequired.isEmpty {
            readiness = .needsSetup
        } else if locked {
            readiness = .locked
        } else if hasInvalidConnection {
            readiness = .invalid
        } else if !configuredConnections.isEmpty, !allConfiguredConnectionsValidated {
            readiness = .needsValidation
        } else if !requiredConnections.isEmpty {
            readiness = allConfiguredConnectionsValidated ? .ready : .needsValidation
        } else if !configuredConnections.isEmpty {
            readiness = .ready
        } else {
            readiness = .configured
        }

        let secretEnvironment = secretEnvironmentRequests(snapshot: snapshot, requirements: requirements)
        let nextActions = Self.nextActions(
            readiness: readiness,
            missingRequired: missingRequired,
            fields: fields
        )
        return SkillConfigurationStatus(
            skillID: snapshot.skillID,
            profile: profile?.profile ?? "default",
            target: profile?.target ?? "default",
            installed: snapshot.installed,
            sourceChanged: snapshot.sourceChanged,
            installation: snapshot.currentInstallation,
            revision: profile?.revision,
            readiness: readiness,
            fields: fields,
            missingRequiredFields: missingRequired,
            environmentNames: requirements.environment.compactMap { mapping in
                requirements.field(mapping.fieldKey)?.kind == .variable ? mapping.name : nil
            },
            secretEnvironment: secretEnvironment,
            validation: profile.map { current in
                snapshot.validations.filter { $0.revision == current.revision }
            } ?? [],
            localDeclarationConflicts: conflicts,
            nextActions: nextActions
        )
    }

    private func ordinaryEnvironment(
        requirements: SkillConfigRequirements,
        variableValues: [String: String]
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for mapping in requirements.environment {
            guard let field = requirements.field(mapping.fieldKey), field.kind == .variable else {
                continue
            }
            if let value = variableValues[field.key] {
                environment[mapping.name] = value
            }
        }
        return environment
    }

    private func secretEnvironmentRequests(
        snapshot: SkillConfigurationSnapshot,
        requirements: SkillConfigRequirements
    ) -> [SkillSecretEnvironmentRequest] {
        var requests: [SkillSecretEnvironmentRequest] = []
        for mapping in requirements.environment {
            guard let field = requirements.field(mapping.fieldKey), field.kind == .secret,
                  let binding = snapshot.binding(field.key) else { continue }
            requests.append(SkillSecretEnvironmentRequest(
                name: mapping.name,
                fieldKey: field.key,
                credentialReference: CapturedSecret.placeholder(for: binding.credentialID)
            ))
        }
        return requests
    }

    private static func nextActions(
        readiness: SkillConfigurationReadiness,
        missingRequired: [String],
        fields: [SkillConfigurationFieldStatus]
    ) -> [String] {
        switch readiness {
        case .notInstalled:
            return ["Install the skill through the reviewed install path before configuring it."]
        case .sourceUnverified:
            return ["Reinstall or re-import this skill through the reviewed install path so its source binding can be verified."]
        case .needsReconfirmation:
            return ["The installed source changed. Review the new source and enter its configuration again; previous secrets are not reused."]
        case .needsSetup:
            return ["Ask the user once for the missing values, then save or bind them: \(missingRequired.joined(separator: ", "))."]
        case .needsValidation:
            return ["Run the native connection validation for this revision."]
        case .invalid:
            return ["Resolve the failing connection check, then validate again."]
        case .locked:
            return ["Unlock the device so the Keychain item can be read. Retry; the saved credential was not deleted."]
        case .configured:
            return ["Configuration is saved. This skill declares no required live connection validation."]
        case .ready:
            return ["Configuration is validated at this revision and can be used by the runtime."]
        }
    }

    private static func canonicalValue(
        _ value: String,
        for field: SkillConfigFieldRequirement
    ) throws -> String {
        guard value.utf8.count <= 4_096,
              !value.utf8.contains(0) else {
            throw SkillConfigurationError.invalidValue(field: field.key, reason: "value is too large")
        }
        switch field.valueType {
        case .string:
            return value
        case .number:
            guard let number = Double(value), number.isFinite else {
                throw SkillConfigurationError.invalidValue(field: field.key, reason: "expected a number")
            }
            return value
        case .boolean:
            let lowered = value.lowercased()
            guard lowered == "true" || lowered == "false" else {
                throw SkillConfigurationError.invalidValue(field: field.key, reason: "expected true or false")
            }
            return lowered
        case .url:
            guard let components = URLComponents(string: value),
                  let scheme = components.scheme, !scheme.isEmpty else {
                throw SkillConfigurationError.invalidValue(field: field.key, reason: "expected an absolute URL")
            }
            return value
        case .enumeration:
            guard field.allowedValues.contains(value) else {
                throw SkillConfigurationError.invalidValue(
                    field: field.key,
                    reason: "expected one of: \(field.allowedValues.joined(separator: ", "))"
                )
            }
            return value
        }
    }

    private static func boundedReason(_ reason: String) -> String {
        let redacted = SecretRedactor.redact(reason)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((redacted.isEmpty ? "denied" : redacted).prefix(200))
    }

    private static func boundedDetail(_ message: String?) -> String? {
        guard let message else { return nil }
        let redacted = SecretRedactor.redact(message)
        let bounded = redacted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bounded.isEmpty else { return nil }
        return String(bounded.prefix(500))
    }

    /// A declared ordinary field whose key reads like a credential must be
    /// declared as `secret` instead, so a package cannot talk the user into
    /// storing a password in plain configuration metadata.
    static func looksSensitiveKey(_ key: String) -> Bool {
        var pieces: [String] = []
        var part = ""
        var previousLower = false
        for character in key {
            if !character.isLetter, !character.isNumber {
                if !part.isEmpty { pieces.append(part.lowercased()); part = "" }
                previousLower = false
                continue
            }
            if character.isUppercase, previousLower, !part.isEmpty {
                pieces.append(part.lowercased())
                part = ""
            }
            part.append(character)
            previousLower = character.isLowercase || character.isNumber
        }
        if !part.isEmpty { pieces.append(part.lowercased()) }
        let set = Set(pieces)
        let direct: Set<String> = [
            "password", "passwd", "passphrase", "secret", "credential", "apikey"
        ]
        if !set.isDisjoint(with: direct) { return true }
        if set.contains("api") && (set.contains("key") || set.contains("keys")) { return true }
        if set.contains("private") && (set.contains("key") || set.contains("keys")) { return true }
        return set.contains("token")
    }
}

import Foundation

/// Declared, user-fillable configuration for a skill. A package declares only
/// the shape of the fields it needs; it never carries values. The native
/// configuration store owns values, secret references and connection
/// bindings, and the runtime delivers them only to authorized targets.
///
/// The block is additive: manifests without `configuration` keep their exact
/// previous bytes, schema and behavior. Unknown field kinds, value types or a
/// malformed environment mapping fail closed at package validation.
public enum SkillConfigurationFieldKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// Ordinary value stored in the skill configuration record.
    case variable
    /// Secret stored only in Keychain; configuration keeps an opaque handle.
    case secret
    /// Native connection credential (for example an iOS Bridge pairing
    /// key). Always device-bound and resolved by the owning native client.
    case connection
}

public enum SkillConfigurationValueType: String, Codable, Sendable, CaseIterable, Hashable {
    case string
    case number
    case boolean
    case url
    case enumeration
}

/// Bilingual display text for a declared configuration field. Manifests may
/// provide `{en, zh-Hans}`; a plain string is accepted as the same fallback
/// for both languages so older/simple authors remain valid. Native UI can
/// select by the user's preferred language; the model-facing configuration
/// tool receives one already-selected value from the App adapter.
public struct SkillConfigurationLocalizedText: Codable, Equatable, Sendable, Hashable {
    public let en: String
    public let zhHans: String

    public init(en: String, zhHans: String) {
        self.en = en
        self.zhHans = zhHans
    }

    public func value(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        for language in preferredLanguages {
            if language.hasPrefix("zh") { return zhHans }
            if language.hasPrefix("en") { return en }
        }
        return en
    }

    private enum CodingKeys: String, CodingKey {
        case en
        case zhHans = "zh-Hans"
        case legacyZhHans = "zhHans"
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let text = try? single.decode(String.self) {
            self.init(en: text, zhHans: text)
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let en = try values.decode(String.self, forKey: .en)
        let current = try values.decodeIfPresent(String.self, forKey: .zhHans)
        let legacy = try values.decodeIfPresent(String.self, forKey: .legacyZhHans)
        if let current, let legacy, current != legacy {
            throw DecodingError.dataCorruptedError(
                forKey: .zhHans,
                in: values,
                debugDescription: "Conflicting Simplified Chinese text fields."
            )
        }
        guard let zhHans = current ?? legacy else {
            throw DecodingError.keyNotFound(
                CodingKeys.zhHans,
                .init(codingPath: decoder.codingPath, debugDescription: "Missing Simplified Chinese text.")
            )
        }
        self.init(en: en, zhHans: zhHans)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(en, forKey: .en)
        try values.encode(zhHans, forKey: .zhHans)
    }
}

public struct SkillConfigurationField: Codable, Equatable, Sendable, Hashable {
    /// Stable field key used by the configuration tool and the runtime
    /// resolver. Never a secret value.
    public var key: String
    public var title: SkillConfigurationLocalizedText?
    public var description: SkillConfigurationLocalizedText?
    public var kind: SkillConfigurationFieldKind
    public var valueType: SkillConfigurationValueType
    public var required: Bool
    /// True only for `secret` fields. Defaults to true for secrets so an
    /// author cannot accidentally declare a password-shaped field ordinary.
    public var sensitive: Bool
    public var defaultValue: String?
    public var allowedValues: [String]?
    public var connectionKind: String?
    /// Credential kinds this field may bind when it is a secret or
    /// connection. Empty/nil means the native default is used.
    public var credentialKinds: [String]?

    public init(
        key: String,
        title: SkillConfigurationLocalizedText? = nil,
        description: SkillConfigurationLocalizedText? = nil,
        kind: SkillConfigurationFieldKind = .variable,
        valueType: SkillConfigurationValueType = .string,
        required: Bool = false,
        sensitive: Bool? = nil,
        defaultValue: String? = nil,
        allowedValues: [String]? = nil,
        connectionKind: String? = nil,
        credentialKinds: [String]? = nil
    ) {
        self.key = key
        self.title = title
        self.description = description
        self.kind = kind
        self.valueType = valueType
        self.required = required
        self.sensitive = sensitive ?? (kind == .secret)
        self.defaultValue = defaultValue
        self.allowedValues = allowedValues
        self.connectionKind = connectionKind
        self.credentialKinds = credentialKinds
    }

    private enum CodingKeys: String, CodingKey {
        case key, title, description, kind, valueType, required, sensitive
        case defaultValue = "default"
        case allowedValues, connectionKind, credentialKinds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decodeIfPresent(SkillConfigurationLocalizedText.self, forKey: .title)
        description = try container.decodeIfPresent(SkillConfigurationLocalizedText.self, forKey: .description)
        kind = try container.decodeIfPresent(SkillConfigurationFieldKind.self, forKey: .kind)
            ?? .variable
        valueType = try container.decodeIfPresent(SkillConfigurationValueType.self, forKey: .valueType)
            ?? .string
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        sensitive = try container.decodeIfPresent(Bool.self, forKey: .sensitive)
            ?? (kind == .secret)
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
        allowedValues = try container.decodeIfPresent([String].self, forKey: .allowedValues)
        connectionKind = try container.decodeIfPresent(String.self, forKey: .connectionKind)
        credentialKinds = try container.decodeIfPresent([String].self, forKey: .credentialKinds)
    }
}

/// Named environment variable delivered to an authorized target process.
/// Ordinary variables travel in the ordinary environment dictionary. A
/// secret field's variable name is returned only as a separate sensitive /
/// native credential-reference delivery request: the generic configuration
/// resolver NEVER places the secret bytes in `environment`, a shell preamble
/// or a staged command file. Connections are opaque native credentials and
/// may not map to an environment variable.
public struct SkillEnvironmentVariable: Codable, Equatable, Sendable, Hashable {
    public var name: String
    public var field: String

    public init(name: String, field: String) {
        self.name = name
        self.field = field
    }
}

public struct SkillConfigurationRequirements: Codable, Equatable, Sendable, Hashable {
    public static let maximumFields = 32
    public static let maximumEnvironmentVariables = 64

    public var fields: [SkillConfigurationField]
    public var environment: [SkillEnvironmentVariable]

    public init(
        fields: [SkillConfigurationField] = [],
        environment: [SkillEnvironmentVariable] = []
    ) {
        self.fields = fields
        self.environment = environment
    }

    private enum CodingKeys: String, CodingKey {
        case fields, environment
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fields = try container.decodeIfPresent([SkillConfigurationField].self, forKey: .fields) ?? []
        environment = try container.decodeIfPresent([SkillEnvironmentVariable].self, forKey: .environment) ?? []
    }

    /// Bounded, fail-closed structural validation. Semantic credential-kind
    /// names are checked again by the native configuration store, which owns
    /// the authoritative credential taxonomy.
    public func validate() throws {
        guard fields.count <= Self.maximumFields else {
            throw SkillValidationError.invalidManifest(
                "configuration declares more than \(Self.maximumFields) fields"
            )
        }
        guard environment.count <= Self.maximumEnvironmentVariables else {
            throw SkillValidationError.invalidManifest(
                "configuration declares more than \(Self.maximumEnvironmentVariables) environment variables"
            )
        }
        var seenKeys = Set<String>()
        for field in fields {
            guard Self.isValidFieldKey(field.key) else {
                throw SkillValidationError.invalidManifest("invalid configuration field key: \(field.key)")
            }
            guard seenKeys.insert(field.key.lowercased()).inserted else {
                throw SkillValidationError.invalidManifest("duplicate configuration field key: \(field.key)")
            }
            try Self.validateText(field.title?.en, field: field.key, maximum: 120, label: "English title")
            try Self.validateText(field.title?.zhHans, field: field.key, maximum: 120, label: "Simplified Chinese title")
            try Self.validateText(field.description?.en, field: field.key, maximum: 600, label: "English description")
            try Self.validateText(field.description?.zhHans, field: field.key, maximum: 600, label: "Simplified Chinese description")
            switch field.kind {
            case .variable:
                guard !field.sensitive else {
                    throw SkillValidationError.invalidManifest(
                        "variable field '\(field.key)' must not be marked sensitive; declare kind secret"
                    )
                }
                guard field.connectionKind == nil else {
                    throw SkillValidationError.invalidManifest(
                        "variable field '\(field.key)' must not declare connectionKind"
                    )
                }
                guard field.credentialKinds == nil else {
                    throw SkillValidationError.invalidManifest(
                        "variable field '\(field.key)' must not declare credentialKinds"
                    )
                }
                try Self.validateValue(field)
            case .secret, .connection:
                guard field.valueType == .string else {
                    throw SkillValidationError.invalidManifest(
                        "\(field.kind.rawValue) field '\(field.key)' must use valueType string"
                    )
                }
                guard field.defaultValue == nil else {
                    throw SkillValidationError.invalidManifest(
                        "\(field.kind.rawValue) field '\(field.key)' must not declare a default value"
                    )
                }
                guard field.allowedValues == nil else {
                    throw SkillValidationError.invalidManifest(
                        "\(field.kind.rawValue) field '\(field.key)' must not declare allowedValues"
                    )
                }
                if field.kind == .secret, !field.sensitive {
                    throw SkillValidationError.invalidManifest(
                        "secret field '\(field.key)' must be sensitive"
                    )
                }
                if field.kind == .connection, field.sensitive {
                    throw SkillValidationError.invalidManifest(
                        "connection field '\(field.key)' must not be marked sensitive"
                    )
                }
            }
            if field.kind == .connection {
                guard let connectionKind = field.connectionKind,
                      Self.isValidConnectionKind(connectionKind) else {
                    throw SkillValidationError.invalidManifest(
                        "connection field '\(field.key)' requires a valid connectionKind"
                    )
                }
            } else if field.connectionKind != nil {
                throw SkillValidationError.invalidManifest(
                    "field '\(field.key)' declares connectionKind but is not a connection"
                )
            }
            if let credentialKinds = field.credentialKinds {
                guard field.kind != .variable else {
                    throw SkillValidationError.invalidManifest(
                        "variable field '\(field.key)' must not declare credentialKinds"
                    )
                }
                guard !credentialKinds.isEmpty, credentialKinds.count <= 8 else {
                    throw SkillValidationError.invalidManifest(
                        "field '\(field.key)' declares an invalid credentialKinds list"
                    )
                }
                guard Set(credentialKinds).count == credentialKinds.count else {
                    throw SkillValidationError.invalidManifest(
                        "field '\(field.key)' declares duplicate credentialKinds"
                    )
                }
                for kind in credentialKinds where !Self.isValidCredentialKindToken(kind) {
                    throw SkillValidationError.invalidManifest(
                        "field '\(field.key)' declares an invalid credential kind: \(kind)"
                    )
                }
            }
        }

        var fieldsByKey: [String: SkillConfigurationField] = [:]
        for field in fields { fieldsByKey[field.key.lowercased()] = field }
        var seenEnvironment = Set<String>()
        for variable in environment {
            guard Self.isValidEnvironmentName(variable.name) else {
                throw SkillValidationError.invalidManifest(
                    "invalid environment variable name: \(variable.name)"
                )
            }
            guard !Self.reservedEnvironmentNames.contains(variable.name.uppercased()) else {
                throw SkillValidationError.invalidManifest(
                    "environment variable '\(variable.name)' is reserved"
                )
            }
            guard seenEnvironment.insert(variable.name.uppercased()).inserted else {
                throw SkillValidationError.invalidManifest(
                    "duplicate environment variable: \(variable.name)"
                )
            }
            guard let field = fieldsByKey[variable.field.lowercased()] else {
                throw SkillValidationError.invalidManifest(
                    "environment variable '\(variable.name)' references unknown field '\(variable.field)'"
                )
            }
            // Secret fields may request a named child environment variable,
            // but the value is delivered only through the separate sensitive
            // credential-reference channel. Connections are opaque native
            // credentials and never become environment variables.
            guard field.kind != .connection else {
                throw SkillValidationError.invalidManifest(
                    "environment variable '\(variable.name)' must not reference connection field '\(variable.field)'"
                )
            }
        }
    }

    private static func validateText(
        _ value: String?,
        field: String,
        maximum: Int,
        label: String
    ) throws {
        guard let value else { return }
        guard !value.isEmpty, value.count <= maximum else {
            throw SkillValidationError.invalidManifest(
                "field '\(field)' has an empty or too long \(label)"
            )
        }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SkillValidationError.invalidManifest(
                "field '\(field)' \(label) contains control characters"
            )
        }
    }

    private static func validateValue(_ field: SkillConfigurationField) throws {
        switch field.valueType {
        case .string:
            break
        case .number:
            if let value = field.defaultValue,
               Double(value) == nil || !value.allSatisfy({ $0.isASCII }) {
                throw SkillValidationError.invalidManifest(
                    "field '\(field.key)' declares a non-numeric default"
                )
            }
        case .boolean:
            if let value = field.defaultValue,
               !["true", "false"].contains(value.lowercased()) {
                throw SkillValidationError.invalidManifest(
                    "field '\(field.key)' declares a non-boolean default"
                )
            }
        case .url:
            if let value = field.defaultValue,
               !Self.isAbsoluteURL(value) {
                throw SkillValidationError.invalidManifest(
                    "field '\(field.key)' declares an invalid URL default"
                )
            }
        case .enumeration:
            guard let allowedValues = field.allowedValues,
                  !allowedValues.isEmpty,
                  allowedValues.count <= 64 else {
                throw SkillValidationError.invalidManifest(
                    "enumeration field '\(field.key)' requires 1...64 allowedValues"
                )
            }
            var seen = Set<String>()
            for value in allowedValues {
                guard !value.isEmpty, value.count <= 256,
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      seen.insert(value).inserted else {
                    throw SkillValidationError.invalidManifest(
                        "enumeration field '\(field.key)' declares an invalid or duplicate allowed value"
                    )
                }
            }
            if let defaultValue = field.defaultValue, !seen.contains(defaultValue) {
                throw SkillValidationError.invalidManifest(
                    "enumeration field '\(field.key)' has a default outside allowedValues"
                )
            }
        }
        if field.valueType != .enumeration, field.allowedValues != nil {
            throw SkillValidationError.invalidManifest(
                "field '\(field.key)' declares allowedValues without valueType enumeration"
            )
        }
    }

    static func isValidFieldKey(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(first) else { return false }
        guard value.utf8.count <= 64 else { return false }
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

    static func isValidCredentialKindToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
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

    static func isAbsoluteURL(_ value: String) -> Bool {
        guard value.utf8.count <= 2_048,
              let components = URLComponents(string: value),
              let scheme = components.scheme,
              !scheme.isEmpty else { return false }
        return true
    }

    /// Names a target process inherits from its own launch contract; a skill
    /// declaration must never override them.
    static let reservedEnvironmentNames: Set<String> = [
        "PATH", "HOME", "SHELL", "USER", "LOGNAME", "TMPDIR", "PWD",
        "LD_PRELOAD", "LD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH", "PYTHONPATH", "PYTHONHOME", "IFS", "ENV",
        "BASH_ENV", "ZDOTDIR"
    ]
}

// FloeCore — Canonical provider configuration validation.
//
// Single source of truth for the provider/model configuration invariants
// enforced at every write boundary: the editor preflight, the local SQLite
// store and CloudKit remote-apply. `ProviderProfile.validate()` delegates
// here. The byte bound is retained; editor normalization accepts pasted names
// and Unicode joiners without weakening endpoint/header rules. This file adds:
//
//   * structured, field-level issues that preserve the rejected input,
//   * human-readable English and Simplified Chinese messages (the App layer
//     maps the stable `messageKey` to its catalog for final presentation),
//   * a non-throwing audit used by sync/import to decide whether an
//     untrusted remote or bundled payload is safe to persist.
//
// User-entered strings are treated as untrusted data. Issues carry a short
// echo of the offending value for inline presentation; they must never be
// written to logs, sync metadata or public documentation.

import Foundation

/// The form field or record component a validation issue belongs to. Used
/// by the editor to mark the specific field instead of showing one generic
/// alert, and by callers that persist/import configurations.
public enum ProviderConfigurationField: String, Sendable, Hashable, CaseIterable {
    case displayName
    case baseURL
    case nonSecretHeader
    case plainHTTP
    /// One of the provider's selected models.
    case model
    /// Bundle-level problem that cannot be attributed to one field.
    case form
}

/// Machine-readable reason. Stable string for tests and catalog mapping;
/// never includes user content.
public enum ProviderConfigurationProblem: String, Sendable, Hashable {
    case displayNameEmpty
    case displayNameTooLong
    case displayNameControlCharacter
    case baseURLMalformed
    case baseURLEmbedsCredentials
    case baseURLUnsupportedScheme
    case plainHTTPRequiresAcknowledgement
    case plainHTTPRequiresPrivateNetwork
    case headerForbidden
    case modelRemoteIDEmpty
    case modelDisplayNameEmpty
    case modelLimitsInvalid
    case modelOutputExceedsContext
    case malformed
}

/// One structured validation finding. `echo` is the offending user string
/// (never logged) kept so the editor can present/restore the input.
public struct ProviderConfigurationIssue: Sendable, Hashable, Identifiable {
    public var id: Int { hashValue }
    public let field: ProviderConfigurationField
    public let problem: ProviderConfigurationProblem
    /// Stable catalog key for the user-facing message.
    public let messageKey: String
    /// Positional, non-secret arguments for the message (byte counts, header
    /// names). Never contains the rejected value itself.
    public let arguments: [String]
    /// The rejected input, trimmed the same way validation trims it. Kept for
    /// inline presentation only; callers must not log or sync it.
    public let echo: String?

    public init(
        field: ProviderConfigurationField,
        problem: ProviderConfigurationProblem,
        messageKey: String,
        arguments: [String] = [],
        echo: String? = nil
    ) {
        self.field = field
        self.problem = problem
        self.messageKey = messageKey
        self.arguments = arguments
        self.echo = echo
    }
}

/// Aggregated validation failure. Carries every issue found in one pass so
/// the editor can mark all offending fields at once. Construct only with at
/// least one issue; `validate(_:)` guarantees this.
public struct ProviderConfigurationValidationReport: Error, Sendable, Hashable {
    public let issues: [ProviderConfigurationIssue]

    public init(issues: [ProviderConfigurationIssue]) {
        self.issues = issues
    }

    /// First issue in stable order, or nil for an empty (successful) audit.
    /// Never traps: callers may construct empty reports to mean "no problem".
    public var primary: ProviderConfigurationIssue? {
        issues.first
    }
}

extension ProviderConfigurationValidationReport: LocalizedError {
    public var errorDescription: String? {
        guard let primary else { return nil }
        return ProviderConfigurationValidation.message(for: primary, language: .english)
    }
}

/// Bilingual presentation language for validation messages. The App layer
/// normally passes `FloeL10n.currentLanguageCode`; package/host tests use the
/// explicit cases without booting the app localization stack.
public enum ProviderValidationLanguage: String, Sendable, Hashable {
    case english
    case chinese

    public static func resolve(_ code: String) -> ProviderValidationLanguage {
        code.hasPrefix("zh") ? .chinese : .english
    }
}

/// Canonical provider/model configuration validation.
public enum ProviderConfigurationValidation {

    /// Hard bounds (unchanged since the rule was introduced).
    public static let displayNameMaxUTF8Bytes = 256

    // MARK: - Provider

    /// Audits one provider profile against the persisted invariants. Pure and
    /// non-throwing; returns every issue found in a stable order
    /// (display name → endpoint URL → headers → transport policy).
    public static func issues(for provider: ProviderProfile) -> [ProviderConfigurationIssue] {
        var result: [ProviderConfigurationIssue] = []
        if let name = provider.displayName {
            result.append(contentsOf: displayNameIssues(name))
        }
        if provider.baseURL.user != nil || provider.baseURL.password != nil {
            result.append(.init(
                field: .baseURL,
                problem: .baseURLEmbedsCredentials,
                messageKey: "providers.validation.endpoint_credentials_in_url"
            ))
        }
        if let forbidden = provider.nonSecretHeaders.keys.first(where: {
            Self.forbiddenHeaderNames.contains($0.lowercased())
        }) {
            result.append(.init(
                field: .nonSecretHeader,
                problem: .headerForbidden,
                messageKey: "providers.validation.header_forbidden",
                arguments: [forbidden],
                echo: forbidden
            ))
        }
        let scheme = provider.baseURL.scheme?.lowercased() ?? ""
        if scheme == "http" {
            if !provider.allowsPlainHTTP {
                result.append(.init(
                    field: .plainHTTP,
                    problem: .plainHTTPRequiresAcknowledgement,
                    messageKey: "providers.validation.plain_http_ack"
                ))
            } else if !provider.baseURL.isLocalOrPrivateNetwork {
                result.append(.init(
                    field: .plainHTTP,
                    problem: .plainHTTPRequiresPrivateNetwork,
                    messageKey: "providers.validation.plain_http_private_only"
                ))
            }
        } else if scheme != "https" {
            result.append(.init(
                field: .baseURL,
                problem: .baseURLUnsupportedScheme,
                messageKey: "providers.validation.endpoint_scheme"
            ))
        }
        return result
    }

    /// Throws the first violation as a `FloeError.invalidConfiguration`
    /// carrying the exact legacy English message. Existing callers and tests
    /// depend on this error type and wording; field-level/bilingual reporting
    /// is available through `issues(for:)`/`message(for:language:)`.
    public static func validate(_ provider: ProviderProfile) throws {
        switch issues(for: provider).first {
        case nil: return
        case .some(let issue):
            throw FloeError.invalidConfiguration(legacyMessage(for: issue))
        }
    }

    // MARK: - Display name

    /// Canonical single-line editor metadata. Preserve meaningful Unicode
    /// joiners and variation selectors; discard copy/paste formatting only.
    /// Never truncate: the final UTF-8 size is validated before any write.
    public static func normalizedDisplayName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var result = String.UnicodeScalarView()
        var separating = false
        for scalar in raw.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                separating = !result.isEmpty
            } else if isDiscardedDisplayNameFormat(scalar) {
                continue
            } else {
                if separating { result.append(" "); separating = false }
                result.append(scalar)
            }
        }
        let name = String(result)
        return name.isEmpty ? nil : name
    }

    private static func isDiscardedDisplayNameFormat(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x061C, 0x180E, 0x200B, 0x200E...0x200F,
             0x202A...0x202E, 0x2060...0x206F, 0xFEFF:
            return true
        default: return false
        }
    }

    private static func isUnsupportedDisplayNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        // Foundation includes format characters in controlCharacters. ZWNJ
        // and ZWJ are meaningful in scripts and emoji; retain them, along
        // with emoji tag sequences and variation selectors.
        switch scalar.value {
        case 0x200C...0x200D, 0xE0020...0xE007F: return false
        default: return CharacterSet.controlCharacters.contains(scalar)
        }
    }

    /// Validates an *already normalized* (trimmed, non-optional) name.
    public static func displayNameIssues(_ name: String) -> [ProviderConfigurationIssue] {
        var result: [ProviderConfigurationIssue] = []
        if name.isEmpty {
            result.append(.init(
                field: .displayName,
                problem: .displayNameEmpty,
                messageKey: "providers.validation.display_name_empty",
                arguments: [String(displayNameMaxUTF8Bytes)],
                echo: name
            ))
        } else {
            if name.utf8.count > displayNameMaxUTF8Bytes {
                result.append(.init(
                    field: .displayName,
                    problem: .displayNameTooLong,
                    messageKey: "providers.validation.display_name_too_long",
                    arguments: [String(displayNameMaxUTF8Bytes), String(name.utf8.count)],
                    echo: name
                ))
            }
            if name.unicodeScalars.contains(where: isUnsupportedDisplayNameScalar) {
                result.append(.init(
                    field: .displayName,
                    problem: .displayNameControlCharacter,
                    messageKey: "providers.validation.display_name_control",
                    arguments: [String(displayNameMaxUTF8Bytes)],
                    echo: name
                ))
            }
        }
        return result
    }

    // MARK: - Models

    /// Mirrors `ConfigurationCodec.validate(model:)` at the package boundary
    /// so editor preflight and remote sync apply the identical rule without
    /// depending on the persistence module.
    public static func issues(for model: ModelProfile) -> [ProviderConfigurationIssue] {
        var result: [ProviderConfigurationIssue] = []
        let trimmedID = model.remoteModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedID.isEmpty {
            result.append(.init(
                field: .model,
                problem: .modelRemoteIDEmpty,
                messageKey: "providers.validation.model_remote_id_empty",
                echo: model.remoteModelID
            ))
        }
        if model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.init(
                field: .model,
                problem: .modelDisplayNameEmpty,
                messageKey: "providers.validation.model_display_name_empty",
                echo: model.displayName
            ))
        }
        if model.limits.contextTokens <= 0 || model.limits.maxOutputTokens < 0 {
            result.append(.init(
                field: .model,
                problem: .modelLimitsInvalid,
                messageKey: "providers.validation.model_limits_invalid"
            ))
        } else if model.limits.maxOutputTokens != 0
                    && model.limits.maxOutputTokens > model.limits.contextTokens {
            result.append(.init(
                field: .model,
                problem: .modelOutputExceedsContext,
                messageKey: "providers.validation.model_output_exceeds_context"
            ))
        }
        return result
    }

    public static func validate(_ model: ModelProfile) throws {
        switch issues(for: model).first {
        case nil: return
        case .some(let issue):
            throw FloeError.invalidConfiguration(legacyMessage(for: issue))
        }
    }

    /// Exact legacy English messages used by the throwing entry points and by
    /// `ProviderProfile.validate()`. Keep byte-identical: callers, tests and
    /// the installed-build error surface recognize these strings.
    public static func legacyMessage(for issue: ProviderConfigurationIssue) -> String {
        switch issue.problem {
        case .displayNameEmpty, .displayNameTooLong, .displayNameControlCharacter:
            return "Provider display name must be 1...256 bytes without control characters"
        case .baseURLMalformed:
            return "Invalid base URL"
        case .baseURLEmbedsCredentials:
            return "Endpoint credentials belong in Keychain, not in the URL"
        case .baseURLUnsupportedScheme:
            return "Endpoint must use http or https scheme"
        case .plainHTTPRequiresAcknowledgement:
            return "Plain HTTP requires explicit allowsPlainHTTP acknowledgement"
        case .plainHTTPRequiresPrivateNetwork:
            return "Plain HTTP is only permitted for localhost or private-network endpoints"
        case .headerForbidden:
            let name = issue.arguments.first ?? ""
            return "\(name) may contain a secret and cannot be stored as a non-secret header"
        case .modelRemoteIDEmpty:
            return "Remote model identifier cannot be empty"
        case .modelDisplayNameEmpty:
            return "Model display name cannot be empty"
        case .modelLimitsInvalid:
            return "Model context must be positive and maximum output cannot be negative"
        case .modelOutputExceedsContext:
            return "Maximum output cannot exceed model context"
        case .malformed:
            return "Configuration is malformed and cannot be saved"
        }
    }

    // MARK: - Bundle preflight

    /// Complete preflight for an editor save or an import/sync payload:
    /// validates the provider and every selected model BEFORE any credential,
    /// Keychain-sync or database side effect. Returns all issues found.
    public static func issues(
        provider: ProviderProfile,
        models: [ModelProfile]
    ) -> [ProviderConfigurationIssue] {
        var result = issues(for: provider)
        for model in models {
            result.append(contentsOf: issues(for: model))
        }
        return result
    }

    // MARK: - Messages

    /// Human-readable, field-level message in the requested language. These
    /// bilingual strings live at the validation boundary so non-App callers
    /// (extensions, sync engine, host tests) get readable errors without the
    /// app catalog; the App layer overrides presentation through
    /// `providers.validation.*` catalog keys (see REPORT integration patch).
    public static func message(
        for issue: ProviderConfigurationIssue,
        language: ProviderValidationLanguage
    ) -> String {
        switch language {
        case .english:
            return englishMessage(issue)
        case .chinese:
            return chineseMessage(issue)
        }
    }

    private static func englishMessage(_ issue: ProviderConfigurationIssue) -> String {
        let maxBytes = issue.arguments.first ?? String(displayNameMaxUTF8Bytes)
        switch issue.problem {
        case .displayNameEmpty:
            return "Enter a provider name or leave it blank to use the default."
        case .displayNameTooLong:
            let actual = issue.arguments.dropFirst().first ?? "?"
            return "Provider display name is \(actual) UTF-8 bytes; the maximum is \(maxBytes). Shorten the name without pasting it into another field."
        case .displayNameControlCharacter:
            return "Provider name contains an unsupported control character. Remove it and save again."
        case .baseURLMalformed:
            return "Enter a valid endpoint URL, for example https://api.example.com/v1"
        case .baseURLEmbedsCredentials:
            return "Endpoint credentials belong in the API key field, not in the URL"
        case .baseURLUnsupportedScheme:
            return "Endpoint must use http or https"
        case .plainHTTPRequiresAcknowledgement:
            return "Plain HTTP requires explicit acknowledgement"
        case .plainHTTPRequiresPrivateNetwork:
            return "Plain HTTP is only permitted for localhost or private-network endpoints"
        case .headerForbidden:
            let name = issue.arguments.first ?? "header"
            return "“\(name)” may contain a secret and cannot be stored as a non-secret header"
        case .modelRemoteIDEmpty:
            return "Model identifier cannot be empty"
        case .modelDisplayNameEmpty:
            return "Model display name cannot be empty"
        case .modelLimitsInvalid:
            return "Model context must be positive and maximum output cannot be negative"
        case .modelOutputExceedsContext:
            return "Maximum output cannot exceed model context"
        case .malformed:
            return "Configuration is malformed and cannot be saved"
        }
    }

    private static func chineseMessage(_ issue: ProviderConfigurationIssue) -> String {
        let maxBytes = issue.arguments.first ?? String(displayNameMaxUTF8Bytes)
        switch issue.problem {
        case .displayNameEmpty:
            return "请输入服务商名称，或留空使用默认名称"
        case .displayNameTooLong:
            let actual = issue.arguments.dropFirst().first ?? "?"
            return "服务商名称为 \(actual) 个 UTF-8 字节，上限为 \(maxBytes) 字节；请缩短名称，不要把名称粘贴到其他字段"
        case .displayNameControlCharacter:
            return "服务商名称包含不支持的控制字符，请删除后重新保存"
        case .baseURLMalformed:
            return "请输入有效的接口地址，例如 https://api.example.com/v1"
        case .baseURLEmbedsCredentials:
            return "接口的凭据应填写在 API 密钥字段，不能放在网址中"
        case .baseURLUnsupportedScheme:
            return "接口地址必须使用 http 或 https"
        case .plainHTTPRequiresAcknowledgement:
            return "使用明文 HTTP 需要明确确认"
        case .plainHTTPRequiresPrivateNetwork:
            return "明文 HTTP 仅允许用于本机或内网地址"
        case .headerForbidden:
            let name = issue.arguments.first ?? "header"
            return "“\(name)” 可能包含密钥，不能作为非机密请求头保存"
        case .modelRemoteIDEmpty:
            return "模型标识符不能为空"
        case .modelDisplayNameEmpty:
            return "模型显示名称不能为空"
        case .modelLimitsInvalid:
            return "模型上下文长度必须为正数，最大输出不能为负数"
        case .modelOutputExceedsContext:
            return "最大输出长度不能超过模型上下文长度"
        case .malformed:
            return "配置格式有误，无法保存"
        }
    }

    private static let forbiddenHeaderNames: Set<String> = [
        "authorization", "proxy-authorization", "x-api-key", "api-key",
        "x-auth-token", "x-amz-security-token", "cookie", "set-cookie"
    ]
}

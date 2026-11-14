// Secret-free, versioned values carried by the existing configuration sync.
import Foundation

public struct ApplicationSettingRecord: Codable, Sendable, Equatable {
    public static let recordPrefix = "app-setting.v1."
    public static let cloudRecordType = "ApplicationSetting"
    public static let storagePrefix = "sync.application-setting."
    public var schemaVersion: Int
    public var key: String
    /// Canonical typed JSON only. Nil is a durable per-setting tombstone.
    public var value: Data?
    public var updatedAt: Date

    public init(key: String, value: Data?, updatedAt: Date = Date(), schemaVersion: Int = 1) {
        self.schemaVersion = schemaVersion; self.key = key; self.value = value; self.updatedAt = updatedAt
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, key, value, updatedAt }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
        key = try fields.decode(String.self, forKey: .key)
        updatedAt = try fields.decode(Date.self, forKey: .updatedAt)
        guard fields.contains(.value) else {
            throw DecodingError.keyNotFound(CodingKeys.value, .init(codingPath: fields.codingPath,
                debugDescription: "An application setting requires an explicit value or tombstone"))
        }
        value = try fields.decodeIfPresent(Data.self, forKey: .value)
    }
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(schemaVersion, forKey: .schemaVersion); try fields.encode(key, forKey: .key)
        try fields.encode(updatedAt, forKey: .updatedAt)
        if let value { try fields.encode(value, forKey: .value) }
        else { try fields.encodeNil(forKey: .value) }
    }
    public var recordID: String { Self.recordPrefix + key }
    public var storageKey: String { Self.storagePrefix + key }
    public static func key(recordID: String) -> String? {
        guard recordID.hasPrefix(recordPrefix) else { return nil }
        let key = String(recordID.dropFirst(recordPrefix.count))
        return ApplicationSettingPolicy.isAllowed(key) ? key : nil
    }
    public func validated(recordID: String? = nil) throws -> Self {
        guard schemaVersion == 1, updatedAt.timeIntervalSince1970.isFinite,
              ApplicationSettingPolicy.isAllowed(key), recordID == nil || recordID == self.recordID else {
            throw FloeError.invalidConfiguration("Unsupported application setting")
        }
        var copy = self
        if let value { copy.value = try ApplicationSettingPolicy.canonicalValue(value, for: key) }
        return copy
    }
    public static func encodeValue<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

public struct SyncedASRSelection: Codable, Sendable, Equatable {
    public var primaryProfileID: UUID?
    public var legacyAliasProfileID: UUID?
    public init(primaryProfileID: UUID?, legacyAliasProfileID: UUID?) {
        self.primaryProfileID = primaryProfileID; self.legacyAliasProfileID = legacyAliasProfileID
    }
}

public struct SyncedAssistantAudioPriorities: Codable, Sendable, Equatable {
    public var transcriptionPriority: [String]
    public var synthesisPriority: [String]
    public init(transcriptionPriority: [String], synthesisPriority: [String]) {
        self.transcriptionPriority = transcriptionPriority; self.synthesisPriority = synthesisPriority
    }
}

public enum ApplicationSettingPolicy {
    public static let asrProfilePrefix = "speech.asr.profile."
    public static let asrSelection = "speech.asr.selection"
    public static let ttsProfilePrefix = "speech.tts.profile."
    public static let ttsSelection = "speech.tts.selection"
    public static let ttsVoiceNames = "speech.tts.voice-names"
    public static let audioPriorities = "speech.assistant.priorities"
    public static let defaultsPrefix = "defaults."
    public static let databasePrefix = "database."
    public static let maximumValueBytes = 65_536
    public static let defaultsKeys: Set<String> = [
        "voice.input.method.v1", "org.floeagent.voice.recognitionLanguage",
        "floe.settings.appearance", "floe.settings.language", "floe.settings.reduceMotion",
        "floe.settings.hapticsEnabled", "floe.settings.dateTimeStyle",
        "floe.settings.userQuestionDefaults.v1", "documentAssistant.leavePolicy.v1",
        "floe.settings.hardwareReturnBehavior"
    ]
    public static let dataDefaultsKeys: Set<String> = ["floe.settings.userQuestionDefaults.v1"]
    public static let databaseKeys: Set<String> = [
        AppSettingsKey.defaultStartPage, AppSettingsKey.runningInputMode,
        AppSettingsKey.verifyFinalAnswer, AppSettingsKey.semanticContextCompaction,
        AppSettingsKey.executionTimeoutSeconds, AppSettingsKey.maxOutputBytes, AppSettingsKey.savesArtifacts,
        AppSettingsKey.sshDefaults, AppSettingsKey.vncDefaults, AppSettingsKey.idleDisconnectMinutes,
        "speech.rate", "speech.pitch", "speech.voiceIdentifier"
    ]
    public static func profileID(_ key: String) -> UUID? {
        guard key.hasPrefix(asrProfilePrefix) else { return nil }
        return UUID(uuidString: String(key.dropFirst(asrProfilePrefix.count)))
    }
    public static func asrKey(_ id: UUID) -> String { asrProfilePrefix + id.uuidString.lowercased() }
    public static func ttsBucket(_ value: TTSSettingsSnapshot) -> String {
        if value.provider == .onDevice, !value.modelID.isEmpty {
            return "onDevice." + FloeDigest.sha256Hex(Data(value.modelID.utf8))
        }
        return value.provider.rawValue + "." + value.billingRoute.rawValue
    }
    public static func isAllowed(_ key: String) -> Bool {
        guard key.utf8.count <= 180 else { return false }
        if let id = profileID(key) { return key == asrKey(id) }
        if key.hasPrefix(ttsProfilePrefix) {
            let bucket = String(key.dropFirst(ttsProfilePrefix.count))
            if bucket.hasPrefix("onDevice.") {
                let hash = bucket.dropFirst("onDevice.".count)
                return hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            }
            return TTSSpeakerProvider.allCases.contains { provider in
                TTSBillingRoute.allCases.contains { provider.rawValue + "." + $0.rawValue == bucket }
            }
        }
        if [asrSelection, ttsSelection, ttsVoiceNames, audioPriorities].contains(key) { return true }
        if key.hasPrefix(defaultsPrefix) { return defaultsKeys.contains(String(key.dropFirst(defaultsPrefix.count))) }
        if key.hasPrefix(databasePrefix) { return databaseKeys.contains(String(key.dropFirst(databasePrefix.count))) }
        return false
    }

    public static func canonicalValue(_ data: Data, for key: String) throws -> Data {
        guard isAllowed(key), data.count <= maximumValueBytes else { throw invalid() }
        let decoder = JSONDecoder()
        if key == defaultsPrefix + "floe.settings.userQuestionDefaults.v1" {
            struct Value: Codable { var optionalTimeoutSeconds: Int }
            let value = try decoder.decode(Value.self, from: data)
            guard (5...86_400).contains(value.optionalTimeoutSeconds) else { throw invalid() }
            return try ApplicationSettingRecord.encodeValue(value)
        }
        if let id = profileID(key) {
            var profile = try decoder.decode(ASRProfile.self, from: data)
            guard profile.id == id, profile.validationProblem() == nil, profile.credentialReference == nil,
                  profile.name.utf8.count <= 512 else { throw invalid() }
            // Secret references never cross the settings wire. A receiver
            // derives its sole allowed account from this validated origin.
            profile.credentialReference = nil
            return try ApplicationSettingRecord.encodeValue(profile)
        }
        if key == asrSelection {
            return try ApplicationSettingRecord.encodeValue(decoder.decode(SyncedASRSelection.self, from: data))
        }
        if key == ttsSelection || key.hasPrefix(ttsProfilePrefix) {
            var value = try decoder.decode(TTSSettingsSnapshot.self, from: data)
            guard value.modelID.utf8.count <= 512, value.voiceID.utf8.count <= 1_024,
                  (value.language?.utf8.count ?? 0) <= 64,
                  !value.provider.requiresCloudCredential || value.provider.supportedBillingRoutes.contains(value.billingRoute),
                  key == ttsSelection || key == ttsProfilePrefix + ttsBucket(value) else { throw invalid() }
            value.openAIBaseURL = value.provider == .openAI
                ? try TTSOpenAISpeechEndpoint.normalized(value.openAIBaseURL) : nil
            return try ApplicationSettingRecord.encodeValue(value)
        }
        if key == ttsVoiceNames {
            let names = try decoder.decode([String: String].self, from: data)
            guard names.count <= 256, names.allSatisfy({ $0.key.utf8.count <= 1_024 && $0.value.count <= 120 }) else { throw invalid() }
            return try ApplicationSettingRecord.encodeValue(names)
        }
        if key == audioPriorities {
            let value = try decoder.decode(SyncedAssistantAudioPriorities.self, from: data)
            guard [value.transcriptionPriority, value.synthesisPriority].allSatisfy({ values in
                values.count <= 64 && values.allSatisfy { !$0.isEmpty && $0.utf8.count <= 160 && !$0.contains("\n") }
            }) else { throw invalid() }
            return try ApplicationSettingRecord.encodeValue(value)
        }
        let raw = key.hasPrefix(defaultsPrefix)
            ? String(key.dropFirst(defaultsPrefix.count)) : String(key.dropFirst(databasePrefix.count))
        switch raw {
        case "floe.settings.reduceMotion", "floe.settings.hapticsEnabled",
             AppSettingsKey.verifyFinalAnswer, AppSettingsKey.semanticContextCompaction, AppSettingsKey.savesArtifacts:
            return try ApplicationSettingRecord.encodeValue(decoder.decode(Bool.self, from: data))
        case AppSettingsKey.executionTimeoutSeconds, AppSettingsKey.maxOutputBytes, AppSettingsKey.idleDisconnectMinutes:
            let value = try decoder.decode(Int.self, from: data)
            // Match the existing typed settings setters, including zero
            // (disabled/unlimited). Do not invent a smaller sync-only ceiling.
            guard value >= 0 else { throw invalid() }
            return try ApplicationSettingRecord.encodeValue(value)
        case "speech.rate", "speech.pitch":
            let value = try decoder.decode(Double.self, from: data)
            guard value.isFinite, (raw == "speech.rate" ? 0.0...1.0 : 0.5...2.0).contains(value) else { throw invalid() }
            return try ApplicationSettingRecord.encodeValue(value)
        case AppSettingsKey.sshDefaults, AppSettingsKey.vncDefaults:
            return try ApplicationSettingRecord.encodeValue(decoder.decode(RemoteSessionDefaults.self, from: data))
        default:
            let value = try decoder.decode(String.self, from: data)
            let choices: [String]?
            switch raw {
            case "floe.settings.hardwareReturnBehavior": choices = ["newline", "send"]
            case "floe.settings.appearance": choices = AppearancePreference.allCases.map(\.rawValue)
            case "floe.settings.language": choices = LanguagePreference.allCases.map(\.rawValue)
            case "floe.settings.dateTimeStyle": choices = DateTimeDisplayStyle.allCases.map(\.rawValue)
            case AppSettingsKey.defaultStartPage: choices = StartPage.allCases.map(\.rawValue)
            case AppSettingsKey.runningInputMode: choices = ["queue", "steer"]
            case "voice.input.method.v1": choices = ["automatic", "system", "enhanced", "cloud"]
            case "documentAssistant.leavePolicy.v1": choices = ["ask", "continueInBackground", "stopCurrentWork"]
            case "org.floeagent.voice.recognitionLanguage": choices = ["automatic", "simplifiedChinese", "traditionalChinese", "english", "japanese", "korean", "french", "german", "spanish", "italian", "portuguese", "russian"]
            default: choices = nil
            }
            guard value.utf8.count <= 1_024, choices?.contains(value) != false else { throw invalid() }
            return try ApplicationSettingRecord.encodeValue(value)
        }
    }
    private static func invalid() -> FloeError { .invalidConfiguration("Invalid portable application setting") }
}

/// Deterministic origin-bound references; raw credentials stay in Keychain.
/// Path/model/voice changes keep their service key; a different origin never
/// reuses an old account when CloudKit arrives ahead of iCloud Keychain.
public enum SpeechCredentialBinding {
    public static let asrService = "org.floeagent.ios.cloud-asr"
    public static let ttsService = "org.floeagent.ios.tts"
    private static func origin(_ value: String?) -> String {
        guard let value, let url = URLComponents(string: value), let host = url.host else { return "default" }
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? ((scheme == "https" || scheme == "wss") ? 443 : ((scheme == "http" || scheme == "ws") ? 80 : 0))
        return scheme + "://" + host.lowercased() + ":" + String(port)
    }
    public static func asrAccount(_ profile: ASRProfile) -> String {
        let fields = [profile.provider.rawValue, profile.billingRoute.rawValue,
                      origin(profile.resolvedFileEndpoint), origin(profile.resolvedLiveEndpoint)]
        let digest = FloeDigest.sha256Hex(Data(fields.joined(separator: "\n").utf8))
        return "profile." + profile.id.uuidString.lowercased() + ".origin." + digest
    }
    public static func ttsAccount(_ value: TTSSettingsSnapshot) -> String {
        let endpoint = value.provider == .openAI ? origin(value.openAIBaseURL ?? "https://api.openai.com/v1") : "default"
        let digest = FloeDigest.sha256Hex(Data([value.provider.rawValue, value.billingRoute.rawValue, endpoint].joined(separator: "\n").utf8))
        return "tts." + value.provider.rawValue + "." + value.billingRoute.rawValue + ".origin." + digest
    }
    public static let settingsApplied = Notification.Name("org.floeagent.sync.application-settings-applied")
    public static let localSettingsChanged = Notification.Name("org.floeagent.sync.local-application-settings-changed")
}

// FloeCore — Typed value types for cross-session app settings.
// See docs/ARCHITECTURE_SETTINGS.md §3.4. Everything here is non-secret and
// Codable so it can persist as a JSON value in the `app_settings` table
// (keys namespaced "<category>.<name>", e.g. "agent.defaultMode").

import Foundation

/// App appearance override (UserDefaults layer; not persisted in DB).
public enum AppearancePreference: String, Sendable, Codable, CaseIterable, Hashable {
    case system
    case light
    case dark
}

/// Language override (UserDefaults layer; not persisted in DB).
public enum LanguagePreference: String, Sendable, Codable, CaseIterable, Hashable {
    case system
    case en
    case zhHans
}

/// How timestamps render in the UI (UserDefaults layer).
public enum DateTimeDisplayStyle: String, Sendable, Codable, CaseIterable, Hashable {
    case relative
    case absolute
}

/// Default agent approval mode. Persisted as `agent.defaultMode`; the
/// conversation flow constructs the matching `ApprovalPolicy` from it.
/// `fullControl` still requires local authentication at the UI layer.
public enum AgentMode: String, Sendable, Codable, CaseIterable, Hashable {
    case human
    case approvalModel
    case fullControl
}

/// Default execution target for agent runs. Mirrors `WorkspaceTarget` in
/// FloeModels but lives in FloeCore so settings stay dependency-free.
public enum ExecutionTargetPreference: Sendable, Codable, Hashable {
    case local
    case host(UUID)

    /// Persisted discriminator.
    public var kindName: String {
        switch self {
        case .local: return "local"
        case .host: return "host"
        }
    }
}

/// Default page the app opens on launch. Persisted as `ui.defaultStartPage`.
public enum StartPage: String, Sendable, Codable, CaseIterable, Hashable {
    case home
    case chat
    case files
    case remote
    case more
}

/// SSH/VNC default behaviour. Persisted as `remote.ssh` / `remote.vnc`.
public struct RemoteSessionDefaults: Sendable, Codable, Hashable {
    public var autoReconnect: Bool
    public var keepAlive: Bool

    public init(autoReconnect: Bool = true, keepAlive: Bool = true) {
        self.autoReconnect = autoReconnect
        self.keepAlive = keepAlive
    }
}

/// Execution-environment preferences. Persisted as individual `exec.*` keys.
public struct ExecutionSettings: Sendable, Codable, Hashable {
    public var target: ExecutionTargetPreference
    public var timeoutSeconds: Int
    public var maxOutputBytes: Int
    public var savesArtifacts: Bool

    public init(
        target: ExecutionTargetPreference = .local,
        timeoutSeconds: Int = 300,
        maxOutputBytes: Int = 64 * 1024,
        savesArtifacts: Bool = true
    ) {
        self.target = target
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputBytes = maxOutputBytes
        self.savesArtifacts = savesArtifacts
    }
}

/// Aggregated cross-session settings snapshot. Individual values persist as
/// separate `app_settings` keys; this type is the typed read model.
public struct AppSettings: Sendable, Codable, Hashable {
    public var defaultAgentMode: AgentMode
    public var execution: ExecutionSettings
    public var defaultStartPage: StartPage
    public var defaultWorkspaceID: UUID?
    public var sshDefaults: RemoteSessionDefaults
    public var vncDefaults: RemoteSessionDefaults
    /// Idle minutes before a remote session is disconnected.
    public var idleDisconnectMinutes: Int

    public init(
        defaultAgentMode: AgentMode = .human,
        execution: ExecutionSettings = ExecutionSettings(),
        defaultStartPage: StartPage = .home,
        defaultWorkspaceID: UUID? = nil,
        sshDefaults: RemoteSessionDefaults = RemoteSessionDefaults(),
        vncDefaults: RemoteSessionDefaults = RemoteSessionDefaults(),
        idleDisconnectMinutes: Int = 15
    ) {
        self.defaultAgentMode = defaultAgentMode
        self.execution = execution
        self.defaultStartPage = defaultStartPage
        self.defaultWorkspaceID = defaultWorkspaceID
        self.sshDefaults = sshDefaults
        self.vncDefaults = vncDefaults
        self.idleDisconnectMinutes = idleDisconnectMinutes
    }
}

/// Well-known `app_settings` keys. Centralised so writers and readers can
/// never drift apart.
public enum AppSettingsKey {
    public static let defaultAgentMode = "agent.defaultMode"
    public static let executionTarget = "exec.target"
    public static let executionTimeoutSeconds = "exec.timeoutSeconds"
    public static let maxOutputBytes = "exec.maxOutputBytes"
    public static let savesArtifacts = "exec.savesArtifacts"
    public static let defaultStartPage = "ui.defaultStartPage"
    public static let defaultWorkspace = "files.defaultWorkspace"
    public static let sshDefaults = "remote.ssh"
    public static let vncDefaults = "remote.vnc"
    public static let idleDisconnectMinutes = "remote.idleDisconnectMinutes"
}

/// Counts returned by destructive clear operations so the UI can echo
/// exactly what was deleted instead of silently succeeding.
public struct ClearReport: Sendable, Codable, Hashable {
    public var deletedConversations: Int
    public var deletedRuns: Int
    public var deletedGrants: Int
    public var deletedKeychainItems: Int

    public init(
        deletedConversations: Int = 0,
        deletedRuns: Int = 0,
        deletedGrants: Int = 0,
        deletedKeychainItems: Int = 0
    ) {
        self.deletedConversations = deletedConversations
        self.deletedRuns = deletedRuns
        self.deletedGrants = deletedGrants
        self.deletedKeychainItems = deletedKeychainItems
    }
}

/// Counts summarising configured capabilities for the diagnostics section.
public struct CapabilitySummary: Sendable, Codable, Hashable {
    public var providerCount: Int
    public var modelCount: Int
    public var toolCount: Int
    public var adapterKinds: [String]

    public init(
        providerCount: Int = 0,
        modelCount: Int = 0,
        toolCount: Int = 0,
        adapterKinds: [String] = []
    ) {
        self.providerCount = providerCount
        self.modelCount = modelCount
        self.toolCount = toolCount
        self.adapterKinds = adapterKinds
    }
}

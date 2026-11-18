// Floe Mac M00 — independent, tiny mode preference store.
//
// SPDX-License-Identifier: MPL-2.0
//
// Startup and mode selection must not depend on the Agent database, provider
// configuration, the OpenCode adapter, the Bridge state or the Harness. This
// store is the only state the launch layer reads.

import Foundation

struct ModePreference: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var mode: AppMode
    var updatedAt: Date
}

struct ResolvedMode: Equatable, Sendable {
    enum Source: String, Sendable {
        case commandLine
        case environment
        case savedPreference
        case inheritedBridge
        case firstRunDefault
    }

    var mode: AppMode
    var source: Source
    var isFirstRun: Bool
    var preferenceURL: URL
}

struct ModePreferenceStore: Sendable {
    static let environmentRootKey = "FLOE_MAC_MODE_ROOT"
    static let environmentModeKey = "FLOE_MAC_MODE"

    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    var preferenceURL: URL {
        rootURL.appendingPathComponent("mode-preference.json", isDirectory: false)
    }

    static var defaultRootURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/Floe Mac", isDirectory: true)
    }

    static func rootURL(
        commandLineRoot: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let commandLineRoot { return commandLineRoot }
        if let text = environment[environmentRootKey], !text.isEmpty {
            return URL(fileURLWithPath: text, isDirectory: true)
        }
        return defaultRootURL
    }

    func load() -> ModePreference? {
        guard let data = try? Data(contentsOf: preferenceURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let preference = try? decoder.decode(ModePreference.self, from: data),
              preference.schemaVersion == ModePreference.currentSchemaVersion else {
            // A malformed or newer preference is treated as a first run. It is
            // never a reason to fail launch or to choose an execution backend.
            return nil
        }
        return preference
    }

    func save(_ mode: AppMode, now: Date = Date()) throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let preference = ModePreference(
            schemaVersion: ModePreference.currentSchemaVersion,
            mode: mode,
            updatedAt: now
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(preference)
        try data.write(to: preferenceURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: preferenceURL.path
        )
    }

    func resolve(
        commandLineMode: AppMode?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        inheritedBridgeSetup: Bool = false
    ) -> ResolvedMode {
        let saved = load()
        let isFirstRun = saved == nil
        if let commandLineMode {
            return ResolvedMode(
                mode: commandLineMode,
                source: .commandLine,
                isFirstRun: isFirstRun,
                preferenceURL: preferenceURL
            )
        }
        if let raw = environment[Self.environmentModeKey],
           let mode = AppMode(rawValue: raw) {
            return ResolvedMode(
                mode: mode,
                source: .environment,
                isFirstRun: isFirstRun,
                preferenceURL: preferenceURL
            )
        }
        if let saved {
            return ResolvedMode(
                mode: saved.mode,
                source: .savedPreference,
                isFirstRun: false,
                preferenceURL: preferenceURL
            )
        }
        if inheritedBridgeSetup {
            return ResolvedMode(
                mode: .bridge,
                source: .inheritedBridge,
                isFirstRun: false,
                preferenceURL: preferenceURL
            )
        }
        return ResolvedMode(
            mode: .agent,
            source: .firstRunDefault,
            isFirstRun: true,
            preferenceURL: preferenceURL
        )
    }
}

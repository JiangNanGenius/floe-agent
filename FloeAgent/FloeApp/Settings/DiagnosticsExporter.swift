// FloeApp — Redacted diagnostics exporter.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §6.4: collects version/build, database
// schema version, capability summary and the in-memory log buffer, then
// runs the whole payload through SecretRedactor before writing it to a
// temporary file for the system share sheet. No secret ever reaches the
// export — the buffer is scrubbed on write and the payload is scrubbed
// again here as defense-in-depth.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore

enum DiagnosticsExporter {

    /// Renders and writes a redacted diagnostics bundle, returning the
    /// temporary file URL for the share sheet.
    static func export(center: SettingsCenter) async throws -> URL {
        let body = await render(center: center)
        let redacted = SecretRedactor.redact(body)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-diagnostics-\(UUID().uuidString).txt")
        try Data(redacted.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Builds the raw (pre-redaction) diagnostics text. Kept separate from
    /// `export` so tests can assert on structure without touching disk.
    static func render(center: SettingsCenter) async -> String {
        var lines: [String] = []
        lines.append("Floe Agent Diagnostics")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        lines.append("generated_at: \(formatter.string(from: Date()))")

        let info = Bundle.main.infoDictionary
        lines.append("version: \(info?["CFBundleShortVersionString"] as? String ?? "unknown")")
        lines.append("build: \(info?["CFBundleVersion"] as? String ?? "unknown")")
        lines.append("database_user_version: \(center.databaseUserVersion)")

        lines.append("providers: \(center.capabilitySummary.providerCount)")
        lines.append("models: \(center.capabilitySummary.modelCount)")
        lines.append("catalog_tools: \(center.capabilitySummary.toolCount)")
        if !center.capabilitySummary.adapterKinds.isEmpty {
            lines.append("adapter_kinds: \(center.capabilitySummary.adapterKinds.joined(separator: ", "))")
        }

        lines.append("sync_status: \(String(describing: center.configSyncStatus))")
        lines.append("gate_fail_closed: \(center.gateIsFailClosed)")
        lines.append("saved_grants: \(center.savedGrants.count)")
        lines.append("session_grants: \(center.memoryGrants.count)")
        lines.append("workspaces: \(center.workspaces.count)")

        lines.append("js: \(describe(center.jsCapability))")
        lines.append("python_local: \(describe(center.localPythonCapability))")
        lines.append("python_remote: \(describe(center.remotePythonCapability))")
        lines.append("icloud_drive: \(describe(center.iCloudDrive))")
        lines.append("keychain: \(describe(center.keychainState))")

        let logText = FloeLogger.buffer.renderedText()
        if !logText.isEmpty {
            lines.append("")
            lines.append("== Recent log (redacted) ==")
            lines.append(logText)
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ state: CapabilityState) -> String {
        switch state {
        case .available(let version): return "available(\(version))"
        case .unavailable(let reason): return "unavailable(\(reason))"
        case .unknown: return "unknown"
        }
    }
}
#endif

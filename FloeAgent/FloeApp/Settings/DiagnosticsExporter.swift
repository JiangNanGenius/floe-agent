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
//
// The export is split into named sections. The feedback upload bounds the
// payload by section (FeedbackUploadService.boundedDiagnostics) instead of
// keeping only the document head and tail, because one oversized section —
// for example the full MetricKit payloads that follow older crash metadata —
// otherwise deletes every later section: the current Office stage trace,
// local inference evidence and durable task summaries.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloePersistence

/// Stable section vocabulary shared by the diagnostics renderer and the
/// bounded feedback upload. `== section <id> ==` is the only line the upload
/// parser treats as a boundary; the wording is unusual enough that ordinary
/// log lines or JSON content cannot collide with it by accident.
enum DiagnosticsSection: String, CaseIterable {
    case reportIdentity = "report_identity"
    case systemRuntime = "system_runtime"
    case officeStageTrace = "office_stage_trace"
    case localInference = "local_inference_evidence"
    case taskSummaries = "durable_task_summaries"
    case metricKitSummaries = "metrickit_summaries"
    case metricKitFullPayloads = "metrickit_full_payloads"
    case recentLog = "recent_log"

    static let headerPrefix = "== section "
    static let headerSuffix = " =="

    var header: String { "\(Self.headerPrefix)\(rawValue)\(Self.headerSuffix)" }

    static func section(forHeader line: String) -> DiagnosticsSection? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(headerPrefix), trimmed.hasSuffix(headerSuffix) else { return nil }
        let start = trimmed.index(trimmed.startIndex, offsetBy: headerPrefix.count)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -headerSuffix.count)
        guard start <= end else { return nil }
        return DiagnosticsSection(rawValue: String(trimmed[start..<end]))
    }
}

@MainActor
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

    /// Builds the raw (pre-redaction) sectioned diagnostics text. Kept
    /// separate from `export` so tests can assert on structure without
    /// touching disk.
    static func render(center: SettingsCenter) async -> String {
        var sections: [RenderedSection] = []
        sections.append(RenderedSection(id: .reportIdentity, body: identitySection(center: center)))

        let runtime = splitRuntimeEvidence(RuntimeDiagnostics.shared.report())
        sections.append(RenderedSection(id: .systemRuntime, body: runtime.runtime))
        sections.append(RenderedSection(id: .officeStageTrace,
                                        body: OfficeStageRecorder.shared.exportText()))
        sections.append(RenderedSection(id: .localInference,
                                        body: localInferenceEvidence()))
        do {
            let summaries = try await SQLiteRunStore(database: center.environment.database)
                .diagnosticRunSummaries()
            sections.append(RenderedSection(id: .taskSummaries,
                                            body: summaries.isEmpty ? "No recorded runs"
                                                                    : summaries.joined(separator: "\n")))
        } catch {
            sections.append(RenderedSection(id: .taskSummaries, body: "Durable task summaries unavailable"))
        }
        sections.append(RenderedSection(id: .metricKitSummaries,
                                        body: labelledMetricKitSummaries(runtime.summaries)))
        sections.append(RenderedSection(id: .metricKitFullPayloads, body: runtime.fullPayloads))

        let logText = FloeLogger.buffer.renderedText()
        sections.append(RenderedSection(id: .recentLog,
                                        body: logText.isEmpty ? "no log entries retained" : logText))
        return render(sections: sections)
    }

    /// One section header plus body, rendered in declaration order.
    struct RenderedSection: Equatable {
        let id: DiagnosticsSection
        let body: String
    }

    static func render(sections: [RenderedSection]) -> String {
        sections.map { $0.id.header + "\n" + $0.body }.joined(separator: "\n")
    }

    // MARK: - Report identity

    private static func identitySection(center: SettingsCenter) -> String {
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
        lines.append("node_local: \(describe(center.nodeCapability))")
        lines.append("python_remote: \(describe(center.remotePythonCapability))")
        lines.append("icloud_drive: \(describe(center.iCloudDrive))")
        lines.append("keychain: \(describe(center.keychainState))")
        return lines.joined(separator: "\n")
    }

    // MARK: - System runtime evidence (previous exit, MetricKit)

    struct RuntimeEvidenceSections: Equatable {
        let runtime: String
        let summaries: String
        let fullPayloads: String
    }

    /// `RuntimeDiagnostics.report()` embeds three pieces in one string:
    /// the previous-exit line, concise MetricKit summaries, then the full
    /// (potentially multi-megabyte) payloads. The upload must see them as
    /// separate sections so the full payloads cannot push the summaries or
    /// any later section out of the byte budget.
    static func splitRuntimeEvidence(_ report: String) -> RuntimeEvidenceSections {
        var runtime = report
        var summaries = ""
        var fullPayloads = ""
        let fullMarker = "\n== MetricKit full payloads ==\n"
        if let fullRange = report.range(of: fullMarker) {
            runtime = String(report[..<fullRange.lowerBound])
            fullPayloads = String(report[fullRange.upperBound...])
        }
        let summaryMarker = "\n== MetricKit summaries ==\n"
        if let summaryRange = runtime.range(of: summaryMarker) {
            summaries = String(runtime[summaryRange.upperBound...])
            runtime = String(runtime[..<summaryRange.lowerBound])
        }
        let trimmedRuntime = runtime.trimmingCharacters(in: .whitespacesAndNewlines)
        return RuntimeEvidenceSections(
            runtime: trimmedRuntime.isEmpty ? "system runtime evidence unavailable" : runtime,
            summaries: summaries,
            fullPayloads: fullPayloads
        )
    }

    /// Concise summaries carry their own `appBuildVersion` (for example the
    /// crash record). Prefixing each summary with that version keeps an old
    /// build's payload identifiable next to the current one without trusting
    /// the filename ordering.
    static func labelledMetricKitSummaries(_ summaries: String) -> String {
        let lines = summaries.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return "no MetricKit payloads retained" }
        return lines.map { "\(metricKitLabel(for: $0)) \($0)" }.joined(separator: "\n")
    }

    static func metricKitLabel(for summaryLine: String) -> String {
        guard let data = summaryLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "[metrickit build=unknown kind=unparsed]"
        }
        let build = firstString(forKey: "appBuildVersion", in: object) ?? "unknown"
        let kind = firstMetricKitKind(in: object) ?? "payload"
        return "[metrickit build=\(build) kind=\(kind)]"
    }

    private static func firstString(forKey key: String, in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary[key] as? String { return value }
            for value in dictionary.values {
                if let found = firstString(forKey: key, in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = firstString(forKey: key, in: value) { return found }
            }
        }
        return nil
    }

    private static func firstMetricKitKind(in object: [String: Any]) -> String? {
        for key in object.keys.sorted() {
            if let records = object[key] as? [[String: Any]],
               let kind = records.first?["kind"] as? String {
                return kind
            }
            if key.hasSuffix("Diagnostics") { return key }
        }
        return nil
    }

    // MARK: - Local inference evidence

    /// Local-model failures are the user-visible "no reply" symptom, and the
    /// provider log is otherwise flooded by unrelated runtime lines (for
    /// example per-tick Linux metrics). Extract the retained local-inference
    /// events into their own section so a runtime flood cannot push the last
    /// prepare/decode/failure step out of the export.
    static func localInferenceEvidence(
        entries: [FloeLogger.Entry] = FloeLogger.buffer.recentEntries,
        maximumEntries: Int = 120,
        maximumBytes: Int = 65_536
    ) -> String {
        let matched = entries.filter {
            $0.message.hasPrefix("localInference") || $0.message.hasPrefix("localModel")
        }
        guard !matched.isEmpty else { return "no local inference events retained in the process log" }
        let selected = Array(matched.suffix(max(1, maximumEntries)))
        var newestFirst: [String] = []
        var bytes = 0
        for entry in selected.reversed() {
            let line = renderedLogLine(entry)
            if bytes + line.utf8.count + 1 > maximumBytes { break }
            newestFirst.append(line)
            bytes += line.utf8.count + 1
        }
        if newestFirst.isEmpty, let last = selected.last {
            newestFirst.append(renderedLogLine(last))
        }
        let lines = newestFirst.reversed()
        let header = "events_retained=\(matched.count) events_exported=\(newestFirst.count)"
        return ([header] + lines).joined(separator: "\n")
    }

    private static let evidenceTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func renderedLogLine(_ entry: FloeLogger.Entry) -> String {
        "[\(evidenceTimestamp.string(from: entry.timestamp))]"
            + " [\(entry.category)] [\(entry.level)] \(entry.message)"
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

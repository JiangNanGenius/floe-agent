#if canImport(UIKit) && canImport(MetricKit)
import Foundation
import MetricKit
import FloeCore

/// System crash/CPU/exit evidence is retained across launches, separately from
/// the bounded live log. An interrupted launch marker alone is not a crash diagnosis.
@MainActor
final class RuntimeDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = RuntimeDiagnostics()
    private let defaults = UserDefaults.standard
    private let activeKey = "diagnostics.processActive"
    private(set) var previousExit = "unknown"
    private var started = false
    private var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RuntimeDiagnostics", isDirectory: true)
    }

    func start() {
        guard !started else { return }
        started = true
        previousExit = defaults.bool(forKey: activeKey) ? "noTerminationCallback; requiresMetricKitOrIPS" : "normalOrFirstLaunch"
        defaults.set(true, forKey: activeKey)
        FloeLogger(category: .app).info("processLaunch previousExit=\(previousExit)")
        MXMetricManager.shared.add(self)
    }

    func normalTermination() {
        defaults.set(false, forKey: activeKey)
        FloeLogger(category: .app).info("processNormalTermination")
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let data = payloads.map { $0.jsonRepresentation() }
        Task { @MainActor in self.retain(data, kind: "diagnostic") }
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        let data = payloads.map { $0.jsonRepresentation() }
        Task { @MainActor in self.retain(data, kind: "metrics") }
    }

    private func retain(_ payloads: [Data], kind: String) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for data in payloads.suffix(4) {
                // Never retain a byte prefix of JSON: that can remove the
                // exception metadata at the end and leave an unparseable file.
                let retained = data.count <= 1_048_576 ? String(decoding: data, as: UTF8.self) : Self.compactEvidence(data)
                let redacted = SecretRedactor.redact(retained)
                let url = folder.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID())-\(kind).json")
                try Data(redacted.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for file in files.dropFirst(8) { try FileManager.default.removeItem(at: file) }
            FloeLogger(category: .app).info("metricKitReceived kind=\(kind) count=\(payloads.count)")
        } catch {
            FloeLogger(category: .app).info("metricKitRetentionFailed")
        }
    }

    func report() -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let reports = files.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(8).compactMap {
            try? String(contentsOf: $0, encoding: .utf8)
        }
        guard !reports.isEmpty else {
            return "previous_exit: \(previousExit)\nMetricKit: no payload received yet; absence does not rule out a crash or Jetsam."
        }
        // Feedback upload preserves the report header and tail. Put compact,
        // complete crash metadata before verbose call trees so that truncating
        // the latter cannot erase the reason for the crash.
        let summaries = reports.map { Self.compactEvidence(Data($0.utf8)) }
        return "previous_exit: \(previousExit)\n== MetricKit summaries ==\n" + summaries.joined(separator: "\n")
            + "\n== MetricKit full payloads ==\n" + reports.joined(separator: "\n")
    }

    /// A valid JSON summary with metadata first in meaning, and only bounded
    /// attributed-thread frames. Full payloads remain separate evidence.
    nonisolated static func compactEvidence(_ data: Data) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return #"{"summaryError":"Stored MetricKit payload is incomplete or invalid; original evidence was retained"}"#
        }
        // A summary retained for an oversized source is already complete.
        if object["floeSummaryVersion"] != nil { return String(decoding: data, as: UTF8.self) }
        var result: [String: Any] = ["floeSummaryVersion": 1, "originalBytes": data.count, "fullCallTreesIncluded": false]
        for key in ["timeStampBegin", "timeStampEnd"] { result[key] = object[key] }
        var records: [[String: Any]] = []
        for key in object.keys.sorted() where key.hasSuffix("Diagnostics") {
            guard let diagnostics = object[key] as? [[String: Any]] else { continue }
            for diagnostic in diagnostics.prefix(4) {
                var record = diagnostic.filter { $0.key != "callStackTree" }
                record["kind"] = key
                if let tree = diagnostic["callStackTree"] as? [String: Any],
                   let stacks = tree["callStacks"] as? [[String: Any]] {
                    let selected = stacks.first { $0["threadAttributed"] as? Bool == true }
                    record["attributedThreadFound"] = selected != nil
                    var pending = (selected?["callStackRootFrames"] as? [[String: Any]]) ?? []
                    var frames: [[String: Any]] = []
                    while !pending.isEmpty && frames.count < 20 {
                        let frame = pending.removeFirst()
                        frames.append(frame.filter { ["binaryUUID", "binaryName", "offsetIntoBinaryTextSegment", "address"].contains($0.key) })
                        pending.insert(contentsOf: (frame["subFrames"] as? [[String: Any]]) ?? [], at: 0)
                    }
                    record["attributedFrames"] = frames
                    record["framesOmitted"] = !pending.isEmpty
                }
                records.append(record)
            }
        }
        result["diagnostics"] = records
        guard var encoded = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else {
            return #"{"summaryError":"MetricKit summary serialization failed"}"#
        }
        if encoded.count > 12_000 {
            // Preserve exception/termination metadata before stack detail.
            result["diagnostics"] = records.map { record in
                record.filter { $0.key != "attributedFrames" }
            }
            encoded = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? encoded
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}
#endif

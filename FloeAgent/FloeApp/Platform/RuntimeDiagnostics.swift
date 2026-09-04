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
                let redacted = SecretRedactor.redact(String(decoding: data.prefix(1_048_576), as: UTF8.self))
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
        return "previous_exit: \(previousExit)\n" + (reports.isEmpty
            ? "MetricKit: no payload received yet; absence does not rule out a crash or Jetsam."
            : reports.joined(separator: "\n"))
    }
}
#endif

import Foundation

/// Private prototype file layout. Everything lives in the app's Documents
/// container so the primary can read diagnostics with the Files app or an
/// explicitly enabled read-only LAN endpoint after a reboot.
///
/// This surface is compiled only for the prototype and is not part of a public
/// Bridge product.
public enum BridgePaths {
    public static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public static var root: URL {
        documents.appendingPathComponent("Bridge", isDirectory: true)
    }

    public static var diagnostics: URL {
        root.appendingPathComponent("diagnostics", isDirectory: true)
    }

    public static var logs: URL {
        root.appendingPathComponent("logs", isDirectory: true)
    }

    public static var commandsHost: URL {
        root.appendingPathComponent("commands/host", isDirectory: true)
    }

    public static var commandsEngine: URL {
        root.appendingPathComponent("commands/engine", isDirectory: true)
    }

    public static var resultsHost: URL {
        root.appendingPathComponent("results/host", isDirectory: true)
    }

    public static var resultsEngine: URL {
        root.appendingPathComponent("results/engine", isDirectory: true)
    }

    public static var processed: URL {
        root.appendingPathComponent("processed", isDirectory: true)
    }

    public static var statusFile: URL {
        diagnostics.appendingPathComponent("status.json")
    }

    public static var engineReadyFile: URL {
        diagnostics.appendingPathComponent("engine-ready.json")
    }

    public static var engineHeartbeatFile: URL {
        diagnostics.appendingPathComponent("engine-heartbeat.json")
    }

    /// Nonsecret terminal evidence written by the bootstrap shim immediately
    /// before its `_exit` path. It records the actual XCTestMain return/fault
    /// result and PID; it is never readiness evidence.
    public static var engineTerminalFile: URL {
        diagnostics.appendingPathComponent("engine-terminal.json")
    }

    /// Host-confirmed real entry for the current dispatch. Written only after
    /// the coordinator observes the engine's own ready marker for the same PID.
    public static var engineEntryConfirmedFile: URL {
        diagnostics.appendingPathComponent("engine-entry-confirmed.json")
    }

    /// Service-owned process/scene liveness beats and bounded transitions.
    public static var livenessFile: URL {
        diagnostics.appendingPathComponent("liveness.json")
    }

    /// Bounded, nonsecret report for the explicitly user-triggered on-device
    /// canary. It contains filenames/dimensions, never screenshot bytes.
    public static var canaryReportFile: URL {
        diagnostics.appendingPathComponent("canary-report.json")
    }

    public static var engineLogFile: URL {
        logs.appendingPathComponent("engine.log")
    }

    public static var hostLogFile: URL {
        logs.appendingPathComponent("host.log")
    }

    public static var ddiSourceFile: URL {
        diagnostics.appendingPathComponent("ddi-source.json")
    }

    /// Bounded pre/post evidence for the prototype-only removal action.
    public static var ddiRemovalReportFile: URL {
        diagnostics.appendingPathComponent("ddi-removal-report.json")
    }

    /// Stage markers and the 15-second heartbeat for the current blocking
    /// install worker. Owned by the service, not by a view.
    public static var ddiInstallProgressFile: URL {
        diagnostics.appendingPathComponent("ddi-progress.json")
    }

    /// Bounded read-only stage-probe evidence. Its host PID and generation let
    /// a later reader distinguish a live report from an old process's file.
    public static var ddiStageProbeFile: URL {
        diagnostics.appendingPathComponent("ddi-stage-probe.json")
    }

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bridge", isDirectory: true)
    }

    public static var pairingStagingDirectory: URL {
        supportDirectory.appendingPathComponent("Staging", isDirectory: true)
    }

    public static var ddiDirectory: URL {
        supportDirectory.appendingPathComponent("DDI", isDirectory: true)
    }

    public static func prepare() {
        let fileManager = FileManager.default
        for directory in [root, diagnostics, logs, commandsHost, commandsEngine,
                          resultsHost, resultsEngine, processed, supportDirectory,
                          pairingStagingDirectory, ddiDirectory] {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var support = supportDirectory
        try? support.setResourceValues(values)

        // No staging file or partial download survives a process boundary.
        // At launch there is no live FFI thread or download to protect.
        if let stale = try? fileManager.contentsOfDirectory(atPath: pairingStagingDirectory.path) {
            for name in stale {
                try? fileManager.removeItem(at: pairingStagingDirectory.appendingPathComponent(name))
            }
        }
        if let ddiEntries = try? fileManager.contentsOfDirectory(atPath: ddiDirectory.path) {
            for name in ddiEntries where name.hasPrefix(".download-") || name.hasPrefix(".import-") || name.hasPrefix(".backup-") {
                try? fileManager.removeItem(at: ddiDirectory.appendingPathComponent(name))
            }
            for name in ddiEntries where !name.hasPrefix(".") {
                let child = ddiDirectory.appendingPathComponent(name, isDirectory: true)
                guard let childEntries = try? fileManager.contentsOfDirectory(atPath: child.path) else { continue }
                for entry in childEntries where entry.hasPrefix(".download-") || entry.hasPrefix(".import-") || entry.hasPrefix(".backup-") {
                    try? fileManager.removeItem(at: child.appendingPathComponent(entry))
                }
            }
        }
    }
}

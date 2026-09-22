// FloeTools — Capability execution router.
//
// Declares, for every stable tool name, which execution backend owns the
// workload: the Linux guest (interpreters, CLIs, packages, servers) or a
// native Apple framework path (video/image/OCR/PDF/Metal/CoreML). A third
// backend models commands executed on a configured remote host over SSH.
//
// The router is a pure, exhaustive decision table so the choice is testable
// and auditable: tools never silently re-route at runtime, and heavy media
// capabilities never fall back to a software emulator unless that bounded
// fallback is explicitly declared here.

import Foundation

public enum CapabilityBackend: String, Sendable, Codable, Hashable {
    /// Native Swift implementation using Apple frameworks
    /// (Vision/CoreImage/Metal/CoreML/PDFKit/AVFoundation/…).
    case nativeApple = "native-apple"
    /// TinyEMU RISC-V Linux guest (shell, Python/Node, apt packages, servers).
    case linuxGuest = "linux-guest"
    /// A user-configured remote host reached over SSH.
    case remoteHost = "remote-host"
}

/// High-level workload class used by settings, docs and audit output.
public enum CapabilityWorkloadClass: String, Sendable, Codable, Hashable {
    case interpreter
    case cli
    case package
    case server
    case video
    case audio
    case image
    case ocr
    case pdf
    case metal
    case coreML
    case remote
    case general
}

public struct CapabilityExecutionDecision: Sendable, Equatable {
    public let toolName: String
    public let workload: CapabilityWorkloadClass
    public let backend: CapabilityBackend
    /// True only when a bounded Linux fallback is explicitly supported for
    /// an otherwise-native capability. Default is false: native media/GPU
    /// work never silently emulates on the interpreter-only guest.
    public let boundedLinuxFallback: Bool
    /// Human/audit-readable explanation of the routing, including any
    /// fallback reason.
    public let reason: String

    public init(
        toolName: String,
        workload: CapabilityWorkloadClass,
        backend: CapabilityBackend,
        boundedLinuxFallback: Bool = false,
        reason: String
    ) {
        self.toolName = toolName
        self.workload = workload
        self.backend = backend
        self.boundedLinuxFallback = boundedLinuxFallback
        self.reason = reason
    }
}

public enum CapabilityExecutionRouter {
    /// Tool names whose interpreter/CLI/package/server workload is owned by
    /// the Linux guest. Names stay stable even after the WASI/PHP/Ruby/Lua
    /// surfaces were retired: a retired name simply has no registered runner.
    static let linuxGuestToolNames: Set<String> = [
        // Shell and interactive terminal sessions.
        "exec.shell", "shell.open", "shell.exchange", "shell.close", "shell.signal",
        // Guest interpreters and managed services.
        "exec.localPython", "exec.localService",
        // Package management inside the guest.
        "apt", "python.packages",
        // Explicit Linux lifecycle.
        "environment.prepareLinux"
    ]

    /// Prefixes owned by the Linux guest (covers versioned/namespaced names).
    static let linuxGuestPrefixes: [String] = [
        "exec.shell", "shell."
    ]

    /// Prefixes for heavy, native-framework capabilities. These run through
    /// Vision, CoreImage/Metal, CoreML, AVFoundation or PDFKit and never
    /// emulate on TinyEMU.
    static let nativePrefixRules: [(prefix: String, workload: CapabilityWorkloadClass, reason: String)] = [
        ("video.", .video, "AVFoundation/Metal video pipeline; TinyEMU has no GPU passthrough"),
        ("audio.", .audio, "native AVFoundation audio pipeline"),
        ("media.", .video, "native media engine (AVFoundation/CoreImage)"),
        ("image.ocr", .ocr, "Vision text recognition"),
        ("image.barcode", .ocr, "Vision barcode detection"),
        ("image.", .image, "native CoreImage/QR pipeline"),
        ("document.pdf", .pdf, "PDFKit via PDFKitGate"),
        ("document.convert", .pdf, "native document conversion"),
        ("document.", .general, "native document engine"),
        ("canvas.", .metal, "native Canvas rendering surface"),
        ("notes.", .general, "native Notes workspace"),
        ("browser.", .general, "in-app native browser surface"),
        ("vnc.", .general, "native VNC client"),
        ("apple.", .general, "Apple-native system integrations"),
        ("font.", .general, "native font management"),
        ("credential.", .general, "native credential storage"),
        ("mail.", .general, "native mail client"),
        ("preview.", .general, "native service preview"),
        ("git.", .general, "native libgit2 engine"),
        ("github.", .general, "HTTPS API via native networking"),
        ("workspace.", .general, "compiled Swift file workspace"),
        ("crypto.", .general, "native CryptoKit/Crypto"),
        ("memory.", .general, "compiled Swift memory store"),
        ("conversation.", .general, "compiled Swift conversation tools"),
        ("checklist.", .general, "compiled Swift planning tools"),
        ("skill.", .general, "compiled Swift skill tools"),
        ("tools.", .general, "virtual discovery tools, no execution backend"),
        ("delegate", .general, "runtime-owned subagent delegation"),
        ("network.", .general, "native URLSession networking"),
        ("web.", .general, "native networking/retrieval stack"),
        ("bluetooth.", .general, "native CoreBluetooth"),
        ("jobs.", .general, "durable job controller; execution backend resolved per job")
    ]

    static let remotePrefixes: [String] = ["ssh.", "remote.", "remoteHosting."]

    /// Returns the declared execution backend for a stable tool name.
    public static func decision(for toolName: String) -> CapabilityExecutionDecision {
        if linuxGuestToolNames.contains(toolName) {
            return linuxDecision(toolName)
        }
        if toolName == "exec.javascript" {
            return CapabilityExecutionDecision(
                toolName: toolName,
                workload: .interpreter,
                backend: .nativeApple,
                reason: "system JavaScriptCore framework; no bundled interpreter payload"
            )
        }
        if toolName == "exec.wasm" || toolName == "exec.compatEvaluator"
            || toolName == "wasm.packages" {
            // The generic WASI/PHP/Ruby/Lua package surfaces have been
            // converged on Linux and are no longer shipped/exposed; the tools
            // answer honestly instead of running a bundled WASM payload.
            return CapabilityExecutionDecision(
                toolName: toolName,
                workload: .interpreter,
                backend: .linuxGuest,
                reason: "WASI interpreter packages retired; language workloads run in the Linux guest"
            )
        }
        for prefix in remotePrefixes where toolName.hasPrefix(prefix) {
            return CapabilityExecutionDecision(
                toolName: toolName,
                workload: .remote,
                backend: .remoteHost,
                reason: "executed on a configured remote host over SSH, not the iOS guest"
            )
        }
        for rule in nativePrefixRules where toolName.hasPrefix(rule.prefix) {
            return CapabilityExecutionDecision(
                toolName: toolName,
                workload: rule.workload,
                backend: .nativeApple,
                reason: rule.reason
            )
        }
        return CapabilityExecutionDecision(
            toolName: toolName,
            workload: .general,
            backend: .nativeApple,
            reason: "compiled Swift tool"
        )
    }

    private static func linuxDecision(_ toolName: String) -> CapabilityExecutionDecision {
        let workload: CapabilityWorkloadClass
        switch toolName {
        case "exec.localService":
            workload = .server
        case "apt", "python.packages":
            workload = .package
        case "exec.localPython":
            workload = .interpreter
        default:
            workload = .cli
        }
        return CapabilityExecutionDecision(
            toolName: toolName,
            workload: workload,
            backend: .linuxGuest,
            reason: "interpreter/CLI/package/server workloads run inside the TinyEMU Linux guest"
        )
    }
}

/// One recorded routing decision. Appended to a bounded ledger so feedback
/// and audit can show which backend actually served a tool call.
public struct CapabilityRouteRecord: Sendable, Identifiable, Codable, Hashable {
    public let id: UUID
    public let toolName: String
    public let backend: CapabilityBackend
    public let workload: CapabilityWorkloadClass
    public let boundedLinuxFallback: Bool
    public let reason: String
    public let at: Date

    public init(
        id: UUID = UUID(),
        toolName: String,
        backend: CapabilityBackend,
        workload: CapabilityWorkloadClass,
        boundedLinuxFallback: Bool,
        reason: String,
        at: Date = Date()
    ) {
        self.id = id
        self.toolName = toolName
        self.backend = backend
        self.workload = workload
        self.boundedLinuxFallback = boundedLinuxFallback
        self.reason = reason
        self.at = at
    }
}

/// Bounded, app-lifetime record of capability backend choices.
public actor CapabilityRouteLedger {
    public static let shared = CapabilityRouteLedger()

    /// Kept small: this is a diagnostic trail, not a system of record (the
    /// hash-chained audit log remains the durable record).
    public static let maxRecords = 256

    private var records: [CapabilityRouteRecord] = []

    public init() {}

    @discardableResult
    public func record(toolName: String) -> CapabilityRouteRecord {
        let decision = CapabilityExecutionRouter.decision(for: toolName)
        let record = CapabilityRouteRecord(
            toolName: decision.toolName,
            backend: decision.backend,
            workload: decision.workload,
            boundedLinuxFallback: decision.boundedLinuxFallback,
            reason: decision.reason
        )
        records.append(record)
        if records.count > CapabilityRouteLedger.maxRecords {
            records.removeFirst(records.count - CapabilityRouteLedger.maxRecords)
        }
        return record
    }

    public func recent(limit: Int = 50) -> [CapabilityRouteRecord] {
        Array(records.suffix(min(max(0, limit), records.count))).reversed()
    }

    public func clear() { records.removeAll() }
}

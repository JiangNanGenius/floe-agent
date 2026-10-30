#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeSkills

// MARK: - Trusted execution target facts
//
// This file is the App-side boundary between the environment services and the
// Skill layer. A target is produced ONLY by trusted App/core services from the
// task's durable binding (run, environment, backend, actual OS/architecture,
// launch generation and connection state). Skill text, Hub declarations and
// model arguments never supply these facts.
//
// Two different questions are answered separately:
//   1. App tool ownership — network/Office/browser/document/CAD/... stay in
//      the App on every target and must never be hidden by a remote default or
//      by migration.
//   2. External execution — only shell/scripts/binaries/dependencies follow the
//      resolved external target. A target that cannot run them produces an
//      explicit limitation; it never falls back to the Mac host, the first
//      environment, a foreign cache or another architecture's package plan.
//
// The DTO is deliberately independent from FloeEnvironments/FloeModels so the
// Skill layer never imports core storage types. AppEnvironment maps the
// trusted `TaskExecutionTarget` at this boundary (see INTERFACE.md).

/// The OS family that actually owns execution for this run.
enum SkillRuntimeOS: String, Codable, Sendable, Equatable {
    /// iOS/iPadOS App toolchain only (no external script target).
    case appNative = "app-native"
    case linux
    case macOS = "macos"
    case unknown
}

/// Mirrors `EnvironmentExecutionBackend` plus the typed SSH route. Raw values
/// for the shared cases are stable so persisted diagnostics stay readable.
enum SkillRuntimeExecutionBackend: String, Codable, Sendable, Equatable {
    case appNative = "native"
    case linuxVM = "linuxVM"
    case macBridge = "macBridge"
    case remoteSSH = "remoteSSH"
    case unresolved
}

enum SkillRuntimeTargetResolution: String, Codable, Sendable, Equatable {
    case resolved
    case unresolved
}

struct SkillRuntimeTarget: Codable, Sendable, Equatable {
    var runID: UUID?
    var environmentID: String?
    /// Core-owned remote host identity for a typed SSH target. Nil for the
    /// App-native, Linux-guest and Mac-bridge routes.
    var remoteHostID: UUID?
    /// Verified remote workspace root used by the shell/file adapters. Never
    /// surfaced in prompts; carried only for adapter construction and plan
    /// identity.
    var remoteRootPath: String?
    var operatingSystem: SkillRuntimeOS
    /// Actual architectures of the execution target. More than one entry is
    /// accepted only for the explicit test/legacy fallback; a resolved remote
    /// target should carry exactly the verified `uname -m` value.
    var architectures: [String]
    var backend: SkillRuntimeExecutionBackend
    /// Debian-family identity when the backend actually knows it. `nil` is
    /// honest "unknown"; apt is refused rather than guessing Debian.
    var distribution: String?
    var launchGeneration: UInt64?
    /// Core-owned runtime generation when it is a non-numeric boot/bridge
    /// identity. Compared for receipt reuse; never part of the identity
    /// fingerprint (a reboot keeps the plan, not a receipt).
    var runtimeGeneration: String?
    var isConnected: Bool
    var resolution: SkillRuntimeTargetResolution

    init(
        runID: UUID? = nil,
        environmentID: String? = nil,
        remoteHostID: UUID? = nil,
        remoteRootPath: String? = nil,
        operatingSystem: SkillRuntimeOS,
        architectures: [String] = [],
        backend: SkillRuntimeExecutionBackend,
        distribution: String? = nil,
        launchGeneration: UInt64? = nil,
        runtimeGeneration: String? = nil,
        isConnected: Bool,
        resolution: SkillRuntimeTargetResolution
    ) {
        self.runID = runID
        self.environmentID = environmentID
        self.remoteHostID = remoteHostID
        self.remoteRootPath = remoteRootPath
        self.operatingSystem = operatingSystem
        self.architectures = architectures
        self.backend = backend
        self.distribution = distribution
        self.launchGeneration = launchGeneration
        self.runtimeGeneration = runtimeGeneration
        self.isConnected = isConnected
        self.resolution = resolution
    }

    // MARK: - Factories used by AppEnvironment/core adapters

    /// The App's own native toolchain (no external target resolved).
    static func appNative(runID: UUID? = nil) -> SkillRuntimeTarget {
        SkillRuntimeTarget(
            runID: runID,
            environmentID: nil,
            remoteHostID: nil,
            remoteRootPath: nil,
            operatingSystem: .appNative,
            architectures: [],
            backend: .appNative,
            distribution: nil,
            launchGeneration: nil,
            runtimeGeneration: nil,
            isConnected: true,
            resolution: .resolved
        )
    }

    /// The pinned local Linux guest (TinyEMU today; a future ARM64 guest passes
    /// its own architecture here, so no RISC-V constant leaks into planning).
    static func linuxGuest(
        environmentID: String,
        runID: UUID? = nil,
        architecture: String,
        distribution: String? = "debian",
        launchGeneration: UInt64? = nil,
        runtimeGeneration: String? = nil,
        isConnected: Bool = true
    ) -> SkillRuntimeTarget {
        SkillRuntimeTarget(
            runID: runID,
            environmentID: environmentID,
            remoteHostID: nil,
            remoteRootPath: nil,
            operatingSystem: .linux,
            architectures: [architecture],
            backend: .linuxVM,
            distribution: distribution,
            launchGeneration: launchGeneration,
            runtimeGeneration: runtimeGeneration,
            isConnected: isConnected,
            resolution: .resolved
        )
    }

    /// The paired Mac bridge. It is a real external target for shell/scripts,
    /// but it has no Debian apt path and no Linux-guest localPython tool.
    static func macBridge(
        environmentID: String,
        runID: UUID? = nil,
        architecture: String = "arm64",
        launchGeneration: UInt64? = nil,
        runtimeGeneration: String? = nil,
        isConnected: Bool = true
    ) -> SkillRuntimeTarget {
        SkillRuntimeTarget(
            runID: runID,
            environmentID: environmentID,
            remoteHostID: nil,
            remoteRootPath: nil,
            operatingSystem: .macOS,
            architectures: [architecture],
            backend: .macBridge,
            distribution: nil,
            launchGeneration: launchGeneration,
            runtimeGeneration: runtimeGeneration,
            isConnected: isConnected,
            resolution: .resolved
        )
    }

    /// A typed SSH target. OS/architecture must come from the actual host
    /// verification performed by the core lane, never from the client OS.
    static func remoteSSH(
        environmentID: String,
        runID: UUID? = nil,
        remoteHostID: UUID,
        remoteRootPath: String,
        operatingSystem: SkillRuntimeOS,
        architecture: String,
        distribution: String? = nil,
        runtimeGeneration: String? = nil,
        isConnected: Bool = true
    ) -> SkillRuntimeTarget {
        SkillRuntimeTarget(
            runID: runID,
            environmentID: environmentID,
            remoteHostID: remoteHostID,
            remoteRootPath: remoteRootPath,
            operatingSystem: operatingSystem,
            architectures: [architecture],
            backend: .remoteSSH,
            distribution: distribution,
            launchGeneration: nil,
            runtimeGeneration: runtimeGeneration,
            isConnected: isConnected,
            resolution: .resolved
        )
    }

    /// Explicit "no target could be resolved". Never replaced by a fallback.
    static let unresolved = SkillRuntimeTarget(
        operatingSystem: .unknown,
        backend: .unresolved,
        launchGeneration: nil,
        runtimeGeneration: nil,
        isConnected: false,
        resolution: .unresolved
    )

    /// The legacy in-process fallback used ONLY when AppEnvironment has not
    /// injected a real target provider yet (tests and pre-integration builds).
    /// It is the pinned local Linux guest fact, not a host guess.
    static func legacyLinuxGuest(
        environmentID: String,
        architectures: [String],
        launchGeneration: UInt64? = nil,
        isConnected: Bool = true
    ) -> SkillRuntimeTarget {
        SkillRuntimeTarget(
            environmentID: environmentID,
            remoteHostID: nil,
            remoteRootPath: nil,
            operatingSystem: .linux,
            architectures: architectures,
            backend: .linuxVM,
            distribution: "debian",
            launchGeneration: launchGeneration,
            runtimeGeneration: nil,
            isConnected: isConnected,
            resolution: .resolved
        )
    }

    // MARK: - Derived facts

    var isResolved: Bool { resolution == .resolved }

    /// True only for a resolved external execution route. App-native is not an
    /// external target even though it can run its own tools.
    var hasExternalExecution: Bool {
        guard isResolved else { return false }
        switch backend {
        case .linuxVM, .macBridge, .remoteSSH: return true
        case .appNative, .unresolved: return false
        }
    }

    /// `exec.localPython` is the managed Linux-guest interpreter. A macOS or
    /// App-native target never pretends to expose it; external Python there is
    /// ordinary `exec.shell` work with its own target-verified interpreter.
    var supportsLocalPython: Bool {
        isResolved && backend == .linuxVM && operatingSystem == .linux
    }

    /// apt/font preparation is allowed only on a Debian-family Linux target
    /// whose distribution fact is actually known. A macOS target, an App-native
    /// target, or a remote Linux target with unknown distribution is refused;
    /// only the reviewed local Linux-VM rootfs may omit the fact. There is no
    /// Homebrew auto-install and no "assume Debian" remote fallback.
    var supportsDebianAPT: Bool {
        guard isResolved, operatingSystem == .linux, hasExternalExecution else { return false }
        let normalized = distribution?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if normalized.isEmpty {
            // The pinned local guest is the one backend whose base image is a
            // reviewed Debian rootfs; remote targets must report their own.
            return backend == .linuxVM
        }
        return ["debian", "ubuntu"].contains(normalized)
    }

    func supportsPackageManager(_ kind: String) -> Bool {
        switch kind {
        case "apt", "font":
            return supportsDebianAPT
        case "pip", "npm":
            guard hasExternalExecution else { return false }
            return operatingSystem == .linux || operatingSystem == .macOS
        case "runtimeComponent":
            // The reviewed engine descriptor is frozen to Linux/RISC-V; the
            // descriptor cross-check in the preparation center is the final
            // authority, this is only the coarse family gate.
            return isResolved && operatingSystem == .linux && normalizedArchitectures.contains("riscv64")
        default:
            return false
        }
    }

    /// Comparable generation identity for receipt reuse. Nil means unknown
    /// (no reuse is claimed); a reboot/rotation changes the token.
    var generationToken: String? {
        if let value = runtimeGeneration?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return launchGeneration.map { String($0) }
    }

    var normalizedArchitectures: [String] {
        architectures.map(Self.normalizeArchitecture)
            .filter { !$0.isEmpty }
    }

    static func normalizeArchitecture(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "aarch64", "arm64e": return "arm64"
        case "amd64", "x64": return "x86_64"
        case "i386", "i686": return "x86"
        default: return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    /// `SkillDependencyProfile.os`-style value. `nil` when no external OS is
    /// known; profiles never fall back to Linux for an unknown target.
    var profileOS: String? {
        switch operatingSystem {
        case .linux: return "linux"
        case .macOS: return "macos"
        case .appNative, .unknown: return nil
        }
    }

    /// Model-safe description. Never contains a host path, environment UUID or
    /// protocol detail.
    var runtimeDescription: String {
        guard isResolved else { return "unresolved target" }
        let arch = normalizedArchitectures.isEmpty ? "" : " " + normalizedArchitectures.joined(separator: "/")
        switch operatingSystem {
        case .appNative:
            return "this iPhone/iPad"
        case .linux:
            let distro = distribution.map { value -> String in
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.isEmpty ? "" : " (\(normalized))"
            } ?? ""
            return "Linux\(arch)\(distro)"
        case .macOS:
            return "macOS\(arch)"
        case .unknown:
            return "unknown target"
        }
    }

    /// Stable target identity used by plans/receipts. Generation, run and
    /// connection state are intentionally excluded: a reboot keeps the plan
    /// valid but forces receipt re-verification; a backend/OS/arch/distro
    /// change is a different target.
    var identityFingerprint: String {
        [
            "os=" + operatingSystem.rawValue,
            "arch=" + normalizedArchitectures.sorted().joined(separator: ","),
            "backend=" + backend.rawValue,
            "distro=" + (distribution?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""),
            "remote=" + (remoteHostID?.uuidString.lowercased() ?? ""),
            "root=" + (remoteRootPath ?? "")
        ].joined(separator: "|")
    }
}

// MARK: - Resolver seam

/// App-injected, trusted resolver. `nil` means "no target could be resolved";
/// callers must not substitute another host, the first environment or the Mac
/// host. The App primary wires this from the actual run binding.
struct SkillRuntimeTargetResolver: Sendable {
    var resolve: @Sendable (_ runID: UUID?, _ resourceContext: SkillResourceContext?)
        async -> SkillRuntimeTarget?

    init(
        resolve: @escaping @Sendable (_ runID: UUID?, _ resourceContext: SkillResourceContext?)
            async -> SkillRuntimeTarget?
    ) {
        self.resolve = resolve
    }
}

// MARK: - Target compatibility

enum SkillTargetCompatibilityProblem: Equatable, Sendable {
    case targetUnresolved
    case targetDisconnected
    case externalExecutionUnavailable
    case runtimeOSMismatch(required: [String], actual: String?)
    case runtimeArchitectureMismatch(required: [String], actual: String?)
    case packageManagerUnavailable(kind: String, target: String)

    var message: String {
        switch self {
        case .targetUnresolved:
            return "the task has no resolved execution target"
        case .targetDisconnected:
            return "the resolved execution target is not connected"
        case .externalExecutionUnavailable:
            return "the resolved target runs App-native tools only; external scripts and dependencies need a Linux or macOS target"
        case .runtimeOSMismatch(let required, let actual):
            return "the package scripts require \(required.joined(separator: "/")) but the resolved target is \(actual ?? "unknown")"
        case .runtimeArchitectureMismatch(let required, let actual):
            return "the package binaries require \(required.joined(separator: "/")) but the resolved target is \(actual ?? "unknown")"
        case .packageManagerUnavailable(let kind, let target):
            return "\(kind) installation is only supported on a Debian-family Linux target, not \(target)"
        }
    }
}

struct SkillTargetCompatibilityReport: Sendable {
    let base: SkillCompatibilityReport
    let targetProblems: [SkillTargetCompatibilityProblem]
    /// External shell/script/dependency work cannot execute on the resolved
    /// target right now and must be deferred or refused — never presented as
    /// portable to this device.
    let externalWorkDeferred: Bool
    let target: SkillRuntimeTarget?
    /// Install admission only judges App correctness and knowable target
    /// limitations. A missing external target never blocks installing the
    /// guide; readiness is still never claimed.
    let isInstallable: Bool
    /// True only when the guide AND every declared external step can run on
    /// the actual target now.
    let isRunnableOnTarget: Bool

    var limitationDescription: String? {
        targetProblems.first?.message
    }
}

enum SkillRuntimeCompatibilityMode: Sendable, Equatable {
    case install
    case run
}

enum SkillRuntimeCompatibility {
    /// Tool names whose ownership is external execution. This is a routing
    /// fact from the existing trusted registration, not a grant.
    static let externalOwnedToolPrefixes = [
        "exec.shell", "exec.localPython", "exec.localService",
        "apt", "python.packages", "environment.", "linux.port",
        "ssh.", "remote.", "remoteHosting."
    ]

    static func isExternalOwnedTool(_ name: String) -> Bool {
        externalOwnedToolPrefixes.contains { name == $0 || name.hasPrefix($0) }
    }

    /// A guide needs the external target when it ships scripts, declares an
    /// external runtime/capability, or references an externally owned tool.
    static func requiresExternalExecution(_ package: ValidatedSkillPackage) -> Bool {
        if package.containsScripts { return true }
        if package.manifest.scriptRuntime != .none { return true }
        if package.declaredCapabilities.contains(.remoteExecution)
            || package.declaredCapabilities.contains(.localPython) {
            return true
        }
        return package.manifest.tools.contains(where: isExternalOwnedTool)
    }

    static func environment(
        for target: SkillRuntimeTarget?,
        appCapabilities: Set<SkillCapability>,
        appTools: Set<String>,
        mode: SkillRuntimeCompatibilityMode
    ) -> SkillRuntimeEnvironment {
        var capabilities = appCapabilities
        var tools = appTools
        let resolved = target.flatMap { $0.isResolved ? $0 : nil }

        if mode == .install {
            // Installing a guide whose external half will be prepared later is
            // allowed; this is not a claim that any host is reachable.
            capabilities.insert(.remoteExecution)
        } else if let resolved, resolved.hasExternalExecution {
            capabilities.insert(.remoteExecution)
        } else {
            capabilities.remove(.remoteExecution)
        }

        if let resolved, !resolved.supportsLocalPython {
            if mode == .run {
                capabilities.remove(.localPython)
                tools.remove("exec.localPython")
            }
        }
        if mode == .run, let resolved, !resolved.hasExternalExecution {
            tools = Set(tools.filter { !isExternalOwnedTool($0) })
        }

        return SkillRuntimeEnvironment(
            platform: .iOS,
            supportedCapabilities: capabilities,
            registeredTools: tools,
            // JavaScriptCore availability is not an executable tool.
            supportsJavaScriptCore: false,
            hasRemoteExecutionHost: resolved?.hasExternalExecution == true,
            runtimeOS: resolved?.profileOS,
            runtimeArchitecture: resolved?.normalizedArchitectures.first
        )
    }

    static func evaluate(
        _ package: ValidatedSkillPackage,
        target: SkillRuntimeTarget?,
        appCapabilities: Set<SkillCapability>,
        appTools: Set<String>,
        mode: SkillRuntimeCompatibilityMode
    ) -> SkillTargetCompatibilityReport {
        let resolved = target.flatMap { $0.isResolved ? $0 : nil }
        let environment = environment(
            for: target, appCapabilities: appCapabilities, appTools: appTools, mode: mode
        )
        let base = SkillCompatibility.evaluate(package, in: environment)
        let requiresExternal = requiresExternalExecution(package)
        var problems: [SkillTargetCompatibilityProblem] = []

        if mode == .run, requiresExternal {
            guard let resolved else {
                problems.append(.targetUnresolved)
                return SkillTargetCompatibilityReport(
                    base: base,
                    targetProblems: problems,
                    externalWorkDeferred: true,
                    target: target,
                    isInstallable: base.isRunnable,
                    isRunnableOnTarget: false
                )
            }
            if !resolved.hasExternalExecution {
                problems.append(.externalExecutionUnavailable)
            }
            if !resolved.isConnected {
                problems.append(.targetDisconnected)
            }
        }

        if let resolved, package.manifest.scriptRuntime != .none,
           let requirements = package.manifest.runtime {
            let osMatches = requirements.os.contains { requirement in
                requirement.caseInsensitiveCompare(resolved.profileOS ?? "") == .orderedSame
            }
            if !osMatches {
                problems.append(.runtimeOSMismatch(
                    required: requirements.os, actual: resolved.profileOS
                ))
            }
            let normalizedRequired = Set(requirements.architectures.map(SkillRuntimeTarget.normalizeArchitecture))
            if !normalizedRequired.contains("any"),
               normalizedRequired.isDisjoint(with: resolved.normalizedArchitectures) {
                problems.append(.runtimeArchitectureMismatch(
                    required: requirements.architectures,
                    actual: resolved.normalizedArchitectures.isEmpty
                        ? nil : resolved.normalizedArchitectures.joined(separator: "/")
                ))
            }
        }

        let canExecuteNow = resolved?.hasExternalExecution == true && resolved?.isConnected == true
        let deferred = requiresExternal && !canExecuteNow
        let installable = mode == .install ? base.isRunnable : base.isRunnable && problems.isEmpty
        return SkillTargetCompatibilityReport(
            base: base,
            targetProblems: problems,
            externalWorkDeferred: deferred,
            target: target,
            isInstallable: installable,
            isRunnableOnTarget: base.isRunnable && problems.isEmpty && !deferred
        )
    }
}

// MARK: - Variant-preserving discovery

/// One installed guide, a bundled native guide and a macOS original with the
/// same id are independent variants. Discovery dedupes EXACT identity only
/// (`id` + digest); a same-id/different-digest pair is preserved. This is what
/// prevents a remote/default/migration target from replacing the skill
/// universe, and prevents an original from being silently swapped for an
/// adapted implementation.
enum SkillRuntimeDiscovery {
    static func identityKey(_ row: ManagedSkill) -> String {
        "\(row.id)|\(row.digest)"
    }

    static func merged(_ groups: [[ManagedSkill]]) -> [ManagedSkill] {
        var seen = Set<String>()
        var result: [ManagedSkill] = []
        for group in groups {
            for row in group {
                guard seen.insert(identityKey(row)).inserted else { continue }
                result.append(row)
            }
        }
        return result
    }

    static func merged(
        installed: [ManagedSkill],
        nativeBundled: [ManagedSkill],
        macOriginals: [ManagedSkill]
    ) -> [ManagedSkill] {
        merged([installed, macOriginals, nativeBundled])
    }
}
#endif

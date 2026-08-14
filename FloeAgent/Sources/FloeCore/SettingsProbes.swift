// FloeCore — Concrete capability probes for the settings center.
// See docs/ARCHITECTURE_SETTINGS.md §3.3/§5: probes are side-effect free,
// never fabricate availability, and report honest `unavailable(reason:)`
// for capabilities that have not landed yet (P3).

import Foundation

#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// Probes the local JavaScript runtime. Real check: construct a JSContext
/// and evaluate a trivial expression — this verifies the framework is
/// linked and functional, not merely present on disk.
public struct JavaScriptCoreProbe: CapabilityProbe {
    public let name = "javascript"

    public init() {}

    public func probe() async -> CapabilityState {
        #if canImport(JavaScriptCore)
        guard let context = JSContext() else {
            return .unavailable(reason: "JavaScriptCore context could not be created")
        }
        context.exceptionHandler = { _, _ in }
        guard let result = context.evaluateScript("1 + 1"), result.toInt32() == 2 else {
            return .unavailable(reason: "JavaScriptCore evaluation failed")
        }
        // JavaScriptCore does not expose an engine version; report the OS.
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = "JavaScriptCore (system \(os.majorVersion).\(os.minorVersion))"
        return .available(version: version)
        #else
        return .unavailable(reason: "JavaScriptCore is not available on this platform")
        #endif
    }
}

/// Local Python execution has not landed (P3). Honest unavailability —
/// the UI must grey this out rather than show a fake toggle.
public struct LocalPythonProbe: CapabilityProbe {
    public let name = "python.local"

    public init() {}

    public func probe() async -> CapabilityState {
        .unavailable(reason: "Local Python execution is not implemented yet (P3)")
    }
}

/// Remote Python execution over paired hosts has not landed (P3).
public struct RemotePythonProbe: CapabilityProbe {
    public let name = "python.remote"

    public init() {}

    public func probe() async -> CapabilityState {
        .unavailable(reason: "Remote Python execution is not implemented yet (P3)")
    }
}

/// Probes iCloud Drive availability via the ubiquity identity token.
/// Returns `.unknown` when the check itself cannot run (never stored).
public struct ICloudStatusProbe: CapabilityProbe {
    public let name = "icloud.drive"

    public init() {}

    public func probe() async -> CapabilityState {
        if FileManager.default.ubiquityIdentityToken != nil {
            return .available(version: "signed in")
        }
        return .unavailable(reason: "No iCloud account is signed in on this device")
    }
}

/// Minimal Keychain surface used by the settings-center probe. Declared
/// in FloeCore so the probe stays cross-platform; FloeSecurity extends
/// `KeychainStore` with a same-module conformance.
public protocol KeychainProbeStore: Sendable {
    func store(account: String, secret: Data) throws
    func read(account: String) throws -> Data
    func delete(account: String) throws
}

/// Probes Keychain read/write health with a temporary item
/// (write → read → delete). The probe payload is a fixed non-secret
/// canary string; the item is always removed afterwards.
public struct KeychainProbe: CapabilityProbe {
    public let name = "keychain"

    private let keychain: any KeychainProbeStore
    private let account = "floe.settings.probe"

    public init(keychain: any KeychainProbeStore) {
        self.keychain = keychain
    }

    public func probe() async -> CapabilityState {
        let canary = Data("floe-probe".utf8)
        do {
            try keychain.store(account: account, secret: canary)
            let readBack = try keychain.read(account: account)
            try keychain.delete(account: account)
            guard readBack == canary else {
                return .unavailable(reason: "Keychain read-back mismatch")
            }
            return .available(version: "read/write ok")
        } catch {
            // Best effort: never leave the probe item behind.
            try? keychain.delete(account: account)
            return .unavailable(reason: "Keychain probe failed: \(error.localizedDescription)")
        }
    }
}

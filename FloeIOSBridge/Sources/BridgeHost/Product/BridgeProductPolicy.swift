import Darwin
import Foundation

import BridgeCore

/// Fixed localhost-first product configuration shared by the model, tests and
/// the final App integration. The media pipeline needs a bounded-but-large
/// consumer buffer so a valid H.264 keyframe fragment is not rejected by the
/// RPC transport while it is being drained.
enum BridgeProductRuntime {
    static let productName = "Floe iOS Bridge"
    static let requestedPort: UInt16 = 8200
    static let streamConsumerBufferBytes = 2 * 1_024 * 1_024

    static func limits() -> BridgeRPCLimits {
        var limits = BridgeRPCLimits.default
        limits.streamConsumerBufferBytes = streamConsumerBufferBytes
        return limits
    }
}

/// Product-owned preferences. These keys are deliberately separate from the
/// prototype `org.floeagent.iosbridge.prototype.*` keys: an old diagnostic LAN
/// or control preference must never turn on the product listener.
struct BridgeProductPreferenceValues: Equatable, Sendable {
    var lanEnabled: Bool
    var bonjourEnabled: Bool
}

enum BridgeProductPreferences {
    static let lanKey = "org.floeagent.iosbridge.product.lan"
    static let bonjourKey = "org.floeagent.iosbridge.product.bonjour"

    static func load(from defaults: UserDefaults = .standard) -> BridgeProductPreferenceValues {
        let storedLAN = defaults.object(forKey: lanKey) == nil
            ? false
            : defaults.bool(forKey: lanKey)
        let storedBonjour = defaults.object(forKey: bonjourKey) == nil
            ? false
            : defaults.bool(forKey: bonjourKey)
        return normalized(lan: storedLAN, bonjour: storedBonjour)
    }

    static func normalized(lan: Bool, bonjour: Bool) -> BridgeProductPreferenceValues {
        BridgeProductPreferenceValues(lanEnabled: lan,
                                      bonjourEnabled: lan && bonjour)
    }

    static func saveLAN(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: lanKey)
    }

    static func saveBonjour(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: bonjourKey)
    }
}

/// Product-only lifecycle preferences. Historical diagnostic builds cannot
/// enable restoration or claim setup completion in a new product install.
enum BridgeProductLifecyclePreferences {
    static let autoRestoreKey = "org.floeagent.iosbridge.product.auto-restore"
    static let completedSetupKey = "org.floeagent.iosbridge.product.completed-setup"

    static func storedAutoRestore(in defaults: UserDefaults = .standard) -> Bool? {
        defaults.object(forKey: autoRestoreKey) == nil
            ? nil
            : defaults.bool(forKey: autoRestoreKey)
    }

    static func completedSetup(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completedSetupKey)
    }
}

/// The product's desired-running intent is deliberately separate from the
/// user's auto-restore preference. A fresh product install starts with no
/// desired run; only an actual owner Start records `true`, and every owner or
/// authenticated Stop records `false`. The key is new and never reads the
/// legacy LAN/control preferences.
enum BridgeProductRunIntent {
    static let key = "org.floeagent.iosbridge.product.desired-running"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? false : defaults.bool(forKey: key)
    }

    static func markRunning(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    static func markStopped(in defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: key)
    }

    /// Restore only when the user asked for auto-restore, the owner last left
    /// the product running, setup completed, no terminal fault is latched and
    /// the current process is not already running. A disabled auto-restore
    /// preference is never overridden by Start.
    static func shouldRestore(autoRestore: Bool,
                              desiredRunning: Bool,
                              completedSetup: Bool,
                              terminalFault: Bool,
                              engineRunning: Bool) -> Bool {
        autoRestore && desiredRunning && completedSetup &&
            !terminalFault && !engineRunning
    }
}

/// Pure restore policy shared with the model. It composes the independent
/// auto-restore preference with the persisted desired-running intent; a
/// stopped owner intent never reopens work even when auto-restore is on.
enum BridgeProductRestorationPolicy {
    static func shouldRestoreOnLaunch(autoRestore: Bool,
                                      desiredRunning: Bool,
                                      completedSetup: Bool,
                                      terminalFault: Bool,
                                      engineRunning: Bool) -> Bool {
        BridgeProductRunIntent.shouldRestore(
            autoRestore: autoRestore,
            desiredRunning: desiredRunning,
            completedSetup: completedSetup,
            terminalFault: terminalFault,
            engineRunning: engineRunning
        )
    }
}

/// A URL is exposed to the owner only when both the RPC transport and the
/// shared engine lifecycle independently agree that the product is ready.
/// A bound port by itself is never presented as a usable address.
enum BridgeProductReadinessPolicy {
    static func isUsable(rpc: BridgeRPCHostSnapshot,
                         shared: BridgeSnapshot) -> Bool {
        guard !shared.terminalFault else { return false }
        guard rpc.isReady, rpc.loopbackReady, rpc.engineReady else { return false }
        guard shared.phase == .ready,
              shared.serviceRunning,
              shared.engineEntryObserved,
              shared.engineRunning else { return false }
        return rpc.port != nil
    }

    static func localURLs(rpc: BridgeRPCHostSnapshot,
                          shared: BridgeSnapshot) -> [URL] {
        guard isUsable(rpc: rpc, shared: shared), let port = rpc.port else { return [] }
        var values: [URL] = []
        if rpc.loopbackIPv4Ready,
           let url = URL(string: "http://127.0.0.1:\(port)/") {
            values.append(url)
        }
        if rpc.loopbackIPv6Ready,
           let url = URL(string: "http://[::1]:\(port)/") {
            values.append(url)
        }
        return values
    }

    static func remotePageURL(rpc: BridgeRPCHostSnapshot,
                              shared: BridgeSnapshot) -> URL? {
        guard let base = localURLs(rpc: rpc, shared: shared).first else { return nil }
        return base.appendingPathComponent("remote")
    }

    /// LAN addresses are presented only after the same real readiness check and
    /// an actual wildcard LAN bind. `addresses` is injected from the interface
    /// table so this policy remains deterministic in checks.
    static func lanURLs(rpc: BridgeRPCHostSnapshot,
                        shared: BridgeSnapshot,
                        addresses: [String]) -> [URL] {
        guard isUsable(rpc: rpc, shared: shared),
              rpc.lanReady,
              let port = rpc.port else { return [] }
        var seen = Set<String>()
        var values: [URL] = []
        for address in addresses where BridgeProductAddress.isIPv4(address) {
            guard seen.insert(address).inserted else { continue }
            if let url = URL(string: "http://\(address):\(port)/") {
                values.append(url)
            }
        }
        return values
    }
}

/// Wi-Fi/Ethernet IPv4 candidates for the optional LAN address display.
/// VPN/tunnel/peer-to-peer interfaces are excluded because the RPC transport
/// deliberately refuses those peer classes; showing their address would be a
/// misleading entrance.
enum BridgeProductNetworkInfo {
    static func ipv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var values: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = interfaceName(pointer.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("wlan") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let value = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                               as: UTF8.self)
            guard BridgeProductAddress.isIPv4(value), !values.contains(value) else { continue }
            values.append(value)
        }
        return values
    }

    private static func interfaceName(_ raw: UnsafePointer<CChar>) -> String {
        var bytes: [UInt8] = []
        var index = 0
        while raw[index] != 0 {
            bytes.append(UInt8(bitPattern: raw[index]))
            index += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum BridgeProductAddress {
    static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard !part.isEmpty,
                  part.count <= 3,
                  part.allSatisfy({ $0.isNumber }),
                  let number = Int(part),
                  (0...255).contains(number) else {
                return false
            }
        }
        return true
    }
}

enum BridgeProductRunState: Equatable, Sendable {
    case needsSetup
    case idle
    case preparing
    case running
    case stopped
    case needsAttention
    case reopenRequired
}

enum BridgeProductPrimaryAction: Equatable, Sendable {
    case setup
    case start
    case stop
    case reopen
}

/// Derives the one primary owner action from the shared lifecycle and the
/// actual RPC listener state. There is no separate UI readiness flag.
enum BridgeProductRunStatePolicy {
    static func runState(shared: BridgeSnapshot,
                         rpcRunning: Bool,
                         requiresSetup: Bool) -> BridgeProductRunState {
        if shared.terminalFault { return .reopenRequired }
        if shared.phase.isActive { return .preparing }
        if shared.phase == .ready, shared.serviceRunning, shared.engineRunning {
            return rpcRunning ? .running : .needsAttention
        }
        if shared.phase == .failed { return .needsAttention }
        if shared.phase == .stopped { return .stopped }
        if requiresSetup { return .needsSetup }
        return .idle
    }

    static func primaryAction(shared: BridgeSnapshot,
                              rpcRunning: Bool,
                              requiresSetup: Bool) -> BridgeProductPrimaryAction {
        if shared.terminalFault { return .reopen }
        if shared.phase.isActive || shared.serviceRunning || shared.engineRunning {
            return .stop
        }
        if requiresSetup { return .setup }
        return .start
    }
}

enum BridgeProductApprovalSource: String, Equatable, Sendable {
    case thisDevice
    case localNetwork
}

struct BridgeProductPendingApproval: Identifiable, Equatable, Sendable {
    let id: String
    let clientName: String
    let source: BridgeProductApprovalSource
    let fingerprint: String?
    let requestedAt: Date
    let deadline: Date
}

/// Display-only policy for the protected pairing prompt. The client name and
/// address are untrusted input; no key material or authority value crosses
/// this boundary.
enum BridgeProductApprovalPolicy {
    /// Admission is independent of app foreground. A same-phone client may
    /// send `/pair` while Bridge is background; one bounded request is queued
    /// until its existing deadline and the owner can approve after reopening
    /// Bridge. Only one request may wait at a time.
    static func canQueue(hasPending: Bool) -> Bool {
        !hasPending
    }

    /// Display-only rule: a prompt is visible only while the app is active.
    /// A queued background request becomes visible when the owner returns.
    static func canPresent(isForeground: Bool, hasPending: Bool) -> Bool {
        isForeground && !hasPending
    }

    static func pending(for request: BridgeRPCApprovalRequest,
                        now: Date = Date()) -> BridgeProductPendingApproval {
        BridgeProductPendingApproval(
            id: request.requestID,
            clientName: displayName(request.clientName),
            source: request.isLoopback ? .thisDevice : .localNetwork,
            fingerprint: fingerprint(request.fingerprint),
            requestedAt: now,
            deadline: now.addingTimeInterval(Self.promptInterval(request.timeout))
        )
    }

    /// The presented deadline and the gate's timeout use one interval. The
    /// authority still enforces its own request timeout independently.
    static func promptInterval(_ timeout: TimeInterval) -> TimeInterval {
        max(0.2, timeout)
    }

    /// Bidi controls and zero-width/format characters are removed so a remote
    /// client cannot disguise the prompt or reverse the owner-facing text.
    static func displayName(_ raw: String, limit: Int = 64) -> String {
        guard limit > 0 else { return "" }
        let filtered = raw.unicodeScalars.filter { scalar in
            let value = scalar.value
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            if CharacterSet.newlines.contains(scalar) { return false }
            if (0x200B...0x200F).contains(value) { return false }
            if (0x202A...0x202E).contains(value) { return false }
            if (0x2060...0x2064).contains(value) { return false }
            if (0x2066...0x2069).contains(value) { return false }
            if value == 0xFEFF { return false }
            return true
        }
        let text = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(limit))
    }

    /// The authority already supplies a short SHA-256 prefix. This check
    /// rejects anything that is not displayable hex rather than rendering an
    /// unexpected value from the wire.
    static func fingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty,
              text.count <= 16,
              text.allSatisfy({ $0.isHexDigit }) else { return nil }
        return text
    }
}

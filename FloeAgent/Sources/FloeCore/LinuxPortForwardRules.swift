// FloeCore — Persistent per-environment TCP port-forward rules.
//
// A rule publishes one guest TCP port on the host. The host port is either
// fixed by the user or allocated dynamically from the IANA dynamic range
// (49152–65535); at most 16 rules are honored per VM. The default bind address
// is 0.0.0.0 so the service is reachable from the LAN, and the app never asks a
// router to expose anything: there is no UPnP/NAT-PMP/PCP behavior and no WAN
// address is ever presented as a URL. Displayed URLs are LAN/loopback only.
//
// The rule set is pure value logic; persistence is a codec with an injected
// `UserDefaults`, and the actual engine call (`floe_vm_hostfwd_add` through
// `LinuxGuestControlling.forwardService`) stays in the app layer.

import Foundation

public enum LinuxPortForwardLimits {
    /// IANA dynamic/private port range, inclusive.
    public static let minimumHostPort = 49_152
    public static let maximumHostPort = 65_535
    /// Hard cap per VM. The engine's forwarding table is the same size, and
    /// the cap is enforced before any rule reaches the guest.
    public static let maximumRulesPerEnvironment = 16
    /// LAN-reachable default. The user may narrow it to a specific local
    /// address; a public/WAN address is never used.
    public static let defaultBindAddress = "0.0.0.0"

    public static var hostPortRange: ClosedRange<Int> {
        minimumHostPort...maximumHostPort
    }

    public static func isAllowedHostPort(_ port: Int) -> Bool {
        hostPortRange.contains(port)
    }
}

/// TCP only: the managed forwarding surface publishes TCP services, and no
/// rule in this model can silently become a UDP exposure.
public enum LinuxPortForwardTransport: String, Sendable, Codable, CaseIterable, Hashable {
    case tcp
}

public struct LinuxPortForwardRule: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public var environmentID: String
    public var label: String
    /// The guest service's TCP port.
    public var guestPort: UInt16
    /// A fixed host port (49152–65535), or nil for dynamic allocation.
    public var requestedHostPort: UInt16?
    /// Local bind address; defaults to `0.0.0.0` (LAN).
    public var bindAddress: String
    public var transport: LinuxPortForwardTransport
    public var isEnabled: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        environmentID: String,
        label: String,
        guestPort: UInt16,
        requestedHostPort: UInt16? = nil,
        bindAddress: String = LinuxPortForwardLimits.defaultBindAddress,
        transport: LinuxPortForwardTransport = .tcp,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.environmentID = environmentID
        self.label = label
        self.guestPort = guestPort
        self.requestedHostPort = requestedHostPort
        self.bindAddress = bindAddress
        self.transport = transport
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    public var isDynamic: Bool { requestedHostPort == nil }

    /// True when the rule asks for a fixed host port. The *applied* port lives
    /// in `LinuxPortForwardPlan`, which may differ after conflict handling.
    public var requestedHostPortText: String {
        requestedHostPort.map(String.init) ?? "动态"
    }
}

public enum LinuxPortForwardRuleError: Error, Equatable, Sendable {
    case guestPortOutOfRange(Int)
    case hostPortOutOfRange(Int)
    case ruleCapReached(limit: Int)
    case hostPortConflict(hostPort: UInt16, existingRuleID: UUID)
    case noAvailableHostPort
    case invalidBindAddress(String)
    case ruleNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .guestPortOutOfRange(let port):
            return "Guest port \(port) is outside 1...65535"
        case .hostPortOutOfRange(let port):
            return "Host port \(port) is outside the managed dynamic range \(LinuxPortForwardLimits.minimumHostPort)...\(LinuxPortForwardLimits.maximumHostPort)"
        case .ruleCapReached(let limit):
            return "At most \(limit) port-forward rules are supported per VM"
        case .hostPortConflict(let port, _):
            return "Host port \(port) is already used by another rule"
        case .noAvailableHostPort:
            return "No free host port is available in \(LinuxPortForwardLimits.minimumHostPort)...\(LinuxPortForwardLimits.maximumHostPort)"
        case .invalidBindAddress(let address):
            return "Bind address '\(address)' is not a local dotted IPv4 address"
        case .ruleNotFound(let id):
            return "Port-forward rule \(id.uuidString) does not exist"
        }
    }
}

public enum LinuxPortForwardPlanReason: String, Sendable, Codable, Hashable {
    /// The fixed port the user asked for was free and is bound.
    case requested
    /// A dynamic rule got the lowest free port in the managed range.
    case dynamicAllocation
    /// The fixed port was already occupied (another process, a restored
    /// forward or another app instance); the planner bound the lowest free
    /// port instead and the UI must show that real port.
    case conflictRemap
    /// A dynamic rule could not get the first free port because it was taken
    /// at apply time; it got the next free one.
    case dynamicRetry
}

/// The port a rule is actually published on.
public struct LinuxPortForwardPlan: Sendable, Equatable, Identifiable {
    public var rule: LinuxPortForwardRule
    public var hostPort: UInt16
    public var reason: LinuxPortForwardPlanReason

    public var id: UUID { rule.id }
    public var guestPort: UInt16 { rule.guestPort }
    public var isFixed: Bool { rule.requestedHostPort != nil }
    /// True when the plan differs from what the user asked for.
    public var wasRemapped: Bool {
        reason == .conflictRemap || reason == .dynamicRetry
    }

    public init(
        rule: LinuxPortForwardRule,
        hostPort: UInt16,
        reason: LinuxPortForwardPlanReason
    ) {
        self.rule = rule
        self.hostPort = hostPort
        self.reason = reason
    }
}

/// Pure rule set for one environment.
public struct LinuxPortForwardSet: Sendable, Equatable {
    public let environmentID: String
    public private(set) var rules: [LinuxPortForwardRule]

    public init(environmentID: String, rules: [LinuxPortForwardRule] = []) {
        self.environmentID = environmentID
        self.rules = rules.filter { $0.environmentID == environmentID }
    }

    public var enabledRules: [LinuxPortForwardRule] {
        rules.filter(\.isEnabled)
    }

    public func rule(id: UUID) -> LinuxPortForwardRule? {
        rules.first { $0.id == id }
    }

    /// Adds one rule, validating the range, the per-VM cap and fixed-port
    /// uniqueness. A conflict is reported, never silently overwritten.
    @discardableResult
    public mutating func addRule(
        guestPort: Int,
        requestedHostPort: Int? = nil,
        label: String,
        bindAddress: String = LinuxPortForwardLimits.defaultBindAddress,
        now: Date = Date()
    ) throws -> LinuxPortForwardRule {
        guard (1...65_535).contains(guestPort) else {
            throw LinuxPortForwardRuleError.guestPortOutOfRange(guestPort)
        }
        guard LinuxPortForwardURL.isValidBindAddress(bindAddress) else {
            throw LinuxPortForwardRuleError.invalidBindAddress(bindAddress)
        }
        if let requestedHostPort,
           !LinuxPortForwardLimits.isAllowedHostPort(requestedHostPort) {
            throw LinuxPortForwardRuleError.hostPortOutOfRange(requestedHostPort)
        }
        guard enabledRules.count < LinuxPortForwardLimits.maximumRulesPerEnvironment else {
            throw LinuxPortForwardRuleError.ruleCapReached(
                limit: LinuxPortForwardLimits.maximumRulesPerEnvironment
            )
        }
        if let requestedHostPort,
           let existing = enabledRules.first(where: {
               $0.bindAddress == bindAddress
                   && $0.requestedHostPort == UInt16(requestedHostPort)
           }) {
            throw LinuxPortForwardRuleError.hostPortConflict(
                hostPort: UInt16(requestedHostPort),
                existingRuleID: existing.id
            )
        }
        let rule = LinuxPortForwardRule(
            environmentID: environmentID,
            label: label,
            guestPort: UInt16(guestPort),
            requestedHostPort: requestedHostPort.map(UInt16.init),
            bindAddress: bindAddress,
            isEnabled: true,
            createdAt: now
        )
        rules.append(rule)
        return rule
    }

    /// Updates the mutable fields of one rule, applying the same validation as
    /// `addRule` (ignoring the rule being edited for conflict checks).
    public mutating func updateRule(
        id: UUID,
        guestPort: Int? = nil,
        requestedHostPort: Int?? = nil,
        label: String? = nil,
        isEnabled: Bool? = nil
    ) throws {
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            throw LinuxPortForwardRuleError.ruleNotFound(id)
        }
        var rule = rules[index]
        if let guestPort {
            guard (1...65_535).contains(guestPort) else {
                throw LinuxPortForwardRuleError.guestPortOutOfRange(guestPort)
            }
            rule.guestPort = UInt16(guestPort)
        }
        if let requestedHostPort {
            if let port = requestedHostPort {
                guard LinuxPortForwardLimits.isAllowedHostPort(port) else {
                    throw LinuxPortForwardRuleError.hostPortOutOfRange(port)
                }
                if let existing = enabledRules.first(where: {
                    $0.id != id
                        && $0.bindAddress == rule.bindAddress
                        && $0.requestedHostPort == UInt16(port)
                }) {
                    throw LinuxPortForwardRuleError.hostPortConflict(
                        hostPort: UInt16(port),
                        existingRuleID: existing.id
                    )
                }
            }
            rule.requestedHostPort = requestedHostPort.map(UInt16.init)
        }
        if let label { rule.label = label }
        if let isEnabled {
            if isEnabled, !rule.isEnabled {
                let enabledCount = enabledRules.filter { $0.id != id }.count
                guard enabledCount < LinuxPortForwardLimits.maximumRulesPerEnvironment else {
                    throw LinuxPortForwardRuleError.ruleCapReached(
                        limit: LinuxPortForwardLimits.maximumRulesPerEnvironment
                    )
                }
            }
            rule.isEnabled = isEnabled
        }
        rules[index] = rule
    }

    public mutating func removeRule(id: UUID) throws {
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            throw LinuxPortForwardRuleError.ruleNotFound(id)
        }
        rules.remove(at: index)
    }

    public mutating func removeAllRules() {
        rules.removeAll()
    }

    /// Plans every enabled rule in creation order. `occupiedHostPorts` are the
    /// host ports already bound by other processes or restored forwards; a
    /// fixed rule whose port is occupied is remapped to a free port and
    /// reported as `.conflictRemap` (restart restoration never fails the whole
    /// set because one service started first).
    public func plan(
        occupiedHostPorts: Set<Int> = []
    ) throws -> [LinuxPortForwardPlan] {
        var reserved = occupiedHostPorts
        var plans: [LinuxPortForwardPlan] = []
        for rule in enabledRules.sorted(by: Self.creationOrder) {
            let requested = rule.requestedHostPort.map(Int.init)
            let fallback = Self.lowestFreeHostPort(excluding: reserved)
            let port: Int
            let reason: LinuxPortForwardPlanReason
            switch requested {
            case .none:
                guard let fallback else {
                    throw LinuxPortForwardRuleError.noAvailableHostPort
                }
                port = fallback
                reason = .dynamicAllocation
            case .some(let value) where reserved.contains(value):
                guard let fallback else {
                    throw LinuxPortForwardRuleError.noAvailableHostPort
                }
                port = fallback
                reason = .conflictRemap
            case .some(let value):
                port = value
                reason = .requested
            }
            reserved.insert(port)
            plans.append(LinuxPortForwardPlan(
                rule: rule,
                hostPort: UInt16(port),
                reason: reason
            ))
        }
        return plans
    }

    public static func creationOrder(
        _ lhs: LinuxPortForwardRule,
        _ rhs: LinuxPortForwardRule
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Lowest free port in the managed range; nil when the range is exhausted.
    public static func lowestFreeHostPort(excluding occupied: Set<Int>) -> Int? {
        for port in LinuxPortForwardLimits.minimumHostPort...LinuxPortForwardLimits.maximumHostPort
        where !occupied.contains(port) {
            return port
        }
        return nil
    }
}

/// URL rendering for published forwards. LAN/loopback only: a public address
/// is rejected, and no router mapping (UPnP/NAT-PMP/PCP) exists anywhere in
/// this path.
public enum LinuxPortForwardURL {
    public static let defaultScheme = "http"

    public static func isDottedIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = UInt8(part), !part.isEmpty else { return false }
            return String(value) == part || (part.count > 1 && part.first != "0")
        }
    }

    /// Bind addresses must be dotted IPv4 and local (0.0.0.0, loopback or an
    /// RFC 1918 / link-local address). Hostnames are never accepted.
    public static func isValidBindAddress(_ text: String) -> Bool {
        guard isDottedIPv4(text) else { return false }
        if text == LinuxPortForwardLimits.defaultBindAddress { return true }
        return isLocalAddress(text)
    }

    /// Loopback, link-local or RFC 1918.
    public static func isLocalAddress(_ text: String) -> Bool {
        guard isDottedIPv4(text) else { return false }
        let parts = text.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 127 { return true }
        if parts[0] == 10 { return true }
        if parts[0] == 172, (16...31).contains(parts[1]) { return true }
        if parts[0] == 192, parts[1] == 168 { return true }
        if parts[0] == 169, parts[1] == 254 { return true }
        return false
    }

    /// A URL is built only for a local address. `0.0.0.0` means "all local
    /// interfaces": without a discovered device address there is no single
    /// honest URL, so the caller gets nil rather than a made-up one.
    public static func url(
        hostPort: UInt16,
        bindAddress: String,
        deviceAddress: String? = nil,
        scheme: String = defaultScheme
    ) -> URL? {
        guard !scheme.isEmpty,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else {
            return nil
        }
        let host: String
        if bindAddress == LinuxPortForwardLimits.defaultBindAddress {
            guard let deviceAddress, isLocalAddress(deviceAddress) else { return nil }
            host = deviceAddress
        } else {
            guard isLocalAddress(bindAddress) else { return nil }
            host = bindAddress
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = Int(hostPort)
        return components.url
    }

    /// QR payload is exactly the displayed URL string; generating a QR code
    /// never widens the address beyond the local one.
    public static func qrPayload(
        hostPort: UInt16,
        bindAddress: String,
        deviceAddress: String? = nil,
        scheme: String = defaultScheme
    ) -> String? {
        url(
            hostPort: hostPort,
            bindAddress: bindAddress,
            deviceAddress: deviceAddress,
            scheme: scheme
        )?.absoluteString
    }
}

/// Persistence codec. Rules are grouped by environment so a deleted
/// environment can be forgotten without touching the others.
public enum LinuxPortForwardRuleStore {
    public static let defaultsKey = "linuxPortForwardRules.v1"

    public static func load(
        from defaults: UserDefaults = .standard
    ) -> [String: [LinuxPortForwardRule]] {
        guard let data = defaults.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode(
                [String: [LinuxPortForwardRule]].self, from: data
              ) else { return [:] }
        var result: [String: [LinuxPortForwardRule]] = [:]
        for (environmentID, rules) in records where !environmentID.isEmpty {
            // Defensive normalization: a hand-edited or downgraded store may
            // exceed the cap; keep the oldest 16 enabled rules deterministically.
            let filtered = rules
                .filter { $0.environmentID == environmentID }
                .sorted(by: LinuxPortForwardSet.creationOrder)
            var enabled = 0
            var kept: [LinuxPortForwardRule] = []
            for rule in filtered {
                if rule.isEnabled {
                    guard enabled < LinuxPortForwardLimits.maximumRulesPerEnvironment else { continue }
                    enabled += 1
                }
                kept.append(rule)
            }
            if !kept.isEmpty { result[environmentID] = kept }
        }
        return result
    }

    public static func save(
        _ rulesByEnvironment: [String: [LinuxPortForwardRule]],
        to defaults: UserDefaults = .standard
    ) {
        let filtered = rulesByEnvironment.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        guard let data = try? JSONEncoder().encode(filtered) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

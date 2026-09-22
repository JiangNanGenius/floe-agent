// FloeApp — Persistent per-environment TCP port forwarding for Linux VMs.
//
// Build 222 owner above the Linux guest service. It keeps the durable rule set
// per environment (FloeCore `LinuxPortForwardRuleStore`), plans host ports from
// the managed 49152–65535 range, applies them through the injected guest
// controller and restores them whenever a VM starts again. Conflicts are
// reported honestly: a fixed port taken by another process is remapped to the
// next free port and the UI shows the port that is really bound.
//
// The app never performs UPnP/NAT-PMP/PCP router mapping: the engine binds a
// local socket (default 0.0.0.0) and URLs are built for LAN/loopback addresses
// only.

#if canImport(UIKit)
import Foundation
import Combine
import Darwin
import FloeCore
import FloeExecution

/// The applying side of the center. The production implementation talks to the
/// injected Linux guest controller; tests inject a scriptable fake so the
/// conflict/restore behavior is verifiable without a VM.
protocol LinuxPortForwardApplying: Sendable {
    func guestIsRunning(environmentID: String) async -> Bool
    func apply(environmentID: String, forward: LinuxGuestServiceForward) async throws
    func remove(environmentID: String, forward: LinuxGuestServiceForward) async
}

struct PlatformLinuxPortForwardApplier: LinuxPortForwardApplying {
    private var controller: (any LinuxGuestControlling)? {
        FloePlatformServices.shared.linuxGuestController()
    }

    func guestIsRunning(environmentID: String) async -> Bool {
        guard let controller else { return false }
        return await controller.guestIsRunning(environmentID: environmentID)
    }

    func apply(environmentID: String, forward: LinuxGuestServiceForward) async throws {
        guard let controller else {
            throw LinuxGuestError.serviceForwardingUnavailable(
                "this build has no Linux guest backend"
            )
        }
        try await controller.forwardService(environmentID: environmentID, forward: forward)
    }

    func remove(environmentID: String, forward: LinuxGuestServiceForward) async {
        await controller?.removeServiceForward(environmentID: environmentID, forward: forward)
    }
}

/// Compact device LAN address lookup for URL display. Only RFC 1918 /
/// link-local / loopback addresses are returned, so a URL can never point at a
/// WAN address.
enum DeviceLANAddress {
    static func currentIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            // en0/en1 are the Wi-Fi/Ethernet interfaces on iOS; keep the order
            // deterministic instead of trusting getifaddrs ordering.
            guard name == "en0" || name == "en1" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let text = String(cString: host)
            guard LinuxPortForwardURL.isLocalAddress(text) else { continue }
            if name == "en0" { return text }
            fallback = fallback ?? text
        }
        return fallback
    }
}

/// One displayed forward: the rule, the port actually bound and its URLs.
struct LinuxPortForwardPreview: Identifiable, Equatable {
    var rule: LinuxPortForwardRule
    var plan: LinuxPortForwardPlan
    /// `http://<lan>:<port>` when the environment is reachable on the LAN.
    var lanURL: URL?
    /// Loopback URL, always available while the bind is local.
    var loopbackURL: URL?
    /// QR payload: exactly the URL string (LAN preferred, loopback fallback).
    var qrPayload: String? { lanURL?.absoluteString ?? loopbackURL?.absoluteString }
    var id: UUID { rule.id }
    var wasRemapped: Bool { plan.wasRemapped }
    /// False when the rule is persisted but the VM is stopped: the port is
    /// only planned, not yet bound.
    var isApplied: Bool = false
}

@MainActor
final class LinuxPortForwardCenter: ObservableObject {
    static let shared = LinuxPortForwardCenter()

    @Published private(set) var rulesByEnvironment: [String: [LinuxPortForwardRule]]
    /// Ports really bound in the current VM(s), keyed by environment.
    @Published private(set) var appliedPlansByEnvironment: [String: [LinuxPortForwardPlan]]
    @Published private(set) var lastError: String?
    /// Set when a fixed port had to be remapped so the UI can explain it.
    @Published private(set) var lastConflictNotice: String?
    @Published private(set) var lastAppliedAt: Date?

    private let applier: any LinuxPortForwardApplying
    private let defaults: UserDefaults
    private let deviceAddressProvider: @Sendable () -> String?

    init(
        applier: any LinuxPortForwardApplying = PlatformLinuxPortForwardApplier(),
        defaults: UserDefaults = .standard,
        deviceAddressProvider: @escaping @Sendable () -> String? = { DeviceLANAddress.currentIPv4() }
    ) {
        self.applier = applier
        self.defaults = defaults
        self.deviceAddressProvider = deviceAddressProvider
        self.rulesByEnvironment = LinuxPortForwardRuleStore.load(from: defaults)
        self.appliedPlansByEnvironment = [:]
        self.lastError = nil
        self.lastConflictNotice = nil
        self.lastAppliedAt = nil
    }

    // MARK: - Reads

    func rules(environmentID: String) -> [LinuxPortForwardRule] {
        (rulesByEnvironment[environmentID] ?? [])
            .sorted(by: LinuxPortForwardSet.creationOrder)
    }

    func rule(environmentID: String, id: UUID) -> LinuxPortForwardRule? {
        rules(environmentID: environmentID).first { $0.id == id }
    }

    func plans(environmentID: String) -> [LinuxPortForwardPlan] {
        appliedPlansByEnvironment[environmentID] ?? []
    }

    func enabledRuleCount(environmentID: String) -> Int {
        rules(environmentID: environmentID).filter(\.isEnabled).count
    }

    /// Published previews: what is actually bound plus the copy/QR URLs. When
    /// the VM is stopped the planned port is shown instead, clearly marked as
    /// not yet applied.
    func previews(environmentID: String) -> [LinuxPortForwardPreview] {
        let deviceAddress = deviceAddressProvider()
        let applied = appliedPlansByEnvironment[environmentID] ?? []
        let plans: [LinuxPortForwardPlan]
        let isApplied: Bool
        if applied.isEmpty {
            let set = LinuxPortForwardSet(
                environmentID: environmentID,
                rules: rules(environmentID: environmentID)
            )
            plans = (try? set.plan()) ?? []
            isApplied = false
        } else {
            plans = applied
            isApplied = true
        }
        let appliedIDs = Set(applied.map(\.rule.id))
        return plans.compactMap { plan in
            guard plan.rule.isEnabled else { return nil }
            guard let loopback = LinuxPortForwardURL.url(
                hostPort: plan.hostPort,
                bindAddress: "127.0.0.1"
            ) else { return nil }
            return LinuxPortForwardPreview(
                rule: plan.rule,
                plan: plan,
                lanURL: LinuxPortForwardURL.url(
                    hostPort: plan.hostPort,
                    bindAddress: plan.rule.bindAddress,
                    deviceAddress: deviceAddress
                ),
                loopbackURL: loopback,
                isApplied: isApplied && appliedIDs.contains(plan.rule.id)
            )
        }
    }

    func preview(environmentID: String, ruleID: UUID) -> LinuxPortForwardPreview? {
        previews(environmentID: environmentID).first { $0.rule.id == ruleID }
    }

    /// Diagnostic line for the settings surface; never a fabricated URL.
    func addressSummary(environmentID: String) -> String {
        guard let address = deviceAddressProvider() else {
            return "未检测到局域网地址（URL 仅在检测到本机 LAN 地址后显示）"
        }
        return "局域网地址 \(address)"
    }

    // MARK: - Mutations

    func addRule(
        environmentID: String,
        guestPort: Int,
        requestedHostPort: Int?,
        label: String
    ) async throws {
        var set = LinuxPortForwardSet(
            environmentID: environmentID,
            rules: rules(environmentID: environmentID)
        )
        try set.addRule(
            guestPort: guestPort,
            requestedHostPort: requestedHostPort,
            label: label
        )
        persist(set.rules, environmentID: environmentID)
        lastError = nil
        await applyRules(environmentID: environmentID)
    }

    func removeRule(environmentID: String, ruleID: UUID) async {
        var set = LinuxPortForwardSet(
            environmentID: environmentID,
            rules: rules(environmentID: environmentID)
        )
        guard (try? set.removeRule(id: ruleID)) != nil else { return }
        persist(set.rules, environmentID: environmentID)
        // Drop the engine forward for the removed rule before re-planning.
        if let applied = appliedPlansByEnvironment[environmentID]?
            .first(where: { $0.rule.id == ruleID }) {
            await applier.remove(
                environmentID: environmentID,
                forward: Self.forward(for: applied)
            )
        }
        await applyRules(environmentID: environmentID)
    }

    func setEnabled(
        environmentID: String,
        ruleID: UUID,
        isEnabled: Bool
    ) async throws {
        var set = LinuxPortForwardSet(
            environmentID: environmentID,
            rules: rules(environmentID: environmentID)
        )
        try set.updateRule(id: ruleID, isEnabled: isEnabled)
        persist(set.rules, environmentID: environmentID)
        if !isEnabled, let applied = appliedPlansByEnvironment[environmentID]?
            .first(where: { $0.rule.id == ruleID }) {
            await applier.remove(
                environmentID: environmentID,
                forward: Self.forward(for: applied)
            )
        }
        await applyRules(environmentID: environmentID)
    }

    /// Removes every rule of a deleted environment.
    func forget(environmentID: String) async {
        await clearEngineForwards(environmentID: environmentID)
        rulesByEnvironment.removeValue(forKey: environmentID)
        appliedPlansByEnvironment.removeValue(forKey: environmentID)
        LinuxPortForwardRuleStore.save(rulesByEnvironment, to: defaults)
    }

    /// The VM stopped: the engine drops its own forwards with the VM, so only
    /// the applied view is cleared. Rules and the user's preference stay.
    func guestStopped(environmentID: String) {
        appliedPlansByEnvironment.removeValue(forKey: environmentID)
    }

    /// Restores every enabled rule of a running VM. Called on guest start, on
    /// rule changes and after a relaunch when the guest is started again.
    func applyRules(environmentID: String) async {
        guard await applier.guestIsRunning(environmentID: environmentID) else {
            appliedPlansByEnvironment.removeValue(forKey: environmentID)
            return
        }
        await clearEngineForwards(environmentID: environmentID)
        let set = LinuxPortForwardSet(
            environmentID: environmentID,
            rules: rules(environmentID: environmentID)
        )
        let planned = (try? set.plan()) ?? []
        var applied: [LinuxPortForwardPlan] = []
        var occupied = Set<Int>()
        var conflict: String?
        for plan in planned {
            do {
                try await applier.apply(
                    environmentID: environmentID,
                    forward: Self.forward(for: plan)
                )
                if plan.wasRemapped, conflict == nil {
                    conflict = "固定端口 \(plan.rule.requestedHostPort ?? 0) 已被占用，\(plan.rule.label) 已改用 \(plan.hostPort)"
                }
                applied.append(plan)
                occupied.insert(Int(plan.hostPort))
            } catch {
                // The engine rejected the port (another process owns it, or a
                // sibling forward raced us). Retry with the next free port
                // instead of leaving the service unreachable.
                var retried = false
                for _ in 0..<4 {
                    guard let next = LinuxPortForwardSet.lowestFreeHostPort(
                        excluding: occupied.union([Int(plan.hostPort)])
                    ) else { break }
                    var candidate = plan
                    candidate.hostPort = UInt16(next)
                    candidate.reason = plan.isFixed ? .conflictRemap : .dynamicRetry
                    do {
                        try await applier.apply(
                            environmentID: environmentID,
                            forward: Self.forward(for: candidate)
                        )
                        if conflict == nil {
                            conflict = "Host 端口 \(plan.hostPort) 已被占用，\(plan.rule.label) 已改用 \(next)"
                        }
                        applied.append(candidate)
                        occupied.insert(next)
                        retried = true
                        break
                    } catch {
                        occupied.insert(next)
                        continue
                    }
                }
                if !retried {
                    lastError = "端口转发失败：\(plan.rule.label) → guest \(plan.rule.guestPort) · \(error.localizedDescription)"
                    FloeLogger(category: .app).warning(
                        "linuxPortForwardApplyFailed environment=\(environmentID) rule=\(plan.rule.id.uuidString) port=\(plan.hostPort)"
                    )
                }
            }
        }
        appliedPlansByEnvironment[environmentID] = applied
        lastConflictNotice = conflict
        lastAppliedAt = Date()
        FloeLogger(category: .app).info(
            "linuxPortForwardApplied environment=\(environmentID) rules=\(applied.count) planned=\(planned.count)"
        )
    }

    /// Removes all engine forwards of one environment (VM stop/delete).
    func clearEngineForwards(environmentID: String) async {
        let applied = appliedPlansByEnvironment[environmentID] ?? []
        for plan in applied {
            await applier.remove(
                environmentID: environmentID,
                forward: Self.forward(for: plan)
            )
        }
        appliedPlansByEnvironment[environmentID] = []
    }

    // MARK: - Internals

    private static func forward(for plan: LinuxPortForwardPlan) -> LinuxGuestServiceForward {
        LinuxGuestServiceForward(
            hostAddress: plan.rule.bindAddress,
            hostPort: plan.hostPort,
            guestPort: plan.rule.guestPort
        )
    }

    private func persist(_ rules: [LinuxPortForwardRule], environmentID: String) {
        if rules.isEmpty {
            rulesByEnvironment.removeValue(forKey: environmentID)
        } else {
            rulesByEnvironment[environmentID] = rules
        }
        LinuxPortForwardRuleStore.save(rulesByEnvironment, to: defaults)
    }
}
#endif

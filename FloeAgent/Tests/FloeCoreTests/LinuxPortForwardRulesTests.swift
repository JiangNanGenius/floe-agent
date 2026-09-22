// FloeCoreTests — Build 222 persistent per-environment TCP port-forward rules.
//
// Fixed and dynamic host ports inside 49152–65535, at most 16 rules per VM,
// LAN bind by default, explicit conflict handling, restart restoration and
// LAN/loopback-only URLs (never a WAN address, never a router mapping).

import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore.LinuxPortForwardRules")
struct LinuxPortForwardRulesTests {

    private func makeSet(_ rules: [LinuxPortForwardRule] = []) -> LinuxPortForwardSet {
        LinuxPortForwardSet(environmentID: "env-1", rules: rules)
    }

    @Test("The managed host-port range, cap and LAN default are the Build 222 contract")
    func constants() {
        #expect(LinuxPortForwardLimits.minimumHostPort == 49_152)
        #expect(LinuxPortForwardLimits.maximumHostPort == 65_535)
        #expect(LinuxPortForwardLimits.maximumRulesPerEnvironment == 16)
        #expect(LinuxPortForwardLimits.defaultBindAddress == "0.0.0.0")
        #expect(LinuxPortForwardLimits.isAllowedHostPort(49_152))
        #expect(LinuxPortForwardLimits.isAllowedHostPort(65_535))
        #expect(!LinuxPortForwardLimits.isAllowedHostPort(49_151))
        #expect(!LinuxPortForwardLimits.isAllowedHostPort(80))
    }

    @Test("A fixed rule inside the range is accepted; outside is rejected")
    func fixedRuleValidation() throws {
        var set = makeSet()
        let rule = try set.addRule(guestPort: 8_080, requestedHostPort: 50_000, label: "web")
        #expect(rule.requestedHostPort == 50_000)
        #expect(!rule.isDynamic)
        #expect(set.enabledRules.count == 1)

        #expect(throws: LinuxPortForwardRuleError.hostPortOutOfRange(80)) {
            try set.addRule(guestPort: 3_000, requestedHostPort: 80, label: "unsafe")
        }
        #expect(throws: LinuxPortForwardRuleError.guestPortOutOfRange(0)) {
            try set.addRule(guestPort: 0, requestedHostPort: nil, label: "bad guest")
        }
        #expect(throws: LinuxPortForwardRuleError.invalidBindAddress("example.com")) {
            try set.addRule(
                guestPort: 3_000,
                requestedHostPort: nil,
                label: "hostname",
                bindAddress: "example.com"
            )
        }
    }

    @Test("At most 16 enabled rules per VM; disabled rules do not consume the cap")
    func ruleCap() throws {
        var set = makeSet()
        for index in 0..<16 {
            try set.addRule(
                guestPort: 8_000 + index,
                requestedHostPort: nil,
                label: "svc-\(index)"
            )
        }
        #expect(set.enabledRules.count == 16)
        #expect(throws: LinuxPortForwardRuleError.ruleCapReached(
            limit: LinuxPortForwardLimits.maximumRulesPerEnvironment
        )) {
            try set.addRule(guestPort: 9_000, requestedHostPort: nil, label: "overflow")
        }
        // Disabling one frees exactly one slot.
        let disabled = set.enabledRules[0]
        try set.updateRule(id: disabled.id, isEnabled: false)
        let added = try set.addRule(guestPort: 9_000, requestedHostPort: nil, label: "replacement")
        #expect(added.isEnabled)
        #expect(set.enabledRules.count == 16)
    }

    @Test("A duplicate fixed host port is a reported conflict, not an overwrite")
    func fixedPortConflict() throws {
        var set = makeSet()
        let first = try set.addRule(guestPort: 8_080, requestedHostPort: 50_000, label: "web")
        #expect(throws: LinuxPortForwardRuleError.hostPortConflict(
            hostPort: 50_000,
            existingRuleID: first.id
        )) {
            try set.addRule(guestPort: 8_081, requestedHostPort: 50_000, label: "duplicate")
        }
        // A different bind address is a different socket.
        _ = try set.addRule(
            guestPort: 8_081,
            requestedHostPort: 50_000,
            label: "loopback copy",
            bindAddress: "127.0.0.1"
        )
        // Editing the rule itself does not conflict with itself.
        try set.updateRule(id: first.id, requestedHostPort: .some(50_001))
        #expect(set.rule(id: first.id)?.requestedHostPort == 50_001)
    }

    @Test("Dynamic rules take the lowest free host port in the range")
    func dynamicAllocation() throws {
        var set = makeSet()
        let first = try set.addRule(guestPort: 3_000, requestedHostPort: nil, label: "a")
        let second = try set.addRule(guestPort: 3_001, requestedHostPort: nil, label: "b")
        let plans = try set.plan()
        #expect(plans.count == 2)
        #expect(plans[0].hostPort == 49_152)
        #expect(plans[0].reason == .dynamicAllocation)
        #expect(plans[1].hostPort == 49_153)
        #expect(plans[1].reason == .dynamicAllocation)
        #expect(first.isDynamic)
        #expect(second.requestedHostPort == nil)
    }

    @Test("Restart restoration keeps a free fixed port and remaps an occupied one")
    func restorationConflictHandling() throws {
        var set = makeSet()
        let fixed = try set.addRule(guestPort: 8_080, requestedHostPort: 50_000, label: "web")
        let dynamic = try set.addRule(guestPort: 3_000, requestedHostPort: nil, label: "api")
        // 50_000 is already bound by another process after a relaunch.
        let plans = try set.plan(occupiedHostPorts: [50_000])
        let fixedPlan = plans.first { $0.rule.id == fixed.id }
        let dynamicPlan = plans.first { $0.rule.id == dynamic.id }
        #expect(fixedPlan?.reason == .conflictRemap)
        #expect(fixedPlan?.wasRemapped == true)
        // 49152 could not be used? It is free: the planner remapped to the
        // lowest free port, which is 49152.
        #expect(fixedPlan?.hostPort == 49_152)
        #expect(dynamicPlan?.reason == .dynamicAllocation)
        #expect(dynamicPlan?.hostPort == 49_153)
        // Restoration is deterministic for the same input.
        #expect(try set.plan(occupiedHostPorts: [50_000]) == plans)
    }

    @Test("Every port in use is an honest failure, not a silent binding")
    func rangeExhausted() throws {
        var set = makeSet()
        try set.addRule(guestPort: 3_000, requestedHostPort: nil, label: "api")
        let occupied = Set(
            LinuxPortForwardLimits.minimumHostPort...LinuxPortForwardLimits.maximumHostPort
        )
        #expect(throws: LinuxPortForwardRuleError.noAvailableHostPort) {
            try set.plan(occupiedHostPorts: occupied)
        }
    }

    @Test("Rules persist per environment and reload with the cap respected")
    func persistence() throws {
        let name = "floe.tests.portforward.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        var envOne = LinuxPortForwardSet(environmentID: "env-1")
        try envOne.addRule(guestPort: 8_080, requestedHostPort: 50_000, label: "web")
        try envOne.addRule(guestPort: 3_000, requestedHostPort: nil, label: "api")
        var envTwo = LinuxPortForwardSet(environmentID: "env-2")
        try envTwo.addRule(guestPort: 5_000, requestedHostPort: nil, label: "other")

        LinuxPortForwardRuleStore.save(
            ["env-1": envOne.rules, "env-2": envTwo.rules],
            to: defaults
        )
        let loaded = LinuxPortForwardRuleStore.load(from: defaults)
        #expect(loaded.keys.sorted() == ["env-1", "env-2"])
        #expect(loaded["env-1"]?.count == 2)
        let restored = LinuxPortForwardSet(
            environmentID: "env-1",
            rules: loaded["env-1"] ?? []
        )
        let plans = try restored.plan()
        #expect(plans.first { $0.rule.label == "web" }?.hostPort == 50_000)
        #expect(plans.first { $0.rule.label == "api" }?.hostPort == 49_152)
    }

    @Test("An over-cap persisted store is normalized deterministically on load")
    func persistedCapNormalization() throws {
        let name = "floe.tests.portforward.cap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        var set = LinuxPortForwardSet(environmentID: "env-1")
        for index in 0..<16 {
            try set.addRule(
                guestPort: 7_000 + index,
                requestedHostPort: nil,
                label: "svc-\(index)",
                now: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        // A hand-edited store with an extra enabled rule beyond the cap.
        let extra = LinuxPortForwardRule(
            environmentID: "env-1",
            label: "overflow",
            guestPort: 9_999,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        LinuxPortForwardRuleStore.save(["env-1": set.rules + [extra]], to: defaults)
        let loaded = LinuxPortForwardRuleStore.load(from: defaults)
        let rules = loaded["env-1"] ?? []
        #expect(rules.count == 16)
        #expect(!rules.contains { $0.label == "overflow" })
    }

    @Test("Removing a rule frees its dynamic port")
    func removeRule() throws {
        var set = makeSet()
        let first = try set.addRule(guestPort: 3_000, requestedHostPort: nil, label: "a")
        let second = try set.addRule(guestPort: 3_001, requestedHostPort: nil, label: "b")
        try set.removeRule(id: first.id)
        #expect(set.rules.count == 1)
        let plans = try set.plan()
        #expect(plans.first?.hostPort == 49_152)
        #expect(plans.first?.rule.id == second.id)
        #expect(throws: LinuxPortForwardRuleError.ruleNotFound(first.id)) {
            try set.removeRule(id: first.id)
        }
    }
}

@Suite("FloeCore.LinuxPortForwardURL")
struct LinuxPortForwardURLTests {

    @Test("A dynamic-range loopback bind renders a copyable local URL")
    func loopbackURL() {
        let url = LinuxPortForwardURL.url(
            hostPort: 49_152,
            bindAddress: "127.0.0.1"
        )
        #expect(url?.absoluteString == "http://127.0.0.1:49152")
        #expect(LinuxPortForwardURL.qrPayload(
            hostPort: 49_152, bindAddress: "127.0.0.1"
        ) == "http://127.0.0.1:49152")
    }

    @Test("A LAN bind resolves to the device's real local address")
    func lanURL() {
        let url = LinuxPortForwardURL.url(
            hostPort: 50_000,
            bindAddress: LinuxPortForwardLimits.defaultBindAddress,
            deviceAddress: "192.168.1.24"
        )
        #expect(url?.absoluteString == "http://192.168.1.24:50000")
        // Without a discovered local address there is no honest single URL.
        #expect(LinuxPortForwardURL.url(
            hostPort: 50_000,
            bindAddress: LinuxPortForwardLimits.defaultBindAddress,
            deviceAddress: nil
        ) == nil)
    }

    @Test("A public/WAN address is never presented as a URL")
    func wanRejected() {
        #expect(LinuxPortForwardURL.url(
            hostPort: 50_000, bindAddress: "8.8.8.8"
        ) == nil)
        #expect(LinuxPortForwardURL.url(
            hostPort: 50_000,
            bindAddress: LinuxPortForwardLimits.defaultBindAddress,
            deviceAddress: "203.0.113.9"
        ) == nil)
        #expect(!LinuxPortForwardURL.isValidBindAddress("203.0.113.9"))
        #expect(!LinuxPortForwardURL.isValidBindAddress("example.com"))
        #expect(!LinuxPortForwardURL.isValidBindAddress(""))
    }

    @Test("Local private and link-local ranges are accepted")
    func localRanges() {
        #expect(LinuxPortForwardURL.isLocalAddress("10.0.0.5"))
        #expect(LinuxPortForwardURL.isLocalAddress("172.16.4.4"))
        #expect(LinuxPortForwardURL.isLocalAddress("172.31.255.254"))
        #expect(!LinuxPortForwardURL.isLocalAddress("172.32.0.1"))
        #expect(LinuxPortForwardURL.isLocalAddress("192.168.0.1"))
        #expect(LinuxPortForwardURL.isLocalAddress("169.254.1.1"))
        #expect(!LinuxPortForwardURL.isLocalAddress("1.1.1.1"))
        #expect(LinuxPortForwardURL.isValidBindAddress("0.0.0.0"))
        #expect(LinuxPortForwardURL.isValidBindAddress("192.168.1.5"))
    }
}

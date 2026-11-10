// SPDX-License-Identifier: MPL-2.0
//
// Focused behavior tests for the shared LAN discovery core: multi-type merge
// and dedupe, address resolution (and honest unresolved rows), permission /
// no-device / out-of-scope / no-Wi-Fi classification, bounded windows,
// bounded result buffers, cancellation, and input scope. All through the
// scripted probe seam — no live network is probed and no OS state is faked.

import Foundation
import Testing
@testable import FloeToolboxDiagnostics

private func lanService(_ name: String, _ type: String = "_http._tcp", interfaces: [String] = []) -> LANDiscoveredService {
    LANDiscoveredService(name: name, serviceType: type, domain: "local.", interfaces: interfaces)
}

/// Thread-safe recorder so @Sendable engine callbacks may capture it.
private final class EventBox: @unchecked Sendable {
    let lock = NSLock()
    private var storage: [LANDiscoveryEvent] = []
    func add(_ event: LANDiscoveryEvent) { lock.lock(); storage.append(event); lock.unlock() }
    var all: [LANDiscoveryEvent] { lock.lock(); defer { lock.unlock() }; return storage }
    func resolved(named name: String) -> Bool {
        all.contains { if case .serviceResolved(let service) = $0 { return service.name == name } else { return false } }
    }
    var foundCount: Int { all.filter { if case .serviceFound = $0 { return true } else { return false } }.count }
}

private func scriptedProbe(
    wifi: Bool = true,
    browses: [String: (batches: [[LANDiscoveredService]], outcome: LANBrowseOutcome)] = [:],
    resolves: [String: (host: String?, port: Int?, addresses: [String], note: String?)] = [:],
    browseDelay: TimeInterval = 0.05
) -> LANDiscoveryProbe {
    LANDiscoveryProbe(
        wifiAvailable: { _ in wifi },
        browse: { type, window, sink in
            guard let steps = browses[type] else {
                try? await Task.sleep(for: .milliseconds(20))
                return LANBrowseOutcome(sawReady: true, blockedReason: nil)
            }
            for batch in steps.batches {
                try? await Task.sleep(for: .nanoseconds(Int(browseDelay * 1_000_000_000)))
                sink(batch)
            }
            return steps.outcome
        },
        resolve: { service, timeout in
            if let answer = resolves[service.name] {
                try? await Task.sleep(for: .nanoseconds(5_000_000))
                return answer
            }
            // No scripted answer: honor the bounded timeout and stay unresolved.
            try? await Task.sleep(for: .seconds(min(timeout, 0.2)))
            return (nil, nil, [], nil)
        }
    )
}

@Test("Declared scope normalizes case, dots and rejects only outside the declared list")
func scopeNormalization() {
    let (accepted, rejected) = LANDiscoveryScope.normalize(["_HTTP._TCP.", "_home-assistant._tcp", "_ssh._tcp", "not-a-type"])
    #expect(accepted == ["_home-assistant._tcp", "_http._tcp"])
    #expect(Set(rejected) == Set(["_ssh._tcp", "not-a-type"]))
    for preset in LANDiscoveryPreset.allCases {
        for type in LANDiscoveryScope.types(for: preset) {
            #expect(LANDiscoveryScope.declaredBonjourTypes.contains(type))
        }
    }
    #expect(LANDiscoveryScope.types(for: .all).count == LANDiscoveryScope.declaredBonjourTypes.count)
}

@Test("Bounds reject empty lists, oversized windows and oversized counts")
func requestBounds() async throws {
    await #expect(throws: (any Error).self) { try LANDiscoveryEngine.Request(requestedTypes: []) }
    await #expect(throws: (any Error).self) { try LANDiscoveryEngine.Request(requestedTypes: ["_http._tcp"], browseSeconds: 0.1) }
    await #expect(throws: (any Error).self) { try LANDiscoveryEngine.Request(requestedTypes: ["_http._tcp"], browseSeconds: 31) }
    await #expect(throws: (any Error).self) { try LANDiscoveryEngine.Request(requestedTypes: (1...65).map { "_http\($0)._tcp" }) }
    _ = try LANDiscoveryEngine.Request(requestedTypes: ["_http._tcp"], browseSeconds: 0.5, resolveSeconds: 0.5)
}

@Test("Multi-type scan merges services, dedupes repeats and resolves address/port")
func multiTypeMergeResolve() async throws {
    let printer = lanService("Office", "_ipp._tcp")
    let probe = scriptedProbe(
        browses: [
            "_http._tcp": ([
                [lanService("NAS"), lanService("Hub")],
                [lanService("NAS"), lanService("Hub"), lanService("NAS")],
            ], LANBrowseOutcome(sawReady: true, blockedReason: nil)),
            "_ipp._tcp": (
                [[printer.withInterfaces(["en0"])]],
                LANBrowseOutcome(sawReady: true, blockedReason: nil)
            )
        ],
        resolves: [
            "NAS": ("nas.local", 8090, ["192.0.2.10"], nil),
            "Office": ("office.local", 631, ["192.0.2.40"], nil)
        ]
    )
    let events = EventBox()
    let report = try await LANDiscoveryEngine.scan(
        try LANDiscoveryEngine.Request(requestedTypes: ["_http._tcp", "_ipp._tcp"], browseSeconds: 0.5, resolveSeconds: 1.5),
        probe: probe,
        onEvent: { events.add($0) }
    )
    #expect(report.status == .foundDevices)
    #expect(report.services.count == 3)
    let nas = report.services.first { $0.name == "NAS" }
    #expect(nas?.resolved == true)
    #expect(nas?.displayAddress == "192.0.2.10")
    #expect(nas?.port == 8090)
    let hub = report.services.first { $0.name == "Hub" }
    #expect(hub?.resolved == false)
    #expect(hub?.addresses.isEmpty == true)
    #expect(hub?.port == nil) // unresolved stays unresolved — no fabricated port
    #expect(report.unresolvedCount == 1)
    #expect(report.browsedTypes == ["_http._tcp", "_ipp._tcp"])
    let office = report.services.first { $0.name == "Office" }
    #expect(office?.interfaces == ["en0"])
    #expect(events.resolved(named: "NAS"))
}

@Test("Ready browsing with zero services reports noDevices, waiting state reports permissionUncertain, never both as 'no devices'")
func statusClassification() async throws {
    let emptyReady = try await LANDiscoveryEngine.scan(
        try LANDiscoveryEngine.Request(requestedTypes: ["_http._tcp"], browseSeconds: 0.5),
        probe: scriptedProbe(browses: ["_http._tcp": ([[]], LANBrowseOutcome(sawReady: true, blockedReason: nil))])
    )
    #expect(emptyReady.status == .noDevices)

    let waiting = try await LANDiscoveryEngine.scan(
        try LANDiscoveryEngine.Request(requestedTypes: ["_http._tcp"], browseSeconds: 0.5),
        probe: scriptedProbe(browses: ["_http._tcp": ([], LANBrowseOutcome(sawReady: false, blockedReason: "waiting: local network unavailable"))])
    )
    #expect(waiting.status == .permissionUncertain)
    #expect(waiting.notes.contains { $0.contains("waiting:") })

    let mixed = try await LANDiscoveryEngine.scan(
        try LANDiscoveryEngine.Request(requestedTypes: ["_http._tcp", "_ipp._tcp"], browseSeconds: 0.5),
        probe: scriptedProbe(browses: [
            "_http._tcp": ([], LANBrowseOutcome(sawReady: false, blockedReason: "waiting: denied")),
            "_ipp._tcp": ([[lanService("Printer")]], LANBrowseOutcome(sawReady: true, blockedReason: nil))
        ])
    )
    #expect(mixed.status == .foundDevices) // partial results win
    #expect(mixed.notes.contains { $0.contains("did not complete") })
}

@Test("No Wi-Fi path stops before browsing; all-out-of-scope requests browse nothing")
func guardedStarts() async throws {
    actor CallLog {
        var browsed: [String] = []
        func add(_ type: String) { browsed.append(type) }
        func all() -> [String] { browsed }
    }
    let log = CallLog()
    let noWiFi = try await LANDiscoveryEngine.scan(
        try LANDiscoveryEngine.Request(requestedTypes: ["_http._tcp"], browseSeconds: 0.5),
        probe: LANDiscoveryProbe(wifiAvailable: { _ in false }, browse: { type, _, _ in
            await log.add(type); return LANBrowseOutcome(sawReady: true, blockedReason: nil)
        }, resolve: { _, _ in (nil, nil, [], nil) })
    )
    #expect(noWiFi.status == .noWiFiPath)
    #expect(await log.all().isEmpty)

    let outOfScope = try await LANDiscoveryEngine.scan(
        try LANDiscoveryEngine.Request(requestedTypes: ["_ssh._tcp"], browseSeconds: 0.5),
        probe: LANDiscoveryProbe(wifiAvailable: { _ in true }, browse: { type, _, _ in
            await log.add(type); return LANBrowseOutcome(sawReady: true, blockedReason: nil)
        }, resolve: { _, _ in (nil, nil, [], nil) })
    )
    #expect(outOfScope.status == .outOfScopeOnly)
    #expect(outOfScope.rejectedTypes == ["_ssh._tcp"])
    #expect(await log.all().isEmpty)
}

@Test("Bounded buffers: the service cap truncates and says so; interfaces merge without duplicate rows")
func boundedMerging() async throws {
    let many = (1...10).map { lanService("dev\($0)") }
    let report = try await LANDiscoveryEngine.scan(
        try LANDiscoveryEngine.Request(requestedTypes: ["_http._tcp"], browseSeconds: 0.5, maximumServices: 4),
        probe: scriptedProbe(browses: ["_http._tcp": ([many], LANBrowseOutcome(sawReady: true, blockedReason: nil))])
    )
    #expect(report.services.count == 4)
    #expect(report.truncated)
    #expect(report.notes.contains { $0.contains("Result limit") })

    let ifaceProbe = scriptedProbe(browses: ["_http._tcp": ([
        [lanService("Cam")],
        [lanService("Cam", interfaces: ["en0"])],
    ], LANBrowseOutcome(sawReady: true, blockedReason: nil))])
    let ifaceEvents = EventBox()
    let merged = try await LANDiscoveryEngine.scan(
        try LANDiscoveryEngine.Request(requestedTypes: ["_http._tcp"], browseSeconds: 0.5, resolveSeconds: 0.5),
        probe: ifaceProbe,
        onEvent: { ifaceEvents.add($0) }
    )
    #expect(merged.services.count == 1)
    #expect(merged.services.first?.interfaces == ["en0"])
    #expect(ifaceEvents.foundCount == 1)
}

@Test("Cancellation stops the scan promptly with CancellationError, preserving no partial rows as success")
func cancellationStopsBounded() async throws {
    let probe = LANDiscoveryProbe(
        wifiAvailable: { _ in true },
        browse: { _, window, _ in
            let deadline = Date().addingTimeInterval(window)
            while Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
            }
            return LANBrowseOutcome(sawReady: false, blockedReason: Task.isCancelled ? "cancelled" : nil)
        },
        resolve: { _, timeout in
            try? await Task.sleep(for: .seconds(timeout))
            return (nil, nil, [], nil)
        }
    )
    let scan = Task {
        try await LANDiscoveryEngine.scan(
            try LANDiscoveryEngine.Request(requestedTypes: ["_http._tcp", "_ipp._tcp"], browseSeconds: 30),
            probe: probe)
    }
    try await Task.sleep(for: .milliseconds(250))
    scan.cancel()
    let started = ContinuousClock.now
    await #expect(throws: (any Error).self) { try await scan.value }
    let components = started.duration(to: .now).components
    let elapsed = Double(components.seconds) + Double(components.attoseconds) / 1e18
    #expect(elapsed < 5) // bounded: cancelled quickly, not held for the 30s window
}

@Test("Preset-wide scope browses every declared type simultaneously through one report")
func presetWideSimultaneousBrowse() async throws {
    actor BrowseRecorder {
        var types: Set<String> = []
        func saw(_ type: String) { types.insert(type) }
        func count() -> Int { types.count }
    }
    let recorder = BrowseRecorder()
    let all = LANDiscoveryScope.types(for: .all)
    let probe = LANDiscoveryProbe(
        wifiAvailable: { _ in true },
        browse: { type, window, sink in
            await recorder.saw(type)
            try? await Task.sleep(for: .milliseconds(20))
            sink([LANDiscoveryTestSupport.service(named: "dev-\(type)")])
            return LANBrowseOutcome(sawReady: true, blockedReason: nil)
        },
        resolve: { service, timeout in
            try? await Task.sleep(for: .nanoseconds(5_000_000))
            return ("\(service.name).local", 80, ["192.0.2.50"], nil)
        }
    )
    let report = try await LANDiscoveryEngine.scan(
        try LANDiscoveryEngine.Request(requestedTypes: all, browseSeconds: 0.5, resolveSeconds: 2),
        probe: probe)
    #expect(report.status == .foundDevices)
    #expect(report.services.count == all.count)
    #expect(await recorder.count() == all.count)
    #expect(report.browsedTypes == all.sorted())
    #expect(report.services.allSatisfy { $0.resolved })
    #expect(report.unresolvedCount == 0)
}

private enum LANDiscoveryTestSupport {
    static func service(named name: String) -> LANDiscoveredService {
        LANDiscoveredService(name: name, serviceType: "_http._tcp", domain: "local.")
    }
}

private extension LANDiscoveredService {
    func withInterfaces(_ names: [String]) -> LANDiscoveredService {
        var copy = self
        copy.interfaces = names
        return copy
    }
}

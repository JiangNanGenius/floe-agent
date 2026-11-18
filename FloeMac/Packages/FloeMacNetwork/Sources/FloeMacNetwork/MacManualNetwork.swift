// SPDX-License-Identifier: MPL-2.0
// A user-initiated toolbox operation owns a short-lived, exact-request lease.
// This is not an Agent task or a grant for background/model-authored actions.
import Foundation
import Observation
import FloeToolboxCore
import FloeToolboxDiagnostics

public enum MacManualNetworkRequest: Sendable, Equatable {
    case ping(String), traceroute(String), dns(String, MacManualDNSRecordType = .a), ports(String, [UInt16]), lan, wifi, roaming
}

public typealias MacManualDNSRecordType = DNSRecordType

final class MacManualNetworkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    let request: MacManualNetworkRequest
    let lease: SessionLease
    init(request: MacManualNetworkRequest, lease: SessionLease) { self.request = request; self.lease = lease }
    func close() { lock.withLock { open = false } }
    func isOpen() -> Bool { lock.withLock { open } }
    func withAdmission<T>(_ start: () throws -> T) throws -> T {
        try lock.withLock {
            guard open else { throw CancellationError() }
            return try start()
        }
    }
    func allows(_ proposed: SessionLease, _ target: String, _ operation: DiagnosticOperation) -> Bool {
        guard isOpen(), proposed == lease else { return false }
        switch (request, operation) {
        case (.ping(let expected), .ping), (.traceroute(let expected), .traceroute),
             (.dns(let expected, _), .dns): return expected == target
        case (.ports(let expected, let expectedPorts), .ports(let ports)):
            return expected == target && expectedPorts == ports
        case (.lan, .discovery(let types)):
            return target == "local." && types == LANDiscoveryScope.declaredBonjourTypes.joined(separator: ",")
        default: return false
        }
    }
}

protocol MacManualNetworkRunning: Sendable {
    func execute() async throws -> String
    func stop() async
}

private actor LiveManualNetworkRun: MacManualNetworkRunning {
    private let request: MacManualNetworkRequest
    private let gate: MacManualNetworkGate
    private let diagnostics: MacToolboxDiagnostics
    private let locale: Locale
    init(request: MacManualNetworkRequest, gate: MacManualNetworkGate, locale: Locale) {
        self.request = request; self.gate = gate
        self.locale = locale
        self.diagnostics = MacToolboxDiagnostics(lease: gate.lease,
            authorize: { lease, target, operation in gate.allows(lease, target, operation) },
            lanProbe: MacLANLiveProbe.probe)
    }
    func execute() async throws -> String {
        guard gate.isOpen() else { throw ToolboxError.staleSession }
        switch request {
        case .ping(let host):
            try MacOwnedDiagnosticCommand.validateHost(host)
            let result = try await MacOwnedDiagnosticCommand.run(.ping,
                arguments: ["-n", "-c", "4", "-W", "1000", host], timeout: .seconds(10), gate: gate)
            return result.output
        case .traceroute(let host):
            try MacOwnedDiagnosticCommand.validateHost(host)
            let result = try await MacOwnedDiagnosticCommand.run(.traceroute,
                arguments: ["-n", "-m", "30", "-q", "1", "-w", "1", host], timeout: .seconds(37), gate: gate)
            return result.output
        case .dns(let host, let type):
            try MacOwnedDiagnosticCommand.validateHost(host)
            let result = try await MacOwnedDiagnosticCommand.run(.dns,
                arguments: ["-q", host, "-t", String(describing: type).uppercased(),
                            "+noall", "+comments", "+answer", "+time=3", "+tries=1"],
                timeout: .seconds(7), gate: gate)
            return result.output
        case .ports(let host, let ports):
            try MacOwnedDiagnosticCommand.validateHost(host)
            guard (1...64).contains(ports.count), !ports.contains(0), Set(ports).count == ports.count else {
                throw ToolboxError.invalid("port bounds")
            }
            var lines: [String] = []
            for port in ports {
                let start = ContinuousClock.now
                let reply = try await MacOwnedDiagnosticCommand.run(.tcp,
                    arguments: ["-z", "-G", "2", "-w", "2", host, String(port)],
                    timeout: .seconds(6), gate: gate)
                let elapsed = start.duration(to: .now).components
                let observation = MacPortObservation(port: port, isOpen: reply.succeeded,
                    elapsedMilliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                lines.append(MacManualNetworkFormatting.port(observation, locale: locale))
            }
            return lines.joined(separator: "\n")
        case .lan:
            let report = try await diagnostics.lanScan()
            return MacManualNetworkFormatting.lan(report, locale: locale)
        case .wifi:
            let observation = try await CoreWLANWiFiProvider().observeGuarded(isCurrent: { [gate] in gate.isOpen() })
            guard gate.isOpen(), !Task.isCancelled else { throw CancellationError() }
            return MacManualNetworkFormatting.wifi(observation, locale: locale)
        case .roaming:
            let provider = CoreWLANWiFiProvider()
            let started = ContinuousClock.now
            var samples: [(seconds: Int, observation: MacWiFiObservation)] = []
            for index in 0..<6 {
                if index > 0 { try await Task.sleep(for: .seconds(2)) }
                let observation = try await provider.observeGuarded(isCurrent: { [gate] in gate.isOpen() })
                guard gate.isOpen(), !Task.isCancelled else { throw CancellationError() }
                samples.append((Int(started.duration(to: .now).components.seconds), observation))
            }
            return MacManualNetworkFormatting.roaming(samples, locale: locale)
        }
    }
    func stop() async { await diagnostics.stop() }
}

/// Owns exactly one explicitly started toolbox operation and its teardown.
@MainActor @Observable
public final class MacManualNetworkOwner {
    public private(set) var running = false
    public private(set) var result: String?
    public private(set) var failure = false
    private var closed = false
    private var gate: MacManualNetworkGate?
    private var task: Task<Void, Never>?
    private var runner: (any MacManualNetworkRunning)?
    private let makeRunner: @Sendable (MacManualNetworkRequest, MacManualNetworkGate, Locale) -> any MacManualNetworkRunning

    public init() { makeRunner = { LiveManualNetworkRun(request: $0, gate: $1, locale: $2) } }
    init(makeRunner: @escaping @Sendable (MacManualNetworkRequest, MacManualNetworkGate, Locale) -> any MacManualNetworkRunning) {
        self.makeRunner = makeRunner
    }
    @discardableResult public func start(_ request: MacManualNetworkRequest, locale: Locale = .current) -> Bool {
        // LAN browsing shares the same verified teardown as the other
        // diagnostics: cancelling the owner task cancels the discovery engine's
        // browse/resolve group, which retires the NWBrowser and deallocates
        // the DNS-SD resolve/address queries on their own queues (proven by
        // MacLANLiveProbeDrainTests before this admission was opened).
        return startOwnedOperation(request, locale: locale)
    }

    // Internal admission for fake-runner lifecycle tests. Public entry above
    // exposes only requests with a verified startup boundary.
    @discardableResult func startOwnedOperation(_ request: MacManualNetworkRequest, locale: Locale = .current) -> Bool {
        guard !closed, task == nil else { return false }
        let gate = MacManualNetworkGate(request: request, lease: SessionLease(ownerID: UUID()))
        let runner = makeRunner(request, gate, locale)
        self.gate = gate; self.runner = runner; running = true; result = nil; failure = false
        task = Task { [weak self] in
            let value: Result<String, any Error>
            do { value = .success(try await runner.execute()) }
            catch { value = .failure(error) }
            await runner.stop()
            guard let self else { return }
            if gate.isOpen() {
                switch value {
                case .success(let text): self.result = text.isEmpty ? "—" : text
                case .failure: self.failure = true
                }
            }
            gate.close(); self.gate = nil; self.runner = nil; self.task = nil; self.running = false
        }
        return true
    }
    public func cancel() {
        gate?.close()
        task?.cancel()
        if let runner { Task { await runner.stop() } }
    }
    public func closeAdmissions() { closed = true; cancel() }
    public func resumeAfterCancelledTermination() { closed = false }
    public func drain(timeout: TimeInterval = 5) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(max(0, timeout))
        while task != nil {
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return true
    }
}

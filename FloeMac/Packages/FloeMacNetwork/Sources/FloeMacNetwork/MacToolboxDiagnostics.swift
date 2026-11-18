import Foundation
import FloeToolboxCore
import FloeToolboxClients
import FloeToolboxDiagnostics

/// One non-reusable diagnostic session. The Mac host creates it for a tool
/// grant, hands it the existing scoped authorizer and an optional live LAN
/// probe, and closes it when the panel or task ends. Late transport results
/// are fenced by lease and generation.
public actor MacToolboxDiagnostics {
    public nonisolated let lease: SessionLease
    private let authorize: DiagnosticAuthorizer
    private let transport: any MacDiagnosticTransport
    private let gate: MacRunGate
    private var closed = false
    private var generation = UUID()
    private var stopTask: Task<Void, Never>?

    /// Live composition over the unchanged FloeToolboxDiagnostics service.
    public init(lease: SessionLease, authorize: @escaping DiagnosticAuthorizer,
                lanProbe: LANDiscoveryProbe? = nil) {
        let gate = MacRunGate(lease: lease)
        self.lease = lease
        self.authorize = authorize
        self.gate = gate
        self.transport = LiveMacDiagnosticTransport(lease: lease, gate: gate, lanProbe: lanProbe)
    }

    /// Injectable composition for isolated tests. The authorizer is still the
    /// host's real scoped callback; only the transport is scripted.
    init(lease: SessionLease, authorize: @escaping DiagnosticAuthorizer,
         transport: any MacDiagnosticTransport) {
        self.lease = lease
        self.authorize = authorize
        self.gate = MacRunGate(lease: lease)
        self.transport = transport
    }

    public var supportsLANDiscovery: Bool { transport.supportsLANDiscovery }

    // MARK: Operations

    public func ping(target: String, count: Int = 4, timeoutSeconds: Int = 1) async throws -> MacPingReport {
        guard (1...100).contains(count), (1...10).contains(timeoutSeconds) else {
            throw ToolboxError.invalid("ping bounds")
        }
        let run = try await permit(target, .ping)
        let transport = self.transport
        let replies = try await perform(run) {
            try await transport.ping(target: target, count: count, timeoutSeconds: timeoutSeconds)
        }
        return MacPingReport(target: target, replies: replies)
    }

    public func traceroute(target: String, maximumHops: Int = 30, timeoutSeconds: Int = 1,
                           requestID: UUID = UUID(),
                           onObservation: TracerouteObserver? = nil) async throws -> [TraceHop] {
        guard (1...30).contains(maximumHops), (1...5).contains(timeoutSeconds) else {
            throw ToolboxError.invalid("trace bounds")
        }
        let run = try await permit(target, .traceroute)
        let fencedObserver: TracerouteObserver?
        if let callback = onObservation {
            fencedObserver = { [weak self] event in
                guard let self else { return }
                guard await self.isCurrent(run) else { return }
                await callback(event)
            }
        } else {
            fencedObserver = nil
        }
        let transport = self.transport
        return try await perform(run) {
            try await transport.traceroute(target: target, maximumHops: maximumHops,
                timeoutSeconds: timeoutSeconds, requestID: requestID, onObservation: fencedObserver)
        }
    }

    public func dns(name: String, type: DNSRecordType = .a, timeout: Double = 5) async throws -> [DNSRecord] {
        guard timeout.isFinite, (0.1...30).contains(timeout) else { throw ToolboxError.invalid("DNS timeout") }
        let run = try await permit(name, .dns)
        let transport = self.transport
        return try await perform(run) { try await transport.dns(name: name, type: type, timeout: timeout) }
    }

    public func ports(target: String, ports: [UInt16], timeout: Double = 2) async throws -> [MacPortObservation] {
        guard !ports.isEmpty, ports.count <= 64, ports.allSatisfy({ $0 != 0 }),
              Set(ports).count == ports.count, timeout.isFinite, (0.05...10).contains(timeout) else {
            throw ToolboxError.invalid("port bounds")
        }
        let run = try await permit(target, .ports(ports))
        let transport = self.transport
        return try await perform(run) {
            try await transport.ports(target: target, ports: ports, timeout: timeout)
        }
    }

    public func discover(type: String, seconds: Double = 3) async throws -> [MacBonjourService] {
        try Self.validateBonjourType(type)
        guard seconds.isFinite, (0.1...30).contains(seconds) else { throw ToolboxError.invalid("discovery window") }
        let run = try await permit("local.", .discovery(type))
        let transport = self.transport
        return try await perform(run) { try await transport.discover(type: type, seconds: seconds) }
    }

    public func lanScan(types: [String] = [], seconds: Double = 3,
                        onEvent: (@Sendable (LANDiscoveryEvent) -> Void)? = nil) async throws -> LANScanReport {
        guard transport.supportsLANDiscovery else {
            throw MacToolboxCapabilityError.unsupported("LAN discovery probe is not configured")
        }
        let requested = types.isEmpty ? LANDiscoveryScope.declaredBonjourTypes : types
        for type in requested { try Self.validateBonjourType(type) }
        let run = try await permit("local.", .discovery(requested.joined(separator: ",")))
        // Event delivery stays synchronous and ordered. `stop()` closes the
        // gate before awaiting the transport, so a late event is dropped
        // without an actor hop that could reorder progress updates.
        let gate = self.gate
        let fencedEvent: (@Sendable (LANDiscoveryEvent) -> Void)?
        if let callback = onEvent {
            fencedEvent = { event in
                guard gate.isOpen else { return }
                callback(event)
            }
        } else {
            fencedEvent = nil
        }
        let transport = self.transport
        return try await perform(run) {
            try await transport.lanScan(types: requested, seconds: seconds, onEvent: fencedEvent)
        }
    }

    /// Ends this session. The shared DiagnosticService stops its sockets and
    /// generation-fences every late callback; the controller never restarts it.
    public func stop() async {
        if let stopTask { await stopTask.value; return }
        closed = true
        generation = UUID()
        gate.close()
        let task = Task { await transport.stop() }
        stopTask = task
        await task.value
    }

    // MARK: Authorization and fencing

    private func permit(_ target: String, _ operation: DiagnosticOperation) async throws -> UUID {
        guard !closed, !Task.isCancelled else { throw ToolboxError.staleSession }
        try Self.validateTarget(target)
        let run = generation
        guard try await authorize(lease, target, operation) else { throw ToolboxError.denied }
        try check(run)
        return run
    }

    private func perform<T: Sendable>(_ run: UUID, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = self.gate
        do {
            let value = try await withTaskCancellationHandler {
                try await operation()
            } onCancel: {
                gate.close()
                Task { await self.stop() }
            }
            try check(run)
            return value
        } catch is CancellationError {
            await stop()
            throw CancellationError()
        } catch let error as DiagnosticError where error == .denied {
            // The live service denies internal work after the gate closes.
            // That is a session fence, not a second user denial.
            try check(run)
            throw error
        } catch {
            try check(run)
            throw error
        }
    }

    private func check(_ run: UUID) throws {
        if Task.isCancelled { throw CancellationError() }
        guard run == generation, !closed, gate.isOpen else { throw ToolboxError.staleSession }
    }

    private func isCurrent(_ run: UUID) async -> Bool {
        run == generation && !closed && gate.isOpen
    }

    // MARK: Input grammar (same rules as the shared service)

    static func validateTarget(_ target: String) throws {
        guard !target.isEmpty, target.utf8.count <= 253,
              !target.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }),
              !target.contains(where: { "@/\\?#".contains($0) }) else {
            throw ToolboxError.invalid("target")
        }
    }

    static func validateBonjourType(_ type: String) throws {
        guard type.utf8.count <= 64, type.hasPrefix("_"),
              type.hasSuffix("._tcp") || type.hasSuffix("._udp"),
              type.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                      || [45, 46, 95].contains($0)
              }) else {
            throw ToolboxError.invalid("Bonjour service type")
        }
    }
}

public struct MacPingObservation: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case reply(milliseconds: Double)
        case timeout
        case unreachable
    }
    public let sequence: Int
    public let address: String
    public let status: Status
    public init(sequence: Int, address: String, status: Status) {
        self.sequence = sequence
        self.address = address
        self.status = status
    }
}

public struct MacPortObservation: Equatable, Sendable {
    public let port: UInt16
    public let isOpen: Bool
    public let elapsedMilliseconds: Double
    public init(port: UInt16, isOpen: Bool, elapsedMilliseconds: Double) {
        self.port = port
        self.isOpen = isOpen
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public struct MacBonjourService: Hashable, Sendable {
    public let name: String
    public let type: String
    public let domain: String
    public init(name: String, type: String, domain: String) {
        self.name = name
        self.type = type
        self.domain = domain
    }
}

public struct MacPingReport: Equatable, Sendable {
    public let target: String
    public let replies: [MacPingObservation]
    public init(target: String, replies: [MacPingObservation]) {
        self.target = target
        self.replies = replies
    }
    public var resolvedAddress: String? { replies.first?.address }
    public var receivedCount: Int {
        replies.reduce(0) { count, reply in
            if case .reply = reply.status { return count + 1 }
            return count
        }
    }
    /// Only the probes that actually ran are in the denominator.
    public var lossPercent: Double? {
        guard !replies.isEmpty else { return nil }
        return Double(replies.count - receivedCount) / Double(replies.count) * 100
    }
}

public enum MacToolboxCapabilityError: Error, Equatable, Sendable {
    case permissionRequired(MacToolboxPermission)
    case selectionRequired(MacToolboxSelection)
    case unsupported(String)
    case staleSession
}

// MARK: Transport seam

public protocol MacDiagnosticTransport: Sendable {
    var supportsLANDiscovery: Bool { get }
    func ping(target: String, count: Int, timeoutSeconds: Int) async throws -> [MacPingObservation]
    func traceroute(target: String, maximumHops: Int, timeoutSeconds: Int, requestID: UUID,
                    onObservation: TracerouteObserver?) async throws -> [TraceHop]
    func dns(name: String, type: DNSRecordType, timeout: Double) async throws -> [DNSRecord]
    func ports(target: String, ports: [UInt16], timeout: Double) async throws -> [MacPortObservation]
    func discover(type: String, seconds: Double) async throws -> [MacBonjourService]
    func lanScan(types: [String], seconds: Double,
                 onEvent: (@Sendable (LANDiscoveryEvent) -> Void)?) async throws -> LANScanReport
    func stop() async
}

/// Unchanged shared service plus a lease gate. The controller already asked
/// the host's scoped authorizer; this inner gate only fences the service's
/// own internal checks and late work.
public struct LiveMacDiagnosticTransport: MacDiagnosticTransport {
    private let service: DiagnosticService
    private let gate: MacRunGate
    public nonisolated let supportsLANDiscovery: Bool

    public init(lease: SessionLease, gate: MacRunGate, lanProbe: LANDiscoveryProbe?) {
        self.gate = gate
        self.supportsLANDiscovery = lanProbe != nil
        self.service = DiagnosticService(lease: lease,
            authorize: { expected, _, _ in gate.allow(expected) },
            lanProbe: lanProbe)
    }

    public func ping(target: String, count: Int, timeoutSeconds: Int) async throws -> [MacPingObservation] {
        let values = try await service.ping(target: target, count: count, timeoutSeconds: timeoutSeconds)
        return values.map { value in
            let status: MacPingObservation.Status
            switch value.status {
            case .reply(let milliseconds): status = .reply(milliseconds: milliseconds)
            case .timeout: status = .timeout
            case .unreachable: status = .unreachable
            }
            return MacPingObservation(sequence: value.sequence, address: value.address, status: status)
        }
    }
    public func traceroute(target: String, maximumHops: Int, timeoutSeconds: Int, requestID: UUID,
                           onObservation: TracerouteObserver?) async throws -> [TraceHop] {
        try await service.traceroute(target: target, maximumHops: maximumHops,
            timeoutSeconds: timeoutSeconds, requestID: requestID, onObservation: onObservation)
    }
    public func dns(name: String, type: DNSRecordType, timeout: Double) async throws -> [DNSRecord] {
        try await service.dns(name: name, type: type, timeout: timeout)
    }
    public func ports(target: String, ports: [UInt16], timeout: Double) async throws -> [MacPortObservation] {
        let values = try await service.ports(target: target, ports: ports, timeout: timeout)
        return values.map { MacPortObservation(port: $0.port,
            isOpen: $0.status == .open, elapsedMilliseconds: $0.elapsedMilliseconds) }
    }
    public func discover(type: String, seconds: Double) async throws -> [MacBonjourService] {
        let values = try await service.discover(type: type, seconds: seconds)
        return values.map { MacBonjourService(name: $0.name, type: $0.type, domain: $0.domain) }
    }
    public func lanScan(types: [String], seconds: Double,
                        onEvent: (@Sendable (LANDiscoveryEvent) -> Void)?) async throws -> LANScanReport {
        try await service.lanScan(types: types, seconds: seconds, onEvent: onEvent)
    }
    public func stop() async {
        gate.close()
        await service.stop()
    }
}

/// Lock-backed lease/generation fence shared by the controller and the live
/// transport. It is closed before a close/cancel is awaited so a late callback
/// cannot re-enter the shared service.
public final class MacRunGate: @unchecked Sendable {
    private let lock = NSLock()
    private let lease: SessionLease
    private var closed = false

    public init(lease: SessionLease) { self.lease = lease }
    public var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return !closed }
    public func allow(_ candidate: SessionLease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && candidate == lease
    }
    public func close() {
        lock.lock(); closed = true; lock.unlock()
    }
}

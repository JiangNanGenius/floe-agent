import Foundation
@preconcurrency import Network
import Darwin
import dnssd
import FloeToolboxCore
import FloeToolboxDiagnostics

/// Mac live probe for the shared LANDiscoveryEngine. It browses only the
/// app-declared Bonjour types, reports a blocked browser separately from an
/// empty result and resolves addresses through DNS-SD. It never performs an
/// address-range scan and never invents an unresolved address or port.
public enum MacLANLiveProbe {
    public static var probe: LANDiscoveryProbe {
        LANDiscoveryProbe(
            wifiAvailable: { timeout in await MacLANPath.available(timeout: timeout) },
            browse: { type, window, sink in await MacLANBrowser.browse(type: type, window: window, sink: sink) },
            resolve: { service, timeout in await MacLANResolver.resolve(service, timeout: timeout) }
        )
    }
}

private final class MacLANGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, any Error>?
    private var waiter: CheckedContinuation<T, any Error>?

    func finish(_ result: Result<T, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(with: result)
    }

    func settledValue() -> T? {
        lock.lock(); defer { lock.unlock() }
        if case .success(let value)? = result { return value }
        return nil
    }

    func wait(seconds: Double) async throws -> T {
        let timer = Task {
            do { try await Task.sleep(for: .seconds(seconds)); finish(.failure(DiagnosticError.timedOut)) } catch {}
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(with: result) }
                else { waiter = continuation; lock.unlock() }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }
}

private enum MacLANPath {
    /// Only a definitely unsatisfied path returns false. An unread path falls
    /// through to browsing so the browser can classify permission honestly.
    static func available(timeout: TimeInterval) async -> Bool {
        let monitor = NWPathMonitor()
        let gate = MacLANGate<Bool>()
        monitor.pathUpdateHandler = { path in
            let hasLAN = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            gate.finish(.success(path.status == .satisfied && hasLAN))
        }
        monitor.start(queue: DispatchQueue(label: "floe.mac.toolbox.lan-path"))
        defer { monitor.cancel() }
        do { return try await gate.wait(seconds: timeout) }
        catch { return gate.settledValue() ?? true }
    }
}

private enum MacLANBrowser {
    private final class Session: @unchecked Sendable {
        let gate = MacLANGate<LANBrowseOutcome>()
        private let lock = NSLock()
        private var browser: NWBrowser?
        private var sawReady = false
        private var blocked: String?

        func attach(_ browser: NWBrowser) {
            lock.lock(); self.browser = browser; lock.unlock()
        }
        func noteReady() { lock.lock(); sawReady = true; lock.unlock() }
        func noteBlocked(_ reason: String) {
            lock.lock(); if blocked == nil { blocked = String(reason.prefix(512)) }; lock.unlock()
        }
        func outcome() -> LANBrowseOutcome {
            lock.lock(); defer { lock.unlock() }
            return LANBrowseOutcome(sawReady: sawReady, blockedReason: blocked)
        }
        func cancelBrowser() {
            lock.lock(); let browser = self.browser; self.browser = nil; lock.unlock()
            browser?.stateUpdateHandler = nil
            browser?.browseResultsChangedHandler = nil
            browser?.cancel()
        }
        static func ingest(_ results: Set<NWBrowser.Result>) -> [LANDiscoveredService] {
            results.compactMap { result in
                guard case .service(let name, let serviceType, let domain, _) = result.endpoint else { return nil }
                let interfaces = result.interfaces.map { "\($0)" }.sorted().prefix(4)
                let indices = result.interfaces.compactMap { UInt32(exactly: $0.index) }
                return LANDiscoveredService(name: name, serviceType: serviceType, domain: domain,
                    interfaces: Array(interfaces), interfaceIndices: indices)
            }
        }
    }

    static func browse(type: String, window: TimeInterval,
                       sink: @escaping @Sendable ([LANDiscoveredService]) -> Void) async -> LANBrowseOutcome {
        let queue = DispatchQueue(label: "floe.mac.toolbox.lan-browse")
        let session = Session()
        let parameters: NWParameters = type.hasSuffix("._udp") ? .udp : .tcp
        return await withTaskCancellationHandler {
            queue.async {
                let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: parameters)
                session.attach(browser)
                browser.stateUpdateHandler = { state in
                    switch state {
                    case .ready: session.noteReady()
                    case .waiting(let error): session.noteBlocked("waiting: \(error.localizedDescription)")
                    case .failed(let error):
                        session.noteBlocked("failed: \(error.localizedDescription)")
                        session.cancelBrowser()
                        session.gate.finish(.success(session.outcome()))
                    default: break
                    }
                }
                browser.browseResultsChangedHandler = { results, _ in
                    sink(Session.ingest(results))
                }
                browser.start(queue: queue)
                queue.asyncAfter(deadline: .now() + window) {
                    session.cancelBrowser()
                    session.gate.finish(.success(session.outcome()))
                }
            }
            do { return try await session.gate.wait(seconds: window + 2) }
            catch {
                await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                    queue.async { session.cancelBrowser(); waiter.resume() }
                }
                return session.gate.settledValue() ?? session.outcome()
            }
        } onCancel: {
            queue.async {
                session.cancelBrowser()
                session.gate.finish(.success(session.outcome()))
            }
        }
    }
}

private enum MacLANResolver {
    static func resolve(_ service: LANDiscoveredService, timeout: TimeInterval) async
        -> (host: String?, port: Int?, addresses: [String], note: String?) {
        let budget = max(0.3, min(3, timeout))
        let interfaceIndex = service.interfaceIndices.first ?? 0
        let start = ContinuousClock.now
        do {
            let (target, port) = try await MacLANResolveQuery.run(
                name: service.name, type: service.serviceType, domain: service.domain,
                interfaceIndex: interfaceIndex, timeout: budget)
            var addresses: [String] = []
            for recordType in [DNSRecordType.a, .aaaa] where addresses.count < 8 {
                let remaining = budget - elapsed(start)
                guard remaining > 0.2 else { break }
                if let values = try? await MacLANAddressQuery.run(
                    name: target, type: recordType, interfaceIndex: interfaceIndex,
                    timeout: min(1.5, remaining)) {
                    addresses.append(contentsOf: values.prefix(8))
                }
            }
            return (target, port, Array(addresses.prefix(8)), nil)
        } catch let error as DiagnosticError {
            switch error {
            case .timedOut:
                return (nil, nil, [], "resolve timed out for \(service.name) (\(service.serviceType))")
            default:
                return (nil, nil, [], "resolve did not complete for \(service.name) (\(service.serviceType))")
            }
        } catch {
            return (nil, nil, [], "resolve did not complete for \(service.name) (\(service.serviceType))")
        }
    }

    private static func elapsed(_ start: ContinuousClock.Instant) -> TimeInterval {
        let value = start.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}

private final class MacLANResolveQuery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "floe.mac.toolbox.lan-resolve")
    private var reference: DNSServiceRef?
    private var source: DispatchSourceRead?
    private var requestedName = ""
    private let gate = MacLANGate<(String, Int)>()

    static func run(name: String, type: String, domain: String,
                    interfaceIndex: UInt32, timeout: Double) async throws -> (String, Int) {
        let query = MacLANResolveQuery()
        do {
            let value = try await query.execute(name: name, type: type, domain: domain,
                interfaceIndex: interfaceIndex, timeout: timeout)
            await query.stop()
            return value
        } catch {
            await query.stop()
            throw error
        }
    }

    private func execute(name: String, type: String, domain: String,
                         interfaceIndex: UInt32, timeout: Double) async throws -> (String, Int) {
        queue.async { [self] in
            requestedName = name
            let error = DNSServiceResolve(&reference, 0, interfaceIndex, name, type, domain, {
                _, flags, _, error, _, hostTarget, port, _, _, context in
                guard let context else { return }
                let query = Unmanaged<MacLANResolveQuery>.fromOpaque(context).takeUnretainedValue()
                if error != kDNSServiceErr_NoError {
                    query.gate.finish(.failure(DiagnosticError.dnsServiceFailure(
                        code: error, name: query.requestedName, type: .srv)))
                    return
                }
                guard flags & UInt32(kDNSServiceFlagsMoreComing) == 0, let hostTarget else { return }
                let target = String(cString: hostTarget).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard !target.isEmpty, target.utf8.count <= 253 else {
                    query.gate.finish(.failure(DiagnosticError.invalid("resolve target")))
                    return
                }
                query.gate.finish(.success((target, Int(UInt16(bigEndian: port)))))
            }, Unmanaged.passUnretained(self).toOpaque())
            guard error == kDNSServiceErr_NoError else {
                gate.finish(.failure(DiagnosticError.dnsServiceFailure(code: error, name: name, type: .srv)))
                return
            }
            guard let reference else {
                gate.finish(.failure(DiagnosticError.system("resolve returned no service reference")))
                return
            }
            let descriptor = DNSServiceRefSockFD(reference)
            guard descriptor >= 0 else {
                gate.finish(.failure(DiagnosticError.system("resolve unavailable")))
                return
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            self.source = source
            source.setEventHandler { [weak self] in
                guard let self, let reference = self.reference else { return }
                let result = DNSServiceProcessResult(reference)
                if result != 0 {
                    self.gate.finish(.failure(DiagnosticError.dnsServiceFailure(
                        code: result, name: self.requestedName, type: .srv)))
                }
            }
            source.resume()
        }
        do {
            let value = try await gate.wait(seconds: timeout)
            await stop()
            return value
        } catch {
            await stop()
            throw error
        }
    }

    private func stop() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                source?.cancel(); source = nil
                if let reference { DNSServiceRefDeallocate(reference) }
                reference = nil
                waiter.resume()
            }
        }
    }
}

private final class MacLANAddressQuery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "floe.mac.toolbox.lan-address")
    private var reference: DNSServiceRef?
    private var source: DispatchSourceRead?
    private var requestedName = ""
    private var requestedType: DNSRecordType = .a
    private var records: [String] = []
    private let gate = MacLANGate<[String]>()

    static func run(name: String, type: DNSRecordType, interfaceIndex: UInt32,
                    timeout: Double) async throws -> [String] {
        let query = MacLANAddressQuery()
        do {
            let value = try await query.execute(name: name, type: type,
                interfaceIndex: interfaceIndex, timeout: timeout)
            await query.stop()
            return value
        } catch {
            await query.stop()
            throw error
        }
    }

    private func execute(name: String, type: DNSRecordType, interfaceIndex: UInt32,
                         timeout: Double) async throws -> [String] {
        guard type == .a || type == .aaaa else { throw DiagnosticError.invalid("address type") }
        queue.async { [self] in
            requestedName = name
            requestedType = type
            let error = DNSServiceQueryRecord(&reference,
                UInt32(kDNSServiceFlagsReturnIntermediates), interfaceIndex, name,
                type.rawValue, UInt16(kDNSServiceClass_IN), { _, flags, _, error, _, recordType, _, length, data, ttl, context in
                    guard let context else { return }
                    let query = Unmanaged<MacLANAddressQuery>.fromOpaque(context).takeUnretainedValue()
                    if error != kDNSServiceErr_NoError {
                        // NoSuchRecord is an honest empty answer for this window.
                        if error == kDNSServiceErr_NoSuchRecord {
                            query.gate.finish(.success(query.records))
                        } else {
                            query.gate.finish(.failure(DiagnosticError.dnsServiceFailure(
                                code: error, name: query.requestedName, type: query.requestedType)))
                        }
                        return
                    }
                    guard flags & UInt32(kDNSServiceFlagsAdd) != 0,
                          flags & UInt32(kDNSServiceFlagsMoreComing) == 0,
                          let data, length == 4 || length == 16,
                          DNSRecordType(rawValue: recordType) == query.requestedType else { return }
                    let record = DNSRecord(name: query.requestedName, type: query.requestedType, ttl: ttl,
                                           data: Data(bytes: data, count: Int(length)))
                    let text = record.text
                    if !text.isEmpty, !query.records.contains(text), query.records.count < 8 {
                        query.records.append(text)
                    }
                    query.gate.finish(.success(query.records))
                }, Unmanaged.passUnretained(self).toOpaque())
            guard error == kDNSServiceErr_NoError else {
                gate.finish(.failure(DiagnosticError.dnsServiceFailure(code: error, name: name, type: type)))
                return
            }
            guard let reference else {
                gate.finish(.failure(DiagnosticError.system("address query returned no service reference")))
                return
            }
            let descriptor = DNSServiceRefSockFD(reference)
            guard descriptor >= 0 else {
                gate.finish(.failure(DiagnosticError.system("address query unavailable")))
                return
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            self.source = source
            source.setEventHandler { [weak self] in
                guard let self, let reference = self.reference else { return }
                let result = DNSServiceProcessResult(reference)
                if result != 0 {
                    self.gate.finish(.failure(DiagnosticError.dnsServiceFailure(
                        code: result, name: self.requestedName, type: self.requestedType)))
                }
            }
            source.resume()
        }
        do {
            let value = try await gate.wait(seconds: timeout)
            await stop()
            return value
        } catch {
            await stop()
            throw error
        }
    }

    private func stop() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                source?.cancel(); source = nil
                if let reference { DNSServiceRefDeallocate(reference) }
                reference = nil
                waiter.resume()
            }
        }
    }
}

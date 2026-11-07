import Foundation
import Darwin
@preconcurrency import Network
import dnssd
import FloeToolboxCore
import FloeToolboxClients

public enum DiagnosticError: Error, Equatable, Sendable {
    case invalid(String), system(String), timedOut, busy, denied, stopped
    case dnsNameNotFound(String), dnsNoRecords(String, DNSRecordType), dnsService(Int32)

    /// DNS-SD error callbacks do not define their other parameters on failure.
    /// Use the request's frozen name/type, and retain unknown service codes.
    public static func dnsServiceFailure(code: Int32, name: String, type: DNSRecordType) -> Self {
        switch code {
        case Int32(kDNSServiceErr_NoSuchName): .dnsNameNotFound(name)
        case Int32(kDNSServiceErr_NoSuchRecord): .dnsNoRecords(name, type)
        default: .dnsService(code)
        }
    }
}
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock(); private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func throwIfCancelled() throws { if isCancelled || Task.isCancelled { throw CancellationError() } }
}
private final class DiagnosticCompletion<T:Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var result: Result<T,any Error>?
    private var waiter: CheckedContinuation<T,any Error>?
    func finish(_ result: Result<T,any Error>) {
        lock.lock(); guard self.result == nil else { lock.unlock(); return }; self.result = result
        let waiter = self.waiter; self.waiter = nil; lock.unlock(); waiter?.resume(with:result)
    }
    func wait(seconds: Double) async throws -> T {
        let timer = Task { do { try await Task.sleep(for:.seconds(seconds)); finish(.failure(DiagnosticError.timedOut)) } catch {} }; defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock(); if let result { lock.unlock(); continuation.resume(with:result) }
                else { waiter = continuation; lock.unlock() }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }
}
enum NetworkDiagnosticTiming {
    // A timed-out libc lookup can finish late, but cannot create unlimited blocked workers.
    private final class Slots: @unchecked Sendable {
        private let lock = NSLock(); private var used = 0
        func acquire() -> Bool { lock.lock(); defer { lock.unlock() }; guard used < 4 else { return false }; used += 1; return true }
        func release() { lock.lock(); used -= 1; lock.unlock() }
    }
    private static let slots = Slots()
    static func withDeadline<T:Sendable>(seconds: Double, timeoutMessage: String, operation: @escaping @Sendable () throws -> T) async throws -> T {
        guard slots.acquire() else { throw DiagnosticError.busy }
        let gate = DiagnosticCompletion<T>()
        DispatchQueue.global(qos:.utility).async { defer { slots.release() }; gate.finish(Result { try operation() }) }
        return try await gate.wait(seconds:seconds)
    }
}
enum HostResolver {
    static func ipv4Addresses(_ host: String) throws -> [UInt32] {
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host,nil,&hints,&result) == 0 else { throw DiagnosticError.system("DNS lookup failed") }
        defer { if let result { freeaddrinfo(result) } }
        var cursor = result, addresses: [UInt32] = []
        while let item = cursor, addresses.count < 64 {
            if let address = item.pointee.ai_addr, item.pointee.ai_addrlen >= MemoryLayout<sockaddr_in>.size {
                let value = address.withMemoryRebound(to:sockaddr_in.self,capacity:1) { $0.pointee.sin_addr.s_addr }
                if !addresses.contains(value) { addresses.append(value) }
            }
            cursor = item.pointee.ai_next
        }
        return addresses
    }
    static func presentation(_ value: UInt32) -> String {
        var address = in_addr(s_addr:value), buffer = [CChar](repeating:0,count:Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET,&address,&buffer,socklen_t(buffer.count)) != nil else { return "" }
        return String(cString:buffer)
    }
}
public enum DiagnosticOperation: Sendable { case ping, traceroute, dns, ports([UInt16]), discovery(String) }
public typealias DiagnosticAuthorizer = @Sendable (SessionLease,String,DiagnosticOperation) async throws -> Bool
public struct PingObservation: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case reply(milliseconds:Double), timeout, unreachable }
    public let sequence: Int; public let address: String; public let status: Status
}
public struct TraceHop: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case reached, intermediate, timeout, unreachable }
    public let ttl: Int; public let address: String?; public let milliseconds: [Double]; public let status: Status
}
public struct PortObservation: Equatable, Sendable {
    public enum Status: Sendable { case open, failed }
    public let port: UInt16; public let status: Status; public let elapsedMilliseconds: Double
}
public enum DNSRecordType: UInt16, CaseIterable, Sendable { case a = 1, cname = 5, ptr = 12, mx = 15, txt = 16, aaaa = 28, srv = 33 }
public struct DNSRecord: Equatable, Sendable {
    public let name: String; public let type: DNSRecordType; public let ttl: UInt32; public let data: Data
    public init(name: String, type: DNSRecordType, ttl: UInt32, data: Data) {
        self.name = name; self.type = type; self.ttl = ttl; self.data = data
    }
    public var text: String {
        if type == .a, data.count == 4 { return data.map(String.init).joined(separator:".") }
        if type == .aaaa, data.count == 16 {
            var address = in6_addr(), buffer = [CChar](repeating:0,count:Int(INET6_ADDRSTRLEN))
            withUnsafeMutableBytes(of:&address) { data.copyBytes(to:$0) }
            if inet_ntop(AF_INET6,&address,&buffer,socklen_t(buffer.count)) != nil { return String(cString:buffer) }
        }
        if type == .txt {
            var offset = 0, strings: [String] = []
            while offset < data.count { let length = Int(data[data.startIndex+offset]); offset += 1; guard offset+length <= data.count else { return "Invalid TXT record" }; strings.append(String(decoding:data[data.startIndex+offset..<data.startIndex+offset+length],as:UTF8.self)); offset += length }
            return strings.joined(separator:"\n")
        }
        let bytes = Array(data)
        func name(at start: Int) -> String? {
            guard start < bytes.count, bytes.count-start <= 255 else { return nil }
            var offset = start, labels: [String] = []
            while offset < bytes.count {
                let count = Int(bytes[offset]); offset += 1
                if count == 0 { return offset == bytes.count ? (labels.isEmpty ? "." : labels.joined(separator:".")+".") : nil }
                // DNS-SD supplies RDATA, not the original DNS message. Compression pointers
                // cannot be resolved here and are preserved as raw data instead of guessed.
                guard count <= 63, offset+count <= bytes.count else { return nil }
                labels.append(bytes[offset..<offset+count].map { value in
                    (33...126).contains(value) && value != 46 && value != 92 ? String(UnicodeScalar(value)) : String(format:"\\%03u",value)
                }.joined()); offset += count
            }
            return nil
        }
        func word(_ offset: Int) -> UInt16 { UInt16(bytes[offset])<<8 | UInt16(bytes[offset+1]) }
        if [.cname,.ptr].contains(type), let name = name(at:0) { return name }
        if type == .mx,bytes.count >= 3,let name = name(at:2) { return "\(word(0)) \(name)" }
        if type == .srv,bytes.count >= 7,let name = name(at:6) { return "\(word(0)) \(word(2)) \(word(4)) \(name)" }
        return data.map { String(format:"%02x",$0) }.joined(separator:" ")
    }
}

/// Uses public DNS-SD APIs, with a bounded result window. No custom resolver or network
/// configuration is installed. Cancellation deallocates the query on its owning queue.
private final class DNSQuery: @unchecked Sendable {
    private let queue = DispatchQueue(label:"floe.toolbox.dns")
    private var reference: DNSServiceRef?
    private var source: DispatchSourceRead?
    private var records: [DNSRecord] = []
    private var bytes = 0
    private var requestedName = ""
    private var requestedType = DNSRecordType.a
    private let gate = DiagnosticCompletion<[DNSRecord]>()
    func run(name: String, type: DNSRecordType, timeout: Double) async throws -> [DNSRecord] {
        queue.async { [self] in
            requestedName = name; requestedType = type
            // Without ReturnIntermediates, authoritative negative answers are
            // suppressed and an absent name looks like a generic timeout.
            let error = DNSServiceQueryRecord(&reference,UInt32(kDNSServiceFlagsReturnIntermediates),0,name,type.rawValue,UInt16(kDNSServiceClass_IN),{ _,flags,_,error,name,type,_,length,data,ttl,context in
                guard let context else { return }; let query = Unmanaged<DNSQuery>.fromOpaque(context).takeUnretainedValue()
                if error != kDNSServiceErr_NoError {
                    query.gate.finish(.failure(DiagnosticError.dnsServiceFailure(code:error,name:query.requestedName,type:query.requestedType))); return
                }
                // A CNAME referral from an A/AAAA query is intermediate, not
                // the requested address result. Let DNS-SD follow the alias.
                guard flags & UInt32(kDNSServiceFlagsAdd) != 0, let name,
                      let type = DNSRecordType(rawValue:type), type == query.requestedType,
                      Int(length) <= 65535 else { return }
                if (type == .a && length != 4) || (type == .aaaa && length != 16) { return }
                let bytes = data.map { Data(bytes:$0,count:Int(length)) } ?? Data()
                guard query.records.count < 256, query.bytes+bytes.count <= 1024*1024 else { query.gate.finish(.failure(DiagnosticError.invalid("DNS result limit"))); return }
                let value = DNSRecord(name:String(cString:name),type:type,ttl:ttl,data:bytes)
                if !query.records.contains(value) { query.records.append(value); query.bytes += bytes.count }
                if flags & UInt32(kDNSServiceFlagsMoreComing) == 0 { query.gate.finish(.success(query.records)) }
            },Unmanaged.passUnretained(self).toOpaque())
            guard error == kDNSServiceErr_NoError else { gate.finish(.failure(DiagnosticError.dnsServiceFailure(code:error,name:name,type:type))); return }
            guard let reference else { gate.finish(.failure(DiagnosticError.system("DNS query returned no service reference"))); return }
            let descriptor = DNSServiceRefSockFD(reference)
            guard descriptor >= 0 else { gate.finish(.failure(DiagnosticError.system("DNS query unavailable"))); return }
            let source = DispatchSource.makeReadSource(fileDescriptor:descriptor,queue:queue); self.source = source
            source.setEventHandler { [weak self] in
                guard let self, let reference = self.reference else { return }
                let result = DNSServiceProcessResult(reference)
                if result != 0 { self.gate.finish(.failure(DiagnosticError.dnsServiceFailure(code:result,name:self.requestedName,type:self.requestedType))) }
            }
            source.resume()
        }
        do { let result = try await gate.wait(seconds:timeout); await stop(); return result }
        catch { await stop(); throw error }
    }
    private func stop() async {
        await withCheckedContinuation { waiter in queue.async { [self] in source?.cancel(); source = nil; if let reference { DNSServiceRefDeallocate(reference); self.reference = nil }; waiter.resume() } }
    }
}

public actor DiagnosticService {
    public nonisolated let lease: SessionLease
    private let authorize: DiagnosticAuthorizer
    private var stopped = false
    private var generation = UUID()
    private var tokens: [UUID:CancellationToken] = [:]
    public init(lease: SessionLease, authorize: @escaping DiagnosticAuthorizer) { self.lease = lease; self.authorize = authorize }
    private func permit(_ target: String, _ operation: DiagnosticOperation) async throws -> UUID {
        guard !stopped, !Task.isCancelled, !target.isEmpty, target.utf8.count <= 253,
              !target.unicodeScalars.contains(where:{ CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !target.contains(where:{ "@/\\?#".contains($0) }) else { throw DiagnosticError.invalid("target") }
        let run = generation
        guard try await authorize(lease,target,operation) else { throw DiagnosticError.denied }
        try check(run); return run
    }
    private func check(_ run: UUID) throws { guard run == generation, !stopped, !Task.isCancelled else { throw DiagnosticError.stopped } }
    public func ping(target: String, count: Int = 4, timeoutSeconds: Int = 1) async throws -> [PingObservation] {
        guard (1...100).contains(count), (1...10).contains(timeoutSeconds) else { throw DiagnosticError.invalid("ping bounds") }
        let run = try await permit(target,.ping), id = UUID(), token = CancellationToken(); tokens[id] = token; defer { tokens.removeValue(forKey:id) }
        let result = try await withTaskCancellationHandler { try await DeviceICMPPing.run(target:target,count:count,timeoutSeconds:timeoutSeconds,cancellation:token) } onCancel: { token.cancel() }
        try check(run)
        return result.replies.map { reply in
            let status: PingObservation.Status
            switch reply.status { case .received(let ms): status = .reply(milliseconds:ms); case .timeout: status = .timeout; case .unreachable: status = .unreachable }
            return PingObservation(sequence:reply.sequence,address:result.resolvedAddress,status:status)
        }
    }
    public func traceroute(target: String, maximumHops: Int = 30, timeoutSeconds: Int = 1) async throws -> [TraceHop] {
        guard (1...30).contains(maximumHops), (1...5).contains(timeoutSeconds) else { throw DiagnosticError.invalid("trace bounds") }
        let run = try await permit(target,.traceroute), id = UUID(), token = CancellationToken(); tokens[id] = token; defer { tokens.removeValue(forKey:id) }
        let result = try await withTaskCancellationHandler { try await DeviceICMPTraceroute.run(target:target,maxHops:maximumHops,waitSeconds:timeoutSeconds,cancellation:token) } onCancel: { token.cancel() }
        try check(run)
        return result.hops.map { hop in
            switch hop.status {
            case .reached(let rtts): TraceHop(ttl:hop.ttl,address:result.resolvedAddress,milliseconds:rtts,status:.reached)
            case .timeExceeded(let address,let rtts): TraceHop(ttl:hop.ttl,address:address,milliseconds:rtts,status:.intermediate)
            case .timeout: TraceHop(ttl:hop.ttl,address:nil,milliseconds:[],status:.timeout)
            case .unreachable: TraceHop(ttl:hop.ttl,address:nil,milliseconds:[],status:.unreachable)
            }
        }
    }
    public func dns(name: String, type: DNSRecordType = .a, timeout: Double = 5) async throws -> [DNSRecord] {
        guard timeout.isFinite, (0.1...30).contains(timeout) else { throw DiagnosticError.invalid("DNS timeout") }
        let run = try await permit(name,.dns), result = try await DNSQuery().run(name:name,type:type,timeout:timeout)
        try check(run); return result
    }
    /// Deliberately bounded, explicitly chosen ports. This is not an address-range scanner.
    public func ports(target: String, ports: [UInt16], timeout: Double = 2) async throws -> [PortObservation] {
        guard !ports.isEmpty, ports.count <= 64, ports.allSatisfy({$0 != 0}), Set(ports).count == ports.count,
              timeout.isFinite, (0.05...10).contains(timeout) else { throw DiagnosticError.invalid("port bounds") }
        let run = try await permit(target,.ports(ports)); var results: [PortObservation] = []
        for batch in stride(from:0,to:ports.count,by:4) {
            try check(run)
            let chosen = Array(ports[batch..<min(batch+4,ports.count)])
            let values = await withTaskGroup(of:PortObservation.self) { group in
                for port in chosen { group.addTask {
                    let start = ContinuousClock.now
                    let status: PortObservation.Status
                    do { let connection = try await NetworkSerialConnection.connect(host:target,port:port,timeout:timeout); await connection.close(); status = .open }
                    catch { status = .failed }
                    let duration = start.duration(to:.now).components
                    return PortObservation(port:port,status:status,elapsedMilliseconds:Double(duration.seconds)*1000+Double(duration.attoseconds)/1e15)
                } }
                var values: [PortObservation] = []; for await value in group { values.append(value) }; return values
            }
            results += values
        }
        try check(run); return ports.compactMap { port in results.first { $0.port == port } }
    }
    public func discover(type: String, seconds: Double = 3) async throws -> [BonjourService] {
        let run = try await permit("local.",.discovery(type))
        let result = try await BonjourDiscovery.browse(type:type,seconds:seconds)
        try check(run); return result
    }
    public func stop() { stopped = true; generation = UUID(); for token in tokens.values { token.cancel() }; tokens.removeAll() }
}

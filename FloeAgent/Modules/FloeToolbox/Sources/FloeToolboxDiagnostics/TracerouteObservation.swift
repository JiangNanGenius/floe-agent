// SPDX-License-Identifier: MPL-2.0
import Foundation

/// An observation from a real probe. A maximum-hop limit is not a total.
/// The caller chooses this correlation ID; it grants no session authority.
public struct TracerouteObservation: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case resolved(address: String)
        case hop(TraceHop)
    }
    public let requestID: UUID
    public let value: Value
    public init(requestID: UUID, value: Value) {
        self.requestID = requestID; self.value = value
    }
}

public typealias TracerouteObserver = @Sendable (TracerouteObservation) async -> Void

/// Optional offline-information adapter. The database/updater remains owned
/// by its service. A missing adapter or database never delays probe output.
public struct TracerouteIPInformationProvider: Sendable {
    private final class Admission: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var waiting: [(UUID, CheckedContinuation<Void, any Error>)] = []
        func acquire() async throws {
            let id = UUID()
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let immediate: Result<Void, any Error>? = lock.withLock {
                        if Task.isCancelled { return .failure(CancellationError()) }
                        if active < 4 { active += 1; return .success(()) }
                        // Model fan-out is four. The shared queue is bounded
                        // too; overload stays retryable, never a negative cache.
                        guard waiting.count < 64 else { return .failure(DiagnosticError.busy) }
                        waiting.append((id, continuation)); return nil
                    }
                    if let immediate { continuation.resume(with: immediate) }
                }
            } onCancel: { self.cancel(id) }
        }
        private func cancel(_ id: UUID) {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return nil }
                return waiting.remove(at: index).1
            }
            continuation?.resume(throwing: CancellationError())
        }
        func release() {
            let next = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                active -= 1
                guard !waiting.isEmpty else { return nil }
                active += 1; return waiting.removeFirst().1
            }
            next?.resume()
        }
        var state: (active: Int, waiting: Int) { lock.withLock { (active, waiting.count) } }
    }
    private static let admission = Admission()
    public let currentVersion: @Sendable () async -> String?
    public let lookup: @Sendable (_ numericAddress: String, _ version: String) async throws -> TracerouteIPInformation?
    public init(currentVersion: @escaping @Sendable () async -> String?,
                lookup: @escaping @Sendable (String, String) async throws -> TracerouteIPInformation?) {
        self.currentVersion = currentVersion; self.lookup = lookup
    }
    /// Admission remains held until the actual adapter returns, even if a
    /// cancelled view has discarded its callback. Rapid close/reopen cannot
    /// accumulate unlimited uncooperative lookup tasks.
    static var informationAdmissionState: (active: Int, waiting: Int) { admission.state }
    public func information(for address: String) async throws -> TracerouteIPInformation? {
        try await Self.admission.acquire()
        defer { Self.admission.release() }
        try Task.checkCancellation()
        let selectedVersion = await currentVersion()
        try Task.checkCancellation()
        guard let version = selectedVersion else { return nil }
        let result = try await lookup(address, version)
        try Task.checkCancellation()
        guard await currentVersion() == version, let result,
              result.address == address, result.datasetVersion == version else { return nil }
        return result
    }
}

/// Real fields only. The adapter must classify local/reserved addresses
/// before lookup and must never infer an ISP from a hostname/ASN name.
public struct TracerouteIPInformation: Sendable, Equatable {
    public let address: String
    public let region: String?
    public let autonomousSystemNumber: UInt32?
    public let organization: String?
    public let source: String
    public let datasetVersion: String
    public init(address: String, region: String? = nil, autonomousSystemNumber: UInt32? = nil,
                organization: String? = nil, source: String, datasetVersion: String) {
        self.address = String(address.prefix(64)); self.region = region.map { String($0.prefix(512)) }
        self.autonomousSystemNumber = autonomousSystemNumber
        self.organization = organization.map { String($0.prefix(512)) }
        self.source = String(source.prefix(512)); self.datasetVersion = String(datasetVersion.prefix(256))
    }
}

/// Public native entry used by Toolbox and the existing execution tool. The
/// cancellation check is supplied by that caller's existing token; no second
/// permission or environment is created. Return means the socket worker and
/// ordered observer delivery have both ended (libc DNS workers stay bounded
/// by the resolver's existing four slots until getaddrinfo actually returns).
public enum ICMPTracerouteProbe {
    public static func run(target: String, maximumHops: Int, timeoutSeconds: Int,
                           requestID: UUID = UUID(),
                           isCancelled: @escaping @Sendable () -> Bool = { false },
                           onObservation: TracerouteObserver? = nil) async throws -> ICMPTracerouteReport {
        guard (1...30).contains(maximumHops), (1...5).contains(timeoutSeconds),
              !target.isEmpty, target.utf8.count <= 253,
              !target.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }), !target.contains(where: { "@/\\?#".contains($0) }) else {
            throw DiagnosticError.invalid("trace bounds or target")
        }
        let token = CancellationToken(externalCancellation: isCancelled)
        return try await withTaskCancellationHandler {
            try await DeviceICMPTraceroute.run(target: target, maxHops: maximumHops,
                waitSeconds: timeoutSeconds, cancellation: token,
                requestID: requestID, onObservation: onObservation)
        } onCancel: { token.cancel() }
    }
}

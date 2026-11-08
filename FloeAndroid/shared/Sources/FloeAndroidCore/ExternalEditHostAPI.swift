// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation
import Crypto
import FloeCore
import FloeTools

public enum BridgeV29 { public static let version = 29 }

/// The ordinary Android editor lane uses the existing SwiftCore.exchange
/// transport and G04 file service. This queue carries no URI, file bytes,
/// grant or model-selected owner. Claimed OS work must really settle before
/// cancellation/root retirement can release it, as in the font host lane.
final class ExternalEditHostMailbox: @unchecked Sendable {
    static let shared = ExternalEditHostMailbox()
    private final class Ticket {
        let id = UUID().uuidString.lowercased()
        let request: Data
        let cancellation: CancellationToken
        let ownerCancellation: CancellationToken?
        let deadline: Date
        var claimed = false
        var cancelled = false
        var result: Data?
        init(request: Data, cancellation: CancellationToken, ownerCancellation: CancellationToken?, budget: TimeInterval) {
            self.request = request; self.cancellation = cancellation
            self.ownerCancellation = ownerCancellation
            deadline = Date().addingTimeInterval(budget)
        }
    }
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var accepting = false
    private var tickets: [String: Ticket] = [:]
    private var queue: [String] = []
    private var retired: [String: Data] = [:]
    private var retiredOrder: [String] = []
    private let rootIsCurrent: @Sendable (UInt64) -> Bool
    private let budget: TimeInterval
    init(budget: TimeInterval = 120, rootIsCurrent: @escaping @Sendable (UInt64) -> Bool = {
        G02NativeRootEpoch.readback() == $0
    }) { self.budget = budget; self.rootIsCurrent = rootIsCurrent }

    func isReady(epoch expected: UInt64) -> Bool {
        rootIsCurrent(expected) && lock.withLock { epoch == expected && accepting }
    }
    private static let cancelled = Data(#"{"ok":false,"error":"cancelled"}"#.utf8)

    func submit(epoch expected: UInt64, request: Data, cancellation: CancellationToken,
                ownerCancellation: CancellationToken? = nil) async throws -> Data {
        try cancellation.throwIfCancelled()
        try ownerCancellation?.throwIfCancelled()
        guard request.count <= 8192 else { throw FloeError.validationFailed("Editor request too large") }
        let ticket = Ticket(request: request, cancellation: cancellation, ownerCancellation: ownerCancellation, budget: budget)
        let admitted = rootIsCurrent(expected) && lock.withLock {
            guard epoch == expected, accepting, tickets.count < 8 else { return false }
            tickets[ticket.id] = ticket; queue.append(ticket.id); return true
        }
        guard admitted else { throw FloeError.invalidConfiguration("External editor host is unavailable") }
        while true {
            let current = rootIsCurrent(expected)
            let result: Data? = lock.withLock {
                if cancellation.isCancelled || ownerCancellation?.isCancelled == true || Task.isCancelled
                    || Date() >= ticket.deadline || !accepting || !current {
                    ticket.cancelled = true
                    if !ticket.claimed && ticket.result == nil { ticket.result = Self.cancelled }
                }
                guard let result = ticket.result else { return nil }
                retired[ticket.id] = Data(SHA256.hash(data: result)); retiredOrder.append(ticket.id)
                while retiredOrder.count > 128 { retired.removeValue(forKey: retiredOrder.removeFirst()) }
                tickets.removeValue(forKey: ticket.id); queue.removeAll { $0 == ticket.id }
                return result
            }
            if let result { return result }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(25)) { continuation.resume() }
            }
        }
    }

    func handle(_ object: [String: Any]) -> [String: Any] {
        guard let operation = object["operation"] as? String else { return ["ok": false] }
        if operation == "handshake" { return ["ok": true, "schema": "floe.externaledit/29"] }
        guard let n = object["epoch"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              let requested = UInt64(n.stringValue), requested > 0, requested <= UInt64(Int64.max)
        else { return ["ok": false, "error": "invalidEpoch"] }
        let current = rootIsCurrent(requested)
        return lock.withLock {
            switch operation {
            case "externalEdit.host.bind":
                guard current, requested >= epoch,
                      !tickets.values.contains(where: { $0.claimed && $0.result == nil }),
                      requested == epoch || tickets.isEmpty else { return ["ok": false] }
                if requested != epoch {
                    retired.removeAll(); retiredOrder.removeAll(); queue.removeAll()
                }
                epoch = requested; accepting = true; return ["ok": true]
            case "externalEdit.host.close":
                guard requested == epoch else { return ["ok": false, "drained": false] }
                accepting = false
                for ticket in tickets.values where ticket.result == nil {
                    ticket.cancelled = true
                    if !ticket.claimed { ticket.result = Self.cancelled }
                }
                return ["ok": true, "drained": !tickets.values.contains { $0.claimed && $0.result == nil }]
            case "externalEdit.host.claim":
                guard requested == epoch, accepting, current else { return ["ok": false] }
                while !queue.isEmpty {
                    let id = queue.removeFirst()
                    guard let ticket = tickets[id], !ticket.claimed, ticket.result == nil else { continue }
                    if ticket.cancelled || ticket.cancellation.isCancelled || ticket.ownerCancellation?.isCancelled == true
                        || Date() >= ticket.deadline {
                        ticket.cancelled = true; ticket.result = Self.cancelled; continue
                    }
                    ticket.claimed = true
                    return ["ok": true, "ticket": ["id": id, "epoch": NSNumber(value: epoch),
                        "request": String(decoding: ticket.request, as: UTF8.self)]]
                }
                return ["ok": true, "ticket": NSNull()]
            case "externalEdit.host.canCommit":
                guard let id = object["ticketID"] as? String, requested == epoch else { return ["ok": false] }
                let allowed = tickets[id].map { accepting && current && $0.claimed && $0.result == nil
                    && !$0.cancelled && !$0.cancellation.isCancelled && $0.ownerCancellation?.isCancelled != true
                    && Date() < $0.deadline } ?? false
                return ["ok": true, "allowed": allowed]
            case "externalEdit.host.settle":
                guard requested == epoch, let id = object["ticketID"] as? String,
                      let text = object["receipt"] as? String, text.utf8.count <= 8192,
                      let data = text.data(using: .utf8),
                      let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let ok = value["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID()
                else { return ["ok": false] }
                guard let ticket = tickets[id] else { return ["ok": retired[id] == Data(SHA256.hash(data: data))] }
                guard ticket.claimed else { return ["ok": false] }
                if let existing = ticket.result { return ["ok": existing == data] }
                ticket.result = data; return ["ok": true]
            default: return ["ok": false, "error": "unsupportedOperation"]
            }
        }
    }
}

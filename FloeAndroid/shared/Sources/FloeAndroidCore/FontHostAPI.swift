// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation
import Crypto
import FloeCore
import FloeTools

public enum BridgeV27 { public static let version = 27 }

/// One same-UID host mailbox for actual Android font validation. Claimed work
/// stays owned until its physical completion; cancellation never frees its slot.
public final class FontHostMailbox: @unchecked Sendable {
    public static let shared = FontHostMailbox()
    private final class Ticket {
        let id = UUID().uuidString.lowercased()
        let epoch: UInt64
        let request: Data
        let cancellation: CancellationToken
        let recoveryWork: RuntimeOwnedWorkToken?
        let deadline = Date().addingTimeInterval(30)
        var claimed = false
        var cancelled = false
        var result: Data?
        init(epoch: UInt64, request: Data, cancellation: CancellationToken, recoveryWork: RuntimeOwnedWorkToken?) {
            self.epoch = epoch; self.request = request; self.cancellation = cancellation
            self.recoveryWork = recoveryWork
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
    public convenience init() {
        self.init(rootIsCurrent: { AndroidRuntimeBootstrap.notesBinding(epoch: $0, ownerToken: nil) != nil })
    }
    init(rootIsCurrent: @escaping @Sendable (UInt64) -> Bool) { self.rootIsCurrent = rootIsCurrent }
    public func isReady(epoch expected: UInt64) -> Bool {
        lock.withLock { epoch == expected && accepting }
    }
    private static func failure(_ code: String) -> Data {
        // Code is a closed internal token, never imported/model text.
        Data("{\"ok\":false,\"error\":\"\(code)\"}".utf8)
    }
    public func submit(epoch expected: UInt64, request: Data,
                       cancellation: CancellationToken,
                       recoveryWork: RuntimeOwnedWorkToken? = nil) async throws -> Data {
        try cancellation.throwIfCancelled()
        guard request.count <= 4096 else { throw FloeError.validationFailed("Font request too large") }
        let cleanup = ((try? JSONSerialization.jsonObject(with: request)) as? [String: Any])?["method"] as? String
        let retained = ["snapshot.rollback", "snapshot.complete"].contains(cleanup ?? "") ? recoveryWork : nil
        let ticket = Ticket(epoch: expected, request: request, cancellation: cancellation, recoveryWork: retained)
        let admitted = lock.withLock {
            guard epoch == expected, accepting, tickets.count < 8 else { return false }
            tickets[ticket.id] = ticket; queue.append(ticket.id); return true
        }
        guard admitted else { throw FloeError.invalidConfiguration("Font library host is unavailable") }
        while true {
            let result: Data? = lock.withLock {
                if cancellation.isCancelled || Task.isCancelled || Date() >= ticket.deadline || !accepting {
                    ticket.cancelled = true
                    if !ticket.claimed && ticket.result == nil { ticket.result = Self.failure("cancelled") }
                }
                guard let result = ticket.result else { return nil }
                retired[ticket.id] = Data(SHA256.hash(data: result))
                retiredOrder.append(ticket.id)
                while retiredOrder.count > 128 { retired.removeValue(forKey: retiredOrder.removeFirst()) }
                tickets.removeValue(forKey: ticket.id)
                queue.removeAll { $0 == ticket.id }
                return result
            }
            if let result { return result }
            // Independent bounded timer: a cancelled Task must still await a
            // claimed OS operation, without spinning or fabricating settlement.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(25)) {
                    continuation.resume()
                }
            }
        }
    }
    private func bind(_ expected: UInt64) -> Bool {
        guard expected > 0, rootIsCurrent(expected) else { return false }
        return lock.withLock {
            if epoch == expected {
                // A later drain gate can retain this exact accepted root.
                // Re-arm admission only after all claimed operations settled;
                // existing cancellation and result receipts stay intact.
                guard !tickets.values.contains(where: { $0.claimed && $0.result == nil }) else { return false }
                accepting = true
                return true
            }
            guard expected > epoch, tickets.isEmpty else { return false }
            epoch = expected; accepting = true; queue.removeAll()
            retired.removeAll(); retiredOrder.removeAll(); return true
        }
    }
    private func close(_ expected: UInt64) -> Bool {
        lock.withLock {
            guard expected == epoch else { return false }
            accepting = false
            for ticket in tickets.values where ticket.result == nil {
                ticket.cancelled = true
                if !ticket.claimed { ticket.result = Self.failure("cancelled") }
            }
            return !tickets.values.contains { $0.claimed && $0.result == nil }
        }
    }
    private func claim(_ expected: UInt64) -> [String: Any]? {
        lock.withLock { () -> [String: Any]? in
            guard expected == epoch, accepting else { return nil }
            while !queue.isEmpty {
                let id = queue.removeFirst()
                guard let ticket = tickets[id], !ticket.claimed, ticket.result == nil else { continue }
                if ticket.cancellation.isCancelled || ticket.cancelled || Date() >= ticket.deadline {
                    ticket.cancelled = true; ticket.result = Self.failure("cancelled"); continue
                }
                ticket.claimed = true
                return ["id": ticket.id, "epoch": NSNumber(value: ticket.epoch),
                        "request": String(decoding: ticket.request, as: UTF8.self)]
            }
            return nil
        }
    }
    private func canCommit(_ expected: UInt64, id: String) -> Bool {
        return lock.withLock {
            guard epoch == expected, accepting, let ticket = tickets[id], ticket.claimed,
                  ticket.result == nil else { return false }
            let retainedCleanup = ticket.recoveryWork.map {
                $0.epoch == expected && $0.kind == .tool && $0.ownerID.hasPrefix("c07.")
                    && RuntimeOwnedWorkRegistry.shared.isAttached($0)
            } ?? false
            return (rootIsCurrent(expected) || retainedCleanup) && !ticket.cancelled
                && !ticket.cancellation.isCancelled && Date() < ticket.deadline
        }
    }
    private func settle(_ expected: UInt64, id: String, result: Data) -> Bool {
        guard result.count <= 60 * 1024,
              let value = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any],
              let ok = value["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID() else { return false }
        return lock.withLock {
            guard expected == epoch else { return false }
            guard let ticket = tickets[id] else { return retired[id] == Data(SHA256.hash(data: result)) }
            guard ticket.epoch == expected, ticket.claimed else { return false }
            if let existing = ticket.result { return existing == result }
            ticket.result = result
            return true
        }
    }
    public static func handle(_ object: [String: Any]) -> [String: Any] { shared.handleMessage(object) }
    public func handleMessage(_ object: [String: Any]) -> [String: Any] {
        guard let operation = object["operation"] as? String else { return ["ok": false, "error": "invalidRequest"] }
        if operation == "handshake" { return ["ok": true, "schema": "floe.fonts/27"] }
        guard let n = object["epoch"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              let epoch = UInt64(n.stringValue), epoch > 0,
              epoch <= UInt64(Int64.max) else { return ["ok": false, "error": "invalidEpoch"] }
        let mailbox = self
        switch operation {
        case "font.host.bind": return ["ok": mailbox.bind(epoch)]
        case "font.host.close": return ["ok": true, "drained": mailbox.close(epoch)]
        case "font.host.claim":
            var result: [String: Any] = ["ok": mailbox.isReady(epoch: epoch)]
            if let ticket = mailbox.claim(epoch) { result["ticket"] = ticket }
            else { result["ticket"] = NSNull() }
            return result
        case "font.host.canCommit":
            guard let id = object["ticketID"] as? String else { return ["ok": false] }
            return ["ok": true, "allowed": mailbox.canCommit(epoch, id: id)]
        case "font.host.settle":
            guard let id = object["ticketID"] as? String, let text = object["receipt"] as? String,
                  text.utf8.count <= 60 * 1024 else { return ["ok": false] }
            return ["ok": mailbox.settle(epoch, id: id, result: Data(text.utf8))]
        default: return ["ok": false, "error": "unsupportedOperation"]
        }
    }
}

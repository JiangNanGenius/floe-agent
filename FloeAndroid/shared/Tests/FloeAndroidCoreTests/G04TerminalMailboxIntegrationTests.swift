// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeAndroidCore

private actor G04DispatchBarrier {
    private var started: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var held: [CheckedContinuation<Void, Never>] = []
    func invoke(_ bytes: Data) async {
        let value = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: String]
        let id = value?["requestID"] ?? "invalid"
        started.insert(id)
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume() }
        if value?["action"] == "lspEnsure" {
            await withCheckedContinuation { held.append($0) }
        }
    }
    func waitFor(_ id: String) async {
        if started.contains(id) { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }
    func releaseAll() { let rows = held; held.removeAll(); rows.forEach { $0.resume() } }
}

@Suite("Terminal mailbox integration fixes")
struct G04TerminalMailboxIntegrationTests {
    private func descriptor(_ action: String, _ id: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["action": action, "requestID": id])
    }
    private func stats(_ box: G04TerminalHostMailbox) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(box.statsJSON().utf8)) as? [String: Any])
    }

    @Test func bindPublishesWithoutRecursivelyLockingAndOldSinkCannotCrossEpoch() throws {
        let box = G04TerminalHostMailbox()
        #expect(box.bind(newEpoch: 1)) // Previously deadlocked in hostBound enqueue.
        let sink = G04TerminalMailboxSink(mailbox: box, epoch: 1)
        let claimedOld = box.nextEvent(timeoutMillis: 0)
        #expect(claimedOld > 0)
        #expect(box.bind(newEpoch: 2))
        sink.emitControl(["type": "stale-reply", "requestID": "old"])
        sink.emitOutput(sessionToken: "old", seq: 1, bytes: Data("old".utf8))
        let current = box.nextEvent(timeoutMillis: 0)
        #expect(current > 0)
        _ = box.ack(event: current)
        #expect(box.nextEvent(timeoutMillis: 0) == 0)
        #expect((try stats(box)["liveEvents"] as? Int) == 0)
        #expect(box.close(closingEpoch: 2))
    }

    @Test func controlOverflowKeepsHardBoundsAndOneExplicitMarker() throws {
        let box = G04TerminalHostMailbox(); #expect(box.bind(newEpoch: 1))
        defer { _ = box.close(closingEpoch: 1) }
        for index in 0..<1000 { box.emitControl(["type": "test", "requestID": "\(index)"]) }
        let value = try stats(box)
        #expect((value["liveEvents"] as? Int) == G04TerminalHostLimits.maximumLiveEvents)
        #expect((value["eventBytes"] as? Int ?? Int.max) <= G04TerminalHostLimits.maximumEventBytes)
        let counters = try #require(value["counters"] as? [String: Int])
        #expect(counters["controlOverflow", default: 0] > 0)
        var markers = 0
        while true {
            let token = box.nextEvent(timeoutMillis: 0); if token <= 0 { break }
            var bytes = [CChar](repeating: 0, count: G04TerminalHostLimits.maximumFrameBytes + 1)
            let capacity = Int32(bytes.count)
            let count = box.describe(event: token, buffer: &bytes, capacity: capacity)
            if count > 0 {
                let data = bytes.withUnsafeBytes { Data($0.prefix(Int(count))) }
                let event = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                if event["type"] as? String == "hostEventOverflow" { markers += 1 }
            }
            _ = box.ack(event: token)
        }
        #expect(markers == 1)
    }

    @Test func initializingLanguageServerDoesNotBlockIndependentControlAndConsumesCapacity() async throws {
        let barrier = G04DispatchBarrier()
        let box = G04TerminalHostMailbox(testHandler: { bytes, _, _ in await barrier.invoke(bytes) })
        #expect(box.bind(newEpoch: 1))
        #expect(box.submitAction(descriptor: try descriptor("lspEnsure", "slow"), payload: nil) > 0)
        await barrier.waitFor("slow")
        #expect(box.submitAction(descriptor: try descriptor("capabilities", "fast"), payload: nil) > 0)
        await barrier.waitFor("fast")
        #expect((try stats(box)["liveActions"] as? Int ?? 0) >= 1)
        #expect(box.close(closingEpoch: 1))
        await barrier.releaseAll()
    }

    /// Claims events until the matching actionReply arrives (bounded).
    private func drainReply(_ box: G04TerminalHostMailbox, requestID: String,
                            timeoutSeconds: Double = 4) throws -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let token = box.nextEvent(timeoutMillis: 5)
            if token > 0 {
                var bytes = [CChar](repeating: 0, count: G04TerminalHostLimits.maximumFrameBytes + 1)
                let count = box.describe(event: token, buffer: &bytes, capacity: Int32(bytes.count))
                var parsed: [String: Any]?
                if count > 0 {
                    let data = bytes.withUnsafeBytes { Data($0.prefix(Int(count))) }
                    parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
                _ = box.ack(event: token)
                if let parsed, parsed["requestID"] as? String == requestID { return parsed }
            }
        }
        return nil
    }

    @Test func capabilitiesCarriesHonestDurableMirrorOnRealDispatch() throws {
        // An epoch no Root generation owns: the durable read must NOT claim
        // it succeeded. settingsKnown stays false, the enabled mirror is
        // exactly the eight catalog defaults, and no server state is
        // fabricated. (Real dispatch — no testHandler.)
        let box = G04TerminalHostMailbox()
        #expect(box.bind(newEpoch: 999_999_999_931))
        defer { _ = box.close(closingEpoch: 999_999_999_931) }
        let request = try JSONSerialization.data(withJSONObject: [
            "action": "capabilities", "requestID": "caps", "conversationID": UUID().uuidString,
        ])
        #expect(box.submitAction(descriptor: request, payload: nil) > 0)
        let capsReply = try drainReply(box, requestID: "caps")
        let value = try #require(capsReply)
        #expect(value["ok"] as? Bool == true)
        #expect(value["settingsKnown"] as? Bool == false)
        #expect((value["settingsRevision"] as? NSNumber)?.int64Value == -1)
        #expect(((value["languageEnabled"] as? [String: Bool])?.count) == 8)
        #expect((value["serverStates"] as? [[String: Any]])?.isEmpty == true)
        #expect((value["languages"] as? [String])?.count == 8)
    }

    @Test func languageToggleRequiresStrictBoolBeforeAnyDurableWrite() throws {
        // A missing or number-coerced "enabled" is an honest invalidType
        // refusal at the grammar edge: it can never mint a durable user
        // choice from a malformed descriptor.
        let box = G04TerminalHostMailbox()
        #expect(box.bind(newEpoch: 999_999_999_932))
        defer { _ = box.close(closingEpoch: 999_999_999_932) }
        let missing = try JSONSerialization.data(withJSONObject: [
            "action": "lspSetLanguageEnabled", "requestID": "toggle-missing", "language": "python",
        ])
        let coerced = try JSONSerialization.data(withJSONObject: [
            "action": "lspSetLanguageEnabled", "requestID": "toggle-coerced",
            "language": "python", "enabled": 1,
        ])
        #expect(box.submitAction(descriptor: missing, payload: nil) > 0)
        #expect(box.submitAction(descriptor: coerced, payload: nil) > 0)
        let missingReply = try drainReply(box, requestID: "toggle-missing")
        let first = try #require(missingReply)
        #expect(first["ok"] as? Bool == false)
        #expect(first["code"] as? String == "invalidType")
        let coercedReply = try drainReply(box, requestID: "toggle-coerced")
        let second = try #require(coercedReply)
        #expect(second["ok"] as? Bool == false)
        #expect(second["code"] as? String == "invalidType")
    }
}

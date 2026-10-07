// FloeWorkbench — CAD session identity + transaction gate tests (Build265 review).
import Foundation
import Testing
@testable import FloeWorkbench

@Suite("CAD document session identity and gating")
struct CadDocumentSupportTests {
    @Test("same relative filename under different roots yields different session keys")
    func distinctRootsDistinctKeys() {
        let owner = UUID()
        let a = CadDocumentIdentity.sessionKey(environmentID: "env", ownerKind: "workspace",
                                               ownerID: owner, rootPath: "/w/one",
                                               relativePath: "plan.dwg")
        let b = CadDocumentIdentity.sessionKey(environmentID: "env", ownerKind: "workspace",
                                               ownerID: owner, rootPath: "/w/two",
                                               relativePath: "plan.dwg")
        #expect(a != b, "two workspace roots must never share a CAD engine session")
    }

    @Test("identity separates environment and owner")
    func distinctOwnersDistinctKeys() {
        let base = CadDocumentIdentity.sessionKey(environmentID: "e1", ownerKind: "chat",
                                                  ownerID: UUID(), rootPath: "/w", relativePath: "a.dxf")
        let otherEnv = CadDocumentIdentity.sessionKey(environmentID: "e2", ownerKind: "chat",
                                                      ownerID: UUID(), rootPath: "/w", relativePath: "a.dxf")
        #expect(base != otherEnv)
    }

    @Test("async mutex serializes overlapping transactions")
    func mutexSerializes() async {
        let mutex = AsyncMutex()
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await mutex.withLock {
                        // Non-atomic read-modify-write would lose increments if
                        // the gate did not serialize.
                        let value = await counter.value
                        try? await Task.sleep(for: .microseconds(50))
                        await counter.set(value + 1)
                    }
                }
            }
        }
        #expect(await counter.value == 20)
    }

    @Test("withLock releases after a thrown error")
    func mutexReleasesOnError() async {
        let mutex = AsyncMutex()
        struct Boom: Error {}
        do {
            try await mutex.withLock { throw Boom() }
        } catch {}
        #expect(await mutex.isBusy == false)
        // The lock must be reusable.
        let value = await mutex.withLock { 7 }
        #expect(value == 7)
    }

    private actor Counter {
        private(set) var value = 0
        func set(_ newValue: Int) { value = newValue }
    }

    @Test("a transaction task cancelled while queued never runs and frees the gate")
    func queuedCancellation() async {
        let gate = CadDocumentGate()
        let ran = Counter()
        try? await gate.acquire() // current holder
        let waiter = Task { () -> Bool in
            do {
                try await gate.acquire()
                await ran.set(1)
                await gate.release()
                return true
            } catch {
                return false
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await gate.release() // the cancelled waiter is resumed here
        let executed = await waiter.value
        #expect(executed == false, "a cancelled queued transaction must not execute")
        #expect(await ran.value == 0)
        // The gate was handed on/freed, so a later acquirer still works.
        let next = Task { () -> Bool in
            do {
                try await gate.acquire()
                await gate.release()
                return true
            } catch { return false }
        }
        #expect(await next.value == true)
        #expect(await gate.isBusy == false)
    }

    @Test("gate serializes overlapping acquisitions without loss")
    func gateFairness() async {
        let gate = CadDocumentGate()
        let order = OrderRecorder()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask {
                    do {
                        try await gate.acquire()
                        await order.append(index)
                        try? await Task.sleep(for: .microseconds(100))
                        await gate.release()
                    } catch {}
                }
            }
        }
        #expect(await order.values.count == 10)
    }

    private actor OrderRecorder {
        private(set) var values: [Int] = []
        func append(_ value: Int) { values.append(value) }
    }
}

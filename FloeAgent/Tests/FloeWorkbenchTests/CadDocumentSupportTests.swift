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
}

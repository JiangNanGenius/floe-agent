import Foundation
import Testing
@testable import FloeMacToolbox

@MainActor
private final class FakeStartupSuspension {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

@MainActor
@Suite("Toolbox startup shutdown fence", .serialized)
struct MacToolboxStartupGateTests {
    private func waitUntilEntered(_ step: FakeStartupSuspension) async -> Bool {
        for _ in 0..<1_000 {
            if step.entered { return true }
            await Task.yield()
        }
        return step.entered
    }

    @Test func shutdownBeforeStartRejectsEveryLateCaller() async {
        let gate = MacToolboxStartupGate()
        var stages: [String] = []
        gate.shutdown()
        await gate.start(prepare: { stages.append("prepare") },
                         load: { stages.append("load") },
                         activate: { stages.append("activate") })
        await gate.start(prepare: { stages.append("again") }, load: {}, activate: {})
        #expect(gate.terminated)
        #expect(stages.isEmpty)
    }

    @Test func shutdownWhilePreparingFencesLateCompletionAndRestart() async {
        let gate = MacToolboxStartupGate()
        let suspended = FakeStartupSuspension()
        var stages: [String] = []
        let run = Task { @MainActor in
            await gate.start(prepare: { stages.append("prepare"); await suspended.wait() },
                             load: { stages.append("load") },
                             activate: { stages.append("activate") })
        }
        guard await waitUntilEntered(suspended) else {
            gate.shutdown(); suspended.resume(); await run.value
            Issue.record("prepare did not suspend"); return
        }
        gate.shutdown()
        suspended.resume()
        await run.value
        await gate.start(prepare: { stages.append("again") }, load: {}, activate: {})
        #expect(stages == ["prepare"])
    }

    @Test func shutdownWhileLoadingFencesLateActivation() async {
        let gate = MacToolboxStartupGate()
        let suspended = FakeStartupSuspension()
        var stages: [String] = []
        let run = Task { @MainActor in
            await gate.start(prepare: { stages.append("prepare") },
                             load: { stages.append("load"); await suspended.wait() },
                             activate: { stages.append("activate") })
        }
        guard await waitUntilEntered(suspended) else {
            gate.shutdown(); suspended.resume(); await run.value
            Issue.record("load did not suspend"); return
        }
        gate.shutdown()
        suspended.resume()
        await run.value
        #expect(stages == ["prepare", "load"])
    }
}

import XCTest
import Foundation
import Darwin

// Supplementary shape probe: the same long-lived `@MainActor async` XCTest
// method pattern used by BridgeEngineTests, plus the host's Timer ->
// `Task { @MainActor }` refresh pattern. It runs under the real XCTest runner
// on macOS and never returns; run_async_xctest_probe.sh samples the JSON and
// terminates the runner. This proves XCTest discovery/coexistence for the
// method shape, not device/DDI/UI validity.

@MainActor
private final class TickStore {
    static let shared = TickStore()
    var ticks = 0
}

@MainActor
final class RuntimeSchedulingAsyncTests: XCTestCase {
    private func write(_ phase: String, iterations: Int) {
        let path = ProcessInfo.processInfo.environment["FLOE_ASYNC_PROBE_OUTPUT"]
            ?? "/tmp/floe-async-driver-probe.json"
        let payload: [String: Any] = [
            "phase": phase,
            "mainThread": pthread_main_np() != 0,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "hostActorTaskTicks": TickStore.shared.ticks,
            "driverIterations": iterations,
            "testMethod": name,
            "authoredBy": "RuntimeScheduling async XCTest shape probe",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testAsyncMainActorDriverStaysAlive() async throws {
        write("entry", iterations: 0)
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                TickStore.shared.ticks += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)

        var iterations = 0
        while true {
            iterations += 1
            if iterations % 2 == 0 {
                write("loop", iterations: iterations)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

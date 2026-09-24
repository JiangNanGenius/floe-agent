// RuntimeLifecycleCheck — focused lifecycle check for the real
// TinyEMUGuestRuntime.swift (FloeExecution/Linux), compiled against a
// controllable stub of the FloeTinyEMU C API.
//
// The stub (runtime_stub/) implements the floe_vm_* subset the Swift runtime
// uses, so the *production* start/stop/write/forward logic runs unchanged:
//
//   * start -> stop -> start -> stop is truthful (isRunning, restart);
//   * a stop whose run loop does not leave its slice inside the bounded
//     timeout must NOT destroy the VM and must not hang (the previous
//     task-group/continuation race could hang forever);
//   * console writes and forwards use the VM pointer under the same lock as
//     destruction, so destroy-during-slice never happens;
//   * a guest poweroff ends the run loop without stop(), and a later stop
//     still destroys the VM.
//
// Usage: runtime-lifecycle-check

import Foundation
import FloeTinyEMU

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - support stubs (the real FloeExecution types live in the package)

struct FloeLogger: Sendable {
    enum Category: String, Sendable { case tools, runtime }
    init(category: Category) {}
    func info(_ message: String) {}
    func error(_ message: String) {}
    func warning(_ message: String) {}
}

public enum LinuxGuestError: Error, LocalizedError, Sendable, Equatable {
    case notRunning(environmentID: String)
    case invalidConfiguration(String)
    case serviceForwardingUnavailable(String)
    case startFailed(String)
    case consoleUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning(let id): return "not running: \(id)"
        case .invalidConfiguration(let detail): return detail
        case .serviceForwardingUnavailable(let detail): return detail
        case .startFailed(let detail): return detail
        case .consoleUnavailable(let detail): return detail
        }
    }
}

public struct LinuxGuestShare: Sendable, Hashable {
    var tag: String
    var hostDirectory: URL
}

public struct LinuxGuestServiceForward: Sendable, Hashable {
    var hostAddress: String
    var hostPort: UInt16
    var guestPort: UInt16
    var isUDP: Bool
}

public struct LinuxGuestEnvironmentDescriptor: Sendable {
    var id: String
    var shares: [LinuxGuestShare]
    var ramMB: Int?
    var networkEnabled: Bool
    var serviceForwards: [LinuxGuestServiceForward]
    var vcpus: Int? = nil
}

public struct LinuxGuestLimits: Sendable {
    var ramMB: Int = 128
    func clampedRAMMB(_ requested: Int?) -> Int { requested ?? ramMB }
}

public struct LinuxGuestImage: Sendable {
    static let runnerGuestPath = "/usr/local/bin/floe-exec"
    var biosPath: String
    var kernelPath: String?
    var initrdPath: String?
    var cmdline: String?
    var diskPath: String?
    var diskReadWrite: Bool = true
    var effectiveCmdline: String { cmdline ?? "console=hvc0" }
}

public protocol LinuxGuestConsoleTransport: Sendable {
    func write(_ bytes: [UInt8]) async throws
    func close() async
    func output() async -> AsyncStream<Data>
}

public struct LinuxGuestSessionHandle: Sendable {
    var transport: any LinuxGuestConsoleTransport
    var start: @Sendable () async throws -> Void
    var stop: @Sendable () async -> Void
    var close: @Sendable () async -> Void
    var isRunning: @Sendable () async -> Bool
    var addForward: @Sendable (LinuxGuestServiceForward) throws -> Void
    var removeForward: @Sendable (LinuxGuestServiceForward) throws -> Void
    var emulatorCPUSample: @Sendable () -> LinuxGuestEmulatorCPUSample?
    var setRAMMB: @Sendable (Int) -> Void
    var setVCPUs: @Sendable (Int) throws -> Void
}

// MARK: - recorder

enum CheckFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _passes = 0
    private var _failures: [String] = []

    func recordPass() {
        lock.lock()
        defer { lock.unlock() }
        _passes += 1
    }

    func recordFailure(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        _failures.append(message)
    }

    var passes: Int {
        lock.lock()
        defer { lock.unlock() }
        return _passes
    }

    var failures: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _failures
    }

    func check(_ name: String, timeout: TimeInterval = 30, _ body: @Sendable @escaping () async throws -> Void) async {
        let state = CheckState()
        _ = Task {
            do {
                try await body()
                state.finish(error: nil)
            } catch {
                state.finish(error: "\(error)")
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !state.isDone {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if !state.isDone {
            state.markTimedOut()
            recordFailure("\(name): timed out after \(Int(timeout))s (check watchdog)")
            print("FAIL  \(name): timed out after \(Int(timeout))s")
        } else if let error = state.error {
            recordFailure("\(name): \(error)")
            print("FAIL  \(name): \(error)")
        } else {
            recordPass()
            print("PASS  \(name)")
        }
    }
}

final class CheckState: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var failure: String?
    private var timedOut = false

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    var error: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func finish(error: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !done, !timedOut else { return }
        done = true
        failure = error
    }

    func markTimedOut() {
        lock.lock()
        defer { lock.unlock() }
        timedOut = true
    }
}

// MARK: - harness

@main
enum RuntimeLifecycleCheck {
    static func makeMachine(network: Bool = true) throws -> TinyEMUGuestMachine {
        let descriptor = LinuxGuestEnvironmentDescriptor(
            id: "env-stub",
            shares: [],
            ramMB: 128,
            networkEnabled: network,
            serviceForwards: []
        )
        let image = LinuxGuestImage(
            biosPath: "/nonexistent/stub-bios.bin",
            kernelPath: nil,
            initrdPath: nil,
            cmdline: "console=hvc0",
            diskPath: nil
        )
        return try TinyEMUGuestMachine(descriptor: descriptor, image: image, limits: LinuxGuestLimits())
    }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw CheckFailure.message(message()) }
    }

    /// Mirror of the stub's ordered checksum (31-multiplier over accepted
    /// bytes).
    static func checksum(_ bytes: [UInt8]) -> UInt64 {
        var value: UInt64 = 0
        for byte in bytes {
            value = value &* 31 &+ UInt64(byte)
        }
        return value
    }

    static func waitUntil(timeout: TimeInterval, _ predicate: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    static func main() async {
        let recorder = Recorder()

        // Process backstop: a lifecycle bug must not run unbounded.
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 120, repeating: .never)
        watchdog.setEventHandler {
            FileHandle.standardError.write(Data("runtime-lifecycle-check watchdog: 120s elapsed; exiting\n".utf8))
            exit(3)
        }
        watchdog.resume()

        await recorder.check("start_stop_restart_stop_is_truthful") {
            floe_stub_set_slice_ms(2)
            floe_stub_set_slices_before_poweroff(0)
            let machine = try makeMachine()
            try XCTAssertFalse(machine.isRunning)
            try machine.start()
            try XCTAssertTrue(machine.isRunning)
            try await machine.write([0x03])
            try XCTAssertGreater(floe_stub_console_input_calls(), 0)
            await machine.stop()
            try XCTAssertFalse(machine.isRunning, "stop must report not running after the loop exits")
            // Restart: the previous exit flag must not leak into the new run,
            // or a later stop would destroy a machine whose loop is running.
            try machine.start()
            try XCTAssertTrue(machine.isRunning)
            try await machine.write([0x1e])
            await machine.stop()
            try XCTAssertFalse(machine.isRunning)
            try XCTAssertEqual(floe_stub_destroy_while_slicing(), 0, "VM destroyed while a slice executed")
            try XCTAssertEqual(floe_stub_use_after_destroy(), 0, "engine call after destroy")
        }

        await recorder.check("stop_timeout_refuses_to_destroy_running_slice") {
            floe_stub_set_slice_ms(1200)
            floe_stub_set_slices_before_poweroff(0)
            let machine = try makeMachine()
            machine.runLoopExitTimeout = 0.25
            try machine.start()
            try XCTAssertTrue(await waitUntil(timeout: 2) { floe_stub_slice_calls() >= 1 })
            let started = Date()
            await machine.stop()
            let elapsed = Date().timeIntervalSince(started)
            try expect(elapsed < 1.0, "stop ignored its bounded timeout (\(elapsed)s)")
            try XCTAssertTrue(machine.isRunning, "timed-out stop must not claim the machine stopped")
            try XCTAssertEqual(floe_stub_destroy_while_slicing(), 0, "VM destroyed while a slice executed")
            // The run loop notices stopRequested after the long slice and
            // exits; a second stop then destroys exactly once.
            try XCTAssertTrue(await waitUntil(timeout: 5) { !machine.isRunning })
            await machine.stop()
            try XCTAssertFalse(machine.isRunning)
            try XCTAssertEqual(floe_stub_destroy_while_slicing(), 0)
        }

        await recorder.check("write_and_forwards_after_stop_fail_honestly") {
            floe_stub_set_slice_ms(2)
            floe_stub_set_slices_before_poweroff(0)
            let machine = try makeMachine()
            try machine.start()
            let forward = LinuxGuestServiceForward(
                hostAddress: "127.0.0.1", hostPort: 18080, guestPort: 8080, isUDP: false
            )
            try machine.addForward(forward)
            try XCTAssertGreater(floe_stub_hostfwd_add_calls(), 0)
            try machine.removeForward(forward)
            await machine.stop()
            do {
                try await machine.write([0x41])
                throw CheckFailure.message("write after stop must fail")
            } catch let error as LinuxGuestError {
                guard case .notRunning = error else { throw CheckFailure.message("unexpected \(error)") }
            }
            do {
                try machine.addForward(forward)
                throw CheckFailure.message("addForward after stop must fail")
            } catch let error as LinuxGuestError {
                guard case .notRunning = error else { throw CheckFailure.message("unexpected \(error)") }
            }
            try machine.removeForward(forward) // must be a no-op, not a crash
            try XCTAssertEqual(floe_stub_use_after_destroy(), 0, "engine call after destroy")
        }

        await recorder.check("partial_console_acceptance_never_truncates") {
            // The engine ring accepts a prefix and returns the count; the
            // runtime must retry until the whole frame is queued, in order,
            // and fail clearly (never silently drop the suffix) if the ring
            // stays full.
            floe_stub_set_slice_ms(2)
            floe_stub_set_slices_before_poweroff(0)
            let machine = try makeMachine()
            try machine.start()
            floe_stub_reset_console_counters()
            floe_stub_set_partial_accept(2)
            let bytes: [UInt8] = [1, 2, 3, 4, 5]
            try await machine.write(bytes)
            try expect(Int(floe_stub_console_bytes_received()) == bytes.count,
                       "accepted \(floe_stub_console_bytes_received()) of \(bytes.count) bytes")
            try expect(floe_stub_console_checksum() == checksum(bytes),
                       "accepted bytes arrived out of order")
            try XCTAssertGreater(floe_stub_console_input_calls(), 1)

            floe_stub_set_partial_accept(0) // permanent ring pressure
            machine.consoleInputDeadline = 0.2
            do {
                try await machine.write([9, 9])
                throw CheckFailure.message("write must fail while the ring stays full")
            } catch let error as LinuxGuestError {
                guard case .consoleUnavailable = error else {
                    throw CheckFailure.message("unexpected error \(error)")
                }
            }
            try expect(Int(floe_stub_console_bytes_received()) == bytes.count,
                       "a partial frame was accepted before failing")
            floe_stub_set_partial_accept(-1)
            await machine.stop()
        }

        await recorder.check("guest_poweroff_ends_run_loop") {
            floe_stub_set_slice_ms(2)
            floe_stub_set_slices_before_poweroff(3)
            let machine = try makeMachine()
            try machine.start()
            try XCTAssertTrue(await waitUntil(timeout: 3) { !machine.isRunning },
                          "guest poweroff must end the run loop")
            await machine.stop() // destroys the already-exited VM
            try XCTAssertFalse(machine.isRunning)
            try XCTAssertEqual(floe_stub_destroy_while_slicing(), 0)
            floe_stub_set_slices_before_poweroff(0)
        }

        print("")
        print("checks passed: \(recorder.passes), failures: \(recorder.failures.count)")
        if !recorder.failures.isEmpty {
            for failure in recorder.failures {
                print("FAILURE: \(failure)")
            }
            exit(1)
        }
    }

    private static func XCTAssertTrue(_ condition: Bool, _ message: String = "expected true") throws {
        if !condition { throw CheckFailure.message(message) }
    }

    private static func XCTAssertFalse(_ condition: Bool, _ message: String = "expected false") throws {
        if condition { throw CheckFailure.message(message) }
    }

    private static func XCTAssertEqual(_ lhs: Int32, _ rhs: Int32, _ message: String = "") throws {
        if lhs != rhs { throw CheckFailure.message("\(lhs) != \(rhs) \(message)") }
    }

    private static func XCTAssertGreater(_ lhs: Int32, _ rhs: Int32) throws {
        if lhs <= rhs { throw CheckFailure.message("\(lhs) <= \(rhs)") }
    }
}

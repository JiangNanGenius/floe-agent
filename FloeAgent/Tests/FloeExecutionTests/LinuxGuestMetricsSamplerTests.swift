// FloeExecutionTests — Bounded Linux guest metrics sampler.
//
// Proves the sampling loop is bounded (one short bounded guest read per
// interval, only while a consumer is registered), that missing values stay
// unknown instead of becoming zero, and that the guest GPU is reported
// unavailable rather than fabricated.

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

/// Scripted command runner: records every invocation and replays canned
/// results. Closures are the seam the supervisor already exposes.
private actor ScriptedGuestRunner: LinuxCommandRunning {
    struct Invocation: Sendable {
        var argv: [String]
        var timeout: TimeInterval
        var maxOutputBytes: Int
    }

    private var results: [LinuxCommandResult]
    private var recorded: [Invocation] = []

    init(results: [LinuxCommandResult]) {
        self.results = results
    }

    func supports(environmentID: String) async -> Bool { true }

    func ownsLinuxEnvironment(environmentID: String) async -> Bool { true }

    func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        recorded.append(Invocation(argv: argv, timeout: timeout, maxOutputBytes: maxOutputBytes))
        guard !results.isEmpty else {
            return LinuxCommandResult(stdout: "", stderr: "no scripted result", exitCode: 1)
        }
        return results.removeFirst()
    }

    func invocations() -> [Invocation] { recorded }
}

@Suite("FloeExecution.LinuxGuestMetricsSampler")
struct LinuxGuestMetricsSamplerTests {

    private static let marker = "@@FLOE@@"

    private func output(
        stat: String = "cpu  100 0 0 900 0 0 0 0 0 0",
        meminfo: String = "MemTotal: 1048576 kB\nMemAvailable: 524288 kB",
        netdev: String = "  eth0: 4096 1 0 0 0 0 0 0 2048 1 0 0 0 0 0 0"
    ) -> String {
        "\(stat)\n\(Self.marker)\n\(meminfo)\n\(Self.marker)\n\(netdev)"
    }

    @Test("One sample reads the bounded guest files and reports real values")
    func singleSampleReadsBoundedFiles() async {
        let runner = ScriptedGuestRunner(results: [
            LinuxCommandResult(stdout: output(), stderr: "", exitCode: 0)
        ])
        let sampler = LinuxGuestMetricsSampler(
            environmentID: "env-1",
            commandRunner: runner,
            emulatorSampleProvider: { _ in
                LinuxGuestEmulatorCPUSample(cpuNanos: 0, wallNanos: 0)
            }
        )
        let metrics = await sampler.sampleNow()

        #expect(metrics.guestMemoryTotalMB == 1024)
        #expect(metrics.guestMemoryUsedMB == 512)
        #expect(metrics.networkRxKB == 4)
        #expect(metrics.networkTxKB == 2)
        #expect(metrics.gpu == .unavailableNativeOnly)
        // First sample has no previous window: CPU stays unknown, never 0.
        #expect(metrics.guestCPUFraction == nil)
        #expect(metrics.emulatorCPUFraction == nil)

        let invocations = await runner.invocations()
        #expect(invocations.count == 1)
        #expect(invocations.first?.argv.first == "sh")
        #expect(invocations.first?.timeout == LinuxGuestMetricsSampler.standardCommandTimeout)
        #expect(invocations.first?.maxOutputBytes == LinuxGuestMetricsSampler.maxCommandOutputBytes)
        // The guest read is a bounded single command, not a streaming shell.
        #expect(invocations.first?.argv.last?.contains("/proc/stat") == true)
        #expect(invocations.first?.argv.last?.contains("/proc/meminfo") == true)
        #expect(invocations.first?.argv.last?.contains("/proc/net/dev") == true)
    }

    @Test("A second sample reports measured CPU and emulator fractions")
    func cpuFractionsNeedTwoSamples() async {
        let runner = ScriptedGuestRunner(results: [
            LinuxCommandResult(stdout: output(stat: "cpu  100 0 0 900 0 0 0 0 0 0"), stderr: "", exitCode: 0),
            LinuxCommandResult(stdout: output(stat: "cpu  200 0 0 900 0 0 0 0 0 0"), stderr: "", exitCode: 0),
        ])
        let emulator = EmulatorSampleSequence()
        let sampler = LinuxGuestMetricsSampler(
            environmentID: "env-1",
            commandRunner: runner,
            emulatorSampleProvider: { _ in emulator.next() }
        )
        _ = await sampler.sampleNow()
        let second = await sampler.sampleNow()

        // Guest: busy delta 100 of total delta 100.
        #expect(second.guestCPUFraction == 1)
        // Emulator thread: half of the wall window was CPU time.
        #expect(second.emulatorCPUFraction == 0.5)
    }

    @Test("A failed guest read keeps unknown values unknown and never claims success")
    func failedReadStaysUnknown() async {
        let runner = ScriptedGuestRunner(results: [
            LinuxCommandResult(stdout: "", stderr: "guest stopped", exitCode: 100)
        ])
        let sampler = LinuxGuestMetricsSampler(
            environmentID: "env-1",
            commandRunner: runner,
            emulatorSampleProvider: { _ in nil }
        )
        let metrics = await sampler.sampleNow()
        #expect(metrics.guestMemoryTotalMB == nil)
        #expect(metrics.guestMemoryUsedMB == nil)
        #expect(metrics.guestCPUFraction == nil)
        #expect(metrics.networkRxKB == nil)
        #expect(metrics.gpu == .unavailableNativeOnly)
    }

    @Test("Truncated output still yields a partial, truthful sample")
    func partialOutput() async {
        let runner = ScriptedGuestRunner(results: [
            LinuxCommandResult(
                stdout: "cpu  50 0 0 950 0 0 0 0 0 0\n\(Self.marker)\nMemTotal: 2048 kB",
                stderr: "",
                exitCode: 0
            )
        ])
        let sampler = LinuxGuestMetricsSampler(
            environmentID: "env-1",
            commandRunner: runner,
            emulatorSampleProvider: { _ in nil }
        )
        let metrics = await sampler.sampleNow()
        #expect(metrics.guestMemoryTotalMB == 2)
        #expect(metrics.guestMemoryUsedMB == 2)
        #expect(metrics.networkRxKB == nil)
    }

    @Test("Sampling is consumer bounded: the loop stops with its last observer")
    func samplingStopsWithLastConsumer() async {
        let runner = ScriptedGuestRunner(results: [
            LinuxCommandResult(stdout: output(), stderr: "", exitCode: 0),
            LinuxCommandResult(stdout: output(), stderr: "", exitCode: 0),
            LinuxCommandResult(stdout: output(), stderr: "", exitCode: 0),
            LinuxCommandResult(stdout: output(), stderr: "", exitCode: 0),
        ])
        let sampler = LinuxGuestMetricsSampler(
            environmentID: "env-1",
            commandRunner: runner,
            emulatorSampleProvider: { _ in nil },
            interval: 1
        )
        let consumer = Task { () -> Int in
            var count = 0
            for await _ in await sampler.metrics() { count += 1 }
            return count
        }
        // Wait for the first published sample: the loop only runs while a
        // consumer is registered.
        let startDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await sampler.consumerCount == 0, ContinuousClock.now < startDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await sampler.consumerCount == 1)
        #expect(await runner.invocations().count >= 1)

        // Dropping the last consumer must terminate the stream and stop the
        // sampling loop instead of leaving a background poll running.
        consumer.cancel()
        _ = await consumer.value
        let stopDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await sampler.consumerCount != 0, ContinuousClock.now < stopDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await sampler.consumerCount == 0)
        let countAfterStop = await runner.invocations().count
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await runner.invocations().count == countAfterStop)
    }

    @Test("The sampler never reports a guest GPU")
    func gpuIsAlwaysUnavailable() async {
        let runner = ScriptedGuestRunner(results: [])
        let sampler = LinuxGuestMetricsSampler(
            environmentID: "env-1",
            commandRunner: runner,
            emulatorSampleProvider: { _ in nil }
        )
        let metrics = await sampler.sampleNow()
        #expect(metrics.gpu == .unavailableNativeOnly)
        #expect(metrics.gpu.rawValue == "unavailableNativeOnly")
    }
}

/// Thread-safe monotonic emulator sample sequence for the delta assertions.
private final class EmulatorSampleSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let samples = [
        LinuxGuestEmulatorCPUSample(cpuNanos: 0, wallNanos: 0),
        LinuxGuestEmulatorCPUSample(cpuNanos: 500, wallNanos: 1000),
    ]

    func next() -> LinuxGuestEmulatorCPUSample {
        lock.lock()
        defer { lock.unlock() }
        let value = samples[min(index, samples.count - 1)]
        index += 1
        return value
    }
}

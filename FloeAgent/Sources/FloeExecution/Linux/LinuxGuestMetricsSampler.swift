// FloeExecution — Bounded metrics sampler for a running Linux guest.
//
// Truthful, point-in-time resource samples for one environment:
//  * guest aggregate CPU fraction from `/proc/stat` jiffie deltas,
//  * guest memory used/total from `/proc/meminfo`,
//  * cumulative network counters from `/proc/net/dev`,
//  * host-side emulator-thread CPU fraction (a proxy for vCPU usage),
//  * GPU status is *always* `.unavailableNativeOnly`: TinyEMU interprets
//    RISC-V with no GPU passthrough, and we never fabricate a measured value.
//
// Sampling is bounded: the loop runs only while at least one consumer is
// iterating the stream, uses one short bounded guest command per interval,
// and stops with the last consumer. Missing values surface as nil ("—"),
// never zero.

import Foundation
import FloeCore
import FloeTools

public actor LinuxGuestMetricsSampler {
    public static let standardInterval: TimeInterval = 3
    public static let maximumInterval: TimeInterval = 30
    public static let standardCommandTimeout: TimeInterval = 5
    public static let maxCommandOutputBytes = 60 * 1024
    private static let sectionMarker = "@@FLOE@@"

    private let environmentID: String
    private let commandRunner: any LinuxCommandRunning
    private let emulatorSampleProvider: @Sendable (String) async -> LinuxGuestEmulatorCPUSample?
    private let interval: TimeInterval
    private let commandTimeout: TimeInterval

    private var observers: [UUID: AsyncStream<BackgroundWorkMetrics>.Continuation] = [:]
    private var loopTask: Task<Void, Never>?
    private var lastProc: GuestProcStatSample?
    private var lastEmulator: LinuxGuestEmulatorCPUSample?

    public init(
        environmentID: String,
        commandRunner: any LinuxCommandRunning,
        emulatorSampleProvider: @escaping @Sendable (String) async -> LinuxGuestEmulatorCPUSample? = { _ in nil },
        interval: TimeInterval = standardInterval,
        commandTimeout: TimeInterval = standardCommandTimeout
    ) {
        self.environmentID = environmentID
        self.commandRunner = commandRunner
        self.emulatorSampleProvider = emulatorSampleProvider
        self.interval = min(Self.maximumInterval, max(1, interval))
        self.commandTimeout = max(1, commandTimeout)
    }

    /// Number of live metric consumers (diagnostics/tests).
    public var consumerCount: Int { observers.count }

    /// Takes one sample on demand. Does not start the background loop.
    @discardableResult
    public func sampleNow() async -> BackgroundWorkMetrics {
        let script = """
        cat /proc/stat; echo \(Self.sectionMarker); \
        cat /proc/meminfo; echo \(Self.sectionMarker); \
        cat /proc/net/dev
        """
        let result: LinuxCommandResult?
        do {
            result = try await commandRunner.run(
                environmentID: environmentID,
                argv: ["sh", "-c", script],
                workingDirectory: nil,
                standardInput: nil,
                timeout: commandTimeout,
                maxOutputBytes: Self.maxCommandOutputBytes,
                cancellation: nil
            )
        } catch {
            result = nil
        }

        let emulatorNow = await emulatorSampleProvider(environmentID)
        var emulatorFraction: Double?
        if let current = emulatorNow, let previous = lastEmulator,
           current.wallNanos > previous.wallNanos {
            emulatorFraction = GuestResourceDeltas.fraction(
                busyDelta: current.cpuNanos &- previous.cpuNanos,
                totalDelta: current.wallNanos &- previous.wallNanos
            )
        }
        lastEmulator = emulatorNow ?? lastEmulator

        guard let result, result.exitCode == 0 else {
            // The guest read failed or the guest stopped; keep known values,
            // leave the rest unknown rather than inventing zeros.
            return BackgroundWorkMetrics(
                emulatorCPUFraction: emulatorFraction,
                gpu: .unavailableNativeOnly
            )
        }

        let sections = result.stdout.components(separatedBy: Self.sectionMarker)
        let stat = sections.indices.contains(0)
            ? GuestProcStatParser.aggregateSample(sections[0]) : nil
        var guestFraction: Double?
        if let current = stat, let previous = lastProc {
            guestFraction = GuestResourceDeltas.fraction(
                busyDelta: current.busyJiffies &- previous.busyJiffies,
                totalDelta: current.totalJiffies &- previous.totalJiffies
            )
        }
        lastProc = stat ?? lastProc

        let memory = sections.indices.contains(1)
            ? GuestMemInfoParser.parse(sections[1]) : nil
        let net = sections.indices.contains(2)
            ? GuestNetDevParser.aggregateCounters(sections[2]) : nil

        return BackgroundWorkMetrics(
            emulatorCPUFraction: emulatorFraction,
            guestCPUFraction: guestFraction,
            guestMemoryUsedMB: memory.map { GuestMemInfoParser.megabytes($0.usedKB) },
            guestMemoryTotalMB: memory.map { GuestMemInfoParser.megabytes($0.totalKB) },
            networkRxKB: net.map { Double($0.rxBytes) / 1024 },
            networkTxKB: net.map { Double($0.txBytes) / 1024 },
            gpu: .unavailableNativeOnly
        )
    }

    /// Bounded metrics stream. Sampling runs only while a consumer is
    /// iterating; the loop stops after the last consumer terminates.
    public func metrics() -> AsyncStream<BackgroundWorkMetrics> {
        AsyncStream { continuation in
            let token = UUID()
            observers[token] = continuation
            if loopTask == nil { startLoop() }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(token) }
            }
        }
    }

    private func startLoop() {
        let interval = self.interval
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let sample = await self.sampleNow()
                await self.publish(sample)
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
            }
        }
    }

    private func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
        if observers.isEmpty {
            loopTask?.cancel()
            loopTask = nil
        }
    }

    private func publish(_ metrics: BackgroundWorkMetrics) {
        for continuation in observers.values {
            continuation.yield(metrics)
        }
    }
}

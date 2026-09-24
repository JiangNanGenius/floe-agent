// FloeExecution — Bounded metrics sampler for a running Linux guest.
//
// Truthful, point-in-time resource samples for one environment:
//  * guest aggregate CPU fraction from `/proc/stat` jiffie deltas,
//  * guest memory used/total from `/proc/meminfo`,
//  * cumulative network counters from `/proc/net/dev`,
//  * the guest's actual core count (the `cpuN` lines of `/proc/stat`) and
//    kernel version (`uname -sr`), tagged with the runtime identity so a
//    reboot can never inherit a previous boot's identity values,
//  * host-side emulator-thread CPU fraction (a proxy for vCPU usage),
//  * GPU status is *always* `.unavailableNativeOnly`: TinyEMU interprets
//    RISC-V with no GPU passthrough, and we never fabricate a measured value.
//
// Sampling is bounded: the loop runs only while at least one consumer is
// iterating the stream, uses one short bounded guest command per interval,
// and stops with the last consumer. Streams use `bufferingNewest(1)`: a slow
// consumer never grows memory, and concurrent requesters share one read.
// Missing values surface as nil, never zero.
//
// CPU semantics, stated once: the `/proc/stat` aggregate line sums every
// vCPU, so its busy/total jiffie delta is already the guest-wide
// utilization — dividing by the core count again would be wrong. A dual-core
// guest fully using both cores therefore tops out at 1.0 (100%), never 2.0.
// The emulator-thread fraction is a *host-side* proxy and is reported
// separately: a spinning run loop can sit near 100% of one host core even
// when the guest is idle, which is why the two must never be merged.
//
// Runtime identity: every sample carries the runtime token (runtime id +
// launch generation) supplied by the caller. The token is authoritative —
// it must come from the runtime lease (B2/D contract), never from UI
// observation. While no token source exists the fields stay unknown (nil)
// and the sampler preserves that instead of inventing a generation. A token
// change between samples resets every delta baseline, so a guest restart can
// never pair stale jiffies with fresh ones.

import Foundation
import FloeCore
import FloeTools

/// Authoritative runtime identity for one guest boot, supplied by the
/// runtime owner (B2/D contract). Unknown fields stay nil; consumers must
/// preserve unknown rather than substitute a locally invented generation.
public struct LinuxGuestRuntimeIdentity: Sendable, Hashable {
    public var runtimeID: String?
    public var launchGeneration: UInt64?

    public init(runtimeID: String? = nil, launchGeneration: UInt64? = nil) {
        self.runtimeID = runtimeID
        self.launchGeneration = launchGeneration
    }
}

/// Whether a metrics sample may be attributed to the live runtime state.
/// This is the production compatibility gate: a sample that cannot be proven
/// to belong to the live boot must never contribute numbers or identity to a
/// newer VM.
public enum LinuxGuestRuntimeIdentityMatch: Sendable, Equatable {
    /// Every identity field that is known on both sides agrees, and at least
    /// one field is known on both sides: the sample belongs to the live boot.
    case sameBoot
    /// A field known on both sides contradicts: the sample is from another
    /// boot (a restart happened since it was taken).
    case differentBoot
    /// Not enough known identity to attribute the sample — including a live
    /// identity that is fully unknown. Consumers must treat this
    /// conservatively: no measured data, no fabricated zero.
    case unverifiable
}

public extension LinuxGuestRuntimeIdentity {
    /// Compares a sample's identity with the live runtime state's identity.
    /// Unknown fields are never treated as equal evidence: two unknown
    /// identities prove nothing about the boot, so they answer
    /// `.unverifiable` rather than pretending a stale sample is current.
    static func match(
        sample: LinuxGuestRuntimeIdentity,
        live: LinuxGuestRuntimeIdentity
    ) -> LinuxGuestRuntimeIdentityMatch {
        var agreedKnownField = false
        if let sampleRuntime = sample.runtimeID, let liveRuntime = live.runtimeID {
            guard sampleRuntime == liveRuntime else { return .differentBoot }
            agreedKnownField = true
        }
        if let sampleGeneration = sample.launchGeneration, let liveGeneration = live.launchGeneration {
            guard sampleGeneration == liveGeneration else { return .differentBoot }
            agreedKnownField = true
        }
        return agreedKnownField ? .sameBoot : .unverifiable
    }
}

/// What one metrics sample may contribute to a surface projection of the live
/// boot. One production decision point shared by the metrics application path
/// (`applyLinuxMetrics`) and the snapshot assembly, so a delayed sample from a
/// previous boot can never attach its numbers (or its identity) to a newer VM:
///
///  * identity is always the live runtime state's own identity, never the
///    sample's — the sample can only contribute when it is proven to be the
///    same boot's;
///  * measured values are present only for a fresh sample that matched the
///    live identity; otherwise every measured field stays nil (rendered as
///    "暂无"), never zero.
public struct LinuxGuestRuntimeMetricsProjection: Sendable, Equatable {
    public var identity: LinuxGuestRuntimeIdentity
    public var match: LinuxGuestRuntimeIdentityMatch
    /// True only when a fresh sample belongs to the live boot.
    public var sampleIsFresh: Bool
    public var sampledAt: Date?
    public var kernelVersion: String?
    public var coreCount: Int?
    public var guestCPUFraction: Double?
    public var hostThreadCPUFraction: Double?
    public var guestMemoryUsedMB: Int?
    public var guestMemoryTotalMB: Int?

    public init(
        identity: LinuxGuestRuntimeIdentity,
        match: LinuxGuestRuntimeIdentityMatch,
        sampleIsFresh: Bool = false,
        sampledAt: Date? = nil,
        kernelVersion: String? = nil,
        coreCount: Int? = nil,
        guestCPUFraction: Double? = nil,
        hostThreadCPUFraction: Double? = nil,
        guestMemoryUsedMB: Int? = nil,
        guestMemoryTotalMB: Int? = nil
    ) {
        self.identity = identity
        self.match = match
        self.sampleIsFresh = sampleIsFresh
        self.sampledAt = sampledAt
        self.kernelVersion = kernelVersion
        self.coreCount = coreCount
        self.guestCPUFraction = guestCPUFraction
        self.hostThreadCPUFraction = hostThreadCPUFraction
        self.guestMemoryUsedMB = guestMemoryUsedMB
        self.guestMemoryTotalMB = guestMemoryTotalMB
    }

    /// Resolves the projection for one environment. `liveIdentity` is read
    /// from the runtime owner's session table at projection time; `sample` is
    /// the latest in-flight/published sample, which may be stale.
    public static func resolve(
        sample: LinuxGuestRuntimeSample?,
        liveIdentity: LinuxGuestRuntimeIdentity,
        now: Date = Date(),
        validity: TimeInterval = LinuxGuestMetricsSampler.sampleValidity
    ) -> LinuxGuestRuntimeMetricsProjection {
        let match = sample.map {
            LinuxGuestRuntimeIdentity.match(sample: $0.runtimeIdentity, live: liveIdentity)
        } ?? .unverifiable
        guard match == .sameBoot, let sample,
              sample.isFresh(now: now, validity: validity) else {
            return LinuxGuestRuntimeMetricsProjection(identity: liveIdentity, match: match)
        }
        return LinuxGuestRuntimeMetricsProjection(
            identity: liveIdentity,
            match: .sameBoot,
            sampleIsFresh: true,
            sampledAt: sample.sampledAt,
            kernelVersion: sample.kernelVersion,
            coreCount: sample.guestCoreCount,
            guestCPUFraction: sample.guestCPUFraction,
            hostThreadCPUFraction: sample.emulatorCPUFraction,
            guestMemoryUsedMB: sample.guestMemoryUsedMB,
            guestMemoryTotalMB: sample.guestMemoryTotalMB
        )
    }
}

/// One unified runtime sample for a Linux environment: guest truth, host
/// proxy, runtime identity and freshness in one value. Text rendering is the
/// App layer's job; this type stays locale-neutral.
public struct LinuxGuestRuntimeSample: Sendable, Hashable {
    public var environmentID: String
    /// Authoritative runtime identity; unknown until the runtime owner
    /// exposes a lease token.
    public var runtimeIdentity: LinuxGuestRuntimeIdentity
    /// When this sample was taken. Aged samples render as unknown on every
    /// surface instead of showing a stale number.
    public var sampledAt: Date
    /// False when the bounded guest read failed or the guest stopped; every
    /// guest-side value is then nil rather than invented.
    public var guestReadSucceeded: Bool
    /// Guest-reported aggregate CPU share, 0...1 of the guest's total
    /// capacity. Already normalized by the aggregate `/proc/stat` delta;
    /// never divide by the core count again.
    public var guestCPUFraction: Double?
    /// Actual vCPUs the running guest kernel reports.
    public var guestCoreCount: Int?
    /// Host emulator-thread occupancy of one host core, 0...1. Reported
    /// separately from the guest value on every surface.
    public var emulatorCPUFraction: Double?
    public var guestMemoryUsedMB: Int?
    public var guestMemoryTotalMB: Int?
    /// `uname -sr` of the running guest kernel, when readable.
    public var kernelVersion: String?
    public var networkRxKB: Double?
    public var networkTxKB: Double?

    public init(
        environmentID: String,
        runtimeIdentity: LinuxGuestRuntimeIdentity = LinuxGuestRuntimeIdentity(),
        sampledAt: Date = Date(),
        guestReadSucceeded: Bool,
        guestCPUFraction: Double? = nil,
        guestCoreCount: Int? = nil,
        emulatorCPUFraction: Double? = nil,
        guestMemoryUsedMB: Int? = nil,
        guestMemoryTotalMB: Int? = nil,
        kernelVersion: String? = nil,
        networkRxKB: Double? = nil,
        networkTxKB: Double? = nil
    ) {
        self.environmentID = environmentID
        self.runtimeIdentity = runtimeIdentity
        self.sampledAt = sampledAt
        self.guestReadSucceeded = guestReadSucceeded
        self.guestCPUFraction = guestCPUFraction.map { min(1, max(0, $0)) }
        self.guestCoreCount = guestCoreCount.map { max(1, $0) }
        self.emulatorCPUFraction = emulatorCPUFraction.map { min(1, max(0, $0)) }
        self.guestMemoryUsedMB = guestMemoryUsedMB.map { max(0, $0) }
        self.guestMemoryTotalMB = guestMemoryTotalMB.map { max(0, $0) }
        self.kernelVersion = kernelVersion
        self.networkRxKB = networkRxKB.map { max(0, $0) }
        self.networkTxKB = networkTxKB.map { max(0, $0) }
    }

    /// Registry-facing projection with the long-standing schema; the shared
    /// work record keeps carrying exactly these fields.
    public var metrics: BackgroundWorkMetrics {
        BackgroundWorkMetrics(
            emulatorCPUFraction: emulatorCPUFraction,
            guestCPUFraction: guestReadSucceeded ? guestCPUFraction : nil,
            guestMemoryUsedMB: guestReadSucceeded ? guestMemoryUsedMB : nil,
            guestMemoryTotalMB: guestReadSucceeded ? guestMemoryTotalMB : nil,
            networkRxKB: guestReadSucceeded ? networkRxKB : nil,
            networkTxKB: guestReadSucceeded ? networkTxKB : nil,
            gpu: .unavailableNativeOnly
        )
    }

    /// A sample is fresh while it is younger than the validity window; older
    /// samples must render as unknown ("暂无" in the App layer), not as stale
    /// numbers.
    public func isFresh(now: Date = Date(), validity: TimeInterval) -> Bool {
        now.timeIntervalSince(sampledAt) <= validity
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public actor LinuxGuestMetricsSampler {
    public static let standardInterval: TimeInterval = 3
    public static let maximumInterval: TimeInterval = 30
    public static let standardCommandTimeout: TimeInterval = 5
    public static let maxCommandOutputBytes = 60 * 1024
    /// Default freshness window for a published sample: ten standard ticks.
    /// Consumers with a custom interval should pass their own window.
    public static let sampleValidity: TimeInterval = 30
    private static let sectionMarker = "@@FLOE@@"

    private let environmentID: String
    private let commandRunner: any LinuxCommandRunning
    private let emulatorSampleProvider: @Sendable (String) async -> LinuxGuestEmulatorCPUSample?
    private let runtimeIdentityProvider: @Sendable (String) async -> LinuxGuestRuntimeIdentity
    private let interval: TimeInterval
    private let commandTimeout: TimeInterval

    private var observers: [UUID: AsyncStream<BackgroundWorkMetrics>.Continuation] = [:]
    private var runtimeObservers: [UUID: AsyncStream<LinuxGuestRuntimeSample>.Continuation] = [:]
    private var loopTask: Task<Void, Never>?
    private var lastProc: GuestProcStatSample?
    private var lastEmulator: LinuxGuestEmulatorCPUSample?
    private var lastIdentity: LinuxGuestRuntimeIdentity?
    private var lastCoreCount: Int?
    private var lastKernelVersion: String?
    /// Reentrancy guard: the guest read awaits twice, and two overlapping
    /// `performSample` calls would pair one delta baseline with two fresh
    /// reads and scramble every value. Concurrent requesters wait for the
    /// single in-flight read and share its result.
    private var samplingInFlight = false
    private var sampleWaiters: [UUID: CheckedContinuation<LinuxGuestRuntimeSample, Never>] = [:]

    public init(
        environmentID: String,
        commandRunner: any LinuxCommandRunning,
        emulatorSampleProvider: @escaping @Sendable (String) async -> LinuxGuestEmulatorCPUSample? = { _ in nil },
        runtimeIdentityProvider: @escaping @Sendable (String) async -> LinuxGuestRuntimeIdentity = { _ in
            LinuxGuestRuntimeIdentity()
        },
        interval: TimeInterval = standardInterval,
        commandTimeout: TimeInterval = standardCommandTimeout
    ) {
        self.environmentID = environmentID
        self.commandRunner = commandRunner
        self.emulatorSampleProvider = emulatorSampleProvider
        self.runtimeIdentityProvider = runtimeIdentityProvider
        self.interval = min(Self.maximumInterval, max(1, interval))
        self.commandTimeout = max(1, commandTimeout)
    }

    /// Number of live metric consumers (diagnostics/tests).
    public var consumerCount: Int { observers.count + runtimeObservers.count }

    /// Number of live consumers of the unified runtime sample stream.
    public var runtimeConsumerCount: Int { runtimeObservers.count }

    /// Takes one sample on demand. Does not start the background loop.
    @discardableResult
    public func sampleNow() async -> BackgroundWorkMetrics {
        await performSample().metrics
    }

    /// Takes one unified runtime sample on demand. Does not start the
    /// background loop.
    @discardableResult
    public func sampleRuntime() async -> LinuxGuestRuntimeSample {
        await performSample()
    }

    /// Serializes sampling across the actor's suspension points: one read
    /// serves every concurrent requester, and delta baselines advance exactly
    /// once per read.
    private func performSample() async -> LinuxGuestRuntimeSample {
        if samplingInFlight {
            return await withCheckedContinuation { continuation in
                let token = UUID()
                sampleWaiters[token] = continuation
            }
        }
        samplingInFlight = true
        let sample = await takeSample()
        samplingInFlight = false
        let waiters = sampleWaiters
        sampleWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(returning: sample)
        }
        return sample
    }

    /// The single bounded guest read both public samplers share. One short
    /// command produces every section. A runtime-identity change resets all
    /// delta baselines and identity values: a fresh boot must never pair its
    /// first jiffies with a previous boot's counters, and a failed read must
    /// never resurrect a previous boot's core/kernel identity.
    private func takeSample() async -> LinuxGuestRuntimeSample {
        let identity = await runtimeIdentityProvider(environmentID)
        if let lastIdentity, !Self.sameIdentity(lastIdentity, identity) {
            lastProc = nil
            lastEmulator = nil
            lastCoreCount = nil
            lastKernelVersion = nil
        }
        lastIdentity = identity

        let script = """
            cat /proc/stat; echo \(Self.sectionMarker); \
            cat /proc/meminfo; echo \(Self.sectionMarker); \
            cat /proc/net/dev; echo \(Self.sectionMarker); \
            uname -sr
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
            // The guest read failed or the guest stopped. Identity values
            // survive only for the boot they were measured on.
            return LinuxGuestRuntimeSample(
                environmentID: environmentID,
                runtimeIdentity: identity,
                guestReadSucceeded: false,
                guestCoreCount: lastCoreCount,
                emulatorCPUFraction: emulatorFraction,
                kernelVersion: lastKernelVersion
            )
        }

        let sections = result.stdout.components(separatedBy: Self.sectionMarker)
        let stat = sections.indices.contains(0)
            ? GuestProcStatParser.aggregateSample(sections[0]) : nil
        let coreCount = sections.indices.contains(0)
            ? Self.guestCoreCount(statSection: sections[0]) : nil
        var guestFraction: Double?
        if let current = stat, let previous = lastProc {
            guestFraction = GuestResourceDeltas.fraction(
                busyDelta: current.busyJiffies &- previous.busyJiffies,
                totalDelta: current.totalJiffies &- previous.totalJiffies
            )
        }
        lastProc = stat ?? lastProc
        lastCoreCount = coreCount ?? lastCoreCount

        let memory = sections.indices.contains(1)
            ? GuestMemInfoParser.parse(sections[1]) : nil
        let net = sections.indices.contains(2)
            ? GuestNetDevParser.aggregateCounters(sections[2]) : nil
        let kernel = sections.indices.contains(3)
            ? sections[3].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty : nil
        lastKernelVersion = kernel ?? lastKernelVersion

        return LinuxGuestRuntimeSample(
            environmentID: environmentID,
            runtimeIdentity: identity,
            guestReadSucceeded: true,
            guestCPUFraction: guestFraction,
            guestCoreCount: lastCoreCount,
            emulatorCPUFraction: emulatorFraction,
            guestMemoryUsedMB: memory.map { GuestMemInfoParser.megabytes($0.usedKB) },
            guestMemoryTotalMB: memory.map { GuestMemInfoParser.megabytes($0.totalKB) },
            kernelVersion: kernel,
            networkRxKB: net.map { Double($0.rxBytes) / 1024 },
            networkTxKB: net.map { Double($0.txBytes) / 1024 }
        )
    }

    /// Identity comparison with unknown-as-wildcard semantics: two unknown
    /// fields are "the same" (no evidence of change), while any known pair
    /// compares exactly. A known value never equals a different known value,
    /// and unknown never manufactures inequality with itself.
    static func sameIdentity(
        _ lhs: LinuxGuestRuntimeIdentity,
        _ rhs: LinuxGuestRuntimeIdentity
    ) -> Bool {
        let sameRuntime = lhs.runtimeID == nil || rhs.runtimeID == nil
            || lhs.runtimeID == rhs.runtimeID
        let sameGeneration = lhs.launchGeneration == nil || rhs.launchGeneration == nil
            || lhs.launchGeneration == rhs.launchGeneration
        return sameRuntime && sameGeneration
    }

    /// Counts the `cpuN` per-CPU lines of `/proc/stat`: the actual core count
    /// the running guest kernel sees. The bare aggregate `cpu` line is
    /// excluded. Returns nil when the section carries no per-CPU lines.
    static func guestCoreCount(statSection: String) -> Int? {
        let count = statSection.split(separator: "\n")
            .filter { line in
                guard let first = line.split(
                    separator: " ", omittingEmptySubsequences: true
                ).first else { return false }
                return first.hasPrefix("cpu")
                    && first.count > 3
                    && first.dropFirst(3).allSatisfy(\.isNumber)
            }
            .count
        return count > 0 ? count : nil
    }

    /// Bounded metrics stream. Sampling runs only while a consumer is
    /// iterating; the loop stops after the last consumer terminates.
    public func metrics() -> AsyncStream<BackgroundWorkMetrics> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let token = UUID()
            observers[token] = continuation
            if loopTask == nil { startLoop() }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(token) }
            }
        }
    }

    /// Bounded unified-runtime-sample stream. Shares the single sampling
    /// loop with `metrics()`: whichever stream a consumer attaches to, the
    /// guest is read at most once per interval, and a slow consumer never
    /// accumulates more than the newest sample.
    public func runtimeSamples() -> AsyncStream<LinuxGuestRuntimeSample> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let token = UUID()
            runtimeObservers[token] = continuation
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
                let sample = await self.performSample()
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
        runtimeObservers.removeValue(forKey: token)
        if observers.isEmpty, runtimeObservers.isEmpty {
            loopTask?.cancel()
            loopTask = nil
        }
    }

    private func publish(_ sample: LinuxGuestRuntimeSample) {
        for continuation in observers.values {
            continuation.yield(sample.metrics)
        }
        for continuation in runtimeObservers.values {
            continuation.yield(sample)
        }
    }
}

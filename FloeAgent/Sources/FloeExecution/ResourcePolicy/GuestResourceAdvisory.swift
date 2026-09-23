// FloeExecution — ResourcePolicy: automatic vCPU/RAM recommendations.
//
// SPDX-License-Identifier: MPL-2.0
//
// One shared service (`GuestResourceAdvisory.shared`) serves BOTH the local
// model caller and the workspace IDE; the user can override any
// recommendation per workload. Recommendations are deterministic and
// evidence-bounded:
//
//  Evidence (all DECLARED, never obtained by scanning source):
//   - commands the workload declares (argv[0] of command/manifest entries),
//   - lock/manifest files (package-lock.json, Pipfile.lock, uv.lock, …),
//   - a bounded list of imports from a static manifest,
//   - worker/service configuration,
//   - history of earlier outcomes at this shape,
//   - package count and code size are AUXILIARY hints only.
//
// No code is executed or scanned here; the recommendation is a plan, not a
// grant — the pool still performs real CPU/RAM/VM admission at start time.

import Foundation

/// Declared evidence about one workload. The app/IDE builds this from
/// manifests, command lists and configuration; never from source scanning.
public struct WorkloadResourceSignals: Sendable, Equatable {
    /// Stable identity for overrides/history (workspace/task id, opaque).
    public var workloadKey: String
    /// Declared commands, normalized to argv[0] ("cargo", "npm", …).
    public var declaredCommands: [String]
    /// Lock/manifest evidence ("package-lock.json", "Pipfile.lock", …).
    public var lockManifests: [String]
    /// Imports declared in a static manifest (bounded; e.g. "torch").
    public var declaredImports: [String]
    /// Worker/service configuration keys/values already resolved by the app.
    public var workerConfiguration: [String: String]
    /// Auxiliary: declared package count.
    public var packageCount: Int?
    /// Auxiliary: declared code size in bytes.
    public var codeBytes: Int?

    public init(
        workloadKey: String,
        declaredCommands: [String] = [],
        lockManifests: [String] = [],
        declaredImports: [String] = [],
        workerConfiguration: [String: String] = [:],
        packageCount: Int? = nil,
        codeBytes: Int? = nil
    ) {
        self.workloadKey = workloadKey
        // Deterministic, de-duplicated inputs make the decision reproducible.
        self.declaredCommands = Array(Set(declaredCommands)).sorted()
        self.lockManifests = Array(Set(lockManifests)).sorted()
        self.declaredImports = Array(Set(declaredImports)).sorted()
        self.workerConfiguration = workerConfiguration
        self.packageCount = packageCount
        self.codeBytes = codeBytes
    }
}

/// One recommendation plus the honest basis for it.
public struct GuestResourceRecommendation: Sendable, Equatable {
    public var shape: GuestResourceRequest
    public var memoryReason: String
    public var vcpuReason: String
    /// 0…1: how strongly the evidence supports this shape.
    public var confidence: Double
    public var evidenceSignals: [String]
    /// True when the user pinned this workload's shape.
    public var userOverride: Bool

    public init(
        shape: GuestResourceRequest,
        memoryReason: String,
        vcpuReason: String,
        confidence: Double,
        evidenceSignals: [String],
        userOverride: Bool = false
    ) {
        self.shape = shape
        self.memoryReason = memoryReason
        self.vcpuReason = vcpuReason
        self.confidence = min(1, max(0, confidence))
        self.evidenceSignals = evidenceSignals
        self.userOverride = userOverride
    }
}

/// Historical outcome of running one workload at a shape.
public struct WorkloadResourceOutcome: Sendable, Equatable {
    public var shape: GuestResourceRequest
    public var succeeded: Bool
    /// The guest/host reported memory pressure (OOM kills, allocation fail).
    public var memoryPressure: Bool

    public init(shape: GuestResourceRequest, succeeded: Bool, memoryPressure: Bool = false) {
        self.shape = shape
        self.succeeded = succeeded
        self.memoryPressure = memoryPressure
    }
}

public actor GuestResourceAdvisory {
    /// Shared service used by the model caller and the workspace IDE alike.
    public static let shared = GuestResourceAdvisory()

    private var overrides: [String: GuestResourceRequest] = [:]
    private var history: [String: [WorkloadResourceOutcome]] = [:]

    public init() {}

    // MARK: user override

    /// Pins a workload's shape; nil removes the pin. The pool still admits.
    public func setUserOverride(_ shape: GuestResourceRequest?, for workloadKey: String) {
        if let shape { overrides[workloadKey] = shape } else { overrides.removeValue(forKey: workloadKey) }
    }

    public func userOverride(for workloadKey: String) -> GuestResourceRequest? {
        overrides[workloadKey]
    }

    // MARK: history

    /// Records one finished run. `outcome.shape` MUST be the shape the guest
    /// was actually GRANTED (the pool's lease), not the requested/planned
    /// shape: a plan is only advanced by a failure at (or above) its own
    /// shape, and a stale report from a smaller shape is ignored.
    public func recordOutcome(_ outcome: WorkloadResourceOutcome, for workloadKey: String) {
        var outcomes = history[workloadKey] ?? []
        outcomes.append(outcome)
        // Keep the last five; older signals stop changing the decision.
        history[workloadKey] = Array(outcomes.suffix(5))
    }

    // MARK: recommendation

    public func recommend(_ signals: WorkloadResourceSignals) -> GuestResourceRecommendation {
        if let pinned = overrides[signals.workloadKey] {
            return GuestResourceRecommendation(
                shape: pinned,
                memoryReason: "user override",
                vcpuReason: "user override",
                confidence: 1,
                evidenceSignals: ["user-override"],
                userOverride: true
            )
        }
        var recommendation = Self.plan(from: signals)

        // History adjustment, bounded by what actually ran: callers record
        // `WorkloadResourceOutcome.shape` as the shape the guest was really
        // GRANTED, so only a FAILED run at (or above) today's planned shape
        // that reported memory pressure is evidence the plan is insufficient.
        // A pressure report from a smaller shape is stale low-shape evidence
        // and never inflates the plan; a successful run is evidence the plan
        // worked. The raise is exactly one declared ladder step above the
        // shape where the workload actually failed (1024 -> 1536 -> 2048,
        // never arithmetic that invents non-existent steps), so repeating the
        // same low-tier failure can never inflate the plan further.
        if let outcomes = history[signals.workloadKey] {
            let planned = recommendation.shape.memory
            let pressuredShape = outcomes
                .filter { !$0.succeeded && $0.memoryPressure && $0.shape.memory >= planned }
                .map(\.shape.memory)
                .max()
            if let pressuredShape {
                let target = pressuredShape.raised() ?? pressuredShape
                if target > planned {
                    recommendation = GuestResourceRecommendation(
                        shape: GuestResourceRequest(vcpus: recommendation.shape.vcpus, memory: target, origin: .recommendation),
                        memoryReason: recommendation.memoryReason + "; earlier runs hit memory pressure at \(pressuredShape.mb) MiB",
                        vcpuReason: recommendation.vcpuReason,
                        confidence: recommendation.confidence,
                        evidenceSignals: recommendation.evidenceSignals + ["history:memory-pressure"]
                    )
                }
            }
        }
        return recommendation
    }

    /// Pure deterministic planning split out for focused testing.
    static func plan(from signals: WorkloadResourceSignals) -> GuestResourceRecommendation {
        var memory: GuestMemoryMiB = .m256
        var wantsDual = false
        var evidence: [String] = []

        func raise(to step: GuestMemoryMiB, reason: String) {
            if step > memory {
                memory = step
                evidence.append(reason)
            } else if !evidence.contains(reason) {
                evidence.append(reason)
            }
        }

        let commands = Set(signals.declaredCommands)
        let imports = Set(signals.declaredImports)
        let locks = Set(signals.lockManifests)

        // Command-based memory signals.
        if commands.contains(where: { ["cc", "gcc", "g++", "clang", "cargo", "make", "cmake", "setup.py"].contains($0) }) {
            raise(to: .m768, reason: "declared native build command")
            wantsDual = true
        }
        if commands.contains(where: { ["node", "npm", "pnpm", "yarn", "bun"].contains($0) }) {
            raise(to: .m512, reason: "declared Node toolchain command")
        }
        if commands.contains("java") {
            raise(to: .m1024, reason: "declared JVM command")
        }
        if commands.contains("python3") || commands.contains("python") {
            raise(to: .m512, reason: "declared Python command")
        }

        // Import-based signals (declared in a manifest, not scanned).
        if imports.contains(where: { ["torch", "tensorflow", "jax", "transformers"].contains($0) }) {
            raise(to: .m1536, reason: "declared heavy ML import")
        } else if imports.contains(where: { ["numpy", "pandas", "scipy"].contains($0) }) {
            raise(to: .m768, reason: "declared numerical import")
        }

        // Lock/manifest evidence: dependency installs are expected.
        if locks.contains(where: {
            ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "Pipfile.lock", "uv.lock", "poetry.lock", "requirements.txt", "Cargo.lock"].contains($0)
        }) {
            raise(to: .m512, reason: "dependency lock manifest present")
        }

        // Worker/service configuration: explicit parallel/service asks.
        var workerParallel = false
        for (key, value) in signals.workerConfiguration {
            let key = key.lowercased()
            if key.contains("worker") || key.contains("service") || key.contains("process") {
                if let count = Int(value), count >= 2 { workerParallel = true }
            }
            if key.contains("parallel") && (value.lowercased() == "true" || (Int(value) ?? 0) >= 2) {
                workerParallel = true
            }
        }
        if workerParallel {
            wantsDual = true
            evidence.append("worker configuration requests parallel execution")
        }

        // Auxiliary hints only: never decide a shape on their own, but a very
        // large declared codebase/package set lifts one RAM step.
        if (signals.packageCount ?? 0) > 200 || (signals.codeBytes ?? 0) > 50 * 1024 * 1024 {
            raise(to: .m512, reason: "auxiliary: large declared codebase/package set")
        }

        let confidence = min(0.9, 0.45 + Double(evidence.count) * 0.15)
        return GuestResourceRecommendation(
            shape: GuestResourceRequest(vcpus: wantsDual ? .two : .one, memory: memory, origin: .recommendation),
            memoryReason: memory == .m256
                ? "no heavy workload signals; the 256 MiB floor covers ordinary shell work"
                : "granted the smallest ladder step covering declared workload signals",
            vcpuReason: wantsDual
                ? "declared parallel build/worker signals benefit from a second hart"
                : "no declared parallel workload; one hart avoids reserving unused emulation",
            confidence: confidence,
            evidenceSignals: evidence.sorted()
        )
    }
}

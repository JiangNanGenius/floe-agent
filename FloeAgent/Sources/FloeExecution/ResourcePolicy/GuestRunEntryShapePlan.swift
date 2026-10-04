// FloeExecution — ResourcePolicy: script-run entry vCPU choice + honest gate.
//
// SPDX-License-Identifier: MPL-2.0
//
// The IDE run sheet asks the user which guest shape a Python/Node script run
// should use (automatic / 1, 2 or 3 vCPU). This type is the pure decision
// layer behind that control. It reuses the existing `GuestResourceAdvisory`
// plan and the `GuestReleaseShapePolicy`, and it produces exactly the typed
// `GuestResourceRequest` + `GuestShapeDowngradePolicy` pair the guest pool
// already consumes — so the sheet can never promise a shape this release
// cannot deliver.
//
// Honesty rules encoded here:
//
//  * Every selection is always listed. An option that cannot be delivered
//    carries a typed refusal instead of disappearing or becoming another
//    shape.
//  * `automatic` is the only selection allowed to resolve below the advisory
//    plan: when the advisory asks for two harts and the release gate, the
//    image's SMP proof or the connected dispatch path cannot deliver them, it
//    resolves to one hart with origin `.recommendation` and an AUTHORIZED
//    single-hart floor, which is the only downgrade the pool may record for an
//    automatic plan. The reason is exposed on the plan, so the UI reports the
//    downgrade instead of hiding it.
//  * An EXPLICIT multi-core selection is `.strict`: when any gate refuses it,
//    `effectiveRequest` stays nil and the selection is refused. It never
//    becomes a one-hart request, and the dispatcher must not start anything.
//  * `GuestRunEntryShapeDispatch.singleHartOnly` remains the honest state for
//    a caller that cannot carry a typed shape into its start path; while it is
//    set, an otherwise-deliverable dual selection is still refused rather than
//    booting a silently different machine. The IDE passes `.shapeAware`
//    because its accepted intent reaches the guest start.
//  * Dual-core is delivered ONLY when the released policy, the verified image
//    manifest's SMP proof and a shape-aware dispatch path all allow it. Since
//    2026-09-27 `production` qualifies two harts (cloud S0–S4 correctness:
//    runs 36004192418 / 36009075837) but the equal-work S5 benchmark is still
//    slower on two harts (0.876×). The plan therefore exposes dual as a real
//    choice and the UI states the measured slowdown; it never claims a
//    speedup. The verified image proof is what guarantees the second hart
//    runs the reworked CONFIG_SMP kernel/firmware pair, so this is not a
//    bare vCPU-count change.
//
// Pool alignment (RuntimeVMPool.admit): a release/image gate refusal under
// `.strict` throws `releaseShapeUnsupported`/`smpUnsupportedByImage`; under
// `.authorized` with a one-hart floor it grants one hart and records the
// downgrade reason. The planner mirrors both branches without touching engine
// state.

import Foundation

/// What the script-run entry offers the user.
public enum GuestRunEntryShapeSelection: String, Sendable, Equatable, CaseIterable, Codable {
    /// The advisory recommendation, resolved to what this release can deliver.
    case automatic
    /// An explicit single-hart guest.
    case singleCore
    /// An explicit dual-hart guest.
    case dualCore
    case tripleCore

    /// The explicit vCPU count this selection asks for. `automatic` carries no
    /// count of its own; the advisory decides it.
    public var explicitVCPUs: GuestVCPUCount? {
        switch self {
        case .automatic: return nil
        case .singleCore: return .one
        case .dualCore: return .two
        case .tripleCore: return .three
        }
    }
}

/// Whether the run dispatch path can actually carry a typed shape request to
/// the guest scheduler.
///
/// This is deliberately NOT inferred from the release policy: a future release
/// can widen `GuestReleaseShapePolicy` (after real SMP qualification) while
/// the IDE still has no channel to hand the request to the start path. In that
/// state a dual selection must remain refused at the entry, never silently
/// boot one hart.
public enum GuestRunEntryShapeDispatch: Sendable, Equatable {
    /// The run controller resolves the environment descriptor itself and no
    /// typed shape can be delivered; only the one-hart worker default exists.
    case singleHartOnly
    /// The run controller can carry the plan's `effectiveRequest` (and its
    /// downgrade policy) into the guest start.
    case shapeAware
}

/// Why the script-run entry refuses a selection. Typed so the UI localizes it
/// and so tests can assert the exact gate, never a string match.
public enum GuestRunEntryShapeRefusal: Sendable, Equatable {
    /// The release gate does not qualify the requested count
    /// (`GuestReleaseShapePolicy`), independent of the image manifest.
    case releaseVCPUUnsupported(requested: Int, maximum: Int)
    /// The release allows it, but the verified image manifest does not PROVE
    /// SMP, so the pool would refuse the second hart.
    case imageDoesNotProveSMP(requested: Int)
    /// The release and the image allow it, but this build's run dispatch path
    /// cannot carry the request to the scheduler; enabling it here would boot
    /// a silently different shape.
    case dispatchNotShapeAware(requested: Int)

    /// English diagnostic detail for logs/evidence; UI surfaces localize the
    /// typed case instead.
    public var diagnosticDetail: String {
        switch self {
        case .releaseVCPUUnsupported(let requested, let maximum):
            return "this release supports at most \(maximum) guest core(s); \(requested) would be refused by the release gate"
        case .imageDoesNotProveSMP(let requested):
            return "the image manifest does not prove \(requested) harts; the image gate would refuse this count"
        case .dispatchNotShapeAware(let requested):
            return "the run dispatch path cannot deliver a typed \(requested)-hart request yet"
        }
    }
}

/// One selectable row of the shape control.
public struct GuestRunEntryShapeOption: Sendable, Equatable, Identifiable {
    public let selection: GuestRunEntryShapeSelection
    /// The vCPU count this option requests: the explicit count for the two
    /// explicit rows, and the advisory's planned count for `automatic`.
    public let requestedVCPUs: GuestVCPUCount
    /// nil when the option can be selected; the typed gate refusal otherwise.
    public let refusal: GuestRunEntryShapeRefusal?

    public init(
        selection: GuestRunEntryShapeSelection,
        requestedVCPUs: GuestVCPUCount,
        refusal: GuestRunEntryShapeRefusal? = nil
    ) {
        self.selection = selection
        self.requestedVCPUs = requestedVCPUs
        self.refusal = refusal
    }

    public var id: GuestRunEntryShapeSelection { selection }
    public var isAvailable: Bool { refusal == nil }
}

/// The resolved run-entry shape decision.
public struct GuestRunEntryShapePlan: Sendable, Equatable {
    /// Measured equal-work result behind the honest dual-core copy: the
    /// current engine passes the S0–S4 correctness contract, but the
    /// equal-work S5 benchmark on the verified SMP pair is SLOWER on two
    /// harts (cloud run 36009075837 medians 1.69 s on one hart vs 1.93 s on
    /// two; ratio 0.876× < 1.10×). The run entry may offer dual, but no UI or
    /// test may present it as a speedup. Replace only with a newer measured
    /// ratio from a completed cloud S5 rerun.
    public static let dualCoreMeasuredEqualWorkSpeedup = 0.876
    /// The user's current selection this plan resolved.
    public let selection: GuestRunEntryShapeSelection
    /// Every row of the control, including the refused ones.
    public let options: [GuestRunEntryShapeOption]
    /// The advisory recommendation the plan was built from.
    public let recommendation: GuestResourceRecommendation
    /// The request a wired dispatcher must send, or nil when the selection is
    /// refused. For `automatic` it may be one hart even though the advisory
    /// asked for two; `automaticDowngradedFromRecommendation` says so.
    public let effectiveRequest: GuestResourceRequest?
    /// How the pool must treat `effectiveRequest`: `.strict` for an explicit
    /// user selection (never silently reduced), `.authorized` with a one-hart
    /// floor for the automatic plan (the only recorded downgrade).
    public let downgrade: GuestShapeDowngradePolicy
    /// True when `automatic` planned two harts but this release can only
    /// deliver one; `refusal` then carries the gate that blocked two.
    public let automaticDowngradedFromRecommendation: Bool
    /// The typed refusal for the current selection, when it is refused.
    public let refusal: GuestRunEntryShapeRefusal?
    /// The largest vCPU count this release + image + dispatch path can
    /// deliver.
    public let maximumDeliverableVCPUs: GuestVCPUCount

    public init(
        selection: GuestRunEntryShapeSelection,
        options: [GuestRunEntryShapeOption],
        recommendation: GuestResourceRecommendation,
        effectiveRequest: GuestResourceRequest?,
        downgrade: GuestShapeDowngradePolicy,
        automaticDowngradedFromRecommendation: Bool,
        refusal: GuestRunEntryShapeRefusal?,
        maximumDeliverableVCPUs: GuestVCPUCount
    ) {
        self.selection = selection
        self.options = options
        self.recommendation = recommendation
        self.effectiveRequest = effectiveRequest
        self.downgrade = downgrade
        self.automaticDowngradedFromRecommendation = automaticDowngradedFromRecommendation
        self.refusal = refusal
        self.maximumDeliverableVCPUs = maximumDeliverableVCPUs
    }

    /// False when the selection is refused: the entry must not dispatch.
    /// `automatic` always resolves (possibly to a recorded single-hart
    /// downgrade), so it is always runnable.
    public var isRunnable: Bool { refusal == nil && effectiveRequest != nil }

    /// The vCPU count this selection would actually run, or nil when refused.
    public var effectiveVCPUs: GuestVCPUCount? { effectiveRequest?.vcpus }

    /// True when the automatic plan delivers exactly what the advisory asked.
    public var automaticDeliversRecommendation: Bool {
        !automaticDowngradedFromRecommendation
    }

    public func option(for selection: GuestRunEntryShapeSelection) -> GuestRunEntryShapeOption? {
        options.first { $0.selection == selection }
    }
}

/// Pure planner for the script-run entry control. No actor, no engine, no
/// scheduler state: the caller decides when to hand `effectiveRequest` +
/// `downgrade` to the guest start path.
public enum GuestRunEntryShapePlanner {
    /// Plans from declared workload signals using the shared deterministic
    /// advisory (same plan `GuestResourceAdvisory.recommend` starts from).
    public static func plan(
        selection: GuestRunEntryShapeSelection,
        signals: WorkloadResourceSignals,
        releasePolicy: GuestReleaseShapePolicy = .production,
        imageProvesSMP: Bool = false,
        imageMaximumVCPUs: Int? = nil,
        dispatch: GuestRunEntryShapeDispatch = .singleHartOnly,
        memoryFloor: GuestMemoryMiB = .m256
    ) -> GuestRunEntryShapePlan {
        plan(
            selection: selection,
            recommendation: GuestResourceAdvisory.plan(from: signals),
            releasePolicy: releasePolicy,
            imageProvesSMP: imageProvesSMP,
            imageMaximumVCPUs: imageMaximumVCPUs,
            dispatch: dispatch,
            memoryFloor: memoryFloor
        )
    }

    /// Plans from an already-computed recommendation (the app passes the
    /// shared actor's `recommend`, which applies user overrides and recorded
    /// outcomes). The vCPU decision itself is still gated here.
    public static func plan(
        selection: GuestRunEntryShapeSelection,
        recommendation: GuestResourceRecommendation,
        releasePolicy: GuestReleaseShapePolicy = .production,
        imageProvesSMP: Bool = false,
        imageMaximumVCPUs: Int? = nil,
        dispatch: GuestRunEntryShapeDispatch = .singleHartOnly,
        memoryFloor: GuestMemoryMiB = .m256
    ) -> GuestRunEntryShapePlan {
        let dualRefusal = dualRefusal(
            releasePolicy: releasePolicy, imageProvesSMP: imageProvesSMP, dispatch: dispatch
        )
        let tripleRefusal = tripleRefusal(
            releasePolicy: releasePolicy,
            imageProvesSMP: imageProvesSMP,
            imageMaximumVCPUs: imageMaximumVCPUs ?? (imageProvesSMP ? 2 : 1),
            dispatch: dispatch
        )
        let maximum: GuestVCPUCount = tripleRefusal == nil ? .three : (dualRefusal == nil ? .two : .one)
        let memory = recommendation.shape.memory

        let options = GuestRunEntryShapeSelection.allCases.map { candidate in
            GuestRunEntryShapeOption(
                selection: candidate,
                requestedVCPUs: candidate.explicitVCPUs ?? recommendation.shape.vcpus,
                refusal: candidate == .dualCore ? dualRefusal
                    : (candidate == .tripleCore ? tripleRefusal : nil)
            )
        }

        switch selection {
        case .automatic:
            // The advisory plan is honored only when every gate can deliver
            // it. A two-hart plan that cannot be delivered becomes a one-hart
            // RECOMMENDATION-origin request under an authorized floor, which
            // is exactly the branch RuntimeVMPool.admit records as an honest
            // downgrade for auto plans.
            let deliverable: GuestVCPUCount = maximum >= .two ? recommendation.shape.vcpus : .one
            let request = GuestResourceRequest(
                vcpus: deliverable, memory: memory, origin: .recommendation
            )
            return GuestRunEntryShapePlan(
                selection: selection,
                options: options,
                recommendation: recommendation,
                effectiveRequest: request,
                downgrade: .authorized(vcpuFloor: .one, memoryFloor: memoryFloor),
                automaticDowngradedFromRecommendation: recommendation.shape.vcpus == .two
                    && deliverable != .two,
                refusal: nil,
                maximumDeliverableVCPUs: maximum
            )

        case .singleCore:
            return GuestRunEntryShapePlan(
                selection: selection,
                options: options,
                recommendation: recommendation,
                effectiveRequest: GuestResourceRequest(
                    vcpus: .one, memory: memory, origin: .userSpecified
                ),
                downgrade: .strict,
                automaticDowngradedFromRecommendation: false,
                refusal: nil,
                maximumDeliverableVCPUs: maximum
            )

        case .dualCore:
            guard dualRefusal == nil else {
                // An explicit dual-core selection is refused, not reduced: no
                // effective request exists, so no dispatcher can start a
                // one-hart guest and label it as what the user chose.
                return GuestRunEntryShapePlan(
                    selection: selection,
                    options: options,
                    recommendation: recommendation,
                    effectiveRequest: nil,
                    downgrade: .strict,
                    automaticDowngradedFromRecommendation: false,
                    refusal: dualRefusal,
                    maximumDeliverableVCPUs: maximum
                )
            }
            return GuestRunEntryShapePlan(
                selection: selection,
                options: options,
                recommendation: recommendation,
                effectiveRequest: GuestResourceRequest(
                    vcpus: .two, memory: memory, origin: .userSpecified
                ),
                downgrade: .strict,
                automaticDowngradedFromRecommendation: false,
                refusal: nil,
                maximumDeliverableVCPUs: maximum
            )
        case .tripleCore:
            return GuestRunEntryShapePlan(
                selection: selection,
                options: options,
                recommendation: recommendation,
                effectiveRequest: tripleRefusal == nil ? GuestResourceRequest(
                    vcpus: .three, memory: memory, origin: .userSpecified
                ) : nil,
                downgrade: .strict,
                automaticDowngradedFromRecommendation: false,
                refusal: tripleRefusal,
                maximumDeliverableVCPUs: maximum
            )
        }
    }

    /// The first gate that refuses a second hart, in release → image →
    /// dispatch order. nil means dual is actually deliverable.
    private static func dualRefusal(
        releasePolicy: GuestReleaseShapePolicy,
        imageProvesSMP: Bool,
        dispatch: GuestRunEntryShapeDispatch
    ) -> GuestRunEntryShapeRefusal? {
        if !releasePolicy.supports(.two) {
            return .releaseVCPUUnsupported(requested: 2, maximum: releasePolicy.maximumSupportedVCPUs)
        }
        if !imageProvesSMP {
            return .imageDoesNotProveSMP(requested: 2)
        }
        if dispatch != .shapeAware {
            return .dispatchNotShapeAware(requested: 2)
        }
        return nil
    }

    private static func tripleRefusal(
        releasePolicy: GuestReleaseShapePolicy,
        imageProvesSMP: Bool,
        imageMaximumVCPUs: Int,
        dispatch: GuestRunEntryShapeDispatch
    ) -> GuestRunEntryShapeRefusal? {
        if !releasePolicy.supports(.three) {
            return .releaseVCPUUnsupported(requested: 3, maximum: releasePolicy.maximumSupportedVCPUs)
        }
        if !imageProvesSMP || imageMaximumVCPUs < 3 {
            return .imageDoesNotProveSMP(requested: 3)
        }
        if dispatch != .shapeAware {
            return .dispatchNotShapeAware(requested: 3)
        }
        return nil
    }
}

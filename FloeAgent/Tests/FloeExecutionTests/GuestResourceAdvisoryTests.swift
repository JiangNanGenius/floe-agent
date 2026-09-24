// FloeExecutionTests — ResourcePolicy: advisory recommendations and the
// script-run entry shape gate.
//
// The IDE run sheet offers Python/Node script runs an automatic / 1-core /
// 2-core choice. These tests pin the honest contract of that entry point and
// of the shared advisory it reuses:
//
//   * the automatic plan requests exactly the advisory's shape when the
//     release gate, the image SMP proof and the connected dispatch path all
//     allow it;
//   * when any of those gates refuses two harts, the automatic plan resolves
//     to one hart with a recorded, explicit reason — never a silent change;
//   * an EXPLICIT dual-core selection is refused outright (`effectiveRequest`
//     is nil) by a single-core release, a missing SMP proof or an unconnected
//     dispatch path; it never becomes a one-hart request, which is exactly the
//     branch `RuntimeVMPool.admit` throws on under `.strict`;
//   * a user override recorded in the advisory cannot bypass the release gate.
//
// No engine, pool or scheduler is started here: every decision is pure.

import Foundation
import XCTest
@testable import FloeExecution

final class GuestResourceAdvisoryTests: XCTestCase {

    private static let syntheticDualRelease = GuestReleaseShapePolicy.internalSyntheticTesting(
        maximumSupportedVCPUs: 2,
        provenance: "GuestResourceAdvisoryTests entry-shape gate"
    )

    /// Native build signals make the advisory plan two harts (`make` in the
    /// declared command set is the documented dual signal).
    private let parallelSignals = WorkloadResourceSignals(
        workloadKey: "ide-run:build.sh",
        declaredCommands: ["make"]
    )

    /// An ordinary Python script run: one hart, 512 MiB, no parallel claim.
    private let pythonSignals = WorkloadResourceSignals(
        workloadKey: "ide-run:scripts/main.py",
        declaredCommands: ["python3"]
    )

    // MARK: automatic

    func testAutomaticPlanRequestsTheAdvisoryShapeWhenEveryGateAllowsDual() {
        let plan = GuestRunEntryShapePlanner.plan(
            selection: .automatic,
            signals: parallelSignals,
            releasePolicy: Self.syntheticDualRelease,
            imageProvesSMP: true,
            dispatch: .shapeAware
        )
        XCTAssertEqual(plan.recommendation.shape.vcpus, .two)
        XCTAssertEqual(plan.effectiveRequest?.vcpus, .two)
        XCTAssertEqual(plan.effectiveRequest?.origin, .recommendation)
        XCTAssertEqual(plan.effectiveRequest?.memory, plan.recommendation.shape.memory)
        XCTAssertFalse(plan.automaticDowngradedFromRecommendation)
        XCTAssertTrue(plan.automaticDeliversRecommendation)
        XCTAssertTrue(plan.isRunnable)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.maximumDeliverableVCPUs, .two)
        // The pool's auto branch: an authorized single-hart floor, so only a
        // real shortage can be recorded as a downgrade — never a silent one.
        XCTAssertEqual(plan.downgrade, .authorized(vcpuFloor: .one, memoryFloor: .m256))
    }

    func testAutomaticPlanResolvesToOneHartWithTheReleaseReason() {
        let plan = GuestRunEntryShapePlanner.plan(
            selection: .automatic,
            signals: parallelSignals,
            releasePolicy: .production,
            imageProvesSMP: true,
            dispatch: .shapeAware
        )
        // The advisory really planned two harts; the entry refuses to claim
        // them and records the gate that blocked the request.
        XCTAssertEqual(plan.recommendation.shape.vcpus, .two)
        XCTAssertEqual(plan.effectiveRequest?.vcpus, .one)
        XCTAssertEqual(plan.effectiveRequest?.origin, .recommendation)
        XCTAssertEqual(plan.effectiveRequest?.memory, plan.recommendation.shape.memory)
        XCTAssertTrue(plan.automaticDowngradedFromRecommendation)
        XCTAssertFalse(plan.automaticDeliversRecommendation)
        XCTAssertTrue(plan.isRunnable, "an automatic plan always resolves to a deliverable shape")
        XCTAssertNil(plan.refusal, "the automatic selection itself is not refused")
        XCTAssertEqual(
            plan.option(for: .dualCore)?.refusal,
            .releaseVCPUUnsupported(requested: 2, maximum: 1)
        )
        XCTAssertEqual(plan.maximumDeliverableVCPUs, .one)
    }

    func testAutomaticPlanFollowsASingleHartRecommendation() {
        let plan = GuestRunEntryShapePlanner.plan(
            selection: .automatic,
            signals: pythonSignals,
            releasePolicy: .production
        )
        XCTAssertEqual(plan.recommendation.shape.vcpus, .one)
        XCTAssertEqual(plan.recommendation.shape.memory, .m512)
        XCTAssertEqual(plan.effectiveRequest?.vcpus, .one)
        XCTAssertEqual(plan.effectiveRequest?.origin, .recommendation)
        XCTAssertFalse(plan.automaticDowngradedFromRecommendation)
        XCTAssertTrue(plan.automaticDeliversRecommendation)
        XCTAssertTrue(plan.isRunnable)
    }

    // MARK: explicit shapes

    func testExplicitDualIsRefusedByTheReleaseGateAndNeverBecomesOneHart() {
        let plan = GuestRunEntryShapePlanner.plan(
            selection: .dualCore,
            signals: parallelSignals,
            releasePolicy: .production,
            imageProvesSMP: true,
            dispatch: .shapeAware
        )
        XCTAssertEqual(plan.refusal, .releaseVCPUUnsupported(requested: 2, maximum: 1))
        XCTAssertNil(plan.effectiveRequest, "an explicit dual request must never resolve to one hart")
        XCTAssertFalse(plan.isRunnable)
        XCTAssertEqual(plan.downgrade, .strict)
        XCTAssertEqual(plan.option(for: .dualCore)?.isAvailable, false)
    }

    func testExplicitDualRequiresTheImageSMPProof() {
        let plan = GuestRunEntryShapePlanner.plan(
            selection: .dualCore,
            signals: parallelSignals,
            releasePolicy: Self.syntheticDualRelease,
            imageProvesSMP: false,
            dispatch: .shapeAware
        )
        XCTAssertEqual(plan.refusal, .imageDoesNotProveSMP(requested: 2))
        XCTAssertNil(plan.effectiveRequest)
        XCTAssertFalse(plan.isRunnable)
    }

    func testExplicitDualRequiresAConnectedShapeDispatchPath() {
        let plan = GuestRunEntryShapePlanner.plan(
            selection: .dualCore,
            signals: parallelSignals,
            releasePolicy: Self.syntheticDualRelease,
            imageProvesSMP: true,
            // Default: the run dispatch path cannot carry a typed request, so
            // enabling dual here would boot a silently different machine.
            dispatch: .singleHartOnly
        )
        XCTAssertEqual(plan.refusal, .dispatchNotShapeAware(requested: 2))
        XCTAssertNil(plan.effectiveRequest)
        XCTAssertFalse(plan.isRunnable)
    }

    func testExplicitDualRunsWhenEveryGateAllowsIt() {
        let plan = GuestRunEntryShapePlanner.plan(
            selection: .dualCore,
            signals: parallelSignals,
            releasePolicy: Self.syntheticDualRelease,
            imageProvesSMP: true,
            dispatch: .shapeAware
        )
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.effectiveRequest?.vcpus, .two)
        XCTAssertEqual(plan.effectiveRequest?.origin, .userSpecified)
        XCTAssertEqual(plan.downgrade, .strict)
        XCTAssertTrue(plan.isRunnable)
        XCTAssertEqual(plan.maximumDeliverableVCPUs, .two)
    }

    func testExplicitSingleIsStrictAndKeepsTheAdvisoryMemory() {
        let plan = GuestRunEntryShapePlanner.plan(
            selection: .singleCore,
            signals: pythonSignals,
            releasePolicy: .production
        )
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.effectiveRequest?.vcpus, .one)
        XCTAssertEqual(plan.effectiveRequest?.origin, .userSpecified)
        XCTAssertEqual(plan.effectiveRequest?.memory, .m512)
        XCTAssertEqual(plan.downgrade, .strict)
        XCTAssertTrue(plan.isRunnable)
    }

    func testEverySelectionIsAlwaysListed() {
        let plan = GuestRunEntryShapePlanner.plan(
            selection: .automatic,
            signals: pythonSignals,
            releasePolicy: .production
        )
        XCTAssertEqual(
            plan.options.map(\.selection),
            [.automatic, .singleCore, .dualCore]
        )
        XCTAssertEqual(plan.option(for: .automatic)?.isAvailable, true)
        XCTAssertEqual(plan.option(for: .singleCore)?.isAvailable, true)
        // The refused row carries its reason instead of disappearing.
        XCTAssertEqual(
            plan.option(for: .dualCore)?.refusal,
            .releaseVCPUUnsupported(requested: 2, maximum: 1)
        )
    }

    // MARK: advisory integration (overrides cannot bypass the gate)

    func testAdvisoryOverrideCannotBypassTheReleaseGate() async {
        let advisory = GuestResourceAdvisory()
        await advisory.setUserOverride(
            GuestResourceRequest(vcpus: .two, memory: .m1024, origin: .userSpecified),
            for: pythonSignals.workloadKey
        )
        let recommendation = await advisory.recommend(pythonSignals)
        XCTAssertTrue(recommendation.userOverride)
        XCTAssertEqual(recommendation.shape.vcpus, .two)

        // The entry honors the override as a recommendation, but the release
        // gate still caps the deliverable shape at one hart; the explicit dual
        // row stays refused.
        let automatic = GuestRunEntryShapePlanner.plan(
            selection: .automatic,
            recommendation: recommendation,
            releasePolicy: .production
        )
        XCTAssertEqual(automatic.effectiveRequest?.vcpus, .one)
        XCTAssertEqual(automatic.effectiveRequest?.memory, .m1024)
        XCTAssertTrue(automatic.automaticDowngradedFromRecommendation)

        let explicit = GuestRunEntryShapePlanner.plan(
            selection: .dualCore,
            recommendation: recommendation,
            releasePolicy: .production
        )
        XCTAssertNil(explicit.effectiveRequest)
        XCTAssertEqual(explicit.refusal, .releaseVCPUUnsupported(requested: 2, maximum: 1))
    }

    func testAdvisoryPlansDualForDeclaredParallelSignals() async {
        let advisory = GuestResourceAdvisory()
        let recommendation = await advisory.recommend(parallelSignals)
        XCTAssertEqual(recommendation.shape.vcpus, .two)
        XCTAssertEqual(recommendation.shape.memory, .m768)
        XCTAssertTrue(recommendation.evidenceSignals.contains("declared native build command"))
    }
}

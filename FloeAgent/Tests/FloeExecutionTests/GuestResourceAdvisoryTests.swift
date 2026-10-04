// FloeExecutionTests — ResourcePolicy: advisory recommendations and the
// script-run entry shape gate.
//
// The IDE run sheet offers Python/Node script runs an automatic / 1-core /
// 2- or 3-core choice. These tests pin the honest contract of that entry point and
// of the shared advisory it reuses:
//
//   * the automatic plan requests exactly the advisory's shape when the
//     release policy, the image SMP proof and the connected dispatch path all
//     allow it;
//   * when any of those gates refuses two harts, the automatic plan resolves
//     to one hart with a recorded, explicit reason — never a silent change;
//   * an EXPLICIT dual-core selection is refused outright (`effectiveRequest`
//     is nil) when the release ceiling, the missing SMP proof or an
//     unconnected dispatch path blocks it; it never becomes a one-hart
//     request, which is exactly the branch `RuntimeVMPool.admit` throws on
//     under `.strict`;
//   * a user override recorded in the advisory cannot bypass the gates.
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

    func testAutomaticPlanDeliversTwoHartsUnderProductionWhenTheImageProvesSMP() {
        let plan = GuestRunEntryShapePlanner.plan(
            selection: .automatic,
            signals: parallelSignals,
            releasePolicy: .production,
            imageProvesSMP: true,
            dispatch: .shapeAware
        )
        // The advisory planned two harts AND the released policy + verified
        // image + shape-aware dispatch all allow them: no downgrade is
        // invented and the option is selectable.
        XCTAssertEqual(plan.recommendation.shape.vcpus, .two)
        XCTAssertEqual(plan.effectiveRequest?.vcpus, .two)
        XCTAssertEqual(plan.effectiveRequest?.origin, .recommendation)
        XCTAssertFalse(plan.automaticDowngradedFromRecommendation)
        XCTAssertTrue(plan.automaticDeliversRecommendation)
        XCTAssertTrue(plan.isRunnable)
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.maximumDeliverableVCPUs, .two)
        XCTAssertNil(plan.option(for: .dualCore)?.refusal)
        XCTAssertTrue(plan.option(for: .dualCore)?.isAvailable == true)
    }

    func testAutomaticPlanResolvesToOneHartWhenTheImageDoesNotProveSMP() {
        let plan = GuestRunEntryShapePlanner.plan(
            selection: .automatic,
            signals: parallelSignals,
            releasePolicy: .production,
            imageProvesSMP: false,
            dispatch: .shapeAware
        )
        // The advisory really planned two harts; the image gate refuses to
        // claim them and records the gate that blocked the request.
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
            .imageDoesNotProveSMP(requested: 2)
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

    func testExplicitDualIsDeliveredUnderProductionWithAVerifiedSMPImage() {
        let plan = GuestRunEntryShapePlanner.plan(
            selection: .dualCore,
            signals: parallelSignals,
            releasePolicy: .production,
            imageProvesSMP: true,
            dispatch: .shapeAware
        )
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.effectiveRequest?.vcpus, .two)
        XCTAssertEqual(plan.effectiveRequest?.origin, .userSpecified)
        XCTAssertEqual(plan.downgrade, .strict)
        XCTAssertTrue(plan.isRunnable)
        XCTAssertTrue(plan.option(for: .dualCore)?.isAvailable == true)
    }

    func testExplicitTripleRequiresThreeCoreImageAndShapeAwareDispatch() {
        let policy = GuestReleaseShapePolicy.internalSyntheticTesting(
            maximumSupportedVCPUs: 3, provenance: "triple planner gate"
        )
        let oldImage = GuestRunEntryShapePlanner.plan(
            selection: .tripleCore, signals: parallelSignals,
            releasePolicy: policy, imageProvesSMP: true,
            imageMaximumVCPUs: 2, dispatch: .shapeAware
        )
        XCTAssertEqual(oldImage.refusal, .imageDoesNotProveSMP(requested: 3))
        XCTAssertNil(oldImage.effectiveRequest)

        let proven = GuestRunEntryShapePlanner.plan(
            selection: .tripleCore, signals: parallelSignals,
            releasePolicy: policy, imageProvesSMP: true,
            imageMaximumVCPUs: 3, dispatch: .shapeAware
        )
        XCTAssertEqual(proven.effectiveRequest?.vcpus, .three)
        XCTAssertEqual(proven.maximumDeliverableVCPUs, .three)
        XCTAssertTrue(proven.isRunnable)
    }

    func testExplicitDualIsRefusedWhenTheImageDoesNotProveSMPAndNeverBecomesOneHart() {
        let plan = GuestRunEntryShapePlanner.plan(
            selection: .dualCore,
            signals: parallelSignals,
            releasePolicy: .production,
            imageProvesSMP: false,
            dispatch: .shapeAware
        )
        XCTAssertEqual(plan.refusal, .imageDoesNotProveSMP(requested: 2))
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

    func testExplicitDualRunsUnderProductionWhenEveryGateAllowsIt() {
        let plan = GuestRunEntryShapePlanner.plan(
            selection: .dualCore,
            signals: parallelSignals,
            releasePolicy: .production,
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
            [.automatic, .singleCore, .dualCore, .tripleCore]
        )
        XCTAssertEqual(plan.option(for: .automatic)?.isAvailable, true)
        XCTAssertEqual(plan.option(for: .singleCore)?.isAvailable, true)
        // The refused row carries its reason instead of disappearing. With no
        // image SMP proof (the default) the image gate is the first refusal.
        XCTAssertEqual(
            plan.option(for: .dualCore)?.refusal,
            .imageDoesNotProveSMP(requested: 2)
        )
    }

    // MARK: advisory integration (overrides cannot bypass the gate)

    func testAdvisoryOverrideCannotBypassTheGates() async {
        let advisory = GuestResourceAdvisory()
        await advisory.setUserOverride(
            GuestResourceRequest(vcpus: .two, memory: .m1024, origin: .userSpecified),
            for: pythonSignals.workloadKey
        )
        let recommendation = await advisory.recommend(pythonSignals)
        XCTAssertTrue(recommendation.userOverride)
        XCTAssertEqual(recommendation.shape.vcpus, .two)

        // The entry honors the override as a recommendation, but the image
        // gate (no SMP proof here) caps the deliverable shape at one hart; the
        // explicit dual row stays refused.
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
        XCTAssertEqual(explicit.refusal, .imageDoesNotProveSMP(requested: 2))
    }

    // MARK: release policy

    func testProductionPolicyQualifiesThreeHartsAndStillDefaultsToOne() throws {
        XCTAssertEqual(GuestReleaseShapePolicy.production.maximumSupportedVCPUs, 3)
        // The worker default is unchanged: no explicit request ⇒ one hart.
        XCTAssertEqual(try GuestReleaseShapePolicy.production.resolve(requestedVCPUs: nil), .one)
        XCTAssertEqual(try GuestReleaseShapePolicy.production.resolve(requestedVCPUs: 1), .one)
        XCTAssertEqual(try GuestReleaseShapePolicy.production.resolve(requestedVCPUs: 2), .two)
        XCTAssertEqual(try GuestReleaseShapePolicy.production.resolve(requestedVCPUs: 3), .three)
        XCTAssertThrowsError(try GuestReleaseShapePolicy.production.resolve(requestedVCPUs: 6)) {
            guard case .invalidVCPUCount = $0 as? GuestReleaseShapeError else {
                return XCTFail("six must be invalid, not clamped: \($0)")
            }
        }
    }

    func testAdvisoryPlansDualForDeclaredParallelSignals() async {
        let advisory = GuestResourceAdvisory()
        let recommendation = await advisory.recommend(parallelSignals)
        XCTAssertEqual(recommendation.shape.vcpus, .two)
        XCTAssertEqual(recommendation.shape.memory, .m768)
        XCTAssertTrue(recommendation.evidenceSignals.contains("declared native build command"))
    }
}

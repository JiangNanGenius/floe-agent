// FloeExecution — ResourcePolicy: pure admission decision logic.
//
// SPDX-License-Identifier: MPL-2.0
//
// The pool's actor owns state and queuing; the actual decision is a pure
// function here so every edge (fit, shortage queue, explicit downgrade,
// floor refusal) is testable deterministically with no concurrency.
//
// Rules, aligned for CPU and RAM:
//  * Admission is simultaneous: VM slot AND vCPU AND RAM must all accept.
//  * `.strict` shortage (temporary, quota/headroom bound) QUEUES — a guest
//    is never silently booted at fewer vCPUs or less RAM than requested.
//  * `.authorized` shortage may grant a smaller shape, but only a ladder
//    step at or above the caller's floors; when even the floor does not
//    fit, the request still queues.

import Foundation

/// A pure admission decision.
public enum GuestResourceAdmissionDecision: Sendable, Equatable {
    /// Admit now with exactly this shape; flags report honest downgrades.
    case admitted(
        shape: GuestResourceRequest,
        vcpusDowngraded: Bool,
        memoryDowngraded: Bool,
        vcpusDowngradeReason: String?,
        memoryDowngradeReason: String?
    )
    /// Nothing admissible at this instant under the declared policy; the
    /// request must queue (the shortage is temporary).
    case queued
}

public enum GuestResourceAdmission {
    /// True when NO pool usage can EVER satisfy the request under the
    /// declared policy — the pool's own immutable total is below the
    /// request's minimum acceptable shape. This is a permanent profile
    /// mismatch (e.g. a dual-hart guest on a one-vCPU quota, or 2 GiB on a
    /// 512 MiB pool) and must be reported as an actionable error instead of
    /// queueing forever.
    ///
    /// The minimum acceptable shape is the request itself under `.strict`;
    /// under `.authorized` it is whichever is lower between the request and
    /// the caller's declared floors.
    public static func isPermanentlyUnsatisfiable(
        request: GuestResourceRequest,
        quota: GuestResourceQuota,
        downgrade: GuestShapeDowngradePolicy
    ) -> Bool {
        let minimumVCPUs: Int
        let minimumMemory: GuestMemoryMiB
        switch downgrade {
        case .strict:
            minimumVCPUs = request.vcpus.count
            minimumMemory = request.memory
        case .authorized(let vcpuFloor, let memoryFloor):
            minimumVCPUs = min(request.vcpus.count, vcpuFloor.count)
            minimumMemory = min(request.memory, memoryFloor)
        }
        if minimumVCPUs > quota.totalVCPUs { return true }
        if minimumMemory.mb > quota.totalMemoryMiB { return true }
        return false
    }

    /// Evaluates a request against the current pool usage and quota.
    public static func evaluate(
        request: GuestResourceRequest,
        runningVMs: Int,
        usedVCPUs: Int,
        usedMemoryMiB: Int,
        quota: GuestResourceQuota,
        downgrade: GuestShapeDowngradePolicy = .strict
    ) -> GuestResourceAdmissionDecision {
        // VM count is the first gate: no VM slot ⇒ queue, regardless of
        // headroom in the other dimensions.
        guard quota.hasRoomForVM(runningVMs: runningVMs) else { return .queued }

        // MARK: memory

        let grantedMemory: GuestMemoryMiB
        let memoryDowngraded: Bool
        let memoryReason: String?
        if quota.memoryFits(usedMemoryMiB: usedMemoryMiB, adding: request.memory.mb) {
            grantedMemory = request.memory
            memoryDowngraded = false
            memoryReason = nil
        } else {
            // Temporary shortage. Strict requests queue; authorized
            // requests take the highest ladder step that fits and stays
            // within [memoryFloor, requested).
            guard case .authorized(_, let memoryFloor) = downgrade,
                  request.memory > memoryFloor else {
                return .queued
            }
            let availableMiB = quota.totalMemoryMiB - usedMemoryMiB
            guard let step = GuestMemoryMiB.largestAtOrBelow(availableMiB),
                  step >= memoryFloor, step < request.memory else {
                return .queued
            }
            grantedMemory = step
            memoryDowngraded = true
            memoryReason = "requested \(request.memory.mb) MiB but only \(step.mb) MiB fit alongside running guests; the caller authorized a downgrade"
        }

        // MARK: vCPUs

        if quota.vcpusFit(usedVCPUs: usedVCPUs, adding: request.vcpus.count) {
            return .admitted(
                shape: GuestResourceRequest(
                    vcpus: request.vcpus, memory: grantedMemory, origin: request.origin
                ),
                vcpusDowngraded: false,
                memoryDowngraded: memoryDowngraded,
                vcpusDowngradeReason: nil,
                memoryDowngradeReason: memoryReason
            )
        }

        // Temporary vCPU shortage. Strict requests queue; authorized
        // requests may drop to the declared vCPU floor when it fits.
        guard case .authorized(let vcpuFloor, _) = downgrade,
              request.vcpus > vcpuFloor,
              quota.vcpusFit(usedVCPUs: usedVCPUs, adding: vcpuFloor.count) else {
            return .queued
        }
        return .admitted(
            shape: GuestResourceRequest(
                vcpus: vcpuFloor, memory: grantedMemory, origin: request.origin
            ),
            vcpusDowngraded: true,
            memoryDowngraded: memoryDowngraded,
            vcpusDowngradeReason: "requested \(request.vcpus.count) vCPUs but only \(vcpuFloor.count) fit the pool quota; the caller authorized a downgrade",
            memoryDowngradeReason: memoryReason
        )
    }
}

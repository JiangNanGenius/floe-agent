// SPDX-License-Identifier: MPL-2.0
//
// Typed stop-settlement projection for the trusted host. Two consumers:
//
//   * `run.cancel` accepted detail — identifier/reason strings only (the
//     frozen RB1 detail carrier): `settled` is `"true"` ONLY when the native
//     authority appended a valid settlement bound to the CURRENT incarnation;
//   * `run.snapshot.stopSettlement` — the cold/hot typed read-back object for
//     hosts that only refresh a snapshot.
//
// Neither path derives a stop from `null`, from the localized checkpoint
// reason, or from the last N events. The durable settlement row is decoded
// and re-verified by `RunStopSettlementReading`; a missing/invalid/historical
// settlement is reported explicitly as `settled:false`.

import Foundation
import FloeCore
import FloeModels
import FloePersistence

/// One bounded accepted `run.cancel` projection. It is not a wire page (the
/// existing accepted detail map already carries closed identifiers/reasons),
/// and no field here is inferred from UI text.
struct RunCancelPresentation {
    var cancel: String
    var settled: Bool
    var settlement: RunStopSettlement?
    var reason: String?
    var pendingJobs: Int?
    var durableState: String
    var attemptID: UUID

    func detail(runID: UUID, ownerPhase: String,
                liveProducer: Bool) -> [String: String] {
        let currentOwnerPresent = ownerPhase != "none" || liveProducer
        // A parked dependency Stop requests cooperative cancellation of
        // jobs; the settlement row alone cannot prove their termination.
        let jobsUnverified = settlement?.path == .parkedDependency
        let currentlySettled = settled && !currentOwnerPresent && !jobsUnverified
        var value: [String: String] = [
            "cancel": settled && !currentlySettled ? "requested" : cancel,
            "settled": currentlySettled ? "true" : "false",
            "stopAttemptID": attemptID.uuidString.lowercased(),
            "durableState": durableState,
            "resourceID": RunWireRevision.runResourceID(runID),
            "revisionVersion": RunWireRevision.runVersion(state: durableState),
            "ownerPhase": ownerPhase,
            "liveProducer": liveProducer ? "true" : "false",
        ]
        if let pendingJobs { value["pendingJobs"] = String(pendingJobs) }
        if let reason { value["reason"] = reason }
        if let settlement, currentlySettled {
            value["settlementSchema"] = RunStopSettlementVocabulary.settlementSchema
            value["settlementID"] = settlement.settlementID.uuidString.lowercased()
            value["settledAt"] = settlement.settledAt
            value["path"] = settlement.path.rawValue
            value["reasonKey"] = settlement.reasonKey
            value["expectedState"] = settlement.expectedState
            value["ownerAbsent"] = settlement.ownerAbsent ? "true" : "false"
            value["incarnation"] = settlement.incarnation.proof
            value["incarnationSource"] = settlement.incarnation.source.rawValue
            value["incarnationEventID"] =
                settlement.incarnation.eventID.uuidString.lowercased()
            value["incarnationSequence"] =
                String(settlement.incarnation.sequence)
            value["settlementDigest"] = settlement.settlementDigest
        }
        return value
    }
}

/// Ownership and native generation at one actor-isolated instant. A stamp
/// change across a suspended storage read invalidates the whole observation,
/// including the no-owner -> owner -> no-owner ABA case.
struct RunStopOwnershipObservation: Sendable {
    var ownerPresent: Bool
    var ownerPhase: String
    var liveProducer: Bool
    var stamp: UInt64?
    var rootEpoch: UInt64?
    var expectedEpoch: UInt64
    var retiring: Bool

    func isStable(through newer: Self) -> Bool {
        guard !retiring, !newer.retiring,
              let stamp, let nextStamp = newer.stamp,
              let rootEpoch, let nextEpoch = newer.rootEpoch else { return false }
        return stamp == nextStamp && rootEpoch == expectedEpoch
            && nextEpoch == newer.expectedEpoch && rootEpoch == nextEpoch
            && expectedEpoch == newer.expectedEpoch
            && ownerPresent == newer.ownerPresent
            && ownerPhase == newer.ownerPhase
            && liveProducer == newer.liveProducer
    }
}

enum RunStopSettlementWire {
    static func readback(store: any RunStore, runID: UUID,
                         conversationID: UUID) async
        -> RunStopSettlementReadback? {
        guard let reader = store as? any RunStopSettlementReading else {
            return nil
        }
        return try? await reader.latestStopSettlement(
            runID: runID, conversationID: conversationID)
    }

    /// Explicit typed object. Absence is never implied by a missing key:
    /// `settled:false` plus a closed machine reason is always emitted.
    static func snapshotValue(_ readback: RunStopSettlementReadback?,
                              currentOwnerPresent: Bool,
                              currentOwnerPhase: String,
                              currentLiveProducer: Bool,
                              ownershipVerified: Bool = true)
        -> SettingsDomainV1.JSONValue {
        var members: [String: SettingsDomainV1.JSONValue] = [
            "schema": .string(RunStopSettlementVocabulary.settlementSchema),
            "settled": .boolean(ownershipVerified && readback?.isSettled == true && !currentOwnerPresent
                                && readback?.settlement?.path != .parkedDependency),
            "currentOwnerPhase": .string(ownershipVerified ? currentOwnerPhase : "unknown"),
            "currentLiveProducer": ownershipVerified ? .boolean(currentLiveProducer) : .null,
            "currentIncarnation": .boolean(
                readback?.isCurrentIncarnation == true),
        ]
        if let readback {
            members["durableState"] = .string(readback.runState)
            if let settlement = readback.settlement {
                members["settlementID"] =
                    .string(settlement.settlementID.uuidString.lowercased())
                members["settledAt"] = .string(settlement.settledAt)
                members["path"] = .string(settlement.path.rawValue)
                members["reasonKey"] = .string(settlement.reasonKey)
                members["expectedState"] =
                    .string(settlement.expectedState)
                members["ownerAbsent"] = ownershipVerified
                    ? .boolean(!currentOwnerPresent) : .null
                members["incarnation"] =
                    .string(settlement.incarnation.proof)
                members["incarnationSource"] =
                    .string(settlement.incarnation.source.rawValue)
                members["incarnationEventID"] = .string(
                    settlement.incarnation.eventID.uuidString.lowercased())
                members["incarnationSequence"] =
                    .integer(Int64(settlement.incarnation.sequence))
                members["settlementDigest"] =
                    .string(settlement.settlementDigest)
                if !ownershipVerified {
                    members["reason"] = .string("ownershipUnverified")
                } else if currentOwnerPresent {
                    members["reason"] = .string("ownerActive")
                } else if settlement.path == .parkedDependency {
                    members["reason"] = .string("jobsUnverified")
                } else if !readback.isSettled {
                    members["reason"] = .string(
                        readback.isCurrentIncarnation
                            ? "notCheckpointed"
                            : "historicalIncarnation")
                }
            } else if !readback.isValid {
                members["reason"] = .string("invalidProof")
            } else {
                members["reason"] = .string("none")
            }
        } else {
            members["reason"] = .string("unavailable")
        }
        return .object(members)
    }
}

extension FacadeRunDomain {
    /// A service-less admission or terminating owner is still an owner.
    /// This must be called after the durable stop read, not inferred from the
    /// historical ownerAbsent bit in the settlement row.
    func currentStopOwnership(runID: UUID) -> RunStopOwnershipObservation {
        let producer = liveServices[runID] != nil
        return RunStopOwnershipObservation(
            ownerPresent: owners[runID] != nil || producer,
            ownerPhase: owners[runID]?.phase.rawValue ?? "none",
            liveProducer: producer, stamp: stopOwnershipStamp(runID: runID),
            rootEpoch: G02NativeRootEpoch.readback(), expectedEpoch: epoch,
            retiring: retirementFenced)
    }
    /// The run's OWN settlement store. Ordinary runs use the durable SQLite
    /// store (which conforms); a temporary RAM store structurally cannot, so
    /// it answers nil and never mints durable proof.
    func runStopSettlementStore(runID: UUID, conversationID: UUID) async
        -> (any RunStopSettlementWriting)? {
        let store: any RunStore
        if let bundle = owners[runID]?.bundle {
            store = bundle.runs
        } else if let route = await TemporaryLiveRouting.route(
            epoch: epoch, conversationID: conversationID) {
            store = route.stores.runs
        } else {
            store = durable.runs
        }
        return store as? any RunStopSettlementWriting
    }

    func runStopIdentity(runID: UUID, conversationID: UUID) async
        -> RunStopIdentitySnapshot? {
        guard let store = await runStopSettlementStore(
            runID: runID, conversationID: conversationID) else { return nil }
        return try? await store.stopIdentity(
            runID: runID, conversationID: conversationID)
    }

    func runStopReadback(runID: UUID, conversationID: UUID) async
        -> RunStopSettlementReadback? {
        let store: any RunStore
        if let bundle = owners[runID]?.bundle {
            store = bundle.runs
        } else if let route = await TemporaryLiveRouting.route(
            epoch: epoch, conversationID: conversationID) {
            store = route.stores.runs
        } else {
            store = durable.runs
        }
        return await RunStopSettlementWire.readback(
            store: store, runID: runID, conversationID: conversationID)
    }

    func runCancelLiveProducer(runID: UUID) -> Bool {
        liveServices[runID] != nil
    }

    func runCancelOwnerPhase(runID: UUID) -> String {
        owners[runID]?.phase.rawValue ?? "none"
    }
}

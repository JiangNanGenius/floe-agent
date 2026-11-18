// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import FloeMacSelfCore

private enum SimulatedShutdownFailure: Error {
    case unavailable
}

@Suite("Mac self-core test fixture cleanup")
struct FixtureCleanupTests {
    private func receipt(
        alreadyClosed: Bool = false,
        databaseClosed: Bool = true,
        preservedRunIDs: [UUID] = [],
        retainedAdmissions: [UUID] = [],
        inventoryAvailable: Bool = true
    ) -> FloeMacSelfShutdownReceipt {
        FloeMacSelfShutdownReceipt(
            closedSessionCount: 0,
            preservedRunIDs: preservedRunIDs,
            databaseClosed: databaseClosed,
            alreadyClosed: alreadyClosed,
            retainedAdmissionConversationIDs: retainedAdmissions,
            admissionInventoryAvailable: inventoryAvailable
        )
    }

    @Test("A valid original receipt remains authoritative after already-closed summaries")
    func validOriginalReceiptSurvivesAlreadyClosed() {
        var evidence = SelfCoreShutdownEvidence()
        let original = receipt()
        let summary = receipt(alreadyClosed: true)
        evidence.record(original)
        evidence.record(summary)
        #expect(evidence.original == original)
        #expect(evidence.permitsCleanup(current: summary))
    }

    @Test("Unknown prior receipts cannot be replaced by an empty already-closed summary")
    func invalidOriginalCannotBeOverwritten() {
        let badReceipts = [
            receipt(databaseClosed: false),
            receipt(preservedRunIDs: [UUID()]),
            receipt(retainedAdmissions: [UUID()]),
            receipt(inventoryAvailable: false)
        ]
        let summary = receipt(alreadyClosed: true)
        for original in badReceipts {
            var evidence = SelfCoreShutdownEvidence()
            evidence.record(original)
            evidence.record(summary)
            #expect(evidence.original == original)
            #expect(!evidence.permitsCleanup(current: summary))
        }
        var missing = SelfCoreShutdownEvidence()
        missing.record(summary)
        #expect(!missing.permitsCleanup(current: summary))
    }

    @Test("A shutdown failure invalidates even a later complete receipt")
    func failureRetainsFixtureEvenAfterSuccess() {
        var evidence = SelfCoreShutdownEvidence()
        evidence.recordFailure()
        evidence.record(receipt())
        #expect(!evidence.permitsCleanup(current: receipt(alreadyClosed: true)))
    }

    @Test("A failed shutdown preserves the fixture and reports its path")
    func shutdownFailureRetainsDatabase() async throws {
        try await withSelfCoreFixture { fixture in
            do {
                try await fixture.disposeAfterShutdown { throw SimulatedShutdownFailure.unavailable }
                Issue.record("A failed shutdown must not remove the fixture")
            } catch let error as SelfCoreFixtureCleanupError {
                #expect(error.root == fixture.root)
                #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
            } catch {
                Issue.record("Expected fixture cleanup error, got \(error)")
            }
        }
    }

    @Test("A residual admission inventory retains the fixture instead of deleting evidence")
    func residualAdmissionRetainsFixture() async throws {
        try await withSelfCoreFixture { fixture in
            let receipt = FloeMacSelfShutdownReceipt(
                closedSessionCount: 0,
                preservedRunIDs: [],
                databaseClosed: true,
                alreadyClosed: false,
                retainedAdmissionConversationIDs: [UUID()],
                admissionInventoryAvailable: true
            )
            do {
                try await fixture.disposeAfterShutdown { receipt }
                Issue.record("A residual admission must retain the fixture")
            } catch is SelfCoreFixtureCleanupError {
                #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
            } catch {
                Issue.record("Expected fixture cleanup error, got \(error)")
            }
        }
    }

    @Test("An unavailable admission inventory also retains the fixture")
    func unavailableInventoryRetainsFixture() async throws {
        try await withSelfCoreFixture { fixture in
            let receipt = FloeMacSelfShutdownReceipt(
                closedSessionCount: 0,
                preservedRunIDs: [],
                databaseClosed: true,
                alreadyClosed: false,
                retainedAdmissionConversationIDs: [],
                admissionInventoryAvailable: false
            )
            do {
                try await fixture.disposeAfterShutdown { receipt }
                Issue.record("An unavailable admission inventory must retain the fixture")
            } catch is SelfCoreFixtureCleanupError {
                #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
            } catch {
                Issue.record("Expected fixture cleanup error, got \(error)")
            }
        }
    }

    @Test("An unconfirmed or previously closed result retains the fixture")
    func unknownClosureRetainsDatabase() async throws {
        try await withSelfCoreFixture { fixture in
            let receipts = [
                FloeMacSelfShutdownReceipt(
                    closedSessionCount: 0, preservedRunIDs: [UUID()],
                    databaseClosed: true, alreadyClosed: false,
                    retainedAdmissionConversationIDs: [],
                    admissionInventoryAvailable: true
                ),
                FloeMacSelfShutdownReceipt(
                    closedSessionCount: 0, preservedRunIDs: [],
                    databaseClosed: true, alreadyClosed: true,
                    retainedAdmissionConversationIDs: [],
                    admissionInventoryAvailable: true
                )
            ]
            for receipt in receipts {
                do {
                    try await fixture.disposeAfterShutdown { receipt }
                    Issue.record("Unconfirmed shutdown must not remove the fixture")
                } catch is SelfCoreFixtureCleanupError {
                    #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
                } catch {
                    Issue.record("Expected fixture cleanup error, got \(error)")
                }
            }
        }
    }
}

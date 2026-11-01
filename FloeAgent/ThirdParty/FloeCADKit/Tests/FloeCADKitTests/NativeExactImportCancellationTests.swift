//
//  NativeExactImportCancellationTests.swift
//  FloeCADKitTests
//
//  E31-R3 kernel qualification for the QUEUED exact-import waiter:
//
//    * one exact parse (the owner) holds the real OCCT reader section at a
//      real prepared-body/pre-reader checkpoint;
//    * a second exact parse queues behind it and is cancelled;
//    * the cancelled waiter must leave the queue and report `cancelled` WHILE
//      the owner still holds the parser, and must never invoke its own OCCT
//      reader (STEPKit.solids / OCCTKernel.readIGES) — no "locked"/"read"
//      checkpoint for the waiter at all;
//    * the owner still completes normally afterwards;
//    * the legacy synchronous entry keeps its non-blocking `import_busy`
//      refusal instead of waiting for the owner (the MainActor must never
//      block behind a worker).
//
//  The fixtures are written by the production STEP/IGES writers; the parsers
//  are the real ones. Nothing here stubs a reader or a document command.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

#if DEBUG
@MainActor
final class NativeExactImportCancellationTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeExactCancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        CADExactImportService.testCheckpoint = nil
        CADExactImportService.testResetPeakConcurrentParsers()
    }

    override func tearDown() async throws {
        CADExactImportService.testCheckpoint = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Real fixtures

    private func boxHandle(_ size: Double) throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: size, depth: size, height: size), placement: .identity),
            "the kernel must build the real box fixture")
    }

    private func oneSolidSTEP() throws -> Data {
        let box = try boxHandle(20)
        let url = workDir.appendingPathComponent("one-solid-\(UUID().uuidString).step")
        XCTAssertTrue(OCCTKernel.writeSTEP([box], to: url))
        return try Data(contentsOf: url)
    }

    private func twoSolidSTEP() throws -> Data {
        let first = try boxHandle(20)
        let second = try boxHandle(10)
        var moved = Transform3D.identity
        moved.translation = SIMD3<Double>(40, 0, 0)
        let placed = try XCTUnwrap(OCCTKernel.transformed(second, by: moved))
        let url = workDir.appendingPathComponent("two-solids-\(UUID().uuidString).step")
        XCTAssertTrue(OCCTKernel.writeSTEP([first, placed], to: url))
        return try Data(contentsOf: url)
    }

    private func solidIGES() throws -> Data {
        let box = try boxHandle(20)
        let url = workDir.appendingPathComponent("solid-\(UUID().uuidString).igs")
        XCTAssertTrue(OCCTKernel.debugWriteIGES([box], to: url, brepMode: true),
                      "OCCT's IGES writer must produce the solid fixture")
        return try Data(contentsOf: url)
    }

    // MARK: - Queued waiter cancelled while the owner holds the parser

    /// Owner = IGES held at prepared body 1; waiter = STEP queued and then
    /// cancelled. The waiter must return `cancelled` before the owner releases,
    /// leaving no STEP reader invocation.
    func testCancelledQueuedSTEPWaiterLeavesWhileTheIGESOwnerStillHoldsTheParser() async throws {
        let ownerData = try solidIGES()
        let waiterData = try oneSolidSTEP()
        let log = ExactCheckpointLog()
        let gate = OwnerHoldGate(phase: "body", atBody: 1)
        CADExactImportService.testCheckpoint = { checkpoint in
            gate.checkpoint(checkpoint)
            log.record(checkpoint)
        }
        defer {
            gate.releaseGate()
            CADExactImportService.testCheckpoint = nil
        }

        let owner = Task {
            try await CADExactImportService.parseOffMain(
                data: ownerData, format: "iges", fileName: "owner.igs",
                cancellation: MeshImportCancellation())
        }
        let ownerEntered = await gate.waitEntered()
        XCTAssertTrue(ownerEntered, "the IGES owner must reach the real prepared-body checkpoint")
        XCTAssertTrue(gate.isHolding, "the owner must still hold the serialized reader section")

        let waiterToken = MeshImportCancellation()
        let waiter = Task {
            try await CADExactImportService.parseOffMain(
                data: waiterData, format: "step", fileName: "waiter.step",
                cancellation: waiterToken)
        }
        let waiterQueued = await log.waitFor(format: "step", phase: "begin", timeout: 20)
        XCTAssertTrue(waiterQueued,
                      "the STEP waiter must reach the import queue before it is cancelled")
        XCTAssertEqual(log.count(format: "step", phase: "locked"), 0,
                       "the queued waiter must not have entered the reader section yet")

        waiterToken.cancel()
        let waiterOutcome = await withTimeout(seconds: 10) {
            do {
                let plan = try await waiter.value
                return "imported-\(plan.solidCount)"
            } catch let error as CADDocumentError {
                return error.code
            } catch {
                return "unexpected:\(error)"
            }
        }

        XCTAssertEqual(waiterOutcome, "cancelled",
                       "a cancelled queued waiter must return cancelled while the owner still holds the parser")
        XCTAssertTrue(gate.isHolding,
                      "the owner must still be holding the parser when the cancelled waiter returns")
        XCTAssertEqual(log.count(format: "step", phase: "locked"), 0,
                       "a cancelled waiter must never acquire the reader section")
        XCTAssertEqual(log.count(format: "step", phase: "read"), 0,
                       "a cancelled waiter must never invoke STEPKit.solids")
        XCTAssertEqual(log.count(format: "step", phase: "body"), 0)

        gate.releaseGate()
        let ownerPlan = try await owner.value
        XCTAssertEqual(ownerPlan.solidCount, 1,
                       "the owner must still complete with its real exact solids")
        XCTAssertGreaterThan(ownerPlan.triangleCount, 0)
    }

    /// Mirror: owner = STEP held at prepared body 1; waiter = IGES queued and
    /// cancelled. Zero IGES reader invocation.
    func testCancelledQueuedIGESWaiterLeavesWhileTheSTEPOwnerStillHoldsTheParser() async throws {
        let ownerData = try twoSolidSTEP()
        let waiterData = try solidIGES()
        let log = ExactCheckpointLog()
        let gate = OwnerHoldGate(phase: "body", atBody: 1)
        CADExactImportService.testCheckpoint = { checkpoint in
            gate.checkpoint(checkpoint)
            log.record(checkpoint)
        }
        defer {
            gate.releaseGate()
            CADExactImportService.testCheckpoint = nil
        }

        let owner = Task {
            try await CADExactImportService.parseOffMain(
                data: ownerData, format: "step", fileName: "owner.step",
                cancellation: MeshImportCancellation())
        }
        let ownerEntered = await gate.waitEntered()
        XCTAssertTrue(ownerEntered)
        XCTAssertTrue(gate.isHolding)

        let waiterToken = MeshImportCancellation()
        let waiter = Task {
            try await CADExactImportService.parseOffMain(
                data: waiterData, format: "iges", fileName: "waiter.igs",
                cancellation: waiterToken)
        }
        let waiterQueued = await log.waitFor(format: "iges", phase: "begin", timeout: 20)
        XCTAssertTrue(waiterQueued)

        waiterToken.cancel()
        let waiterOutcome = await withTimeout(seconds: 10) {
            do {
                let plan = try await waiter.value
                return "imported-\(plan.solidCount)"
            } catch let error as CADDocumentError {
                return error.code
            } catch {
                return "unexpected:\(error)"
            }
        }
        XCTAssertEqual(waiterOutcome, "cancelled")
        XCTAssertTrue(gate.isHolding)
        XCTAssertEqual(log.count(format: "iges", phase: "locked"), 0)
        XCTAssertEqual(log.count(format: "iges", phase: "read"), 0,
                       "a cancelled waiter must never invoke OCCTKernel.readIGES")

        gate.releaseGate()
        let ownerPlan = try await owner.value
        XCTAssertEqual(ownerPlan.solidCount, 2)
    }

    /// The owner is held BEFORE its own reader (locked checkpoint); the waiter
    /// queues and is cancelled. This covers the acquisition-time cancellation
    /// check that must run before the reader as well.
    func testWaiterCancelledBeforeTheOwnerStartsReadingStillNeverReads() async throws {
        let ownerData = try oneSolidSTEP()
        let waiterData = try solidIGES()
        let log = ExactCheckpointLog()
        let gate = OwnerHoldGate(phase: "locked", atBody: 0)
        CADExactImportService.testCheckpoint = { checkpoint in
            gate.checkpoint(checkpoint)
            log.record(checkpoint)
        }
        defer {
            gate.releaseGate()
            CADExactImportService.testCheckpoint = nil
        }

        let owner = Task {
            try await CADExactImportService.parseOffMain(
                data: ownerData, format: "step", fileName: "owner.step",
                cancellation: MeshImportCancellation())
        }
        let ownerEntered = await gate.waitEntered()
        XCTAssertTrue(ownerEntered)
        XCTAssertTrue(gate.isHolding)

        let waiterToken = MeshImportCancellation()
        let waiter = Task {
            try await CADExactImportService.parseOffMain(
                data: waiterData, format: "iges", fileName: "waiter.igs",
                cancellation: waiterToken)
        }
        let waiterQueued = await log.waitFor(format: "iges", phase: "begin", timeout: 20)
        XCTAssertTrue(waiterQueued)
        waiterToken.cancel()
        let waiterOutcome = await withTimeout(seconds: 10) {
            do {
                let plan = try await waiter.value
                return "imported-\(plan.solidCount)"
            } catch let error as CADDocumentError {
                return error.code
            } catch {
                return "unexpected:\(error)"
            }
        }
        XCTAssertEqual(waiterOutcome, "cancelled")
        XCTAssertEqual(log.count(format: "iges", phase: "locked"), 0)
        XCTAssertEqual(log.count(format: "iges", phase: "read"), 0)

        gate.releaseGate()
        _ = try await owner.value
    }

    // MARK: - Legacy synchronous entry stays non-blocking

    /// The legacy sync entry must refuse with `import_busy` instead of waiting
    /// for the in-flight owner: it is the only path that may run on the
    /// MainActor while a worker owns the parser.
    func testLegacySynchronousEntryRefusesPromptlyWhileTheOwnerHoldsTheParser() async throws {
        let ownerData = try solidIGES()
        let syncData = try oneSolidSTEP()
        let gate = OwnerHoldGate(phase: "body", atBody: 1)
        CADExactImportService.testCheckpoint = { checkpoint in gate.checkpoint(checkpoint) }
        defer {
            gate.releaseGate()
            CADExactImportService.testCheckpoint = nil
        }

        let owner = Task {
            try await CADExactImportService.parseOffMain(
                data: ownerData, format: "iges", fileName: "owner.igs",
                cancellation: MeshImportCancellation())
        }
        let ownerEntered = await gate.waitEntered()
        XCTAssertTrue(ownerEntered)
        XCTAssertTrue(gate.isHolding)

        let started = Date()
        var refusal = ""
        do {
            _ = try CADExactImportService.parse(
                data: syncData, format: "step", fileName: "sync.step",
                waitForParser: false)
            refusal = "imported"
        } catch let error as CADDocumentError {
            refusal = error.code
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(refusal, "import_busy",
                       "the legacy sync entry must refuse while a worker owns the parser")
        XCTAssertLessThan(elapsed, 1.0,
                          "the legacy sync entry must not wait for the owner (took \(elapsed)s)")

        gate.releaseGate()
        let ownerPlan = try await owner.value
        XCTAssertEqual(ownerPlan.solidCount, 1)
    }
}

// MARK: - Test harness (real checkpoints only)

/// Records every real exact-import checkpoint and can wait for one.
nonisolated private final class ExactCheckpointLog: @unchecked Sendable {
    private let condition = NSCondition()
    private var entries: [CADExactImportCheckpoint] = []

    func record(_ checkpoint: CADExactImportCheckpoint) {
        condition.lock()
        entries.append(checkpoint)
        condition.broadcast()
        condition.unlock()
    }

    func count(format: String, phase: String) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return entries.filter { $0.format == format && $0.phase == phase }.count
    }

    /// Wait (on a background queue, never the MainActor) for the first
    /// checkpoint with this format/phase.
    func waitFor(format: String, phase: String, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.condition.lock()
                let deadline = Date(timeIntervalSinceNow: timeout)
                var found = false
                while true {
                    if self.entries.contains(where: { $0.format == format && $0.phase == phase }) {
                        found = true
                        break
                    }
                    if !self.condition.wait(until: deadline) { break }
                }
                self.condition.unlock()
                continuation.resume(returning: found)
            }
        }
    }
}

/// Holds the FIRST parser that reaches `phase`/`atBody`, and reports whether it
/// is still held. Later checkpoints pass through, so a queued waiter that did
/// enter would be visible instead of blocking the suite.
nonisolated private final class OwnerHoldGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let phase: String
    private let atBody: Int
    private var claimed = false
    private var holding = false

    init(phase: String, atBody: Int) {
        self.phase = phase
        self.atBody = atBody
    }

    func checkpoint(_ checkpoint: CADExactImportCheckpoint) {
        guard checkpoint.phase == phase,
              atBody == 0 || checkpoint.bodyIndex == atBody else { return }
        lock.lock()
        let shouldHold = !claimed
        claimed = true
        if shouldHold { holding = true }
        lock.unlock()
        guard shouldHold else { return }
        entered.signal()
        _ = release.wait(timeout: .now() + 20)
        lock.lock()
        holding = false
        lock.unlock()
    }

    func waitEntered() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let result = self.entered.wait(timeout: .now() + 20)
                continuation.resume(returning: result == .success)
            }
        }
    }

    var isHolding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return holding
    }

    func releaseGate() { release.signal() }
}

/// Race `operation` against a timeout so a regression fails with a clear
/// assertion instead of hanging the suite.
private func withTimeout<T: Sendable>(seconds: TimeInterval,
                                      operation: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
#endif

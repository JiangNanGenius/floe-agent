//
//  NativeImportSourceReadTests.swift
//  FloeCADKitTests
//
//  E31-R3 kernel qualification for the manual import source read:
//
//    * a user-selected import URL is read OFF the MainActor (the injected
//      security-scoped lease records which thread opened it);
//    * the lease is opened exactly once and closed exactly once, and the bytes
//      are materialized into `Data` while it is still open (no `.mappedIfSafe`,
//      so nothing faults after release);
//    * a caller cancelled while the read runs gets NO bytes back; the read is
//      joined and the lease is closed before `read` returns;
//    * an already-cancelled caller takes no lease and reads nothing;
//    * an unreadable source still closes the lease it opened.
//
//  The fixture bytes come from the production STEP writer; the read is the real
//  file read. Only the security-scope lease is injected, because a unit test
//  cannot obtain a real document-picker scope.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Foundation
import XCTest
@testable import FloeCAD

#if DEBUG
@MainActor
final class NativeImportSourceReadTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeImportSource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// Real STEP bytes from the production writer.
    private func stepBytes() throws -> Data {
        let box = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 20, depth: 20, height: 20), placement: .identity))
        let url = workDir.appendingPathComponent("fixture-\(UUID().uuidString).step")
        XCTAssertTrue(OCCTKernel.writeSTEP([box], to: url))
        return try Data(contentsOf: url)
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Read off the MainActor, balanced lease

    func testReadRunsOffMainAndBalancesTheLeaseAroundTheMaterializedBytes() async throws {
        let bytes = try stepBytes()
        let url = try write(bytes, "plate.step")
        let recorder = LeaseRecorder()

        let result = await CADImportSourceReader.read(url: url, lease: recorder.lease)

        guard case .success(let source) = result else {
            return XCTFail("a readable selected source must produce its bytes: \(result)")
        }
        XCTAssertEqual(source.data, bytes,
                       "the read must return the file's exact bytes")
        XCTAssertEqual(source.fileName, "plate.step")
        XCTAssertEqual(source.url, url, "the user-selected URL identity is preserved")
        XCTAssertTrue(source.usedSecurityScope,
                      "the read must run under the security-scoped lease that was opened")
        XCTAssertEqual(recorder.beginCount, 1)
        XCTAssertEqual(recorder.endCount, 1,
                       "the lease must be closed exactly once, after the read")
        XCTAssertFalse(recorder.beganOnMainThread,
                       "the manual import read must never run on the MainActor")
        XCTAssertFalse(recorder.endedOnMainThread)
        XCTAssertEqual(recorder.maxConcurrentScopes, 1,
                       "one read must never nest or duplicate its scope")
        XCTAssertEqual(try Data(contentsOf: url), bytes,
                       "the source must be unchanged by the import")
    }

    // MARK: - Cancellation joins the read and closes the lease

    func testCancelledReadIsJoinedBeforeTheLeaseClosesAndReturnsNoBytes() async throws {
        let bytes = try stepBytes()
        let url = try write(bytes, "cancel.step")
        let recorder = LeaseRecorder()
        recorder.holdBegin()

        let task = Task { await CADImportSourceReader.read(url: url, lease: recorder.lease) }
        let reachedLease = await recorder.waitForBegin(timeout: 20)
        XCTAssertTrue(reachedLease,
                      "the read must reach the injected lease")
        task.cancel()
        recorder.releaseBegin()

        let result = await task.value
        switch result {
        case .failure(.cancelled):
            break
        default:
            return XCTFail("a caller cancelled during the read must not receive bytes: \(result)")
        }
        XCTAssertEqual(recorder.beginCount, 1)
        XCTAssertEqual(recorder.endCount, 1,
                       "the read is joined and the lease closed before `read` returns")
        XCTAssertEqual(recorder.maxConcurrentScopes, 1,
                       "the lease was open while the read ran and closed after it")
        XCTAssertEqual(try Data(contentsOf: url), bytes,
                       "a cancelled read must leave the source untouched")
    }

    // MARK: - Already cancelled: no lease, no read

    func testAlreadyCancelledCallerOpensNoLeaseAndReadsNothing() async throws {
        let bytes = try stepBytes()
        let url = try write(bytes, "pre-cancelled.step")
        let recorder = LeaseRecorder()

        let task = Task { () -> Result<CADImportSource, CADImportSourceReadError> in
            // Wait until this Task is really cancelled, so the read starts
            // with `Task.isCancelled == true` deterministically.
            while !Task.isCancelled { await Task.yield() }
            return await CADImportSourceReader.read(url: url, lease: recorder.lease)
        }
        task.cancel()
        let result = await task.value
        switch result {
        case .failure(.cancelled):
            break
        default:
            return XCTFail("a pre-cancelled caller must not read: \(result)")
        }
        XCTAssertEqual(recorder.beginCount, 0,
                       "a pre-cancelled import must not take a security scope")
        XCTAssertEqual(recorder.endCount, 0)
    }

    // MARK: - Unreadable source still balances its lease

    func testUnreadableSourceReportsFailureAfterClosingTheLease() async throws {
        let recorder = LeaseRecorder()
        let missing = workDir.appendingPathComponent("missing-\(UUID().uuidString).step")

        let result = await CADImportSourceReader.read(url: missing, lease: recorder.lease)

        switch result {
        case .failure(.unreadable):
            break
        default:
            return XCTFail("a missing source must report an unreadable failure: \(result)")
        }
        XCTAssertEqual(recorder.beginCount, 1)
        XCTAssertEqual(recorder.endCount, 1,
                       "a failed read must still close the scope it opened")
    }
}

// MARK: - Injected security-scoped lease

/// Counts lease begin/end, records the thread that ran the read, and can hold
/// the worker inside `begin` so a test can cancel deterministically while a
/// read is in flight.
nonisolated final class LeaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var begins = 0
    private var ends = 0
    private var beginOnMain = false
    private var endOnMain = false
    private var concurrentScopes = 0
    private var maxConcurrent = 0
    private var beginToEnd = 0
    private var beginSemaphore: DispatchSemaphore?
    private let beginEntered = DispatchSemaphore(value: 0)

    func holdBegin() {
        lock.lock()
        beginSemaphore = DispatchSemaphore(value: 0)
        lock.unlock()
    }

    func releaseBegin() {
        lock.lock()
        let gate = beginSemaphore
        lock.unlock()
        gate?.signal()
    }

    /// Waits on a background queue: the caller (`@MainActor` test) must stay
    /// free so its `Task` can enter `CADImportSourceReader.read`. Waiting
    /// synchronously here blocks the MainActor executor before the inherited
    /// task body ever runs, so `read` never reaches the injected lease.
    func waitForBegin(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: self.beginEntered.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

    var lease: CADImportSourceLease {
        CADImportSourceLease(
            begin: { [self] _ in
                lock.lock()
                begins += 1
                beginToEnd += 1
                concurrentScopes += 1
                maxConcurrent = max(maxConcurrent, concurrentScopes)
                if Thread.isMainThread { beginOnMain = true }
                let gate = beginSemaphore
                lock.unlock()
                beginEntered.signal()
                if let gate { _ = gate.wait(timeout: .now() + 20) }
                return true
            },
            end: { [self] _ in
                lock.lock()
                ends += 1
                beginToEnd -= 1
                concurrentScopes = max(0, concurrentScopes - 1)
                if Thread.isMainThread { endOnMain = true }
                lock.unlock()
            })
    }

    var beginCount: Int { lock.lock(); defer { lock.unlock() }; return begins }
    var endCount: Int { lock.lock(); defer { lock.unlock() }; return ends }
    var beganOnMainThread: Bool { lock.lock(); defer { lock.unlock() }; return beginOnMain }
    var endedOnMainThread: Bool { lock.lock(); defer { lock.unlock() }; return endOnMain }
    var maxConcurrentScopes: Int { lock.lock(); defer { lock.unlock() }; return maxConcurrent }
    var beginToEndCount: Int { lock.lock(); defer { lock.unlock() }; return beginToEnd }
}
#endif

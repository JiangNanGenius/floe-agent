// SPDX-License-Identifier: MPL-2.0
import Dispatch
import Foundation
import Testing
@testable import FloeGit

@Suite("Process-wide native Git remote epoch")
struct GitRemoteOperationEpochTests {
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func append(_ value: Int) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var snapshot: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    }

    @Test func trustReloadWaitsForOtherRepositoryRemoteIO() throws {
        let firstEntered = DispatchSemaphore(value: 0)
        let secondAttempted = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let finishFirst = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let trace = Trace()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            GitRemoteTrust.withExclusiveRemoteOperation {
                trace.append(1); firstEntered.signal()
                _ = finishFirst.wait(timeout: .now() + 5)
                trace.append(2)
            }
        }
        defer { finishFirst.signal() }
        try #require(firstEntered.wait(timeout: .now() + 2) == .success)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            secondAttempted.signal()
            GitRemoteTrust.withExclusiveRemoteOperation {
                trace.append(3); secondEntered.signal()
            }
        }
        try #require(secondAttempted.wait(timeout: .now() + 2) == .success)
        #expect(secondEntered.wait(timeout: .now() + .milliseconds(50)) == .timedOut)
        finishFirst.signal()
        try #require(group.wait(timeout: .now() + 2) == .success)
        #expect(trace.snapshot == [1, 2, 3])
    }

    private enum ProbeError: Error { case expected }
    @Test func nestedPreparationThrowReleasesEpochForAnotherRepository() {
        do {
            try GitRemoteTrust.withExclusiveRemoteOperation {
                try GitRemoteTrust.withExclusiveRemoteOperation { throw ProbeError.expected }
            }
            Issue.record("The throwing probe must propagate")
        } catch ProbeError.expected { }
        catch { Issue.record("Unexpected epoch probe error") }
        let otherRepository = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            GitRemoteTrust.withExclusiveRemoteOperation { otherRepository.signal() }
        }
        #expect(otherRepository.wait(timeout: .now() + 2) == .success)
    }
}

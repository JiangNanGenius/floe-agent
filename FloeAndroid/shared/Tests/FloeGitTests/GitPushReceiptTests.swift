// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeGit

/// GIT-PUSH-CONFLICT regression seam. `git_remote_push` returns the
/// transport result, which is `0` even when the server rejects every ref;
/// rejections exist only in the `push_update_reference` callback stream.
/// These tests drive the real callback trampoline and the terminal outcome
/// evaluator so a rejected — or unreported — push can never be evaluated
/// as a success. No network, no libgit2 runtime: the receipt layer is pure.
@Suite("Git push receipt")
struct GitPushReceiptTests {

    // MARK: - Accepted refs

    @Test("All-accepted report succeeds and keeps reported order")
    func acceptedReportSucceeds() throws {
        let recorder = GitPushUpdateRecorder()
        let payload = LocalGitService.CredentialPayload(token: nil, pushUpdates: recorder)
        let raw = Unmanaged.passRetained(payload).toOpaque()
        defer { Unmanaged<LocalGitService.CredentialPayload>.fromOpaque(raw).release() }

        // One refspec is pushed per call; a no-op up-to-date update is still
        // reported as accepted by the pinned backend.
        deliver("refs/heads/main", status: nil, to: raw)
        let receipt = try GitPushOutcomeEvaluator.evaluate(updates: recorder.snapshot, pushedRefs: ["refs/heads/main"])

        #expect(receipt.updates.count == 1)
        #expect(receipt.updates[0].outcome == .accepted)
        #expect(receipt.updates[0].rejection == nil)
        #expect(!receipt.isRejected)
    }

    // MARK: - Rejected refs

    @Test("Server rejection is a typed refusal, never a success")
    func rejectedReportThrowsTypedRefusal() throws {
        let recorder = GitPushUpdateRecorder()
        let payload = LocalGitService.CredentialPayload(token: nil, pushUpdates: recorder)
        let raw = Unmanaged.passRetained(payload).toOpaque()
        defer { Unmanaged<LocalGitService.CredentialPayload>.fromOpaque(raw).release() }

        // Transport returned 0 while the server said no: the historical bug.
        deliver("refs/heads/main", status: "refusing to allow ... non-fast-forward", to: raw)

        var refusal: GitPushRefusedError?
        do {
            _ = try GitPushOutcomeEvaluator.evaluate(updates: recorder.snapshot, pushedRefs: ["refs/heads/main"])
        } catch let error as GitPushRefusedError {
            refusal = error
        }
        let typed = try #require(refusal)
        #expect(typed.classification == .nonFastForward)
        #expect(typed.receipt.rejected.map(\.refname) == ["refs/heads/main"])
    }

    @Test("Partial acceptance still fails the push when any ref is rejected")
    func partialRejectionFails() throws {
        let recorder = GitPushUpdateRecorder()
        recorder.record(accepted: "refs/heads/main")
        recorder.record(rejected: "refs/heads/release", reason: .protectedBranch)

        #expect(GitPushReceipt(updates: recorder.snapshot).isRejected)
        #expect(throws: GitPushRefusedError.self) {
            try GitPushOutcomeEvaluator.evaluate(updates: recorder.snapshot, pushedRefs: ["refs/heads/main", "refs/heads/release"])
        }
    }

    // MARK: - Callback/transport ordering and no false success

    @Test("Receipt preserves server report order through the callback")
    func reportOrderIsPreserved() {
        let recorder = GitPushUpdateRecorder()
        let payload = LocalGitService.CredentialPayload(token: nil, pushUpdates: recorder)
        let raw = Unmanaged.passRetained(payload).toOpaque()
        defer { Unmanaged<LocalGitService.CredentialPayload>.fromOpaque(raw).release() }

        deliver("refs/heads/a", status: nil, to: raw)
        deliver("refs/heads/b", status: "protected branch", to: raw)
        deliver("refs/heads/c", status: nil, to: raw)

        #expect(recorder.snapshot.map(\.refname) == ["refs/heads/a", "refs/heads/b", "refs/heads/c"])
        #expect(recorder.snapshot.map(\.outcome) == [.accepted, .rejected, .accepted])
    }

    @Test("Unreported push is ambiguous and never a silent success")
    func emptyReportThrowsUnreported() throws {
        // Transport returned 0 but the server confirmed nothing.
        #expect(throws: GitPushUnreportedError.self) {
            try GitPushOutcomeEvaluator.evaluate(updates: [], pushedRefs: ["refs/heads/main"])
        }
        let error = GitPushUnreportedError(pushedRefs: ["refs/heads/main"])
        #expect(error.pushedRefs == ["refs/heads/main"])
    }

    // MARK: - Per-operation payload isolation

    @Test("Concurrent push payloads never share updates")
    func payloadIsolation() {
        let first = GitPushUpdateRecorder()
        let second = GitPushUpdateRecorder()
        let firstPayload = LocalGitService.CredentialPayload(token: nil, pushUpdates: first)
        let secondPayload = LocalGitService.CredentialPayload(token: nil, pushUpdates: second)
        let firstRaw = Unmanaged.passRetained(firstPayload).toOpaque()
        let secondRaw = Unmanaged.passRetained(secondPayload).toOpaque()
        defer {
            Unmanaged<LocalGitService.CredentialPayload>.fromOpaque(firstRaw).release()
            Unmanaged<LocalGitService.CredentialPayload>.fromOpaque(secondRaw).release()
        }

        // Interleaved deliveries as two serialized pushes overlap in callback time.
        deliver("refs/heads/main", status: nil, to: firstRaw)
        deliver("refs/heads/main", status: "permission denied", to: secondRaw)
        deliver("refs/heads/feature", status: "protected branch", to: firstRaw)

        #expect(first.snapshot.count == 2)
        #expect(first.snapshot[0].outcome == .accepted)
        #expect(first.snapshot[0].refname == "refs/heads/main")
        #expect(first.snapshot[1].refname == "refs/heads/feature")
        #expect(first.snapshot[1].rejection == .protectedBranch)
        #expect(second.snapshot.count == 1)
        #expect(second.snapshot[0].refname == "refs/heads/main")
        #expect(second.snapshot[0].rejection == .permissionDenied)
    }

    @Test("Payload without a recorder ignores push callbacks safely")
    func payloadWithoutRecorderIsSafe() {
        let payload = LocalGitService.CredentialPayload(token: nil, pushUpdates: nil)
        let raw = Unmanaged.passRetained(payload).toOpaque()
        defer { Unmanaged<LocalGitService.CredentialPayload>.fromOpaque(raw).release() }
        // Fetch/clone-style payloads must not crash or fabricate state.
        deliver("refs/heads/main", status: "anything", to: raw)
    }

    // MARK: - Bounded classifications keep raw server text out

    @Test("Classifier maps server messages to closed buckets and drops raw text")
    func classifierBuckets() {
        #expect(GitPushRejectionClassifier.classify(refname: "refs/heads/main", status: "non-fast-forward, fetch first") == .nonFastForward)
        #expect(GitPushRejectionClassifier.classify(refname: "refs/heads/main", status: "cannot push non-fastforwardable reference") == .nonFastForward)
        #expect(GitPushRejectionClassifier.classify(refname: "refs/heads/main", status: "protected branch hook declined") == .protectedBranch)
        #expect(GitPushRejectionClassifier.classify(refname: "refs/heads/main", status: "permission denied (403)") == .permissionDenied)
        #expect(GitPushRejectionClassifier.classify(refname: "refs/heads/main", status: "push declined by repository rule: signature required") == .repositoryRule)
        #expect(GitPushRejectionClassifier.classify(refname: "refs/heads/main", status: "internal server error, try again later") == .serverUnavailable)
        #expect(GitPushRejectionClassifier.classify(refname: "refs/heads/main", status: "mdreftbl spurious decline 7f3a9c") == .other)
    }

    @Test("Receipt never retains the raw server status text")
    func rawStatusTextDoesNotLeak() throws {
        let recorder = GitPushUpdateRecorder()
        let payload = LocalGitService.CredentialPayload(token: nil, pushUpdates: recorder)
        let raw = Unmanaged.passRetained(payload).toOpaque()
        defer { Unmanaged<LocalGitService.CredentialPayload>.fromOpaque(raw).release() }

        let secretLike = "token=EXAMPLE_NOT_A_CREDENTIAL repository example/private permission denied"
        deliver("refs/heads/main", status: secretLike, to: raw)

        let snapshot = recorder.snapshot
        #expect(snapshot[0].rejection == .permissionDenied)
        let encoded = try JSONEncoder().encode(snapshot[0])
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("EXAMPLE_NOT_A_CREDENTIAL"))
        #expect(!text.contains(secretLike))
        // Refname stays bounded and exact for ordinary refs.
        #expect(snapshot[0].refname == "refs/heads/main")
    }

    @Test("Reported refnames are bounded")
    func refnamesAreBounded() {
        let recorder = GitPushUpdateRecorder()
        recorder.record(accepted: String(repeating: "a", count: 600))
        #expect(recorder.snapshot[0].refname.count == 256)
    }

    @Test("A non-NULL empty server status is still a refusal")
    func emptyStatusRejects() throws {
        let recorder = GitPushUpdateRecorder()
        let payload = LocalGitService.CredentialPayload(token: nil, pushUpdates: recorder)
        let raw = Unmanaged.passRetained(payload).toOpaque()
        defer { Unmanaged<LocalGitService.CredentialPayload>.fromOpaque(raw).release() }
        deliver("refs/heads/main", status: "", to: raw)
        #expect(throws: GitPushRefusedError.self) {
            try GitPushOutcomeEvaluator.evaluate(updates: recorder.snapshot, pushedRefs: ["refs/heads/main"])
        }
    }

    @Test("Partial, foreign or duplicate accepted reports do not confirm a push")
    func acceptedReportsMustMatchExactPushedRefs() {
        let main = GitPushRefUpdate(refname: "refs/heads/main", outcome: .accepted)
        let foreign = GitPushRefUpdate(refname: "refs/heads/other", outcome: .accepted)
        for (updates, expected) in [([main], ["refs/heads/main", "refs/heads/release"]),
                                    ([foreign], ["refs/heads/main"]),
                                    ([main, main], ["refs/heads/main"])] {
            #expect(throws: GitPushUnreportedError.self) {
                try GitPushOutcomeEvaluator.evaluate(updates: updates, pushedRefs: expected)
            }
        }
    }

    // MARK: - Trampoline

    private func deliver(_ refname: String, status: String?, to raw: UnsafeMutableRawPointer) {
        refname.withCString { rawRef in
            let code: Int32
            if let status {
                code = status.withCString { rawStatus in
                    LocalGitService.pushUpdateReferenceCallback(rawRef, rawStatus, raw)
                }
            } else {
                code = LocalGitService.pushUpdateReferenceCallback(rawRef, nil, raw)
            }
            #expect(code == 0)
        }
    }
}

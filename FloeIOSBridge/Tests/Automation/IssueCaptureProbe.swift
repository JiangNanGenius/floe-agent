import XCTest
import Foundation

/// Native macOS XCTest fixture for the actual XCTest issue-record hook used by
/// the embedded engine. It records one deliberate issue and proves the scoped
/// capture sees it. The test is intentionally reported as one failure by
/// XCTest (the issue is forwarded to `super`); the runner treats that as the
/// expected shape and verifies the capture marker. No phone or Simulator is
/// involved.
final class IssueCaptureProbeTests: XCTestCase {
    private let capture = BridgeEngineIssueCapture()

    override func record(_ issue: XCTIssueReference) {
        capture.noteIssue()
        super.record(issue)
    }

    func testRecordedIssueCannotBecomeSuccess() {
        let token = capture.begin()
        let issue = XCTIssueReference(
            type: .assertionFailure,
            compactDescription: "fixture issue"
        )
        record(issue)
        let count = capture.end(token)

        let outcome = BridgeSDKCallOutcome(
            entered: true,
            returned: true,
            recordedIssueCount: count
        )
        var checksOK = count == 1
        checksOK = checksOK && outcome.classification == "returned-with-issue"
        checksOK = checksOK && outcome.textDispatchClaim(actualValueVerified: false) == "unknown"
        checksOK = checksOK && outcome.textDispatchClaim(actualValueVerified: true) == "true"
        print("FLOE_ISSUE_CAPTURE_OK count=\(count) classification=\(outcome.classification) checks_ok=\(checksOK ? 1 : 0)")
    }
}

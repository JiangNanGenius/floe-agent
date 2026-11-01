import Foundation
import XCTest

/// Product-mode sanitizer for XCTest issues recorded by the embedded engine.
///
/// `XCTIssue` descriptions, associated errors and attachments can contain
/// element values (including text typed earlier). The product forwards only a
/// fixed summary plus the genuine issue type, severity and source-code
/// context, so the issue still fails/records normally in the real test
/// lifecycle without carrying input-bearing content into an xcresult.
enum BridgeEngineIssueSanitizer {
    static let compactDescription =
        "Automation issue recorded; its description, associated error and attachments were suppressed."

    static func sanitized(_ issue: XCTIssue) -> XCTIssue {
        XCTIssue(type: issue.type,
                 compactDescription: compactDescription,
                 detailedDescription: nil,
                 sourceCodeContext: issue.sourceCodeContext,
                 associatedError: nil,
                 attachments: [],
                 severity: issue.severity)
    }
}

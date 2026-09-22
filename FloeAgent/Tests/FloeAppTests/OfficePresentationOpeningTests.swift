// FloeAppTests — PPT/PPTX opening route and bounded-outcome coverage.
//
// Build 221 routed every presentation extension to the strict visible-render
// requirement, which is correct, but the bounded outcome was a terminal error:
// on the device a presentation whose engine never reported a painted slide left
// the surface on an unbounded "opening" state (then a dead end) while DOCX/XLSX
// kept working. These tests pin the App-side route and the bounded, recoverable
// outcome for all three owning entry paths (Workspace preview / IDE tab / Notes
// remembered mode) without the native host: the simulator target compiles the
// host path out, exactly like the CI simulator gate.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import FloeDocuments
@testable import FloeApp

@Suite("FloeApp.OfficePresentationOpening")
@MainActor
struct OfficePresentationOpeningTests {

    /// The three owning entry paths and the first intent each one mounts.
    private static let entryPaths: [(name: String, readOnly: Bool)] = [
        ("Workspace preview", true),
        ("Workspace/IDE edit entry", false),
        ("Notes remembered mode", true),
    ]

    /// The App's device-only arming is intentionally inside
    /// `#if canImport(FloeOfficeNative)` (the simulator App target has no host
    /// controller to probe). These tests compose the same two-line decision
    /// from the App's shipped route plus the document-layer contract, and the
    /// mirror test below pins the two format lists together.
    private static func policy(_ pathExtension: String,
                               readOnly: Bool,
                               hostSupportsVisibleRender: Bool = true) -> OfficeOpeningPolicy {
        var requirement = OfficeRenderRequirement.forDocument(pathExtension: pathExtension)
        if requirement == .visibleRenderRequired, !hostSupportsVisibleRender {
            requirement = .openOnly
        }
        return OfficeOpeningPolicy(requiresVisibleRender: requirement == .visibleRenderRequired,
                                   readOnly: readOnly)
    }

    @Test("PPT/PPTX route to the visible-render requirement; DOCX/XLSX stay open-only")
    func presentationRoutingIsUnchangedForOffice() {
        for name in ["ppt", "pptx", "pptm", "pps", "ppsx", "pot", "potx",
                     "odp", "otp", "fodp", "odg", "otg", "fodg", "PPTX", "PpTx"] {
            #expect(OfficeRenderRequirement.forDocument(pathExtension: name) == .visibleRenderRequired,
                    Comment(rawValue: name))
        }
        for name in ["docx", "docm", "xlsx", "xlsm", "doc", "xls", "odt", "ods", "rtf", "txt", "pdf", ""] {
            #expect(OfficeRenderRequirement.forDocument(pathExtension: name) == .openOnly,
                    Comment(rawValue: name))
        }
    }

    @Test("The App gate and the document-layer policy mirror each other")
    func appAndDocumentListsMirror() {
        #expect(OfficeRenderRequirement.renderRequiredExtensions
                == OfficeOpeningPolicy.presentationExtensions)
    }

    @Test("A presentation waits bounded for the render through every entry path")
    func presentationsWaitBoundedlyThroughAllEntryPaths() {
        for entry in Self.entryPaths {
            var policy = Self.policy("pptx", readOnly: entry.readOnly)
            #expect(policy.requiresVisibleRender, Comment(rawValue: entry.name))
            #expect(policy.openSettled() == .waiting, Comment(rawValue: entry.name))
            #expect(policy.renderObserved() == .ready, Comment(rawValue: entry.name))
            #expect(policy.warning == nil, Comment(rawValue: entry.name))
        }
    }

    @Test("A bounded render wait is a recoverable notice in every entry path, never a failure")
    func boundedRenderWaitIsRecoverable() throws {
        for entry in Self.entryPaths {
            var policy = Self.policy("pptx", readOnly: entry.readOnly)
            #expect(policy.openSettled() == .waiting, Comment(rawValue: entry.name))
            #expect(policy.renderDeadlineElapsed() == .renderUnverified, Comment(rawValue: entry.name))
            #expect(policy.outcome != .failed, Comment(rawValue: entry.name))
            let warning = try #require(policy.warning, Comment(rawValue: entry.name))
            #expect(warning.actions.contains(.retryPreview), Comment(rawValue: entry.name))
            #expect(warning.detailZh.contains("编辑副本"), Comment(rawValue: entry.name))
            #expect(warning.detailEn.contains("retained"), Comment(rawValue: entry.name))
        }
    }

    @Test("Word and Excel never wait, never warn and never fail on a late bound")
    func documentsKeepTheirOpenOnlyWorkflow() {
        for path in ["report.docx", "budget.xlsx"] {
            var policy = Self.policy((path as NSString).pathExtension, readOnly: false)
            #expect(!policy.requiresVisibleRender, Comment(rawValue: path))
            #expect(policy.openSettled() == .ready, Comment(rawValue: path))
            #expect(policy.warning == nil, Comment(rawValue: path))
            #expect(policy.renderDeadlineElapsed() == .ready, Comment(rawValue: path))
        }
    }

    @Test("A host without the visible-render contract keeps the open-only route")
    func olderHostKeepsOpenOnlyRoute() {
        var policy = Self.policy("pptx", readOnly: false, hostSupportsVisibleRender: false)
        #expect(!policy.requiresVisibleRender)
        #expect(policy.openSettled() == .ready)
        #expect(policy.warning == nil)
    }

    @Test("Every bounded outcome has an exit: ready, notice, or recoverable failure")
    func everyBoundedOutcomeHasAnExit() {
        var failed = Self.policy("pptx", readOnly: true)
        #expect(failed.openingDeadlineElapsed() == .failed)
        #expect(failed.warning?.actions.contains(.recover) == true)

        var unverified = Self.policy("pptx", readOnly: true)
        _ = unverified.openSettled()
        _ = unverified.renderDeadlineElapsed()
        #expect(unverified.warning?.actions.contains(.dismiss) == true)
        // A late paint repairs the notice.
        #expect(unverified.renderObserved() == .ready)
        #expect(unverified.warning == nil)
    }
}
#endif

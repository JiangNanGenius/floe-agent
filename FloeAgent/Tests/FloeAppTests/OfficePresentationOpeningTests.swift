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

    // MARK: - Loaded / editable / visible at the save boundary

    @Test("A presentation that settled open but never painted cannot save")
    func unrenderedPresentationCannotSave() {
        var gate = OfficeVisibleRenderGate(requirement: .visibleRenderRequired)
        #expect(gate.openSettled() == .waitingForRender)
        #expect(!gate.permitsSave, "an opened but unpainted presentation must not save")
        #expect(gate.deadlineExceeded() == .failed)
        #expect(!gate.permitsSave, "a bounded-outcome presentation must not save either")
    }

    @Test("A presentation can save only once the edit surface itself painted")
    func renderedPresentationCanSave() {
        var gate = OfficeVisibleRenderGate(requirement: .visibleRenderRequired)
        _ = gate.openSettled()
        #expect(gate.visibleRenderObserved() == .ready)
        #expect(gate.permitsSave, "a painted presentation permits save")
        // A late failure after a real paint never revokes the save permit.
        #expect(gate.hostFailed() == .ready)
        #expect(gate.permitsSave)
    }

    @Test("Word and Excel can save from the settled open, unchanged")
    func documentsCanSaveAtOpen() {
        for path in ["docx", "xlsx"] {
            var gate = OfficeVisibleRenderGate(requirement: .openOnly)
            #expect(gate.openSettled() == .ready, Comment(rawValue: path))
            #expect(gate.permitsSave, Comment(rawValue: path))
        }
    }

    // MARK: - Late paint repairs the bounded outcome

    @Test("A late paint after the App render deadline repairs the presentation to ready and savable")
    func latePaintAfterRenderDeadlineRepairsSession() {
        var gate = OfficeVisibleRenderGate(requirement: .visibleRenderRequired)
        #expect(gate.openSettled() == .waitingForRender)
        #expect(gate.deadlineExceeded() == .failed)
        #expect(!gate.permitsSave, "the bounded-outcome session must not save before a real paint")
        // The engine painted after the deadline: the bounded outcome means
        // "no paint yet", never "can never paint", so the real first frame
        // repairs the session (the editable first-frame transition).
        #expect(gate.visibleRenderObserved() == .ready)
        #expect(gate.isReady && gate.permitsSave)
    }

    @Test("A late paint after the host's bounded render failure repairs the session to ready and savable")
    func latePaintAfterHostFailureRepairsSession() {
        var gate = OfficeVisibleRenderGate(requirement: .visibleRenderRequired)
        _ = gate.openSettled()
        #expect(gate.hostFailed() == .failed)
        #expect(!gate.permitsSave)
        #expect(gate.visibleRenderObserved() == .ready)
        #expect(gate.isReady && gate.permitsSave)
    }

    @Test("A late paint after the bounded outcome clears the user-facing notice through the policy")
    func latePaintClearsTheRecoverableNotice() {
        var policy = OfficeOpeningPolicy(requiresVisibleRender: true, readOnly: false)
        #expect(policy.openSettled() == .waiting)
        #expect(policy.renderDeadlineElapsed() == .renderUnverified)
        #expect(policy.warning != nil)
        #expect(policy.renderObserved() == .ready)
        #expect(policy.warning == nil)
        #expect(policy.outcome == .ready)
    }

    @Test("An early edit-entry acknowledgement never readies a presentation without the edit paint")
    func earlyEditEntryAckNeverReadiesWithoutTheEditPaint() {
        // The host may run the guarded edit entry on its bounded
        // extent-bootstrap fallback; the App contract is unchanged by how
        // early the entry ran. The entry's permission acknowledgement
        // settles the open, the session still awaits the visible render,
        // and the bounded outcome without a paint stays recoverable —
        // the acknowledgement and the first editable frame stay distinct.
        var policy = Self.policy("pptx", readOnly: false)
        #expect(policy.openSettled() == .waiting)
        #expect(policy.renderObserved() == .ready)
        #expect(policy.warning == nil)

        var gate = OfficeVisibleRenderGate(requirement: .visibleRenderRequired)
        #expect(gate.openSettled() == .waitingForRender,
                "the entry acknowledgement settles the open, not readiness")
        #expect(gate.awaitsVisibleRender)
        #expect(!gate.isReady && !gate.permitsSave)
        // No paint by the deadline: the recoverable notice, never ready.
        #expect(gate.deadlineExceeded() == .failed)
        #expect(!gate.permitsSave)
    }

    // MARK: - First frame ownership

    @Test("A preview-to-edit remount never inherits the preview's paint")
    func remountRequiresItsOwnPaint() {
        // The preview session painted its file-based surface fine. That frame
        // is exactly what the edit surface must not be told to be ready on.
        var preview = OfficeVisibleRenderGate(requirement: .visibleRenderRequired)
        _ = preview.openSettled()
        _ = preview.visibleRenderObserved()
        #expect(preview.isReady)
        #expect(preview.permitsSave)
        // The edit entry mounts a new controller, a new open generation and a
        // new gate; readiness starts over, and only the edit surface's own
        // post-entry paint (the host's evidence) may settle it ready.
        var editing = OfficeVisibleRenderGate(requirement: .visibleRenderRequired)
        #expect(editing.state == .waitingForOpen, "the edit gate must start unrendered")
        _ = editing.openSettled()
        #expect(editing.awaitsVisibleRender)
        #expect(!editing.isReady && !editing.permitsSave)
        _ = editing.visibleRenderObserved()
        #expect(editing.isReady && editing.permitsSave)
    }

    // MARK: - Permission report budget

    @Test("The permission report wait outlasts the paint-gated report but stays under the open watchdog")
    func permissionReportBudgetTracksTheOpeningContract() {
        // Editable presentation: the host's verified report legitimately follows
        // the first painted tile (the paint-gated edit entry), so the wait is
        // the editable opening budget minus the watchdog margin.
        let editable = OfficeOpeningPolicy(requiresVisibleRender: true, readOnly: false)
        #expect(OfficeFileSession.permissionReportBudget(openingPolicy: editable, readOnly: false) == 40)
        #expect(OfficeFileSession.permissionReportBudget(openingPolicy: editable, readOnly: false)
                < editable.openingBudget, "the open watchdog stays the outer bound")
        // Preview keeps its historical bound.
        let preview = OfficeOpeningPolicy(requiresVisibleRender: true, readOnly: true)
        #expect(OfficeFileSession.permissionReportBudget(openingPolicy: preview, readOnly: true) == 25)
        #expect(OfficeFileSession.permissionReportBudget(openingPolicy: preview, readOnly: true)
                < preview.openingBudget)
        // A session without a policy falls back to the same contract.
        #expect(OfficeFileSession.permissionReportBudget(openingPolicy: nil, readOnly: false) == 40)
        #expect(OfficeFileSession.permissionReportBudget(openingPolicy: nil, readOnly: true) == 25)
    }
}
#endif

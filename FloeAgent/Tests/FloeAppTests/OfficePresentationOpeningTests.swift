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

    @Test("An edit attempt the engine never confirmed gets the recoverable render notice, never a bare ready")
    func unconfirmedEditAttemptNeverClaimsBareReadyOnPresentations() {
        // Mirrors the shipped `acknowledgeEditPermission` nil-permission branch:
        // a presentation whose engine never reported its permission settles as
        // `renderUnverified` (banner, save refused until a real paint), while
        // Word/Excel keep their historical open-only readiness. First-frame
        // evidence is never weakened into a silent ready claim.
        for entry in Self.entryPaths where !entry.readOnly {
            var policy = Self.policy("pptx", readOnly: entry.readOnly)
            #expect(policy.requiresVisibleRender, Comment(rawValue: entry.name))
            #expect(policy.renderDeadlineElapsed() == .renderUnverified, Comment(rawValue: entry.name))
            #expect(policy.warning?.actions.contains(.retryPreview) == true, Comment(rawValue: entry.name))
        }
        for path in ["report.docx", "budget.xlsx"] {
            var policy = Self.policy((path as NSString).pathExtension, readOnly: false)
            #expect(policy.renderDeadlineElapsed() == .ready, Comment(rawValue: path))
            #expect(policy.warning == nil, Comment(rawValue: path))
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

// The durable Office stage trace is the evidence path for exactly the
// bounded-opening outcomes above: a user-visible spinner must leave a
// content-free record of which stage (host / working copy / import /
// permission / first paint / error, correlated by session + generation) never
// arrived. These tests live in this already-listed test file so the shared
// workspace's generated Xcode project does not need regeneration.
@Suite("FloeApp.OfficeStageDiagnostics")
@MainActor
struct OfficeStageDiagnosticsTests {

    private func temporaryTraceURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-office-stage-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("office-stage.jsonl", isDirectory: false)
    }

    private func temporaryRecorder(eventLimit: Int = 512, fileLimit: Int = 262_144) -> OfficeStageRecorder {
        OfficeStageRecorder(fileURL: temporaryTraceURL(),
                            eventLimit: eventLimit,
                            fileLimit: fileLimit)
    }

    @Test("The export carries session, generation, stage and sanitized detail")
    func exportCarriesCorrelationIdentity() {
        let recorder = temporaryRecorder()
        recorder.record(session: "ABCDEF01-2345-6789", generation: 3, stage: "engine.open",
                        detail: ["engineReadOnly": "false", "success": "true"])
        let text = recorder.exportText()
        #expect(text.contains("session=ABCDEF01"))
        #expect(text.contains("generation=3"))
        #expect(text.contains("stage=engine.open"))
        #expect(text.contains("engineReadOnly=false"))
        #expect(text.contains("events_retained=1 events_exported=1"))
    }

    @Test("A path or an over-long value never reaches the export")
    func exportNeverCarriesContentOrPaths() {
        let recorder = temporaryRecorder()
        recorder.record(session: "s", generation: 1, stage: "workingCopy.open",
                        detail: [
                            "path": "/var/mobile/Containers/secret.docx",
                            "long": String(repeating: "x", count: 400),
                            "ok": "12",
                        ])
        let text = recorder.exportText()
        // The unsafe values are dropped by the recorder's sanitizer (a path
        // or an over-long value is not content-free); the safe counter is
        // kept, so the trace stays useful.
        #expect(!text.contains("Containers"))
        #expect(!text.contains("/var"))
        #expect(!text.contains("xxx"))
        #expect(text.contains("ok=12"))
    }

    @Test("The export is bounded by lines and by bytes and keeps the newest events")
    func exportIsBoundedAndKeepsNewest() {
        let recorder = temporaryRecorder()
        for index in 0..<400 {
            recorder.record(session: "session-\(index)", generation: index,
                            stage: "stage-\(index)", detail: ["index": String(index)])
        }
        let text = recorder.exportText(lineLimit: 20, maxBytes: 1_024)
        #expect(text.utf8.count <= 1_024, "byte bound")
        #expect(text.split(separator: "\n").count <= 21, "line bound (header + 20)")
        // Newest events are retained; the oldest are dropped.
        #expect(text.contains("stage-399"))
        #expect(!text.contains("stage-379"))
        // The header reports the real retained/exported counts.
        #expect(text.contains("events_retained=400"))
    }

    @Test("An empty recorder still renders a valid, content-free header")
    func emptyExportIsValid() {
        let recorder = temporaryRecorder()
        let text = recorder.exportText()
        #expect(text == "events_retained=0 events_exported=0")
    }

    // MARK: - Restart recovery

    @Test("A new recorder instance recovers and exports the previous instance's stages")
    func relaunchRecoversThePreviousTrace() {
        let url = temporaryTraceURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let previous = OfficeStageRecorder(fileURL: url)
        previous.record(session: "PREV-AAAA-BBBB", generation: 4, stage: "engine.open",
                        detail: ["success": "true"])
        previous.record(session: "PREV-AAAA-BBBB", generation: 4, stage: "edit.entry")

        // The process died or was relaunched; the fresh instance must not
        // start blind and must export the old tail.
        let relaunched = OfficeStageRecorder(fileURL: url)
        #expect(relaunched.trace(session: "PREV-AAAA-BBBB").map(\.stage)
                == ["engine.open", "edit.entry"])
        let text = relaunched.exportText()
        #expect(text.contains("events_retained=2 events_exported=2"))
        #expect(text.contains("session=PREV-AAA"))
        #expect(text.contains("generation=4"))
        #expect(text.contains("stage=engine.open"))
        #expect(text.contains("success=true"))
        #expect(text.contains("at="), "every line carries an absolute time for cross-launch correlation")
    }

    @Test("The first record after a relaunch keeps the recovered tail instead of overwriting it")
    func firstRecordAfterRelaunchKeepsTheOldTail() {
        let url = temporaryTraceURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = OfficeStageRecorder(fileURL: url, eventLimit: 8, fileLimit: 16_384)
        for index in 0..<5 {
            first.record(session: "old", generation: index, stage: "stage.old\(index)")
        }
        let second = OfficeStageRecorder(fileURL: url, eventLimit: 8, fileLimit: 16_384)
        second.record(session: "new", generation: 0, stage: "stage.new")

        let third = OfficeStageRecorder(fileURL: url, eventLimit: 8, fileLimit: 16_384)
        #expect(third.allEvents.map(\.stage)
                == ["stage.old0", "stage.old1", "stage.old2", "stage.old3", "stage.old4", "stage.new"])
        // The ring bound still applies across the relaunch.
        let bounded = OfficeStageRecorder(fileURL: url, eventLimit: 3, fileLimit: 16_384)
        #expect(bounded.allEvents.map(\.stage) == ["stage.old3", "stage.old4", "stage.new"])
    }

    @Test("Recovery reads only the bounded file tail and keeps the newest events")
    func recoveryReadsOnlyTheBoundedTail() throws {
        let url = temporaryTraceURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var raw = ""
        for index in 0..<200 {
            raw += "{\"session\":\"s\",\"generation\":\(index),\"stage\":\"old.\(index)\","
                + "\"detail\":{\"index\":\"\(index)\"},\"at\":0}\n"
        }
        try Data(raw.utf8).write(to: url)

        let recorder = OfficeStageRecorder(fileURL: url, eventLimit: 512, fileLimit: 1_024)
        // Mirror the bounded tail read exactly: only the last fileLimit bytes
        // are eligible, decoded line by line.
        let data = try Data(contentsOf: url)
        let start = max(0, data.count - 1_024)
        let eligible = data.suffix(from: start)
            .split(separator: 0x0A)
            .compactMap { try? JSONDecoder().decode(OfficeStageEvent.self, from: Data($0)) }
            .map(\.stage)
        #expect(!eligible.isEmpty)
        #expect(eligible.count < 200, "an oversized file must not be loaded whole")
        #expect(recorder.allEvents.map(\.stage) == eligible.suffix(512).map { $0 })
        #expect(recorder.exportText().contains("stage=old.199"))
        #expect(!recorder.allEvents.contains { $0.stage == "old.0" })
    }

    @Test("Recovery tolerates malformed lines and re-sanitizes crafted fields")
    func recoveryToleratesDamageAndResanitizes() throws {
        let url = temporaryTraceURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let encoder = JSONEncoder()
        var payload = Data()
        func append(_ event: OfficeStageEvent) throws {
            payload.append(try encoder.encode(event))
            payload.append(0x0A)
        }
        try append(OfficeStageEvent(session: "good-1", generation: 1, stage: "engine.open",
                                    detail: ["success": "true"], at: Date()))
        payload.append(Data("not json at all".utf8))
        payload.append(0x0A)
        try append(OfficeStageEvent(session: "good-2", generation: 2, stage: "workingCopy.open",
                                    detail: ["path": "/var/mobile/Containers/secret.docx",
                                             "long": String(repeating: "x", count: 400),
                                             "ok": "12"],
                                    at: Date()))
        // A crafted identity field with a path and a line break: the whole
        // event is dropped, never exported.
        try append(OfficeStageEvent(session: "/var/mobile/evil\nevents_exported=999",
                                    generation: 3, stage: "stage.evil",
                                    detail: [:], at: Date()))
        try append(OfficeStageEvent(session: "good-3", generation: 4, stage: "render.gate",
                                    detail: [:], at: Date()))
        // Torn tail line: the previous process died mid-write.
        payload.append(Data("{\"session\":\"torn\",\"generation\":5".utf8))
        try payload.write(to: url)

        let recorder = OfficeStageRecorder(fileURL: url)
        #expect(recorder.allEvents.map(\.stage) == ["engine.open", "workingCopy.open", "render.gate"])
        let text = recorder.exportText()
        #expect(text.contains("events_retained=3 events_exported=3"))
        #expect(text.contains("ok=12"))
        #expect(!text.contains("Containers"))
        #expect(!text.contains("/var"))
        #expect(!text.contains("xxx"))
        #expect(!text.contains("evil"))
        #expect(!text.contains("torn"))
        #expect(!text.contains("999"))
    }

    @Test("events_exported reports the lines actually rendered under the byte bound")
    func exportedCountMatchesRenderedLines() {
        let recorder = temporaryRecorder()
        for index in 0..<60 {
            recorder.record(session: "session-\(index)", generation: index,
                            stage: "stage-\(index)",
                            detail: ["payload": String(repeating: "d", count: 40)])
        }
        let text = recorder.exportText(lineLimit: 60, maxBytes: 1_024)
        #expect(text.utf8.count <= 1_024)
        let lines = text.split(separator: "\n")
        let exportedField = lines[0]
            .split(separator: " ")
            .first { $0.hasPrefix("events_exported=") }
            .map { $0.dropFirst("events_exported=".count) }
        let exported = exportedField.flatMap { Int($0) }
        #expect(exported == lines.count - 1, "the header count is the real rendered line count")
        #expect(lines.count - 1 < 60, "the byte bound really trimmed the body")
        #expect(text.contains("at="))
    }
}
#endif

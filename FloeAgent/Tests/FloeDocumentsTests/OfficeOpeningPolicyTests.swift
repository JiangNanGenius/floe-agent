// FloeDocuments — bounded Office opening contract tests.
//
// Build 221 shipped a presentation readiness gate that fails the whole session
// when the pinned engine host never reports a painted slide surface. On the
// device that turned every PPT/PPTX open into an unbounded "opening" state (and
// then a dead-end error) while DOCX/XLSX kept working, because presentations
// were the only formats routed through the visible-render requirement.
//
// These tests characterize the repair: the requirement itself is unchanged
// (a presentation still may not claim a rendered editor), but the bounded
// outcome is now recoverable and every phase is bounded. The three owning entry
// paths (Workspace preview, IDE tab, Notes remembered mode) share one contract.
//
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import FloeDocuments

@Suite("Office bounded opening policy")
struct OfficeOpeningPolicyTests {

    private static let presentationExtensions = [
        "ppt", "pptx", "pptm", "pps", "ppsx", "pot", "potx",
        "odp", "otp", "fodp", "odg", "otg", "fodg",
    ]

    @Test("Presentation formats are the only ones that wait for the engine's first paint")
    func presentationFormatsWaitForRender() {
        for name in Self.presentationExtensions + ["PPTX", "PpTx"] {
            #expect(OfficeOpeningPolicy.requiresVisibleRender(pathExtension: name), Comment(rawValue: name))
        }
        for name in ["docx", "docm", "xlsx", "xlsm", "doc", "xls", "odt", "ods", "rtf", "txt", "pdf", ""] {
            #expect(!OfficeOpeningPolicy.requiresVisibleRender(pathExtension: name), Comment(rawValue: name))
        }
    }

    @Test("The document-layer format list mirrors the App and host lists")
    func formatListMirrorsAppAndHost() throws {
        // Three mirrors exist by design (host decision function, App gate,
        // document-layer policy). The first two are asserted against each other
        // by `office_render_readiness.py`; this asserts the third.
        let expected = Set(Self.presentationExtensions)
        #expect(OfficeOpeningPolicy.presentationExtensions == expected)

        // The App gate's literal list is extracted from the shipped source so a
        // drift cannot pass silently in either direction.
        let source = try Self.appGateSource()
        let literal = try Self.literalExtensions(in: source)
        #expect(literal == expected)
    }

    @Test("Word/Excel keep the open-only contract: ready on open, no warning, no deadline")
    func documentsKeepOpenOnlyContract() {
        for entry in OfficeOpeningPolicy.Intent.allCases {
            var policy = OfficeOpeningPolicy(intent: entry, pathExtension: "docx")
            #expect(policy.outcome == .waiting)
            #expect(policy.openSettled() == .ready)
            #expect(policy.isSettled)
            #expect(policy.warning == nil)
            // A settled document never degrades on a late bound.
            #expect(policy.renderDeadlineElapsed() == .ready)
            #expect(policy.openingDeadlineElapsed() == .ready)
        }
        var workbook = OfficeOpeningPolicy(intent: .ideTab, pathExtension: "xlsx")
        #expect(workbook.openSettled() == .ready)
        #expect(workbook.warning == nil)
    }

    @Test("A presentation reaches the first visible render through every entry path")
    func presentationsSettleReadyOnRenderThroughAllEntryPaths() {
        for entry in OfficeOpeningPolicy.Intent.allCases {
            var policy = OfficeOpeningPolicy(intent: entry, pathExtension: "pptx")
            // The open settles without render evidence: still bounded, never
            // ready and never failed.
            #expect(policy.openSettled() == .waiting, Comment(rawValue: entry.rawValue))
            #expect(!policy.isSettled)
            #expect(policy.warning == nil)
            // The host's visible-render observation settles it ready.
            #expect(policy.renderObserved() == .ready, Comment(rawValue: entry.rawValue))
            #expect(policy.isSettled)
            #expect(policy.warning == nil)
        }
    }

    @Test("A render signal that beats the open report still settles ready")
    func renderBeforeOpenSettlesReady() {
        var policy = OfficeOpeningPolicy(intent: .workspaceEdit, pathExtension: "ppt")
        #expect(policy.renderObserved() == .ready)
        #expect(policy.openSettled() == .ready)
        #expect(policy.warning == nil)
    }

    @Test("A bounded render wait is recoverable, never a dead end, for every entry path")
    func boundedRenderWaitIsRecoverable() {
        for entry in OfficeOpeningPolicy.Intent.allCases {
            var policy = OfficeOpeningPolicy(intent: entry, pathExtension: "pptx")
            _ = policy.openSettled()
            #expect(policy.renderDeadlineElapsed() == .renderUnverified, Comment(rawValue: entry.rawValue))
            #expect(policy.isSettled)

            let warning = try? #require(policy.warning)
            #expect(warning?.actions.contains(.retryPreview) == true)
            #expect(warning?.actions.contains(.dismiss) == true)
            // Never a terminal error: the user can always leave the notice and
            // keep the mounted engine surface.
            #expect(policy.outcome != .failed)
        }
    }

    @Test("A late render observation repairs a bounded render-unverified outcome")
    func lateRenderRepairsUnverifiedOutcome() {
        var policy = OfficeOpeningPolicy(intent: .notesEdit, pathExtension: "pptx")
        _ = policy.openSettled()
        #expect(policy.renderDeadlineElapsed() == .renderUnverified)
        #expect(policy.warning != nil)
        // A genuinely slow paint must never be a permanent failure.
        #expect(policy.renderObserved() == .ready)
        #expect(policy.warning == nil)
    }

    @Test("An open that never settles is the only terminal, recoverable outcome")
    func openingDeadlineIsTheOnlyTerminalOutcome() {
        for name in ["pptx", "docx", "xlsx"] {
            var policy = OfficeOpeningPolicy(intent: .workspacePreview, pathExtension: name)
            #expect(policy.openingDeadlineElapsed() == .failed, Comment(rawValue: name))
            #expect(policy.isSettled)
            let warning = try? #require(policy.warning)
            #expect(warning?.actions.contains(.recover) == true)
            // A late settle can never resurrect a failed open.
            #expect(policy.openSettled() == .failed)
            #expect(policy.renderObserved() == .ready)
        }
    }

    @Test("Budgets are bounded, positive and above the pinned host's own probe deadline")
    func budgetsAreBounded() {
        for entry in OfficeOpeningPolicy.Intent.allCases {
            let policy = OfficeOpeningPolicy(intent: entry, pathExtension: "pptx")
            #expect(policy.openingBudget >= 30 && policy.openingBudget <= 90)
            // The pinned host reports its own bounded render outcome at 20 s
            // (preview) / 25 s (editable); the App-side net must be larger so
            // the host's honest report always wins.
            #expect(policy.renderBudget >= (policy.readOnly ? 20 : 25))
            #expect(policy.renderBudget <= policy.openingBudget)
        }
        let preview = OfficeOpeningPolicy(intent: .workspacePreview, pathExtension: "pptx")
        let editable = OfficeOpeningPolicy(intent: .ideTab, pathExtension: "pptx")
        #expect(preview.readOnly && !editable.readOnly)
        #expect(preview.openingBudget < editable.openingBudget)
        #expect(preview.renderBudget < editable.renderBudget)
    }

    @Test("The visible notice is bilingual, names the retained copy and offers recovery")
    func warningCopyIsActionable() throws {
        var unverified = OfficeOpeningPolicy(intent: .notesEdit, pathExtension: "pptx")
        _ = unverified.openSettled()
        _ = unverified.renderDeadlineElapsed()
        let warning = try #require(unverified.warning)
        #expect(!warning.titleZh.isEmpty && !warning.titleEn.isEmpty)
        #expect(warning.detailZh.contains("编辑副本"))
        #expect(warning.detailEn.contains("retained"))
        #expect(warning.detailZh.contains("重试") || warning.detailZh.contains("恢复"))
        #expect(warning.detailEn.contains("retry") || warning.detailEn.contains("recover"))

        var failed = OfficeOpeningPolicy(intent: .workspacePreview, pathExtension: "docx")
        _ = failed.openingDeadlineElapsed()
        let failure = try #require(failed.warning)
        #expect(failure.actions.contains(.recover))
        #expect(failure.detailZh.contains("保留"))
        #expect(failure.detailEn.contains("retained"))
    }

    @Test("Every entry path reaches a bounded outcome for every Office extension")
    func everyEntryPathIsBounded() {
        var extensions = Self.presentationExtensions
        extensions.append(contentsOf: ["docx", "xlsx", "odt", "ods", "rtf", "pdf"])
        for entry in OfficeOpeningPolicy.Intent.allCases {
            for name in extensions {
                var settled = OfficeOpeningPolicy(intent: entry, pathExtension: name)
                _ = settled.openSettled()
                _ = settled.renderDeadlineElapsed()
                #expect(settled.isSettled, Comment(rawValue: "\(entry.rawValue)/\(name)"))
                #expect(settled.outcome != .waiting, Comment(rawValue: "\(entry.rawValue)/\(name)"))

                var neverOpened = OfficeOpeningPolicy(intent: entry, pathExtension: name)
                #expect(neverOpened.openingDeadlineElapsed() == .failed,
                        Comment(rawValue: "\(entry.rawValue)/\(name)"))
            }
        }
    }

    // MARK: - Source mirror helpers

    /// Locates `FloeApp/Workspace/OfficeDocumentEditorView.swift` from this
    /// test file so the App's literal render-required list can be compared.
    private static func appGateSource() throws -> String {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = folder
                .appendingPathComponent("FloeApp", isDirectory: true)
                .appendingPathComponent("Workspace", isDirectory: true)
                .appendingPathComponent("OfficeDocumentEditorView.swift")
            if let text = try? String(contentsOf: candidate, encoding: .utf8) { return text }
            folder.deleteLastPathComponent()
        }
        throw OfficeOpeningPolicyTestError.appGateSourceMissing
    }

    private static func literalExtensions(in source: String) throws -> Set<String> {
        let marker = "renderRequiredExtensions"
        guard let markerRange = source.range(of: marker) else {
            throw OfficeOpeningPolicyTestError.appGateListMissing
        }
        guard let open = source.range(of: "[", range: markerRange.upperBound..<source.endIndex),
              let close = source.range(of: "]", range: open.upperBound..<source.endIndex) else {
            throw OfficeOpeningPolicyTestError.appGateListMissing
        }
        let body = source[open.upperBound..<close.lowerBound]
        let matches = body.split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"")) }
            .filter { !$0.isEmpty }
        guard !matches.isEmpty else { throw OfficeOpeningPolicyTestError.appGateListMissing }
        return Set(matches)
    }

    private enum OfficeOpeningPolicyTestError: Error {
        case appGateSourceMissing
        case appGateListMissing
    }
}

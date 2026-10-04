// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && DEBUG
import Foundation
import FloeDocuments
import FloePersistence
import FloeWorkspace

/// Debug-only workspace fixture for the cloud simulator Office stage run.
///
/// It generates a real PPTX (title, bullets, a native editable chart and a
/// shape) and a real DOCX through the same OOXML builders the product uses,
/// then writes them into the shared task-root workspace seeded by
/// `--ui-test-batch-fixture`. That lets the Workspace preview, IDE tab and
/// Notes entry paths be driven against real documents without a native
/// engine, and with no test-only control inside the product UI. Gated on
/// `-ui-testing` plus an explicit launch argument; idempotent per install.
@MainActor
enum OfficeWorkspaceStageFixture {
    static let launchArgument = "--ui-test-office-workspace-fixture"
    static let deckName = "办公验收-演示.pptx"
    static let wordName = "办公验收-文稿.docx"

    static func seedIfRequested(environment: AppEnvironment) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"), arguments.contains(launchArgument) else { return }
        let fixtureID = UUID(uuidString: "57C0A79F-CF1B-45D2-B640-EF54E5C55391")!
        do {
            let record = try await SQLiteWorkspaceStore(database: environment.database)
                .ensureWorkspace(conversationID: fixtureID, title: "批量选择测试")
            let lease = try await environment.workspaceCenter.acquireTaskRoot(record, conversationID: fixtureID)
            defer { lease.release() }
            let deck = lease.url.appendingPathComponent(deckName)
            if !FileManager.default.fileExists(atPath: deck.path) {
                try OfficeDocumentBuilder.createPresentation(at: deck, title: "Floe 演示验收", slides: [
                    OfficePresentationSlide(title: "Floe 演示验收", bullets: [
                        "真实 PPTX：首帧、编辑与写回链路",
                        "Cloud iPad simulator stage trace",
                    ], notes: "Simulator host blocker probe"),
                    OfficePresentationSlide(title: "对象与图表", bullets: [
                        "原生可编辑图表",
                        "形状与文本对象",
                    ], objects: [
                        OfficePresentationObject(kind: .shape, layout: .right,
                                                 text: ["形状"],
                                                 shape: .roundedRectangle,
                                                 fillColor: "1F6FEB",
                                                 textColor: "FFFFFF", bold: true),
                        OfficePresentationObject(kind: .chart, layout: .left,
                                                 chart: OfficePresentationChart(
                                                    chartType: .bar,
                                                    title: "季度收入",
                                                    categories: ["Q1", "Q2", "Q3"],
                                                    series: [OfficePresentationChartSeries(
                                                        name: "收入", values: [120, 150, 168])])),
                    ]),
                ])
            }
            let word = lease.url.appendingPathComponent(wordName)
            if !FileManager.default.fileExists(atPath: word.path) {
                try OfficeDocumentBuilder.createWord(at: word, title: "Floe 文稿验收", paragraphs: [
                    "真实 DOCX，用于 DOCX 入口回归。",
                    "DOCX entry regression fixture.",
                ])
            }
        } catch {
            // A fixture failure leaves the pre-existing workspace untouched.
        }
    }
}
#endif

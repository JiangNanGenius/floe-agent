// SPDX-License-Identifier: MPL-2.0
// Real imported chart native rendering/save/reopen plus independent opt-in
// native ChartDataDialog UI edits. No package mutation, builder substitution
// or formal datasource API is invented for either scenario.
#if canImport(UIKit) && canImport(FloeOfficeNative) && targetEnvironment(simulator) && DEBUG
import Foundation
import XCTest
import UIKit
import SwiftUI
import WebKit
import ZIPFoundation
import CryptoKit
import FloeOfficeNative
@testable import FloeApp

@MainActor
final class OfficeNativeChartAppQualificationTests: XCTestCase {
    func testOriginalFiveCategoryChartNativeRenderAndUneditedSaveReopen() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FLOE_NATIVE_CHART_APP_QUALIFICATION"] == "1" else { throw XCTSkip("Opt-in native imported-chart qualification") }
        let input = URL(fileURLWithPath: try XCTUnwrap(env["FLOE_NATIVE_CHART_INPUT"], "Stage the original private fixture, then supply its App-readable path"))
        XCTAssertEqual(try digest(input), "6e087c89a1f29cf9b90d891f6d907c3f916fb6ae42b08a6f99a2ea17a067c961", "Wrong original; do not regenerate or pre-edit")
        executionTimeAllowance = 480; continueAfterFailure = true
        let fm = FileManager.default
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = docs.appendingPathComponent("Qualification/OfficeChart-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        print("FLOE_NATIVE_CHART_ARTIFACT_ROOT=\(root.path)")
        let source = root.appendingPathComponent("original.pptx"); try fm.copyItem(at: input, to: source)
        attach(source, "chart-original-pptx")
        let original = try inspect(source, evidenceRoot: root, stage: "original")
        XCTAssertEqual(original.categories, ["场地", "拍摄", "印刷", "茶歇 90人", "体验物料 90人"])
        XCTAssertEqual(original.values, [1800, 900, 240, 1620, 1080])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        defer { previousKeyWindow?.makeKey() }
        let session = OfficeFileSession(); let window = mount(session, scene)
        defer { window.isHidden = true; window.rootViewController = nil }
        let output = root.appendingPathComponent("native-saved.pptx")
        do {
            await session.open(source)
            try await waitReady(session)
            try await captureChart(session, root: root, stage: "original-preview", window: window, requireOriginalFiveBars: true)
            if session.readOnly {
                let accepted = await session.requestEditing()
                XCTAssertTrue(accepted, "Native edit entry rejected")
            }
            try await wait(150, "editable chart document") { !session.readOnly && session.canAct && session.documentActionsReady }
            // Real native save/export. Never patch or restore embedded data
            // ourselves; existing save validation remains in force.
            let nativeOutput = try await session.exportDocument(format: "pptx")
            try fm.copyItem(at: nativeOutput, to: output)
            attach(output, "chart-native-saved-pptx")
            await capturePostSavePDFDiagnostic(session, root: root, savedPPTX: output)
            let saved = try inspect(output, evidenceRoot: root, stage: "saved")
            XCTAssertEqual(saved.categories, original.categories, "Native save changed/dropped categories")
            XCTAssertEqual(saved.values, original.values, "Native save changed/dropped values")
            XCTAssertEqual(try digest(source), try digest(input), "Original was overwritten")
            let report: [String: Any] = [
                "sourceSHA256": try digest(source), "outputSHA256": try digest(output),
                "scenario": "original-native-render-unedited-save-reopen",
                "nativeChartDataEdit": "not-tested-no-reliable-App-bridge",
                "categories": saved.categories, "values": saved.values,
                "externalDataAndWorkbookChecked": true, "cacheWorkbookAgreementChecked": true,
                "visualReview": "pending-primary-image-review"
            ]
            let receipt = root.appendingPathComponent("verification.json")
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: receipt)
            attach(receipt, "chart-structure-verification")
            await session.release()
        } catch { await session.release(); throw error }
        window.isHidden = true; window.rootViewController = nil
        let reopened = OfficeFileSession(); let reopenedWindow = mount(reopened, scene)
        defer { reopenedWindow.isHidden = true; reopenedWindow.rootViewController = nil }
        do {
            await reopened.open(output); try await waitReady(reopened)
            try await captureChart(reopened, root: root, stage: "native-saved-reopened", window: reopenedWindow, requireOriginalFiveBars: true)
            await reopened.release()
        } catch { await reopened.release(); throw error }
    }

    func testOriginalChartNativeDataDialogEditSaveAndReopen() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FLOE_NATIVE_CHART_UI_EDIT_QUALIFICATION"] == "1" else { throw XCTSkip("Opt-in actual native chart dialog editing") }
        let input = URL(fileURLWithPath: try XCTUnwrap(env["FLOE_NATIVE_CHART_INPUT"]))
        guard try digest(input) == "6e087c89a1f29cf9b90d891f6d907c3f916fb6ae42b08a6f99a2ea17a067c961" else {
            throw failure("Actual original fixture hash gate failed")
        }
        let driverURL = URL(fileURLWithPath: try XCTUnwrap(env["FLOE_NATIVE_CHART_UI_DRIVER"]))
        let expectedDriverHash = try XCTUnwrap(env["FLOE_NATIVE_CHART_UI_DRIVER_SHA256"]).lowercased()
        let actualDriverHash = try digest(driverURL)
        guard expectedDriverHash.count == 64, actualDriverHash == expectedDriverHash else {
            throw failure("Private actual UI driver hash gate failed")
        }
        let driver = try String(contentsOf: driverURL, encoding: .utf8)
        executionTimeAllowance = 600; continueAfterFailure = true
        let fm = FileManager.default
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = docs.appendingPathComponent("Qualification/OfficeChartEdit-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        print("FLOE_NATIVE_CHART_EDIT_ARTIFACT_ROOT=\(root.path)")
        let source = root.appendingPathComponent("original.pptx"); try fm.copyItem(at: input, to: source)
        attach(source, "chart-edit-original")
        let original = try inspect(source, evidenceRoot: root, stage: "original")
        XCTAssertEqual(original.categories, ["场地", "拍摄", "印刷", "茶歇 90人", "体验物料 90人"])
        XCTAssertEqual(original.values, [1800,900,240,1620,1080])
        let originalTexts = try slideAndNoteTexts(source)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        defer { previous?.makeKey() }
        let session = OfficeFileSession(); let window = mount(session, scene)
        defer { window.isHidden = true; window.rootViewController = nil }
        let output = root.appendingPathComponent("native-chart-edited.pptx")
        do {
            await session.open(source); try await waitReady(session)
            if session.readOnly {
                let accepted = await session.requestEditing()
                guard accepted else { throw failure("Real chart document edit entry rejected") }
            }
            try await wait(150, "editable native chart for actual dialog") { !session.readOnly && session.canAct && session.documentActionsReady }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await wait(45, "native chart edit surface paint") { OfficeFileSession.hostRenderDiagnostics(native)["stage"] == "visible-render" }
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            _ = try await web.evaluateJavaScript(driver)
            try await performChartUI("navigateOriginalSlide4", web: web, root: root, stage: "01-chart-slide", window: window)
            try await performChartUI("activateOriginalChart", web: web, root: root, stage: "02-entered-native-chart", window: window)
            try await performChartUI("openDataDialog", web: web, root: root, stage: "03-original-native-grid", window: window)
            try await performChartUI("editUniqueVisibleCell", parameters: ["场地", "场地 QA"], web: web, root: root, stage: "04-category-ui-commit", window: window)
            try await performChartUI("editUniqueVisibleCell", parameters: ["1800", "2100"], web: web, root: root, stage: "05-modified-native-grid", window: window)
            try await performChartUI("closeDataDialog", web: web, root: root, stage: "06-native-dialog-closed", window: window)
            try await performChartUI("exitChartWithExistingEscape", web: web, root: root, stage: "07-native-chart-exited", window: window)
            let nativeOutput = try await session.exportDocument(format: "pptx")
            try fm.copyItem(at: nativeOutput, to: output); attach(output, "chart-edited-native-saved-pptx")
            await capturePostSavePDFDiagnostic(session, root: root, savedPPTX: output)
            let saved = try inspect(output, evidenceRoot: root, stage: "edited-saved")
            XCTAssertEqual(saved.categories, ["场地 QA", "拍摄", "印刷", "茶歇 90人", "体验物料 90人"])
            XCTAssertEqual(saved.values, [2100,900,240,1620,1080])
            let savedTexts = try slideAndNoteTexts(output)
            for (part, text) in originalTexts { XCTAssertEqual(savedTexts[part], text, "Original slide/notes text lost: \(part)") }
            XCTAssertEqual(try digest(source), try digest(input), "Chart UI edit overwrote original")
            let receipt: [String: Any] = [
                "scenario": "actual-native-chart-dialog-edit-save-reopen", "driverSHA256": actualDriverHash,
                "sourceSHA256": try digest(source), "outputSHA256": try digest(output),
                "categories": saved.categories, "values": saved.values,
                "originalTextPartsChecked": originalTexts.count,
                "externalDataAndWorkbookChecked": true, "cacheWorkbookAgreementChecked": true,
                "formulasAddressActualWorkbookChecked": true, "visualReview": "pending-primary-image-review"
            ]
            let receiptURL = root.appendingPathComponent("verification.json")
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted,.sortedKeys]).write(to: receiptURL)
            attach(receiptURL, "chart-native-ui-edit-verification")
            _ = try? await web.evaluateJavaScript("window.__floeChartQA && window.__floeChartQA.detach();")
            await session.release()
        } catch { await session.release(); throw error }
        window.isHidden = true; window.rootViewController = nil
        let reopened = OfficeFileSession(); let reopenWindow = mount(reopened, scene)
        defer { reopenWindow.isHidden = true; reopenWindow.rootViewController = nil }
        do {
            await reopened.open(output); try await waitReady(reopened)
            try await captureChart(reopened, root: root, stage: "08-edited-native-saved-reopened", window: reopenWindow)
            let native = try XCTUnwrap(reopened.controller as? FloeOfficeNativeViewController)
            let reopeningReceipt: [String: Any] = ["savedCopyReopened": true,
                "outputSHA256": try digest(output), "selectedChartPart": 3,
                "nativeRenderDiagnostics": OfficeFileSession.hostRenderDiagnostics(native),
                "visualReview": "pending-primary-image-review"]
            let reopeningURL = root.appendingPathComponent("08-edited-native-saved-reopened.json")
            try JSONSerialization.data(withJSONObject: reopeningReceipt, options: [.prettyPrinted,.sortedKeys]).write(to: reopeningURL)
            attach(reopeningURL, "08-edited-native-reopen-observation")
            await reopened.release()
        } catch { await reopened.release(); throw error }
    }

    func testOriginalChartNativeSeriesInsertDeleteSaveAndReopen() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FLOE_NATIVE_CHART_SERIES_QUALIFICATION"] == "1" else { throw XCTSkip("Opt-in actual native series insert/delete") }
        let input = URL(fileURLWithPath: try XCTUnwrap(env["FLOE_NATIVE_CHART_INPUT"]))
        let originalHash = "6e087c89a1f29cf9b90d891f6d907c3f916fb6ae42b08a6f99a2ea17a067c961"
        guard try digest(input) == originalHash else { throw failure("Actual original fixture hash mismatch") }
        let driverURL = URL(fileURLWithPath: try XCTUnwrap(env["FLOE_NATIVE_CHART_UI_DRIVER"]))
        let driverHash = try XCTUnwrap(env["FLOE_NATIVE_CHART_UI_DRIVER_SHA256"])
        guard driverHash.count == 64, try digest(driverURL) == driverHash else { throw failure("Actual UI driver hash mismatch") }
        let driver = try String(contentsOf: driverURL, encoding: .utf8)
        executionTimeAllowance = 1200; continueAfterFailure = false
        let fm = FileManager.default
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = docs.appendingPathComponent("Qualification/OfficeChartSeries-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        print("FLOE_NATIVE_CHART_SERIES_ROOT=\(root.path)")
        let original = root.appendingPathComponent("original.pptx"); try fm.copyItem(at: input, to: original)
        let originalTexts = try slideAndNoteTexts(original)
        let originalSecondary = try inspectSecondaryChart(original, root: root)
        _ = try inspect(original, evidenceRoot: root, stage: "original")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow); defer { previous?.makeKey() }
        var nextInput = original
        for (phase, operation, expectedCount) in [("added", "addVerifiedSeries", 2), ("deleted", "deleteVerifiedAddedSeries", 1)] {
            let phaseRoot = root.appendingPathComponent(phase, isDirectory: true)
            try fm.createDirectory(at: phaseRoot, withIntermediateDirectories: true)
            let session = OfficeFileSession(); let window = mount(session, scene)
            defer { window.isHidden = true; window.rootViewController = nil }
            let output = phaseRoot.appendingPathComponent("native-saved.pptx")
            do {
                await session.open(nextInput); try await waitReady(session)
                if session.readOnly { guard await session.requestEditing() else { throw failure("Native series edit rejected") } }
                try await wait(150, "editable native series document") { !session.readOnly && session.canAct && session.documentActionsReady }
                let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
                let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
                _ = try await web.evaluateJavaScript(driver)
                try await performChartUI("navigateOriginalSlide4", web: web, root: phaseRoot, stage: "01-target", window: window)
                try await performChartUI("activateOriginalChart", web: web, root: phaseRoot, stage: "02-chart", window: window)
                try await performChartUI("openDataDialog", web: web, root: phaseRoot, stage: "03-grid-before", window: window)
                try await performChartUI(operation, web: web, root: phaseRoot, stage: "04-grid-after", window: window)
                try await performChartUI("closeDataDialog", web: web, root: phaseRoot, stage: "05-dialog-closed", window: window)
                try await performChartUI("exitChartWithExistingEscape", web: web, root: phaseRoot, stage: "06-chart-exited", window: window)
                let produced = try await session.exportDocument(format: "pptx")
                try fm.copyItem(at: produced, to: output); attach(output, "chart-series-\(phase)-saved")
                let facts = try inspectSeriesRoundtrip(output, expectedCount: expectedCount, root: phaseRoot)
                XCTAssertEqual(try inspectSecondaryChart(output, root: phaseRoot), originalSecondary, "Second chart data/formulas/workbook changed during first-chart transaction")
                let texts = try slideAndNoteTexts(output)
                for (part, text) in originalTexts { XCTAssertEqual(texts[part], text, "Original slide/notes changed: \(part)") }
                XCTAssertEqual(try digest(original), originalHash)
                let receipt = phaseRoot.appendingPathComponent("series-verification.json")
                var report = facts; report["driverSHA256"] = driverHash; report["outputSHA256"] = try digest(output)
                report["actualNativeUIAction"] = operation; report["visualReview"] = "pending-primary"
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: receipt)
                attach(receipt, "chart-series-\(phase)-verification")
                await session.release()
            } catch { await session.release(); throw error }
            window.isHidden = true; window.rootViewController = nil
            let reopened = OfficeFileSession(); let reopenWindow = mount(reopened, scene)
            defer { reopenWindow.isHidden = true; reopenWindow.rootViewController = nil }
            do {
                await reopened.open(output); try await waitReady(reopened)
                try await captureChart(reopened, root: phaseRoot, stage: "07-fresh-reopen", window: reopenWindow)
                await reopened.release()
            } catch { await reopened.release(); throw error }
            nextInput = output
        }
        XCTAssertEqual(try digest(input), originalHash, "Private original fixture changed")
    }

    /// Independent unchanged-second-chart check: resolves its own actual
    /// relationship and reads the embedded workbook rather than copying it.
    private func inspectSecondaryChart(_ url: URL, root: URL) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        let chart = ChartSeriesTransactionXML()
        let parser = XMLParser(data: try bytes("ppt/charts/chart2.xml", archive))
        parser.shouldResolveExternalEntities = false; parser.delegate = chart
        guard parser.parse(), !chart.series.isEmpty else { throw failure("Original second chart missing/invalid") }
        let relationID = try XCTUnwrap(chart.externalID, "Second chart externalData missing")
        let rels = NativeChartSeries(); try parse(try bytes("ppt/charts/_rels/chart2.xml.rels", archive), rels)
        let relation = try XCTUnwrap(rels.relationships[relationID]); let target = try XCTUnwrap(relation["Target"])
        guard relation["TargetMode"] != "External", (relation["Type"] ?? "").hasSuffix("/package"),
              !target.hasPrefix("/"), !target.contains(":"), !target.contains("\\"), !target.contains("%") else { throw failure("Invalid second chart workbook reference") }
        var parts = ["ppt", "charts"]
        for part in target.split(separator: "/") {
            if part == ".." { guard !parts.isEmpty else { throw failure("Second workbook escapes package") }; parts.removeLast() }
            else if part != "." { parts.append(String(part)) }
        }
        guard parts.starts(with: ["ppt", "embeddings"]) else { throw failure("Second chart workbook not embedded") }
        let bookURL = root.appendingPathComponent("actual-secondary-workbook.xlsx")
        try bytes(parts.joined(separator: "/"), archive).write(to: bookURL); attach(bookURL, "actual-second-chart-workbook")
        let workbook = try Archive(url: bookURL, accessMode: .read)
        let book = NativeChartSeries(); try parse(try bytes("xl/workbook.xml", workbook), book)
        let sheetName = try XCTUnwrap(book.sheetNames.first)
        let strings = NativeChartSeries(); if workbook["xl/sharedStrings.xml"] != nil { try parse(try bytes("xl/sharedStrings.xml", workbook), strings) }
        let sheet = NativeChartSeries(); try parse(try bytes("xl/worksheets/sheet1.xml", workbook), sheet)
        func text(_ key: String) -> String {
            let value = sheet.cells[key] ?? ""
            if sheet.cellTypes[key] == "s", let i = Int(value), strings.sharedStrings.indices.contains(i) { return strings.sharedStrings[i] }
            return value
        }
        var summaries: [[String: Any]] = []
        for (index, series) in chart.series.enumerated() {
            guard index < 25, !series.categories.isEmpty, series.categories.count == series.values.count else { throw failure("Second chart series shape invalid") }
            let column = String(UnicodeScalar(66 + index)!)
            let finalRow = series.categories.count + 1
            XCTAssertEqual((2...finalRow).map { text("A\($0)") }, series.categories)
            XCTAssertEqual((2...finalRow).compactMap { Double(text("\(column)\($0)")) }, series.values)
            XCTAssertEqual(text("\(column)1"), series.name)
            XCTAssertTrue(series.nameFormula.contains(sheetName) && series.nameFormula.hasSuffix("$\(column)$1"))
            XCTAssertTrue(series.categoryFormula.contains(sheetName) && series.categoryFormula.hasSuffix("$A$2:$A$\(finalRow)"))
            XCTAssertTrue(series.valueFormula.contains(sheetName) && series.valueFormula.hasSuffix("$\(column)$2:$\(column)$\(finalRow)"))
            summaries.append(["name": series.name, "categories": series.categories, "values": series.values,
                "nameFormula": series.nameFormula, "categoryFormula": series.categoryFormula, "valueFormula": series.valueFormula])
        }
        let cells = Dictionary(uniqueKeysWithValues: sheet.cells.keys.compactMap { key -> (String, String)? in
            let value = text(key); return value.isEmpty ? nil : (key, value)
        })
        let semantic: [String: Any] = ["series": summaries, "workbookSheets": book.sheetNames, "actualWorkbookCells": cells]
        return String(decoding: try JSONSerialization.data(withJSONObject: semantic, options: [.sortedKeys]), as: UTF8.self)
    }

    private func inspectSeriesRoundtrip(_ url: URL, expectedCount: Int, root: URL) throws -> [String: Any] {
        let archive = try Archive(url: url, accessMode: .read)
        let expectedCategories = ["场地", "拍摄", "印刷", "茶歇 90人", "体验物料 90人"]
        for entry in archive where entry.path.hasPrefix("ppt/charts/chart") && entry.path.hasSuffix(".xml") {
            let reader = ChartSeriesTransactionXML()
            let parser = XMLParser(data: try bytes(entry.path, archive)); parser.shouldResolveExternalEntities = false; parser.delegate = reader
            guard parser.parse() else { throw parser.parserError ?? failure("Series chart XML invalid") }
            guard reader.series.first?.categories == expectedCategories else { continue }
            XCTAssertEqual(reader.series.count, expectedCount, "Added/deleted native series count differs")
            guard reader.series.count == expectedCount else { throw failure("Actual series count mismatch") }
            XCTAssertEqual(reader.series[0].values, [1800,900,240,1620,1080], "Original series modified")
            XCTAssertEqual(reader.series[0].name, "金额（元）", "Original series name changed")
            let relID = try XCTUnwrap(reader.externalID, "c:externalData missing after series edit")
            let relations = NativeChartSeries()
            try parse(try bytes("ppt/charts/_rels/" + (entry.path as NSString).lastPathComponent + ".rels", archive), relations)
            let relation = try XCTUnwrap(relations.relationships[relID]); let target = try XCTUnwrap(relation["Target"])
            XCTAssertNotEqual(relation["TargetMode"], "External"); XCTAssertTrue((relation["Type"] ?? "").hasSuffix("/package"))
            guard !target.hasPrefix("/"), !target.contains(":"), !target.contains("\\"), !target.contains("%") else { throw failure("Invalid workbook reference") }
            var components = ["ppt", "charts"]
            for part in target.split(separator: "/") {
                if part == ".." { guard !components.isEmpty else { throw failure("Escaped workbook path") }; components.removeLast() }
                else if part != "." { components.append(String(part)) }
            }
            guard components.starts(with: ["ppt", "embeddings"]) else { throw failure("Workbook outside actual embedding") }
            let workbookURL = root.appendingPathComponent("actual-series-workbook.xlsx")
            try bytes(components.joined(separator: "/"), archive).write(to: workbookURL); attach(workbookURL, "actual-series-workbook")
            let workbook = try Archive(url: workbookURL, accessMode: .read)
            let book = NativeChartSeries(); try parse(try bytes("xl/workbook.xml", workbook), book)
            let sheetName = try XCTUnwrap(book.sheetNames.first)
            let strings = NativeChartSeries(); if workbook["xl/sharedStrings.xml"] != nil { try parse(try bytes("xl/sharedStrings.xml", workbook), strings) }
            let sheet = NativeChartSeries(); try parse(try bytes("xl/worksheets/sheet1.xml", workbook), sheet)
            func text(_ cell: String) -> String {
                let value = sheet.cells[cell] ?? ""
                if sheet.cellTypes[cell] == "s", let i = Int(value), strings.sharedStrings.indices.contains(i) { return strings.sharedStrings[i] }
                return value
            }
            XCTAssertEqual((2...6).map { text("A\($0)") }, expectedCategories)
            for (index, series) in reader.series.enumerated() {
                let column = index == 0 ? "B" : "C"
                XCTAssertEqual(series.categories, expectedCategories)
                XCTAssertEqual(text("\(column)1"), series.name, "Series name cache/workbook mismatch")
                XCTAssertEqual(series.values, (2...6).compactMap { Double(text("\(column)\($0)")) }, "Native cache/workbook mismatch")
                XCTAssertTrue(series.categoryFormula.contains(sheetName) && series.categoryFormula.hasSuffix("$A$2:$A$6"))
                XCTAssertTrue(series.valueFormula.contains(sheetName) && series.valueFormula.hasSuffix("$\(column)$2:$\(column)$6"))
                XCTAssertTrue(series.nameFormula.contains(sheetName) && series.nameFormula.hasSuffix("$\(column)$1"), "Series title formula must address its actual workbook header")
                XCTAssertFalse(series.formulas.contains { $0.isEmpty || Double($0) != nil || $0.hasPrefix("label ") })
                if index == 1 {
                    XCTAssertEqual(series.values, [101,202,303,404,505])
                    XCTAssertEqual(series.name, "FLOE QA Added"); XCTAssertEqual(text("C1"), "FLOE QA Added")
                }
            }
            if expectedCount == 1 {
                XCTAssertFalse(sheet.cells.keys.contains { text($0) == "FLOE QA Added" }, "Deleted label is still referenced by a workbook cell")
                // Unreferenced shared-string pool entries may legitimately
                // survive; only active cells/caches/series define deletion.
            }
            return ["seriesCount": reader.series.count, "categories": expectedCategories,
                "seriesValues": reader.series.map(\.values), "nativeWorkbookAndFormulasVerified": true]
        }
        throw failure("Original five-category chart missing after series transaction")
    }

    private func performChartUI(_ operation: String, parameters: [String] = [], web: WKWebView,
                                root: URL, stage: String, window: UIWindow) async throws {
        do {
            _ = try await web.callAsyncJavaScript(
                "if (!window.__floeChartQA || typeof window.__floeChartQA[operation] !== 'function') throw new Error('verified chart UI driver unavailable'); return JSON.stringify(await window.__floeChartQA[operation](...parameters));",
                arguments: ["operation":operation,"parameters":parameters], in: nil, contentWorld: .page)
            try await recordChartUI(web, root: root, stage: stage, window: window)
        } catch {
            try? await recordChartUI(web, root: root, stage: stage + "-failed", window: window)
            let errorURL = root.appendingPathComponent(stage + "-failure.txt")
            try? Data(error.localizedDescription.utf8).write(to: errorURL); attach(errorURL, stage + "-failure")
            throw error
        }
    }

    private func recordChartUI(_ web: WKWebView, root: URL, stage: String, window: UIWindow) async throws {
        let raw = try await web.callAsyncJavaScript("return JSON.stringify(window.__floeChartQA.observe());", arguments: [:], in: nil, contentWorld: .page)
        let json = try XCTUnwrap(raw as? String)
        guard json.utf8.count < 65_536 else { throw failure("Unexpectedly oversized native chart dialog observation") }
        let observation = root.appendingPathComponent(stage + ".json")
        try Data(json.utf8).write(to: observation); attach(observation, stage + "-observed-native-UI")
        let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true
        let image = try await web.takeSnapshot(configuration: config)
        let surface = root.appendingPathComponent(stage + "-surface.png")
        try XCTUnwrap(image.pngData()).write(to: surface); attach(surface, stage + "-surface")
        let whole = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let wholeURL = root.appendingPathComponent(stage + "-window.png")
        try XCTUnwrap(whole.pngData()).write(to: wholeURL); attach(wholeURL, stage + "-window")
    }

    private func slideAndNoteTexts(_ url: URL) throws -> [String: String] {
        let archive = try Archive(url: url, accessMode: .read); var result: [String: String] = [:]
        for entry in archive where entry.path.hasSuffix(".xml") &&
            (entry.path.hasPrefix("ppt/slides/slide") || entry.path.hasPrefix("ppt/notesSlides/notesSlide")) {
            let reader = NativeChartSeries(); try parse(try bytes(entry.path, archive), reader)
            if !reader.visibleText.isEmpty { result[entry.path] = reader.visibleText }
        }
        return result
    }

    private func inspect(_ url: URL, evidenceRoot: URL, stage: String) throws -> NativeChartSeries {
        let archive = try Archive(url: url, accessMode: .read)
        for entry in archive where entry.path.hasPrefix("ppt/charts/chart") && entry.path.hasSuffix(".xml") {
            let chart = NativeChartSeries(); try parse(try bytes(entry.path, archive), chart)
            guard chart.categories.count == 5 else { continue }
            let relationID = try XCTUnwrap(chart.externalID, "Actual c:externalData missing")
            let relPath = "ppt/charts/_rels/" + (entry.path as NSString).lastPathComponent + ".rels"
            let relations = NativeChartSeries(); try parse(try bytes(relPath, archive), relations)
            let relation = try XCTUnwrap(relations.relationships[relationID])
            XCTAssertNotEqual(relation["TargetMode"], "External", "Expected an actually embedded editable workbook")
            XCTAssertTrue((relation["Type"] ?? "").hasSuffix("/package"))
            let target = try XCTUnwrap(relation["Target"])
            var parts = ["ppt", "charts"]
            for part in target.split(separator: "/") {
                if part == ".." { guard !parts.isEmpty else { throw failure("Workbook target escapes package") }; parts.removeLast() }
                else if part != "." { parts.append(String(part)) }
            }
            guard !target.hasPrefix("/"), !target.contains(":"), !target.contains("\\"), !target.contains("%"),
                  parts.starts(with: ["ppt", "embeddings"]) else { throw failure("Invalid embedded workbook target") }
            let workbookData = try bytes(parts.joined(separator: "/"), archive)
            let workbookURL = evidenceRoot.appendingPathComponent("\(stage)-embedded-chart.xlsx")
            try workbookData.write(to: workbookURL); attach(workbookURL, "\(stage)-chart-workbook")
            let workbook = try Archive(url: workbookURL, accessMode: .read)
            let book = NativeChartSeries(); try parse(try bytes("xl/workbook.xml", workbook), book)
            let sheetName = try XCTUnwrap(book.sheetNames.first)
            let strings = NativeChartSeries()
            if workbook["xl/sharedStrings.xml"] != nil { try parse(try bytes("xl/sharedStrings.xml", workbook), strings) }
            let sheet = NativeChartSeries(); try parse(try bytes("xl/worksheets/sheet1.xml", workbook), sheet)
            let categories = (2...6).map { row -> String in
                let value = sheet.cells["A\(row)"] ?? ""
                if sheet.cellTypes["A\(row)"] == "s", let index = Int(value), strings.sharedStrings.indices.contains(index) { return strings.sharedStrings[index] }
                return value
            }
            XCTAssertEqual(categories, chart.categories, "Chart caches do not match the actual embedded workbook")
            let values = (2...6).compactMap { Double(sheet.cells["B\($0)"] ?? "") }
            XCTAssertEqual(values, chart.values)
            XCTAssertTrue(chart.categoryFormula.contains(sheetName) && chart.categoryFormula.hasSuffix("$A$2:$A$6"), "Category formula no longer addresses actual workbook range")
            XCTAssertTrue(chart.valueFormula.contains(sheetName) && chart.valueFormula.hasSuffix("$B$2:$B$6"), "Value formula no longer addresses actual workbook range")
            XCTAssertFalse(chart.formulas.contains { $0.isEmpty || Double($0) != nil || $0.hasPrefix("label ") }, "Invalid native internal-label formula")
            return chart
        }
        throw failure("No actual five-category chart survived in native PPTX")
    }

    private func captureChart(_ session: OfficeFileSession, root: URL, stage: String, window: UIWindow, requireOriginalFiveBars: Bool = false) async throws {
        let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
        try await wait(45, "native chart paint") { OfficeFileSession.hostRenderDiagnostics(native)["stage"] == "visible-render" }
        let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
        // Actual renderer slide selection; no HTML/canvas substitute. Original
        // chart1 is on slide4 (zero-based 3), confirmed by original rels.
        let navigation: Any?
        do {
            navigation = try await web.callAsyncJavaScript(Self.targetSlideNavigationScript, arguments: [:], in: nil, contentWorld: .page)
        } catch {
            let last = try? await web.evaluateJavaScript("JSON.stringify(window.__floeChartTargetObservation || {targetObservationUnavailable:true})")
            if let json = last as? String {
                let diagnostic = root.appendingPathComponent(stage + "-target-failed.json")
                try? Data(json.utf8).write(to: diagnostic); attach(diagnostic, stage + "-target-failed")
            }
            let failed = WKSnapshotConfiguration(); failed.afterScreenUpdates = true
            if let image = try? await web.takeSnapshot(configuration: failed), let png = image.pngData() {
                let snapshot = root.appendingPathComponent(stage + "-target-failed.png")
                try? png.write(to: snapshot); attach(snapshot, stage + "-target-failed-surface")
            }
            throw error
        }
        let navigationJSON = try XCTUnwrap(navigation as? String)
        let observation = root.appendingPathComponent(stage + "-target-observation.json")
        try Data(navigationJSON.utf8).write(to: observation); attach(observation, stage + "-target-observation")
        let facts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(navigationJSON.utf8)) as? [String: Any])
        let rect = try XCTUnwrap(facts["targetCSSRect"] as? [String: NSNumber])
        let targetConfiguration = WKSnapshotConfiguration(); targetConfiguration.afterScreenUpdates = true
        targetConfiguration.rect = CGRect(x: try XCTUnwrap(rect["x"]).doubleValue, y: try XCTUnwrap(rect["y"]).doubleValue,
            width: try XCTUnwrap(rect["width"]).doubleValue, height: try XCTUnwrap(rect["height"]).doubleValue)
        let targetImage = try await web.takeSnapshot(configuration: targetConfiguration)
        let targetURL = root.appendingPathComponent(stage + "-target-slide.png")
        try XCTUnwrap(targetImage.pngData()).write(to: targetURL); attach(targetURL, stage + "-actual-target-slide")
        if requireOriginalFiveBars {
            // Only the hash-locked original five-category fixture, never the
            // edited/series scenarios. Actual target snapshot is preserved even
            // on failure; PDF pixels are not used for native acceptance.
            let visibility = Self.originalFiveBarVisibility(targetImage)
            let numeric = root.appendingPathComponent(stage + "-five-bar-visibility.json")
            try JSONSerialization.data(withJSONObject: visibility, options: [.prettyPrinted,.sortedKeys]).write(to: numeric)
            attach(numeric, stage + "-five-bar-visibility")
            XCTAssertEqual(visibility["geometryValid"] as? Bool, true, "Fixed original slide geometry could not be checked")
            if let bars = visibility["bars"] as? [[String: Any]] {
                XCTAssertEqual(bars.count, 5)
                for bar in bars {
                    XCTAssertEqual(bar["visible"] as? Bool, true,
                        "Original chart column \(bar["index"] ?? "?") is not visibly filled in actual native target snapshot")
                }
            }
            XCTAssertEqual(visibility["allFiveVisible"] as? Bool, true, "Native chart must visibly render all five original bars")
        }
        let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true
        let image = try await web.takeSnapshot(configuration: config)
        let surface = root.appendingPathComponent(stage + "-surface.png")
        try XCTUnwrap(image.pngData()).write(to: surface); attach(surface, stage + "-surface")
        let whole = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let windowURL = root.appendingPathComponent(stage + "-window.png")
        try XCTUnwrap(whole.pngData()).write(to: windowURL); attach(windowURL, stage + "-window")
    }

    /// Bounded pixel qualification for this exact fixed slide4 fixture only.
    /// Plot x/y geometry was independently checked against its native PDF
    /// reference and actual slide snapshots, with the original data hash gate.
    /// Read bar interiors; no OCR, axes/legend text or generic blue-pixel total.
    private static func originalFiveBarVisibility(_ image: UIImage) -> [String: Any] {
        guard image.imageOrientation == .up, let source = image.cgImage else {
            return ["geometryValid": false, "allFiveVisible": false, "reason": "unsupported-image-orientation", "bars": []]
        }
        let ratio = Double(source.width) / Double(source.height)
        guard source.width >= 320, source.height >= 180, abs(ratio - 16.0 / 9.0) < 0.012 else {
            return ["geometryValid": false, "allFiveVisible": false, "reason": "unexpected-slide-bounds",
                "sourceWidth": source.width, "sourceHeight": source.height, "bars": []]
        }
        let width = min(source.width, 1600)
        let height = max(1, Int((Double(source.height) * Double(width) / Double(source.width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            // CGBitmapContext memory rows from this CGImage draw match the
            // source image's top-left raster rows; no UIKit view transform.
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return ["geometryValid": false, "allFiveVisible": false, "reason": "pixel-buffer-unavailable", "bars": []] }
        let values = [1800.0, 900, 240, 1620, 1080]
        let centers = [0.1554, 0.2532, 0.3511, 0.4490, 0.5470]
        let baseline = 0.7376, plotHeight = 0.3070, halfWidth = 0.0135, inset = 0.004
        var bars: [[String: Any]] = []
        for index in values.indices {
            let x1 = max(0, Int(((centers[index] - halfWidth) * Double(width)).rounded(.up)))
            let x2 = min(width, Int(((centers[index] + halfWidth) * Double(width)).rounded(.down)))
            let y1 = max(0, Int(((baseline - plotHeight * values[index] / 2000 + inset) * Double(height)).rounded(.up)))
            let y2 = min(height, Int(((baseline - inset) * Double(height)).rounded(.down)))
            var blue = 0, count = 0
            if x2 > x1, y2 > y1 {
                for y in y1..<y2 { for x in x1..<x2 {
                    let offset = (y * width + x) * 4
                    let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                    if r <= 85 && g >= 60 && g <= 155 && b >= 170 && b - r >= 90 { blue += 1 }
                    count += 1
                }}
            }
            let fill = count > 0 ? Double(blue) / Double(count) : 0
            bars.append(["index": index + 1, "expectedValue": values[index], "x": x1, "y": y1,
                "width": max(0,x2-x1), "height": max(0,y2-y1), "samplePixels": count,
                "bluePixels": blue, "fillFraction": fill, "visible": count >= 24 && fill >= 0.65])
        }
        return ["geometryValid": true, "allFiveVisible": bars.allSatisfy { ($0["visible"] as? Bool) == true },
            "sourceWidth": source.width, "sourceHeight": source.height, "sampleWidth": width, "sampleHeight": height,
            "minimumBlueFillFraction": 0.65, "minimumSamplePixels": 24, "bars": bars,
            "scope": "hash-locked-original-slide4-five-bars; native-snapshot-only"]
    }

    private static let targetSlideNavigationScript = #"""
    const app = window.app, map = app && app.map, layer = map && map._docLayer;
    const container = app && app.sectionContainer;
    const manager = window.RenderManager || (app && app.definitions && app.definitions.RenderManager);
    if (!layer || !container || !manager || typeof manager.getTiles !== 'function') throw new Error('actual target-part tile observation unavailable');
    const started = performance.now(), deadline = Date.now() + 45000;
    const waitState = async predicate => {
        while (Date.now() < deadline) { const value = predicate(); if (value) return value; await new Promise(r=>setTimeout(r,50)); }
        throw new Error('target slide visibility/paint deadline: ' + JSON.stringify(window.__floeChartTargetObservation || {}));
    };
    map.setPart(3);
    await waitState(()=>layer._selectedPart===3 && !layer._isZooming && app.activeDocument && app.activeDocument.activeLayout);
    let layout = app.activeDocument.activeLayout;
    const section = container.getDocumentAnchorSection();
    if (!section || !section.size || typeof layout.scrollTo !== 'function') throw new Error('actual document viewport navigation unavailable');
    if (app.file.fileBasedView) {
        const target = layout.viewRectangles && layout.viewRectangles[3];
        if (!target) throw new Error('file-based target slide rectangle missing');
        // Same existing scrollTo route as PartsPreview._scrollViewToPartPosition,
        // center actual target page without changing zoom, layout or canvas size.
        layout.scrollTo(Math.max(0,target.pX1+(target.pWidth-section.size[0])/2),
                        Math.max(0,target.pY1+(target.pHeight-section.size[1])/2));
    }
    container.requestReDraw();
    const observe = () => {
        layout=app.activeDocument.activeLayout;
        const canvas=container.canvas, css=canvas.getBoundingClientRect(), anchor=container.getDocumentAnchorSection();
        const point=app.activeDocument.fileSize.clone(); point.pX=0; point.pY=0; point.part=3;
        const page=app.file.fileBasedView && layout.viewRectangles && layout.viewRectangles[3];
        let left,top,width,height;
        if (page) {
            left=anchor.myTopLeft[0]+page.pX1-layout.scrollProperties.viewX;
            top=anchor.myTopLeft[1]+page.pY1-layout.scrollProperties.viewY;
            width=page.pWidth; height=page.pHeight;
        } else {
            left=layout.documentToViewX(point); top=layout.documentToViewY(point);
            width=app.activeDocument.fileSize.pX; height=app.activeDocument.fileSize.pY;
        }
        const sx=css.width/canvas.width,sy=css.height/canvas.height;
        const fullyVisible=left>=anchor.myTopLeft[0]-1 && top>=anchor.myTopLeft[1]-1
            && left+width<=anchor.myTopLeft[0]+anchor.size[0]+1 && top+height<=anchor.myTopLeft[1]+anchor.size[1]+1
            && width>1 && height>1;
        const part=String(app.file.fileBasedView ? layer.getPartFromIndex(3) : layer.getSelectedPart());
        const resolvedTargetIndex=typeof layer.getIndexFromPart==='function' ? layer.getIndexFromPart(part) : null;
        // File-based layout includes an inclusive extra grid row/column.
        // TilesSection clips using this same page-local document rectangle;
        // out-of-page tiles are not drawn and cannot prove visible paint.
        const pageBounds=app.file.fileBasedView
            ? (layout.documentRectangles && layout.documentRectangles[3])
            : {pWidth:app.activeDocument.fileSize.pX,pHeight:app.activeDocument.fileSize.pY};
        if (!pageBounds || !(pageBounds.pWidth>0 && pageBounds.pHeight>0)) {
            window.__floeChartTargetObservation={stage:'target-bounds-unavailable',layoutType:layout.type,
                fileBased:!!app.file.fileBasedView,selectedPart:layer._selectedPart,
                documentRectangleCount:layout.documentRectangles ? layout.documentRectangles.length : null,
                fileSizePixels:{width:app.activeDocument.fileSize.pX,height:app.activeDocument.fileSize.pY},
                targetBounds:pageBounds || null};
            throw new Error('target document bounds unavailable');
        }
        // Observe the same enumeration the actual TilesSection.onDraw uses.
        // Single-window Impress painting does not consume layout.currentCoordList.
        const layoutCoords=typeof layout.getCurrentCoordList==='function' ? layout.getCurrentCoordList() : [];
        const tilesSection=container.getSectionWithName(app.CSections.Tiles.name);
        const painter=tilesSection && tilesSection.sectionProperties && tilesSection.sectionProperties.tsManager;
        if (!tilesSection || typeof tilesSection.forEachTileInView!=='function' || !painter || typeof painter._paintContext!=='function')
            throw new Error('actual renderer tile enumeration unavailable');
        const renderedCoords=[];
        tilesSection.forEachTileInView(Math.round(map.getZoom()),part,app.activeDocument.activeModes[0],painter._paintContext(),
            (_tile,coord)=>{renderedCoords.push(coord);return true;});
        const candidates=renderedCoords.filter(c=>String(c.part)===part && manager.isValidTile(c));
        const tileSize=manager.tileSize;
        if (!(tileSize>0)) throw new Error('actual tile size unavailable');
        const intersectsPage=c=>c.x<pageBounds.pWidth && c.y<pageBounds.pHeight && c.x+tileSize>0 && c.y+tileSize>0;
        const coords=app.file.fileBasedView ? candidates.filter(intersectsPage) : candidates;
        const excluded=app.file.fileBasedView ? candidates.filter(c=>!intersectsPage(c)).map(c=>c.key()) : [];
        const all=manager.getTiles(); let decoded=0,painted=0; const missing=[];
        for (const coord of coords) {
            const tile=all.get(coord.key());
            const ready=!!tile && typeof tile.isReadyToDraw==='function' && tile.isReadyToDraw();
            if (ready) decoded++;
            // lastRendered starts as epoch time, not a paint. touchImage sets the
            // monotonic value immediately before real canvas.drawImage in TilesSection.
            if (ready && Number.isFinite(tile.lastRendered) && tile.lastRendered>=started && tile.lastRendered<=performance.now()+1) painted++;
            else if (missing.length<12) missing.push(coord.key());
        }
        const result={selectedPart:layer._selectedPart,targetPartID:part,fileBased:!!app.file.fileBasedView,
            layoutType:layout.type,fullyVisible,resolvedTargetIndex,
            layoutCandidateCount:layoutCoords.length,layoutCandidatePartIDs:Array.from(new Set(layoutCoords.map(c=>String(c.part)))).slice(0,16),
            rendererCandidateCount:renderedCoords.length,rendererCandidatePartIDs:Array.from(new Set(renderedCoords.map(c=>String(c.part)))).slice(0,16),
            rendererCandidateKeys:renderedCoords.slice(0,16).map(c=>c.key()),targetDocumentPixels:{width:pageBounds.pWidth,height:pageBounds.pHeight},excludedOutOfPageTiles:excluded,requiredTargetTiles:coords.length,decodedTargetTiles:decoded,paintedTargetTiles:painted,
            targetCSSRect:{x:css.left+left*sx,y:css.top+top*sy,width:width*sx,height:height*sy},missingTargetTiles:missing};
        window.__floeChartTargetObservation=result;
        return result;
    };
    const result=await waitState(()=>{const r=observe();return r.selectedPart===3 && r.resolvedTargetIndex===3 && r.fullyVisible && r.requiredTargetTiles>0 && r.decodedTargetTiles===r.requiredTargetTiles && r.paintedTargetTiles===r.requiredTargetTiles ? r:null;});
    await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
    return JSON.stringify(result);
    """#

    private func mount(_ session: OfficeFileSession, _ scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: OfficeDocumentSurface(session: session).frame(maxWidth: .infinity, maxHeight: .infinity))
        window.windowLevel = .normal + 1; window.makeKeyAndVisible(); return window
    }
    private func waitReady(_ session: OfficeFileSession) async throws {
        try await wait(120, "native chart open") { session.canAct && session.documentActionsReady && session.controller != nil }
    }
    private func wait(_ seconds: TimeInterval, _ stage: String, _ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready(), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard ready() else { throw failure("Timed out: " + stage) }
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "NativeChartAppQualification", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func bytes(_ name: String, _ archive: Archive) throws -> Data {
        let entry = try XCTUnwrap(archive[name], "Missing actual package part: \(name)"); var result = Data()
        _ = try archive.extract(entry) { result.append($0) }; return result
    }
    private func parse(_ data: Data, _ reader: NativeChartSeries) throws {
        let parser = XMLParser(data: data); parser.delegate = reader; parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw parser.parserError ?? failure("Invalid actual XML") }
    }
    private func digest(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
    /// Supplementary renderer diagnostic, strictly after the original-format
    /// save is retained. It never substitutes for PPTX structure/paint gates.
    private func capturePostSavePDFDiagnostic(_ session: OfficeFileSession, root: URL, savedPPTX: URL) async {
        var facts: [String: Any] = ["purpose": "compare-native-PDF-with-bitmap-chart-rendering",
            "timing": "after-retained-PPTX-before-independent-inspect", "visualReview": "pending-primary",
            "qualifiesPPTX": false]
        do {
            let pptxBefore = try digest(savedPPTX)
            let generated = try await session.exportDocument(format: "pdf")
            let size = try generated.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard size > 5, size <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            let reader = try FileHandle(forReadingFrom: generated)
            defer { try? reader.close() }
            let magic = try reader.read(upToCount: 5)
            guard magic == Data("%PDF-".utf8) else { throw CocoaError(.fileReadCorruptFile) }
            let copy = root.appendingPathComponent("native-post-save-diagnostic.pdf")
            try FileManager.default.copyItem(at: generated, to: copy)
            facts["pdfBytes"] = size; facts["pdfSHA256"] = try digest(copy)
            facts["pdfHeaderVerified"] = true; facts["pdfExportSucceeded"] = true
            facts["retainedPPTXUnchanged"] = (try digest(savedPPTX)) == pptxBefore
            attach(copy, "chart-post-save-render-diagnostic-PDF")
        } catch {
            // A diagnostic export failure must not replace/skip the original
            // independent PPTX validation or its unchanged strict assertions.
            facts["error"] = String(String(describing: error).prefix(1024))
            facts["pdfExportSucceeded"] = false
        }
        let receipt = root.appendingPathComponent("post-save-pdf-diagnostic.json")
        do {
            try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]).write(to: receipt)
            attach(receipt, "chart-post-save-PDF-diagnostic")
        } catch {
            print("Chart supplementary PDF diagnostic receipt unavailable: \(error.localizedDescription.prefix(256))")
        }
    }

    private func attach(_ url: URL, _ name: String) { let attachment = XCTAttachment(contentsOfFile: url); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment) }
}

/// Independent actual OOXML reader; never changes the archive.
private final class NativeChartSeries: NSObject, XMLParserDelegate {
    var categories: [String] = [], values: [Double] = [], formulas: [String] = []
    var categoryFormula = "", valueFormula = "", externalID: String?
    var relationships: [String: [String: String]] = [:], cells: [String: String] = [:], cellTypes: [String: String] = [:]
    var sharedStrings: [String] = [], sheetNames: [String] = [], visibleText = ""
    private var stack: [String] = [], buffer = "", cell = "", shared = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let local = String(name.split(separator: ":").last ?? ""); stack.append(local); buffer = ""
        if local == "externalData" { externalID = attributes["r:id"] }
        if local == "Relationship", let id = attributes["Id"] { relationships[id] = attributes }
        if local == "sheet", let name = attributes["name"] { sheetNames.append(name) }
        if local == "c" { cell = attributes["r"] ?? ""; cellTypes[cell] = attributes["t"] ?? "n" }
        if local == "si" { shared = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
        if stack.last == "t" { visibleText += string }
        if stack.last == "t", stack.contains("si") { shared += string }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let local = String(name.split(separator: ":").last ?? "")
        if local == "v", stack.contains("cat"), stack.contains("pt") { categories.append(buffer) }
        if local == "v", stack.contains("val"), stack.contains("pt"), let value = Double(buffer) { values.append(value) }
        if local == "f" { formulas.append(buffer); if stack.contains("cat") { categoryFormula = buffer }; if stack.contains("val") { valueFormula = buffer } }
        if !cell.isEmpty, local == "v" || local == "t" { cells[cell] = buffer }
        if local == "c" { cell = "" }
        if local == "si" { sharedStrings.append(shared) }
        stack.removeLast(); buffer = ""
    }
}
/// Separate multi-series inspector: original single-series validator is unchanged.
private final class ChartSeriesTransactionXML: NSObject, XMLParserDelegate {
    struct Series {
        var categories: [String] = [], values: [Double] = [], name = ""
        var categoryFormula = "", valueFormula = "", nameFormula = "", formulas: [String] = []
    }
    var series: [Series] = []; var externalID: String?
    private var current: Series?, stack: [String] = [], buffer = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let local = String(name.split(separator: ":").last ?? ""); stack.append(local); buffer = ""
        if local == "ser" { current = Series() }
        if local == "externalData" { externalID = attributes["r:id"] }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let local = String(name.split(separator: ":").last ?? "")
        if local == "v", current != nil {
            if stack.contains("cat"), stack.contains("pt") { current?.categories.append(buffer) }
            if stack.contains("val"), stack.contains("pt"), let value = Double(buffer) { current?.values.append(value) }
            if stack.contains("tx") { current?.name = buffer }
        }
        if local == "f", current != nil {
            current?.formulas.append(buffer)
            if stack.contains("cat") { current?.categoryFormula = buffer }
            if stack.contains("val") { current?.valueFormula = buffer }
            if stack.contains("tx") { current?.nameFormula = buffer }
        }
        if local == "ser", let value = current { series.append(value); current = nil }
        stack.removeLast(); buffer = ""
    }
}
#endif

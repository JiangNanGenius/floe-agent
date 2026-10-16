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
            try await captureChart(session, root: root, stage: "original-preview", window: window)
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
            try await captureChart(reopened, root: root, stage: "native-saved-reopened", window: reopenedWindow)
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

    private func performChartUI(_ operation: String, parameters: [String] = [], web: WKWebView,
                                root: URL, stage: String, window: UIWindow) async throws {
        do {
            _ = try await web.callAsyncJavaScript(
                "if (!window.__floeChartQA || typeof window.__floeChartQA[operation] !== 'function') throw new Error('verified chart UI driver unavailable'); return JSON.stringify(await window.__floeChartQA[operation](...parameters));",
                arguments: ["operation":operation,"parameters":parameters], in: nil, in: .page)
            try await recordChartUI(web, root: root, stage: stage, window: window)
        } catch {
            try? await recordChartUI(web, root: root, stage: stage + "-failed", window: window)
            let errorURL = root.appendingPathComponent(stage + "-failure.txt")
            try? Data(error.localizedDescription.utf8).write(to: errorURL); attach(errorURL, stage + "-failure")
            throw error
        }
    }

    private func recordChartUI(_ web: WKWebView, root: URL, stage: String, window: UIWindow) async throws {
        let raw = try await web.callAsyncJavaScript("return JSON.stringify(window.__floeChartQA.observe());", arguments: [:], in: nil, in: .page)
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

    private func captureChart(_ session: OfficeFileSession, root: URL, stage: String, window: UIWindow) async throws {
        let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
        try await wait(45, "native chart paint") { OfficeFileSession.hostRenderDiagnostics(native)["stage"] == "visible-render" }
        let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
        // Actual renderer slide selection; no HTML/canvas substitute. Original
        // chart1 is on slide4 (zero-based 3), confirmed by original rels.
        _ = try await web.callAsyncJavaScript(#"""
        const map = window.app && window.app.map;
        if (!map || typeof map.setPart !== 'function') throw new Error('native slide navigation unavailable');
        map.setPart(3);
        const deadline = Date.now() + 20000;
        while ((!map._docLayer || map._docLayer._selectedPart !== 3) && Date.now() < deadline)
            await new Promise(resolve => setTimeout(resolve, 100));
        if (!map._docLayer || map._docLayer._selectedPart !== 3) throw new Error('native slide selection did not reach chart slide');
        // Cached tiles do not emit a new alltilesloaded event. Observe actual
        // selected part and compositor turns, then retain pixels for primary
        // review; do not pretend selection proves the five bars painted.
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        return {selectedPart: map._docLayer._selectedPart, chartPixels: 'pending-image-review'};
        """#, arguments: [:], in: nil, in: .page)
        let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true
        let image = try await web.takeSnapshot(configuration: config)
        let surface = root.appendingPathComponent(stage + "-surface.png")
        try XCTUnwrap(image.pngData()).write(to: surface); attach(surface, stage + "-surface")
        let whole = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let windowURL = root.appendingPathComponent(stage + "-window.png")
        try XCTUnwrap(whole.pngData()).write(to: windowURL); attach(windowURL, stage + "-window")
    }

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
#endif

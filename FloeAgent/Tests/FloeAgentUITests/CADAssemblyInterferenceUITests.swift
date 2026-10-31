// FloeAgentUITests — native assembly interference inspector.
//
// The existing real CAD fixture builds a 100×60×10 mm plate with a Ø10
// through-hole through the public command vocabulary. With
// `--ui-test-cad-assembly-interference` it also places three REAL assembly
// occurrences of that immutable body through `CADAssemblyService`:
// A at the origin, B 50 mm along X (a positive exact common), and C 250 mm
// along X (separate from both). No mocked service, precomputed result or
// alternate UI path is used here.
//
// This flow opens the actual CAD Tools → Assembly → Interference sheet,
// inspects the default three-instance/three-pair selection, proves a selected
// subset reduces the pair count, restores it, runs the real check and reads the
// actual service result counts/pair identities from the native inspector.

import XCTest

@MainActor
final class CADAssemblyInterferenceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-ui-testing", "-ui-testing-ipad",
            "--ui-test-cad-fixture",
            "--ui-test-cad-assembly-interference",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testRealInspectorDefaultSelectionSubsetAndActualResult() throws {
        guard waitFor(app.otherElements["CADFixtureHarness"],
                      "the real CAD fixture workbench must launch", timeout: 60) else { return }
        guard openCADTools() else { return }
        guard waitFor(app.otherElements["CADWorkbenchToolsPanel"],
                      "the native CAD tools sheet must open", timeout: 20) else { return }
        expandSheet(named: "CAD Tools")

        // The tools sheet's default mode is the real Assembly panel. Select it
        // explicitly, then wait for its report to contain the three fixture
        // occurrences before opening the inspector: the sheet snapshots the
        // report at presentation.
        let toolsPanel = app.otherElements["CADWorkbenchToolsPanel"]
        let assemblySegment = toolsPanel.segmentedControls.firstMatch.buttons["Assembly"].firstMatch
        if assemblySegment.exists && assemblySegment.isHittable {
            assemblySegment.tap()
        }
        let instanceRows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "CADAssemblyInstanceSelect-"))
        guard waitForCount(instanceRows, 3,
                           "the real fixture must load three assembly occurrences",
                           timeout: 30) else { return }

        let interference = app.buttons["Interference"].firstMatch
        guard revealInAssemblyPanel(interference) else {
            fail("the Assembly panel must expose its ordinary Interference action")
            return
        }
        guard waitUntilEnabled(interference) else {
            fail("the ordinary Interference action must enable after the assembly report loads")
            return
        }
        interference.tap()

        guard waitFor(app.navigationBars["Interference check"],
                      "the native interference inspector must open", timeout: 15) else { return }
        expandSheet(named: "Interference check")

        let pairCount = app.staticTexts["CADAssemblyInterferencePairCount"]
        guard waitFor(pairCount,
                      "the inspector must show its actual selection summary",
                      timeout: 15) else { return }
        guard require(pairCount.label == "3 selected · 3 pairs",
                      "the inspector must start with the real all-instance selection; got \(pairCount.label)") else {
            return
        }

        let toggles = selectionToggles()
        guard require(toggles.count == 3,
                      "the inspector must list exactly three real fixture instances; got \(toggles.count)") else { return }
        let selectionPrefix = "CADAssemblyInterferenceSelection-"
        var surfacedIDs = Set<String>()
        for toggle in toggles {
            guard require(toggle.identifier.hasPrefix(selectionPrefix),
                          "a native instance toggle must carry its real selection identifier") else { return }
            let id = String(toggle.identifier.dropFirst(selectionPrefix.count))
            guard require(UUID(uuidString: id) != nil,
                          "the native selection control must surface its real instance UUID") else { return }
            surfacedIDs.insert(id)
        }
        guard require(surfacedIDs.count == 3,
                      "the three native toggles must be distinct real instances") else { return }
        snapshot("CAD assembly interference inspector - default 3 instances, 3 pairs")

        // Prove the selected subset actually changes the pair count. Two
        // toggles reach zero pairs; both are restored before the real run.
        guard toggleSelection(named: "Plate C") else { return }
        guard waitForPairCount("2 selected · 1 pair") else {
            fail("selecting two real instances must produce exactly one pair")
            return
        }
        guard toggleSelection(named: "Plate B") else { return }
        guard waitForPairCount("1 selected · 0 pairs") else {
            fail("selecting one real instance must produce no pair")
            return
        }
        guard toggleSelection(named: "Plate B") else { return }
        guard waitForPairCount("2 selected · 1 pair") else { return }
        guard toggleSelection(named: "Plate C") else { return }
        guard waitForPairCount("3 selected · 3 pairs") else { return }

        let start = app.buttons["CADAssemblyInterferenceStart"]
        guard revealInSheet(start, direction: .towardBottom) else {
            fail("the native Run check action must remain reachable")
            return
        }
        guard require(start.isEnabled,
                      "the restored three-instance selection must enable the real check") else {
            return
        }
        start.tap()

        guard waitForCompletedSummary(timeout: 180) else {
            fail("the real three-pair interference check did not produce an actual result")
            return
        }
        // Capture the completed counts while the actual result section is in
        // view; Root needs the native proportions, not a synthetic board.
        _ = revealResultSummary()
        snapshot("CAD assembly interference - actual completed result")

        let scan = scanInterferenceSheet()
        guard assertResultValue("CADAssemblyInterferenceResultPairs",
                                equals: "3 / 3", in: scan) else { return }
        guard assertResultValue("CADAssemblyInterferenceResultInterfering",
                                equals: "1", in: scan) else { return }
        guard assertResultValue("CADAssemblyInterferenceResultClearances",
                                equals: "2", in: scan) else { return }
        guard assertResultValue("CADAssemblyInterferenceResultContacts",
                                equals: "0", in: scan) else { return }
        guard assertResultValue("CADAssemblyInterferenceResultUnresolved",
                                equals: "0", in: scan) else { return }
        guard require(scan.labels.contains("Penetrating"),
                      "the actual A/B common must be classified as penetrating") else { return }
        guard require(scan.labels.contains("Separated"),
                      "the two non-overlapping pairs must be classified as separated") else { return }
        for (first, second) in [("Plate A", "Plate B"),
                                ("Plate A", "Plate C"),
                                ("Plate B", "Plate C")] {
            guard require(containsPair(first, second, in: scan.labels),
                          "the actual result must name the \(first)/\(second) pair") else { return }
        }
    }

    // MARK: - Real workbench navigation

    private func openCADTools() -> Bool {
        var button = app.buttons["CADWorkbenchToolsButton"].firstMatch
        if !button.exists || !button.isHittable {
            let overflow = app.navigationBars.buttons["OverflowBarButtonItem"].firstMatch
            guard overflow.waitForExistence(timeout: 5) else {
                fail("the native workbench overflow must expose CAD Tools")
                return false
            }
            overflow.tap()
            let labeled = app.buttons["CAD Tools"].firstMatch
            if labeled.waitForExistence(timeout: 5) { button = labeled }
        }
        guard require(button.waitForExistence(timeout: 10),
                      "the workbench must expose the CAD Tools entry") else { return false }
        guard require(button.isHittable,
                      "the CAD Tools entry must be reachable") else { return false }
        button.tap()
        return true
    }

    private func expandSheet(named title: String) {
        let bar = app.navigationBars[title].firstMatch
        guard bar.waitForExistence(timeout: 10) else { return }
        // Existing native inspector expansion gesture: drag the front sheet's
        // navigation bar, never the background ToolPalette.
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    private func revealInAssemblyPanel(_ element: XCUIElement) -> Bool {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return true }
            // Scope the gesture to the open CAD Tools sheet. The background
            // ToolPalette is also a hittable ScrollView and must never be the
            // scroll target for this sheet.
            guard let target = assemblyScrollTarget() else { return false }
            target.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return element.exists && element.isHittable
    }

    private func assemblyScrollTarget() -> XCUIElement? {
        let sheet = app.otherElements["CADWorkbenchToolsPanel"].firstMatch
        guard sheet.exists else { return nil }
        let panel = sheet.descendants(matching: .any)
            .matching(identifier: "CADAssemblyPanel").firstMatch
        if panel.exists && panel.isHittable { return panel }
        let scroll = sheet.scrollViews.firstMatch
        if scroll.exists && scroll.isHittable { return scroll }
        return nil
    }

    // MARK: - Interference selection

    private func selectionToggles() -> [XCUIElement] {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@", "CADAssemblyInterferenceSelection-")
        let switches = app.switches.matching(predicate).allElementsBoundByIndex
        if !switches.isEmpty { return switches }
        return app.buttons.matching(predicate).allElementsBoundByIndex
    }

    private func toggleSelection(named name: String) -> Bool {
        guard let toggle = selectionToggles().first(where: { $0.label.contains(name) }) else {
            fail("the inspector must expose the real instance \(name) as a native toggle")
            return false
        }
        // A SwiftUI Toggle exposes the full labeled row as its accessibility
        // frame (the existing provider-picker tests pin this behavior), so
        // activate the switch control at its trailing edge rather than the
        // row's center label.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        return true
    }

    private func waitForPairCount(_ expected: String) -> Bool {
        let pairCount = app.staticTexts["CADAssemblyInterferencePairCount"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expected),
            object: pairCount)
        if XCTWaiter().wait(for: [expectation], timeout: 10) == .completed {
            return true
        }
        fail("the actual selection summary must become \(expected); it is \(pairCount.label)")
        return false
    }

    // MARK: - Actual result

    private func waitForCompletedSummary(timeout: TimeInterval) -> Bool {
        let summary = resultElement("CADAssemblyInterferenceResultPairs")
        let errorText = resultElement("CADAssemblyInterferenceError")
        let deadline = Date().addingTimeInterval(timeout)
        var pass = 0
        while Date() < deadline {
            if errorText.exists {
                fail("the real interference check failed: \(errorText.label)")
                return false
            }
            if summary.exists { return true }
            // The result section is inserted above the Run check row. Probe
            // the front List in both directions at a measured cadence instead
            // of hammering it: whichever side the finished section appears on
            // is reached within two probes without touching the background
            // workbench or its tool palette.
            if pass > 0, pass.isMultiple(of: 4), let list = frontSheetList() {
                if (pass / 4).isMultiple(of: 2) { list.swipeDown() } else { list.swipeUp() }
            }
            pass += 1
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        return false
    }

    private struct SheetScan {
        var resultValues: [String: String] = [:]
        var labels = Set<String>()
    }

    /// Read the real result values and pair names by scrolling only the front
    /// sheet's List. Native List virtualizes cells, so a single snapshot is not
    /// enough; 14 positions cover this compact inspector without touching the
    /// background workbench or tool palette.
    private func scanInterferenceSheet() -> SheetScan {
        var scan = SheetScan()
        guard let list = frontSheetList() else { return scan }
        // Return to the first section before walking the whole inspector; the
        // actual selection summary is the top marker, not a background view.
        let pairCount = app.staticTexts["CADAssemblyInterferencePairCount"]
        for _ in 0..<6 {
            if pairCount.exists { break }
            list.swipeDown()
        }
        let resultPredicate = NSPredicate(
            format: "identifier BEGINSWITH %@", "CADAssemblyInterferenceResult")
        for _ in 0..<14 {
            let values = app.descendants(matching: .any)
                .matching(resultPredicate).allElementsBoundByIndex
            for element in values where !element.identifier.isEmpty {
                // This is the real native accessibility value, separate from
                // its label. A substring of a label cannot prove a count.
                scan.resultValues[element.identifier] = element.value as? String ?? ""
            }
            for text in app.staticTexts.allElementsBoundByIndex {
                scan.labels.insert(text.label)
            }
            let identifiers = ["Pairs", "Interfering", "Clearances", "Contacts", "Unresolved"]
                .map { "CADAssemblyInterferenceResult" + $0 }
            if identifiers.allSatisfy({ scan.resultValues[$0] != nil }),
               scan.labels.contains("Penetrating"), scan.labels.contains("Separated"),
               [("Plate A", "Plate B"), ("Plate A", "Plate C"), ("Plate B", "Plate C")]
                .allSatisfy({ containsPair($0.0, $0.1, in: scan.labels) }) {
                break
            }
            list.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return scan
    }

    private func assertResultValue(_ identifier: String, equals expected: String,
                                   in scan: SheetScan) -> Bool {
        guard let rendered = scan.resultValues[identifier] else {
            fail("the actual result row \(identifier) was not reachable in the inspector")
            return false
        }
        guard require(rendered == expected,
                      "\(identifier) must report the actual value \(expected); rendered \"\(rendered)\"") else {
            return false
        }
        return true
    }

    private func containsPair(_ first: String, _ second: String,
                              in labels: Set<String>) -> Bool {
        labels.contains { label in
            label.contains(first) && label.contains(second) && label.contains("↔")
        }
    }

    /// Put the first actual result row on screen for the visual attachment.
    /// Uses the row's real frame; it works even when an accessibility element
    /// with combined label/value is not hit-testable.
    private func revealResultSummary() -> Bool {
        let summary = resultElement("CADAssemblyInterferenceResultPairs")
        let window = app.windows.firstMatch.frame
        guard !window.isEmpty else { return summary.exists }
        for _ in 0..<12 {
            if summary.exists {
                let frame = summary.frame
                if !frame.isEmpty && frame.intersects(window) { return true }
                if let list = frontSheetList() {
                    if frame.minY > window.midY { list.swipeUp() } else { list.swipeDown() }
                }
            } else if let list = frontSheetList() {
                list.swipeDown()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return summary.exists
    }

    private func resultElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: - Scrolling, diagnostics and waits

    private enum ScrollDirection { case towardTop, towardBottom }

    private func revealInSheet(_ element: XCUIElement,
                               direction: ScrollDirection) -> Bool {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return true }
            guard let list = frontSheetList() else { break }
            switch direction {
            case .towardTop: list.swipeDown()
            case .towardBottom: list.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return element.exists && element.isHittable
    }

    private func frontSheetList() -> XCUIElement? {
        let list = app.collectionViews.firstMatch
        if list.exists && list.isHittable { return list }
        let table = app.tables.firstMatch
        if table.exists && table.isHittable { return table }
        return nil
    }

    @discardableResult
    private func waitFor(_ element: XCUIElement, _ message: String,
                         timeout: TimeInterval = 10) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        fail(message)
        return false
    }

    private func waitForCount(_ query: XCUIElementQuery, _ count: Int,
                              _ message: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if query.count == count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        fail("\(message); found \(query.count) instead of \(count)")
        return false
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isEnabled { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    @discardableResult
    private func require(_ condition: Bool, _ message: String) -> Bool {
        if condition { return true }
        fail(message)
        return false
    }

    private func fail(_ message: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "CAD assembly interference failure hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "CAD assembly interference failure"
        screen.lifetime = .keepAlways
        add(screen)
        XCTFail(message)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

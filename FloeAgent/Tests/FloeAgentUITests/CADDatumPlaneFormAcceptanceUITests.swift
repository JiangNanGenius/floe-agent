// FloeAgentUITests — M07 native datum-plane FORM acceptance.
//
// The `--ui-test-cad-datum-angle` and `--ui-test-cad-datum-three-point` DEBUG
// launch arguments open the REAL CAD workbench through the existing
// `CADWorkbenchFixtureHarness` and seed one saved package through the same
// production command/session vocabulary the editor uses. These tests then
// drive only shipped product surfaces:
//
//   * Command Search -> `plane.angle`, the shipped angle bar field/commit;
//   * Items -> plane row -> Edit Plane -> `DatumPlaneEditSheet`;
//   * Items -> 3-Point Plane -> `ThreePointPlaneSheet` and its anchor pickers;
//   * the native viewport face picker (Bottom view + real viewport tap);
//   * the native History distance field for a parent-thickness change;
//   * Undo/Redo and the existing host Save control.
//
// Every asserted document fact (plane id, stored formula, ordered anchor
// refs, origin/normal, source area, dependent sketch frame, body bounds,
// revision/change count, reference errors) is read back from the live
// `FloeCADDocument`/`EditorViewModel` by the DEBUG qualification panel. No
// test label can fabricate a pass; a missing/renamed control fails with the
// live accessibility tree in the message.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(XCTest)
import XCTest

@MainActor
private enum CADDatumFormLaunch {
    static let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                       // Argument-domain override: deterministic millimetre
                       // display without writing the persisted user unit.
                       "-floe.cad.unit", "mm",
                       "-ui-testing", "--ui-test-cad-fixture"]
    static let iPadBase = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                           "-floe.cad.unit", "mm",
                           "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture"]

    static func app(_ extra: [String], iPad: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (iPad ? iPadBase : base) + extra
        app.launch()
        return app
    }

    static func angle(reset: Bool, reopen: Bool = false) -> XCUIApplication {
        var args = ["--ui-test-cad-datum-angle"]
        if reset { args.append("--ui-test-cad-datum-reset") }
        if reopen { args.append("--ui-test-cad-datum-reopen") }
        return app(args)
    }

    static func threePoint(reset: Bool, reopen: Bool = false) -> XCUIApplication {
        var args = ["--ui-test-cad-datum-three-point"]
        if reset { args.append("--ui-test-cad-datum-reset") }
        if reopen { args.append("--ui-test-cad-datum-reopen") }
        return app(args)
    }

    static func compactThreePoint() -> XCUIApplication {
        app(["--ui-test-cad-datum-three-point",
             "--ui-test-cad-datum-reset",
             "--ui-test-cad-compact",
             "--ui-test-cad-large-text"], iPad: false)
    }
}

@MainActor
private enum CADDatumFormUI {
    static let readbackIDs = [
        "CADDatumReadbackIdentity",
        "CADDatumReadbackSelection",
        "CADDatumReadbackPlane",
        "CADDatumReadbackChild",
        "CADDatumReadbackBodies",
        "CADDatumReadbackErrors",
    ]

    static func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    static func describe(_ element: XCUIElement) -> String {
        element.exists ? "label '\(element.label)'" : "element is absent"
    }

    static func waitForAbsence(_ element: XCUIElement,
                               timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    static func waitForLabel(_ element: XCUIElement, _ value: String,
                             timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let predicate = NSPredicate(format: "label == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    static func waitForLabel(_ element: XCUIElement, contains text: String,
                             timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    static func waitForValue(_ element: XCUIElement, _ value: String,
                             timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    static func readback(_ app: XCUIApplication, _ identifier: String) -> String {
        let element = any(app, identifier)
        return element.exists ? element.label : ""
    }

    static func waitForReadback(_ app: XCUIApplication, _ identifier: String,
                                contains text: String,
                                timeout: TimeInterval) -> Bool {
        waitForLabel(any(app, identifier), contains: text, timeout: timeout)
    }

    static func waitForReadback(_ app: XCUIApplication, _ identifier: String,
                                equals text: String,
                                timeout: TimeInterval) -> Bool {
        waitForLabel(any(app, identifier), text, timeout: timeout)
    }

    static func waitForReadbackChange(_ app: XCUIApplication,
                                      _ identifier: String,
                                      from previous: String,
                                      timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = readback(app, identifier)
            if !current.isEmpty && current != previous { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    static func waitForVectorComponent(_ app: XCUIApplication,
                                       identifier: String, key: String,
                                       index: Int, equals value: Double,
                                       timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let vector = vector(readback(app, identifier), key),
               vector.count > index,
               abs(vector[index] - value) < 1e-3 {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    static func assertFixtureLoaded(_ app: XCUIApplication,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        XCTAssertTrue(any(app, "CADFixtureHarness").waitForExistence(timeout: 60),
                      "the real CAD fixture host must open: \(app.debugDescription)",
                      file: file, line: line)
    }

    static func waitForWorkbench(_ app: XCUIApplication,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        assertFixtureLoaded(app, file: file, line: line)
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 60),
                      "the real workbench must finish opening: \(app.debugDescription)",
                      file: file, line: line)
    }

    static func assertReadbackPanel(_ app: XCUIApplication,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        for identifier in readbackIDs {
            XCTAssertTrue(any(app, identifier).waitForExistence(timeout: 30),
                          "the live document readback \(identifier) must exist: \(app.debugDescription)",
                          file: file, line: line)
        }
    }

    // MARK: Items

    static func itemsPanel(_ app: XCUIApplication) -> XCUIElement {
        any(app, "ItemsPanel")
    }

    static func openItems(_ app: XCUIApplication,
                          file: StaticString = #filePath,
                          line: UInt = #line) {
        if itemsPanel(app).exists { return }
        if app.buttons["ItemsButton"].waitForExistence(timeout: 3),
           app.buttons["ItemsButton"].isHittable {
            app.buttons["ItemsButton"].tap()
        } else {
            openCompactMenuAction(app, label: "Items", file: file, line: line)
        }
        XCTAssertTrue(itemsPanel(app).waitForExistence(timeout: 20),
                      "the real Items panel must open: \(app.debugDescription)",
                      file: file, line: line)
    }

    static func toggleItems(_ app: XCUIApplication,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        if !itemsPanel(app).exists {
            openItems(app, file: file, line: line)
            return
        }
        if app.buttons["ItemsButton"].waitForExistence(timeout: 3),
           app.buttons["ItemsButton"].isHittable {
            app.buttons["ItemsButton"].tap()
        } else {
            openCompactMenuAction(app, label: "Items", file: file, line: line)
        }
        XCTAssertTrue(waitForAbsence(itemsPanel(app), timeout: 10),
                      "the real Items panel must close: \(app.debugDescription)",
                      file: file, line: line)
    }

    static func openCompactMenuAction(_ app: XCUIApplication, label: String,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        let more = app.buttons["CADCompactMoreMenu"]
        XCTAssertTrue(more.waitForExistence(timeout: 10),
                      "the compact toolbar overflow must exist: \(app.debugDescription)",
                      file: file, line: line)
        more.tap()
        let button = app.buttons[label].firstMatch
        if button.waitForExistence(timeout: 5), button.isHittable {
            button.tap()
            return
        }
        let labelled = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(labelled.waitForExistence(timeout: 5),
                      "the compact toolbar must offer \(label): \(app.debugDescription)",
                      file: file, line: line)
        labelled.tap()
    }

    static func reveal(_ element: XCUIElement, in container: XCUIElement,
                       maxSwipes: Int = 5) {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return }
            guard container.exists else { return }
            container.swipeUp()
        }
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return }
            guard container.exists else { return }
            container.swipeDown()
        }
    }

    /// SwiftUI Forms virtualize rows: an offscreen control may not exist at
    /// all until the form scrolls. Scroll the form until the identifier
    /// materializes, then reveal it.
    static func revealAny(_ app: XCUIApplication, _ identifier: String,
                          in container: XCUIElement,
                          maxSwipes: Int = 6) -> XCUIElement {
        for _ in 0..<maxSwipes {
            let element = any(app, identifier)
            if element.exists {
                reveal(element, in: container)
                return element
            }
            guard container.exists else { break }
            container.swipeUp()
        }
        return any(app, identifier)
    }

    static func openPlaneEdit(_ app: XCUIApplication, planeID: String,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        openItems(app, file: file, line: line)
        let row = any(app, "ItemPlane-\(planeID)")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the real Items plane row \(planeID) must exist: \(app.debugDescription)",
                      file: file, line: line)
        reveal(row, in: itemsPanel(app))
        XCTAssertTrue(row.isHittable,
                      "the real Items plane row must be reachable: \(app.debugDescription)",
                      file: file, line: line)
        row.press(forDuration: 1.2)

        var edit = app.buttons["ItemEditPlane"]
        if !edit.waitForExistence(timeout: 8) {
            let menuEdit = app.menuItems["ItemEditPlane"]
            if menuEdit.waitForExistence(timeout: 3) {
                edit = menuEdit
            }
        }
        if !edit.waitForExistence(timeout: 5) {
            let labelled = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Edit Plane")).firstMatch
            if labelled.waitForExistence(timeout: 5) {
                edit = labelled
            }
        }
        XCTAssertTrue(edit.waitForExistence(timeout: 5),
                      "the real Items context menu must offer Edit Plane: \(app.debugDescription)",
                      file: file, line: line)
        edit.tap()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if datumEditSheetIsPresent(app) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("the real datum edit sheet must present: \(app.debugDescription)",
                file: file, line: line)
    }

    static func datumEditSheetIsPresent(_ app: XCUIApplication) -> Bool {
        any(app, "DatumPlaneEditSheet").exists
            || app.buttons["DatumEditApply"].exists
            || app.buttons["DatumOffsetApply"].exists
    }

    static func waitForDatumEditGone(_ app: XCUIApplication,
                                     timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !datumEditSheetIsPresent(app) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !datumEditSheetIsPresent(app)
    }

    static func waitForCreateSheetGone(_ app: XCUIApplication,
                                       timeout: TimeInterval) -> Bool {
        waitForAbsence(app.buttons["ThreePointPlaneCreate"], timeout: timeout)
    }

    // MARK: Command Search / angle bar

    static func runCommandSearch(_ app: XCUIApplication, resultID: String,
                                 query: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        if app.buttons["CommandSearchButton"].waitForExistence(timeout: 3),
           app.buttons["CommandSearchButton"].isHittable {
            app.buttons["CommandSearchButton"].tap()
        } else {
            openCompactMenuAction(app, label: "Command Search", file: file, line: line)
        }
        let field = app.textFields["CommandSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the real Command Search field must open: \(app.debugDescription)",
                      file: file, line: line)
        field.tap()
        field.typeText(query)
        let result = any(app, resultID)
        XCTAssertTrue(result.waitForExistence(timeout: 20),
                      "Command Search must offer \(resultID): \(app.debugDescription)",
                      file: file, line: line)
        XCTAssertTrue(result.isHittable,
                      "the real command result must be hittable: \(app.debugDescription)",
                      file: file, line: line)
        result.tap()
        let panel = any(app, "CommandSearchPanel")
        XCTAssertTrue(waitForAbsence(panel, timeout: 10),
                      "the real command must dismiss Command Search: \(app.debugDescription)",
                      file: file, line: line)
        let refusal = any(app, "CommandSearchRefusal")
        XCTAssertFalse(refusal.exists,
                       "the real command must not refuse: \(describe(refusal))",
                       file: file, line: line)
    }

    static func selectStandardView(_ app: XCUIApplication, _ title: String,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        let views = app.buttons["ViewsMenu"]
        XCTAssertTrue(views.waitForExistence(timeout: 10),
                      "the real Views menu must exist: \(app.debugDescription)",
                      file: file, line: line)
        views.tap()
        let button = app.buttons[title].firstMatch
        if button.waitForExistence(timeout: 5), button.isHittable {
            button.tap()
        } else {
            let menuItem = app.menuItems[title].firstMatch
            if menuItem.waitForExistence(timeout: 5), menuItem.isHittable {
                menuItem.tap()
            } else {
                let labelled = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@", title)).firstMatch
                XCTAssertTrue(labelled.waitForExistence(timeout: 5),
                              "the real Views menu must offer \(title): \(app.debugDescription)",
                              file: file, line: line)
                labelled.tap()
            }
        }
        // The production camera flight is 0.35 s; run the run loop (not a
        // blocking sleep) so the display link can finish the flight.
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
    }

    static func tapViewportCenter(_ app: XCUIApplication,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        let viewport = any(app, "CADEditorViewport")
        XCTAssertTrue(viewport.waitForExistence(timeout: 20),
                      "the real editor viewport must expose its identity: \(app.debugDescription)",
                      file: file, line: line)
        XCTAssertTrue(viewport.isHittable,
                      "the real editor viewport must be hittable: \(app.debugDescription)",
                      file: file, line: line)
        XCTAssertGreaterThan(viewport.frame.width, 1,
                             "the real editor viewport frame must be non-empty", file: file, line: line)
        XCTAssertGreaterThan(viewport.frame.height, 1,
                             "the real editor viewport frame must be non-empty", file: file, line: line)
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    // MARK: Text / picker input

    static func replaceText(_ field: XCUIElement, with text: String,
                            in app: XCUIApplication,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "the real text field must exist: \(app.debugDescription)",
                      file: file, line: line)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let seed = field.value as? String ?? ""
        if !seed.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                  count: seed.count))
        }
        field.typeText(text)
        XCTAssertTrue(waitForValue(field, text, timeout: 10),
                      "the real text field must hold \(text); got \(describe(field))",
                      file: file, line: line)
    }

    static func replaceKeypadNumber(_ field: XCUIElement, with text: String,
                                    in app: XCUIApplication,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "the real numeric field must exist: \(app.debugDescription)",
                      file: file, line: line)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let pad = any(app, "NumericKeypad")
        XCTAssertTrue(pad.waitForExistence(timeout: 10),
                      "the real numeric keypad must open from the History field: \(app.debugDescription)",
                      file: file, line: line)
        let seed = field.value as? String ?? ""
        let delete = app.buttons["KeypadDelete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10),
                      "the real numeric keypad must expose Delete", file: file, line: line)
        for _ in seed { delete.tap() }
        for character in text {
            let token = character == "-" ? "−" : String(character)
            let key = app.buttons["Keypad-" + token]
            XCTAssertTrue(key.waitForExistence(timeout: 10),
                          "the real numeric keypad must expose \(token)",
                          file: file, line: line)
            key.tap()
        }
        let commit = app.buttons["KeypadCommit"]
        XCTAssertTrue(commit.waitForExistence(timeout: 10),
                      "the real numeric keypad must expose its commit action",
                      file: file, line: line)
        commit.tap()
        XCTAssertTrue(waitForAbsence(pad, timeout: 10),
                      "committing the value must close the real keypad",
                      file: file, line: line)
        XCTAssertTrue(waitForValue(field, text, timeout: 10),
                      "the real numeric field must hold \(text); got \(describe(field))",
                      file: file, line: line)
    }

    static func selectPickerOption(_ app: XCUIApplication, pickerID: String,
                                   option: String,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        let container = formScrollContainer(app)
        let picker = revealAny(app, pickerID, in: container)
        XCTAssertTrue(picker.waitForExistence(timeout: 15),
                      "the real picker \(pickerID) must exist: \(app.debugDescription)",
                      file: file, line: line)
        reveal(picker, in: container)
        var target = picker
        if !picker.isHittable {
            // SwiftUI may expose the Form row by its composed "Point N"
            // label rather than the identifier attached to the Picker. It is
            // the same shipped control.
            let index = pickerID.last.flatMap { Int(String($0)) } ?? 0
            let row = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Point \(index + 1)")
            ).firstMatch
            if row.waitForExistence(timeout: 5), row.isHittable {
                target = row
            }
        }
        XCTAssertTrue(target.isHittable,
                      "the real picker \(pickerID) must be reachable: \(app.debugDescription)",
                      file: file, line: line)
        target.tap()

        let candidates = [
            app.buttons[option].firstMatch,
            app.menuItems[option].firstMatch,
            app.cells[option].firstMatch,
            app.staticTexts[option].firstMatch,
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", option)).firstMatch,
        ]
        for candidate in candidates {
            if candidate.waitForExistence(timeout: 3), candidate.isHittable {
                candidate.tap()
                return
            }
        }
        XCTFail("the real picker \(pickerID) must offer '\(option)': \(app.debugDescription)",
                file: file, line: line)
    }

    static func formScrollContainer(_ app: XCUIApplication) -> XCUIElement {
        // Scope to the presented sheet first: the Items panel behind it is
        // also a ScrollView and must never be swiped instead of the form.
        for rootID in ["ThreePointPlaneSheet", "DatumPlaneEditSheet"] {
            let root = any(app, rootID)
            guard root.exists else { continue }
            let types: [XCUIElement.ElementType] = [.collectionView, .table, .scrollView]
            for type in types {
                let element = root.descendants(matching: type).firstMatch
                if element.exists { return element }
            }
            return root
        }
        let collections = app.collectionViews.allElementsBoundByIndex
        if let last = collections.last, last.exists { return last }
        let tables = app.tables.allElementsBoundByIndex
        if let last = tables.last, last.exists { return last }
        let scrolls = app.scrollViews.allElementsBoundByIndex
        if let last = scrolls.last, last.exists { return last }
        return app
    }

    // MARK: Save / History

    static func tapHostSave(_ app: XCUIApplication,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        let save = app.buttons["cad.host.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 20),
                      "the production host Save control must exist", file: file, line: line)
        save.tap()
        let outcome = any(app, "cad.host.saveOutcome")
        XCTAssertTrue(outcome.waitForExistence(timeout: 90),
                      "the production host must report its save outcome: \(app.debugDescription)",
                      file: file, line: line)
        XCTAssertEqual(outcome.label, "Saved",
                       "the real host save must succeed; got \(outcome.label)",
                       file: file, line: line)
    }

    static func openHistory(_ app: XCUIApplication,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        if app.buttons["HistoryButton"].waitForExistence(timeout: 3),
           app.buttons["HistoryButton"].isHittable {
            app.buttons["HistoryButton"].tap()
        } else {
            openCompactMenuAction(app, label: "History", file: file, line: line)
        }
        let panel = any(app, "HistoryPanel")
        XCTAssertTrue(panel.waitForExistence(timeout: 20),
                      "the real History panel must open: \(app.debugDescription)",
                      file: file, line: line)
    }

    static func editHistoryDistance(_ app: XCUIApplication, rowName: String,
                                    with value: String,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        openHistory(app, file: file, line: line)
        let row = any(app, "HistoryRow-\(rowName)")
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "the real History row \(rowName) must exist: \(app.debugDescription)",
                      file: file, line: line)
        let panel = any(app, "HistoryPanel")
        reveal(row, in: panel)
        XCTAssertTrue(row.isHittable,
                      "the real History row must be reachable: \(app.debugDescription)",
                      file: file, line: line)
        let field = row.textFields["HistoryDistanceField"]
        XCTAssertTrue(field.waitForExistence(timeout: 15),
                      "the real History distance field must exist on \(rowName): \(app.debugDescription)",
                      file: file, line: line)
        replaceKeypadNumber(field, with: value, in: app, file: file, line: line)
    }

    // MARK: Readback parsing

    static func string(_ line: String, _ key: String) -> String? {
        guard let range = line.range(of: "\(key)=") else { return nil }
        let rest = line[range.upperBound...]
        let token = rest.prefix { $0 != " " }
        return token.isEmpty ? nil : String(token)
    }

    static func quoted(_ line: String, _ key: String) -> String? {
        guard let range = line.range(of: "\(key)=\"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    static func number(_ line: String, _ key: String) -> Double? {
        string(line, key).flatMap(Double.init)
    }

    static func vector(_ line: String, _ key: String) -> [Double]? {
        guard let range = line.range(of: "\(key)=(") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: ")") else { return nil }
        return rest[..<end].split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
    }

    static func bracket(_ line: String, _ key: String) -> String? {
        guard let range = line.range(of: "\(key)=["),
              let end = line[range.upperBound...].firstIndex(of: "]") else { return nil }
        return String(line[range.upperBound..<end])
    }

    static func bodySegment(_ bodies: String, name: String) -> String? {
        bodies.split(separator: ";").map(String.init).first {
            $0.contains("name=\(name) ")
        }
    }

    static func approx(_ value: Double?, _ expected: Double,
                       _ tolerance: Double = 1e-3) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= tolerance
    }

    static func vectorsApprox(_ lhs: [Double]?, _ rhs: [Double]?,
                              _ tolerance: Double = 1e-3) -> Bool {
        guard let lhs, let rhs, lhs.count == rhs.count, !lhs.isEmpty else {
            return false
        }
        return zip(lhs, rhs).allSatisfy { pair in
            abs(pair.0 - pair.1) <= tolerance
        }
    }

    static func assertNoReadbackError(_ app: XCUIApplication,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        let errors = readback(app, "CADDatumReadbackErrors")
        XCTAssertTrue(errors.contains("reference=0"),
                      "the live document must have no reference errors: \(errors)",
                      file: file, line: line)
        XCTAssertTrue(errors.contains("eval=0"),
                      "the live document must have no eval errors: \(errors)",
                      file: file, line: line)
        XCTAssertTrue(errors.contains("rejection=0"),
                      "the live document must have no rebuild rejection: \(errors)",
                      file: file, line: line)
        XCTAssertTrue(errors.contains("error=none"),
                      "the editor must carry no error message: \(errors)",
                      file: file, line: line)
    }

    static func assertNoFormError(_ app: XCUIApplication,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        for identifier in ["ThreePointPlaneError", "DatumEditError", "DatumOffsetError"] {
            let element = any(app, identifier)
            XCTAssertFalse(element.exists,
                           "the real form must not misreport \(identifier): \(describe(element))",
                           file: file, line: line)
        }
    }

    // MARK: Attachments / cleanup

    static func snapshot(_ name: String, in app: XCUIApplication,
                         test: XCTestCase, croppedTo crop: XCUIElement? = nil) {
        let full = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        full.name = name
        full.lifetime = .keepAlways
        test.add(full)
        if let crop, crop.exists {
            let detail = XCTAttachment(screenshot: crop.screenshot())
            detail.name = name + " — detail"
            detail.lifetime = .keepAlways
            test.add(detail)
        }
    }

    /// Best-effort removal of the two fixture-owned packages. It never turns
    /// an assertion failure into a different one, and the next reset launch
    /// removes them anyway.
    static func cleanupFixtures() {
        let app = XCUIApplication()
        app.launchArguments = CADDatumFormLaunch.base + ["--ui-test-cad-datum-cleanup"]
        app.launch()
        _ = any(app, "CADDatumFixtureCleanup").waitForExistence(timeout: 20)
        app.terminate()
    }
}

@MainActor
final class CADDatumPlaneFormAcceptanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
        CADDatumFormUI.cleanupFixtures()
    }

    // MARK: - Angle form

    func testAnglePlaneCreateEditUndoRedoReselectAndReopen() throws {
        let app = CADDatumFormLaunch.angle(reset: true)
        defer { app.terminate() }
        CADDatumFormUI.waitForWorkbench(app)
        CADDatumFormUI.assertReadbackPanel(app)

        // The fixture's real picker tap must leave a supported selected face.
        XCTAssertTrue(app.descendants(matching: .any)["SelectionInfoBar"]
            .waitForExistence(timeout: 30),
                      "the real face picker must publish its selection: \(app.debugDescription)")
        XCTAssertTrue(CADDatumFormUI.readback(app, "CADDatumReadbackSelection").contains("face="),
                      "the fixture must start from a real selected face")
        XCTAssertTrue(CADDatumFormUI.readback(app, "CADDatumReadbackPlane") == "none",
                      "the angle package must start without a datum plane")
        CADDatumFormUI.assertNoReadbackError(app)

        // Real Command Search -> plane.angle -> shipped angle bar.
        CADDatumFormUI.runCommandSearch(
            app, resultID: "CommandResult-Add Plane - Angle", query: "Angle")
        let angleField = app.textFields["AnglePlaneAngleField"]
        XCTAssertTrue(angleField.waitForExistence(timeout: 20),
                      "the real angle bar field must present: \(app.debugDescription)")
        XCTAssertEqual(angleField.value as? String, "30",
                       "the native angle bar must start at its real 30° default")
        let commit = app.buttons["AnglePlaneCommit"]
        XCTAssertTrue(commit.waitForExistence(timeout: 10),
                      "the real angle bar must expose Add Plane")
        XCTAssertTrue(commit.isHittable,
                      "the real angle bar Add Plane must be reachable")
        commit.tap()
        XCTAssertTrue(CADDatumFormUI.waitForAbsence(commit, timeout: 20),
                      "Add Plane must commit and dismiss the real angle bar")

        XCTAssertTrue(CADDatumFormUI.waitForReadback(
            app, "CADDatumReadbackPlane", contains: "kind=angle", timeout: 30),
            "the real angle datum must exist after Add Plane")
        let createdLine = CADDatumFormUI.readback(app, "CADDatumReadbackPlane")
        guard let planeID = CADDatumFormUI.string(createdLine, "id") else {
            return XCTFail("the angle readback has no plane id: \(createdLine)")
        }
        XCTAssertEqual(CADDatumFormUI.quoted(createdLine, "formula"), "30.0",
                       "the native angle bar stores String(30.0), the exact edit-sheet fence")
        XCTAssertTrue(CADDatumFormUI.approx(CADDatumFormUI.number(createdLine, "value"), 30),
                      "the angle definition must store 30°")
        XCTAssertTrue(CADDatumFormUI.approx(
            CADDatumFormUI.vector(createdLine, "normal")?[1],
            cos(30 * Double.pi / 180)),
            "the real resolved normal must be cos30 about the source top face")
        CADDatumFormUI.assertNoReadbackError(app)
        CADDatumFormUI.snapshot("M07 angle — created from a real face through the native angle bar",
                                in: app, test: self)

        // Real Items -> Edit Plane -> Cancel must not mutate the document.
        CADDatumFormUI.openItems(app)
        let row = CADDatumFormUI.any(app, "ItemPlane-\(planeID)")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "Items must list the real angle plane: \(app.debugDescription)")
        let identityBeforeCancel = CADDatumFormUI.readback(app, "CADDatumReadbackIdentity")
        CADDatumFormUI.openPlaneEdit(app, planeID: planeID)
        let expression = app.textFields["DatumAngleExpression"]
        XCTAssertTrue(expression.waitForExistence(timeout: 20),
                      "the real Items edit sheet must expose the angle field")
        XCTAssertEqual(expression.value as? String, "30.0",
                       "the real Items sheet must read the stored native formula")
        CADDatumFormUI.replaceText(expression, with: "60", in: app)
        let cancel = app.buttons["DatumEditCancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10),
                      "the real datum edit sheet must expose Cancel")
        cancel.tap()
        XCTAssertTrue(CADDatumFormUI.waitForDatumEditGone(app, timeout: 20),
                      "Cancel must dismiss the real edit sheet")
        XCTAssertEqual(CADDatumFormUI.readback(app, "CADDatumReadbackIdentity"),
                       identityBeforeCancel,
                       "Cancel must leave revision, change count and undo stack unchanged")
        XCTAssertTrue(CADDatumFormUI.readback(app, "CADDatumReadbackPlane")
            .contains("formula=\"30.0\""),
                      "Cancel must leave the stored formula unchanged")
        CADDatumFormUI.assertNoReadbackError(app)

        // Real Items edit 30 -> 45, exact stored formula CAS.
        CADDatumFormUI.openPlaneEdit(app, planeID: planeID)
        let editField = app.textFields["DatumAngleExpression"]
        XCTAssertTrue(editField.waitForExistence(timeout: 20),
                      "the real Items edit sheet must reopen on the saved angle")
        XCTAssertEqual(editField.value as? String, "30.0",
                       "the reopen must show the exact stored formula")
        CADDatumFormUI.replaceText(editField, with: "45", in: app)
        let done = app.buttons["DatumEditApply"]
        XCTAssertTrue(done.waitForExistence(timeout: 10),
                      "the real datum edit sheet must expose Done")
        XCTAssertTrue(done.isEnabled,
                      "the real Done action must enable for a valid angle expression")
        done.tap()
        XCTAssertTrue(CADDatumFormUI.waitForDatumEditGone(app, timeout: 20),
                      "Done must dismiss the real edit sheet")
        XCTAssertTrue(CADDatumFormUI.waitForReadback(
            app, "CADDatumReadbackPlane", contains: "formula=\"45\"", timeout: 20),
            "the real edit must store the authored formula 45")
        let editedLine = CADDatumFormUI.readback(app, "CADDatumReadbackPlane")
        XCTAssertEqual(CADDatumFormUI.string(editedLine, "id"), planeID,
                       "editing must keep the same plane identity")
        XCTAssertTrue(CADDatumFormUI.approx(
            CADDatumFormUI.vector(editedLine, "normal")?[1],
            cos(45 * Double.pi / 180)),
            "the real resolved normal must be cos45 after the edit")
        CADDatumFormUI.assertNoReadbackError(app)
        CADDatumFormUI.snapshot("M07 angle — Items edit stores 45 and keeps the same plane id",
                                in: app, test: self)

        // Real Undo / Redo.
        let undo = app.buttons["UndoButton"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the real Undo must exist")
        undo.tap()
        XCTAssertTrue(CADDatumFormUI.waitForReadback(
            app, "CADDatumReadbackPlane", contains: "formula=\"30.0\"", timeout: 20),
            "Undo must restore the stored 30.0 formula")
        XCTAssertTrue(CADDatumFormUI.approx(
            CADDatumFormUI.vector(
                CADDatumFormUI.readback(app, "CADDatumReadbackPlane"), "normal")?[1],
            cos(30 * Double.pi / 180)),
            "Undo must restore the cos30 normal")
        let redo = app.buttons["RedoButton"]
        XCTAssertTrue(redo.waitForExistence(timeout: 10), "the real Redo must exist")
        redo.tap()
        XCTAssertTrue(CADDatumFormUI.waitForReadback(
            app, "CADDatumReadbackPlane", contains: "formula=\"45\"", timeout: 20),
            "Redo must reapply the stored 45 formula")
        XCTAssertTrue(CADDatumFormUI.approx(
            CADDatumFormUI.vector(
                CADDatumFormUI.readback(app, "CADDatumReadbackPlane"), "normal")?[1],
            cos(45 * Double.pi / 180)),
            "Redo must restore the cos45 normal")

        // Real picker reselect: Bottom view + an actual viewport tap, then the
        // shipped datum edit sheet's "Use Selected Face" action.
        CADDatumFormUI.toggleItems(app)
        CADDatumFormUI.selectStandardView(app, "Bottom")
        CADDatumFormUI.tapViewportCenter(app)
        XCTAssertTrue(app.descendants(matching: .any)["SelectionInfoBar"]
            .waitForExistence(timeout: 20),
                      "the real bottom-face pick must publish its selection: \(app.debugDescription)")
        let bottomSelection = CADDatumFormUI.readback(app, "CADDatumReadbackSelection")
        XCTAssertTrue(bottomSelection.contains("face="),
                      "the bottom tap must hold a real datum face; got \(bottomSelection)")
        CADDatumFormUI.openItems(app)
        CADDatumFormUI.openPlaneEdit(app, planeID: planeID)
        let reselect = app.buttons["DatumReselectSource"]
        XCTAssertTrue(reselect.waitForExistence(timeout: 20),
                      "the real edit sheet must offer Use Selected Face: \(app.debugDescription)")
        reselect.tap()
        XCTAssertTrue(CADDatumFormUI.waitForDatumEditGone(app, timeout: 20),
                      "Use Selected Face must dismiss the real edit sheet")
        XCTAssertTrue(CADDatumFormUI.waitForVectorComponent(
            app, identifier: "CADDatumReadbackPlane", key: "origin",
            index: 1, equals: 0, timeout: 20),
            "reselecting the real bottom cap must move the plane origin to y=0")
        let reselectedLine = CADDatumFormUI.readback(app, "CADDatumReadbackPlane")
        XCTAssertEqual(CADDatumFormUI.string(reselectedLine, "id"), planeID,
                       "source reselect must keep the plane id")
        XCTAssertEqual(CADDatumFormUI.quoted(reselectedLine, "formula"), "45",
                       "source reselect must keep the stored formula")
        XCTAssertLessThan(CADDatumFormUI.vector(reselectedLine, "normal")?[1] ?? 1, -0.5,
                         "the real bottom source must turn the resolved normal negative")
        XCTAssertTrue(CADDatumFormUI.approx(
            abs(CADDatumFormUI.vector(reselectedLine, "normal")?[1] ?? 0),
            cos(45 * Double.pi / 180), 5e-3),
            "the bottom source must keep the 45° normal magnitude")
        CADDatumFormUI.assertNoReadbackError(app)
        CADDatumFormUI.snapshot("M07 angle — real bottom-face reselect keeps id/formula and moves origin",
                                in: app, test: self)

        // Existing host Save, then a new process must reopen the same state.
        CADDatumFormUI.toggleItems(app)
        CADDatumFormUI.tapHostSave(app)
        let savedLine = CADDatumFormUI.readback(app, "CADDatumReadbackPlane")
        let savedRevision = CADDatumFormUI.string(
            CADDatumFormUI.readback(app, "CADDatumReadbackIdentity"), "rev")
        XCTAssertNotNil(savedRevision, "the saved readback must expose a real revision")
        XCTAssertTrue(savedLine.contains("id=\(planeID)"),
                      "the saved readback must still name the same plane")
        app.terminate()

        let reopened = CADDatumFormLaunch.angle(reset: false, reopen: true)
        defer { reopened.terminate() }
        CADDatumFormUI.waitForWorkbench(reopened)
        CADDatumFormUI.assertReadbackPanel(reopened)
        XCTAssertTrue(CADDatumFormUI.waitForReadback(
            reopened, "CADDatumReadbackPlane", equals: savedLine, timeout: 30),
            "the reopened id/formula/normal/origin must match the saved readback")
        // The angle reopen does not mutate the package; the saved revision
        // must not regress.
        let reopenedRevision = CADDatumFormUI.string(
            CADDatumFormUI.readback(reopened, "CADDatumReadbackIdentity"), "rev")
        XCTAssertNotNil(reopenedRevision,
                        "the reopen must expose the live package revision")
        if let saved = savedRevision.flatMap(Int.init),
           let reopenedValue = reopenedRevision.flatMap(Int.init) {
            XCTAssertGreaterThanOrEqual(
                reopenedValue, saved,
                "the reopen must not lose the saved package revision")
        }
        XCTAssertTrue(CADDatumFormUI.readback(reopened, "CADDatumReadbackSelection") == "face=none",
                      "a saved-package reopen must not re-arm a fixture face pick")
        CADDatumFormUI.assertNoReadbackError(reopened)
        CADDatumFormUI.snapshot("M07 angle — new process reopens the same datum identity and geometry",
                                in: reopened, test: self)

        // The real edit sheet must still read the saved formula after reopen.
        CADDatumFormUI.openItems(reopened)
        CADDatumFormUI.openPlaneEdit(reopened, planeID: planeID)
        let reopenedField = reopened.textFields["DatumAngleExpression"]
        XCTAssertTrue(reopenedField.waitForExistence(timeout: 20),
                      "the reopened real edit sheet must expose the angle field")
        XCTAssertEqual(reopenedField.value as? String, "45",
                       "the reopened sheet must read the saved 45 formula")
        let reopenedCancel = reopened.buttons["DatumEditCancel"]
        XCTAssertTrue(reopenedCancel.waitForExistence(timeout: 10),
                      "the reopened real edit sheet must expose Cancel")
        reopenedCancel.tap()
        XCTAssertTrue(CADDatumFormUI.waitForDatumEditGone(reopened, timeout: 20),
                      "Cancel must dismiss the reopened sheet")
    }

    // MARK: - Three-point form

    func testThreePointSheetCreateEditReselectSaveReopenParentFollow() throws {
        let app = CADDatumFormLaunch.threePoint(reset: true)
        defer { app.terminate() }
        CADDatumFormUI.waitForWorkbench(app)
        CADDatumFormUI.assertReadbackPanel(app)
        XCTAssertTrue(CADDatumFormUI.readback(app, "CADDatumReadbackPlane") == "none",
                      "the three-point package must start without a datum plane")
        CADDatumFormUI.assertNoReadbackError(app)

        CADDatumFormUI.openItems(app)
        let add = app.buttons["ItemsAddThreePointPlane"]
        XCTAssertTrue(add.waitForExistence(timeout: 20),
                      "the real Items panel must offer 3-Point Plane: \(app.debugDescription)")
        CADDatumFormUI.reveal(add, in: CADDatumFormUI.itemsPanel(app))
        XCTAssertTrue(add.isHittable,
                      "the real 3-Point Plane action must be reachable: \(app.debugDescription)")
        add.tap()
        CADDatumFormUI.waitForSheet(app, field: "ThreePointPlanePoint0")

        // Cancel a fully selected draft: no plane, no document change.
        selectThreePointCandidates(app,
                                   point0: "Anchor A · Line · Start point",
                                   point1: "Anchor A · Line · End point",
                                   point2: "Anchor B · Line · End point")
        let create = app.buttons["ThreePointPlaneCreate"]
        XCTAssertTrue(create.waitForExistence(timeout: 10),
                      "the real three-point sheet must expose Create")
        XCTAssertTrue(create.isEnabled,
                      "three distinct real anchors must enable Create")
        let identityBeforeCancel = CADDatumFormUI.readback(app, "CADDatumReadbackIdentity")
        let cancel = app.buttons["ThreePointPlaneCancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10),
                      "the real three-point sheet must expose Cancel")
        cancel.tap()
        XCTAssertTrue(CADDatumFormUI.waitForCreateSheetGone(app, timeout: 20),
                      "Cancel must dismiss the real three-point sheet")
        XCTAssertEqual(CADDatumFormUI.readback(app, "CADDatumReadbackIdentity"),
                       identityBeforeCancel,
                       "Cancel must not mutate revision, change count or undo stack")
        XCTAssertTrue(CADDatumFormUI.readback(app, "CADDatumReadbackPlane") == "none",
                      "Cancel must not create a plane")
        CADDatumFormUI.assertNoFormError(app)

        // Create through the same real sheet.
        CADDatumFormUI.openItems(app)
        XCTAssertTrue(add.waitForExistence(timeout: 10),
                      "the real Items panel must still offer 3-Point Plane")
        add.tap()
        CADDatumFormUI.waitForSheet(app, field: "ThreePointPlanePoint0")
        selectThreePointCandidates(app,
                                   point0: "Anchor A · Line · Start point",
                                   point1: "Anchor A · Line · End point",
                                   point2: "Anchor B · Line · End point")
        XCTAssertTrue(app.buttons["ThreePointPlaneCreate"].isEnabled,
                      "the real Create must be enabled for three distinct anchors")
        app.buttons["ThreePointPlaneCreate"].tap()
        XCTAssertTrue(CADDatumFormUI.waitForCreateSheetGone(app, timeout: 30),
                      "Create must commit and dismiss the real three-point sheet")
        XCTAssertTrue(CADDatumFormUI.waitForReadback(
            app, "CADDatumReadbackPlane", contains: "kind=threePoints", timeout: 30),
            "Create must produce a real three-point datum")
        let createdLine = CADDatumFormUI.readback(app, "CADDatumReadbackPlane")
        guard let planeID = CADDatumFormUI.string(createdLine, "id") else {
            return XCTFail("the three-point readback has no plane id: \(createdLine)")
        }
        guard let originalPoints = CADDatumFormUI.bracket(createdLine, "points") else {
            return XCTFail("the three-point readback has no ordered point refs: \(createdLine)")
        }
        XCTAssertEqual(originalPoints.split(separator: ";").count, 3,
                       "the created datum must persist exactly three ordered anchors")
        XCTAssertGreaterThan(CADDatumFormUI.number(createdLine, "area") ?? 0, 1,
                            "the real three-point source must be non-degenerate")
        CADDatumFormUI.assertNoReadbackError(app)
        CADDatumFormUI.assertNoFormError(app)
        CADDatumFormUI.snapshot("M07 three-point — created through the native candidate sheet",
                                in: app, test: self)

        // Reorder the persisted anchors through the real Items sheet. Point 3
        // stays its saved B end; points 1/2 swap, so the ordered refs change
        // while all three remain distinct and real.
        CADDatumFormUI.openPlaneEdit(app, planeID: planeID)
        let firstEditPicker = CADDatumFormUI.revealAny(
            app, "DatumEditPoint0", in: CADDatumFormUI.formScrollContainer(app))
        XCTAssertTrue(firstEditPicker.exists,
                      "the real three-point edit sheet must expose ordered pickers: \(app.debugDescription)")
        CADDatumFormUI.selectPickerOption(
            app, pickerID: "DatumEditPoint0", option: "Anchor A · Line · End point")
        CADDatumFormUI.selectPickerOption(
            app, pickerID: "DatumEditPoint1", option: "Anchor A · Line · Start point")
        let editDone = app.buttons["DatumEditApply"]
        XCTAssertTrue(editDone.waitForExistence(timeout: 10),
                      "the real three-point edit sheet must expose Done")
        XCTAssertTrue(editDone.isEnabled,
                      "three distinct real anchors must enable Done")
        editDone.tap()
        XCTAssertTrue(CADDatumFormUI.waitForDatumEditGone(app, timeout: 30),
                      "Done must commit and dismiss the real edit sheet")
        XCTAssertTrue(CADDatumFormUI.waitForReadbackChange(
            app, "CADDatumReadbackPlane", from: createdLine, timeout: 20),
            "the edited three-point readback must change its ordered point refs")
        let editedLine = CADDatumFormUI.readback(app, "CADDatumReadbackPlane")
        guard let editedPoints = CADDatumFormUI.bracket(editedLine, "points") else {
            return XCTFail("the edited three-point readback has no point refs: \(editedLine)")
        }
        XCTAssertEqual(CADDatumFormUI.string(editedLine, "id"), planeID,
                       "editing anchors must keep the plane id")
        XCTAssertNotEqual(editedPoints, originalPoints,
                          "editing must replace the ordered anchor refs")
        XCTAssertGreaterThan(CADDatumFormUI.number(editedLine, "area") ?? 0, 1,
                            "the edited three-point frame must stay non-degenerate")
        CADDatumFormUI.assertNoReadbackError(app)

        let undo = app.buttons["UndoButton"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the real Undo must exist")
        undo.tap()
        XCTAssertTrue(CADDatumFormUI.waitForReadback(
            app, "CADDatumReadbackPlane", contains: "points=[\(originalPoints)]", timeout: 20),
            "Undo must restore the original ordered anchors")
        let redo = app.buttons["RedoButton"]
        XCTAssertTrue(redo.waitForExistence(timeout: 10), "the real Redo must exist")
        redo.tap()
        XCTAssertTrue(CADDatumFormUI.waitForReadback(
            app, "CADDatumReadbackPlane", contains: "points=[\(editedPoints)]", timeout: 20),
            "Redo must restore the edited ordered anchors")

        // A second ordered reorder keeps identity and a non-degenerate frame.
        // Point 1 returns to the offset-supported sketch A, so the persisted
        // plane origin still follows the parent thickness; point 2 becomes
        // sketch B's start point (sketch B remains on the ground).
        CADDatumFormUI.openPlaneEdit(app, planeID: planeID)
        CADDatumFormUI.selectPickerOption(
            app, pickerID: "DatumEditPoint0", option: "Anchor A · Line · Start point")
        CADDatumFormUI.selectPickerOption(
            app, pickerID: "DatumEditPoint1", option: "Anchor B · Line · Start point")
        let secondDone = app.buttons["DatumEditApply"]
        XCTAssertTrue(secondDone.waitForExistence(timeout: 10))
        XCTAssertTrue(secondDone.isEnabled)
        secondDone.tap()
        XCTAssertTrue(CADDatumFormUI.waitForDatumEditGone(app, timeout: 30))
        XCTAssertTrue(CADDatumFormUI.waitForReadbackChange(
            app, "CADDatumReadbackPlane", from: editedLine, timeout: 20),
            "the second ordered reselect must change the persisted point refs")
        let reselectedLine = CADDatumFormUI.readback(app, "CADDatumReadbackPlane")
        guard let reselectedPoints = CADDatumFormUI.bracket(reselectedLine, "points") else {
            return XCTFail("the reselected three-point readback has no point refs")
        }
        XCTAssertEqual(CADDatumFormUI.string(reselectedLine, "id"), planeID)
        XCTAssertNotEqual(reselectedPoints, editedPoints,
                          "the second ordered reselect must change the persisted order")
        XCTAssertGreaterThan(CADDatumFormUI.number(reselectedLine, "area") ?? 0, 1)
        CADDatumFormUI.assertNoReadbackError(app)
        CADDatumFormUI.snapshot("M07 three-point — ordered anchors edited, undone/redone and reselected",
                                in: app, test: self)

        CADDatumFormUI.toggleItems(app)
        CADDatumFormUI.tapHostSave(app)
        let savedLine = CADDatumFormUI.readback(app, "CADDatumReadbackPlane")
        let savedRevision = CADDatumFormUI.string(
            CADDatumFormUI.readback(app, "CADDatumReadbackIdentity"), "rev")
        XCTAssertNotNil(savedRevision, "the saved readback must expose a real revision")
        XCTAssertEqual(CADDatumFormUI.bracket(savedLine, "points"), reselectedPoints,
                       "the saved package must carry the final ordered anchors")
        app.terminate()

        // Reopen: the fixture installs the real downstream support sketch +
        // Extrude through the same production transaction path the M07
        // service tests use. Change the real parent thickness through History.
        let reopened = CADDatumFormLaunch.threePoint(reset: false, reopen: true)
        defer { reopened.terminate() }
        CADDatumFormUI.waitForWorkbench(reopened)
        CADDatumFormUI.assertReadbackPanel(reopened)
        XCTAssertTrue(CADDatumFormUI.waitForReadback(
            reopened, "CADDatumReadbackPlane", equals: savedLine, timeout: 30),
            "the reopened three-point id/points/frame must match the saved readback")
        // The fixture installs the downstream probe on this reopen, a real
        // document change; a 2 s production autosave may legitimately advance
        // the revision before this read. It must never lose the saved base.
        let reopenedRevision = CADDatumFormUI.string(
            CADDatumFormUI.readback(reopened, "CADDatumReadbackIdentity"), "rev")
        XCTAssertNotNil(reopenedRevision,
                        "the reopen must expose the live package revision")
        if let saved = savedRevision.flatMap(Int.init),
           let reopenedValue = reopenedRevision.flatMap(Int.init) {
            XCTAssertGreaterThanOrEqual(
                reopenedValue, saved,
                "the reopen must not lose the saved package revision")
        }
        XCTAssertTrue(CADDatumFormUI.waitForReadback(
            reopened, "CADDatumReadbackChild", contains: "support=\(planeID)", timeout: 30),
            "the reopen must show the dependent sketch supported by the datum")
        let childBefore = CADDatumFormUI.readback(reopened, "CADDatumReadbackChild")
        XCTAssertFalse(childBefore.contains("body=none"),
                       "the dependent sketch must have its real Extrude body: \(childBefore)")
        guard let childMinBefore = CADDatumFormUI.vector(childBefore, "min"),
              let childMaxBefore = CADDatumFormUI.vector(childBefore, "max"),
              childMinBefore.count >= 3, childMaxBefore.count >= 3 else {
            return XCTFail("the reopen has no real dependent body bounds: \(childBefore)")
        }
        let bodiesBefore = CADDatumFormUI.readback(reopened, "CADDatumReadbackBodies")
        guard let parentBefore = CADDatumFormUI.bodySegment(bodiesBefore, name: "ParentPlate"),
              let parentMaxBefore = CADDatumFormUI.vector(parentBefore, "max"),
              parentMaxBefore.count >= 2 else {
            return XCTFail("the readback has no real ParentPlate body bounds: \(bodiesBefore)")
        }
        CADDatumFormUI.assertNoReadbackError(reopened)
        CADDatumFormUI.snapshot("M07 three-point — reopen shows the dependent sketch and body",
                                in: reopened, test: self)

        CADDatumFormUI.editHistoryDistance(reopened, rowName: "ParentPlate", with: "20")
        XCTAssertTrue(CADDatumFormUI.waitForVectorComponent(
            reopened, identifier: "CADDatumReadbackPlane", key: "origin",
            index: 1, equals: 20, timeout: 30),
            "changing the real parent thickness must move the three-point plane to y=20")
        XCTAssertTrue(CADDatumFormUI.waitForVectorComponent(
            reopened, identifier: "CADDatumReadbackChild", key: "origin",
            index: 1, equals: 20, timeout: 30),
            "the dependent sketch must follow the datum to y=20")
        let followedLine = CADDatumFormUI.readback(reopened, "CADDatumReadbackPlane")
        XCTAssertEqual(CADDatumFormUI.string(followedLine, "id"), planeID,
                       "the parent change must keep the datum id")
        XCTAssertEqual(CADDatumFormUI.bracket(followedLine, "points"), reselectedPoints,
                       "the parent change must keep the ordered anchor refs")
        XCTAssertGreaterThan(CADDatumFormUI.number(followedLine, "area") ?? 0, 1,
                            "the followed frame must stay non-degenerate")
        let childAfter = CADDatumFormUI.readback(reopened, "CADDatumReadbackChild")
        XCTAssertTrue(childAfter.contains("support=\(planeID)"),
                      "the dependent sketch must keep its datum support")
        XCTAssertTrue(CADDatumFormUI.vectorsApprox(
            CADDatumFormUI.vector(childAfter, "origin"),
            CADDatumFormUI.vector(followedLine, "origin")),
            "the dependent sketch origin must equal the followed datum origin")
        XCTAssertTrue(CADDatumFormUI.vectorsApprox(
            CADDatumFormUI.vector(childAfter, "normal"),
            CADDatumFormUI.vector(followedLine, "normal")),
            "the dependent sketch normal must equal the followed datum normal")
        guard let childMinAfter = CADDatumFormUI.vector(childAfter, "min"),
              let childMaxAfter = CADDatumFormUI.vector(childAfter, "max"),
              childMinAfter.count >= 3, childMaxAfter.count >= 3 else {
            return XCTFail("the followed readback has no real dependent body bounds: \(childAfter)")
        }
        let bodiesAfter = CADDatumFormUI.readback(reopened, "CADDatumReadbackBodies")
        guard let parentAfter = CADDatumFormUI.bodySegment(bodiesAfter, name: "ParentPlate"),
              let parentMaxAfter = CADDatumFormUI.vector(parentAfter, "max"),
              parentMaxAfter.count >= 2 else {
            return XCTFail("the followed readback has no real ParentPlate body bounds: \(bodiesAfter)")
        }
        XCTAssertTrue(CADDatumFormUI.approx(parentMaxAfter[1], 20),
                      "the real ParentPlate body must grow to y=20")
        XCTAssertNotEqual(parentMaxBefore[1], parentMaxAfter[1],
                          "the changed parent dimension must move the real body bounds")
        XCTAssertTrue(childMinBefore != childMinAfter || childMaxBefore != childMaxAfter,
                      "the dependent body bounds must follow the parent change; "
                          + "before \(childMinBefore)/\(childMaxBefore), "
                          + "after \(childMinAfter)/\(childMaxAfter)")
        XCTAssertTrue(CADDatumFormUI.readback(reopened, "CADDatumReadbackErrors")
            .contains("reference=0"),
                      "the followed graph must have no reference errors")
        CADDatumFormUI.assertNoFormError(reopened)
        for rowName in ["ParentPlate", "Three point child"] {
            let errorBadge = CADDatumFormUI.any(reopened, "HistoryError-\(rowName)")
            XCTAssertFalse(errorBadge.exists,
                           "the real History row \(rowName) must not misreport an error: "
                               + CADDatumFormUI.describe(errorBadge))
        }
        CADDatumFormUI.snapshot("M07 three-point — parent thickness change follows plane and downstream sketch",
                                in: reopened, test: self)

        CADDatumFormUI.toggleItems(reopened)
        CADDatumFormUI.tapHostSave(reopened)
        let followPlane = CADDatumFormUI.readback(reopened, "CADDatumReadbackPlane")
        let followChild = CADDatumFormUI.readback(reopened, "CADDatumReadbackChild")
        let followRevision = CADDatumFormUI.string(
            CADDatumFormUI.readback(reopened, "CADDatumReadbackIdentity"), "rev")
        XCTAssertNotNil(followRevision, "the followed readback must expose a real revision")
        reopened.terminate()

        let final = CADDatumFormLaunch.threePoint(reset: false, reopen: true)
        defer { final.terminate() }
        CADDatumFormUI.waitForWorkbench(final)
        CADDatumFormUI.assertReadbackPanel(final)
        XCTAssertTrue(CADDatumFormUI.waitForReadback(
            final, "CADDatumReadbackPlane", equals: followPlane, timeout: 30),
            "the final reopen must retain the followed plane identity and frame")
        XCTAssertEqual(CADDatumFormUI.string(
            CADDatumFormUI.readback(final, "CADDatumReadbackIdentity"), "rev"),
                       followRevision,
                       "the final reopen must retain the followed package revision")
        XCTAssertTrue(CADDatumFormUI.waitForReadback(
            final, "CADDatumReadbackChild", contains: "support=\(planeID)", timeout: 30),
            "the final reopen must retain the dependent sketch")
        let finalChild = CADDatumFormUI.readback(final, "CADDatumReadbackChild")
        XCTAssertEqual(CADDatumFormUI.string(finalChild, "sketch"),
                       CADDatumFormUI.string(followChild, "sketch"),
                       "the final reopen must keep the dependent sketch identity")
        XCTAssertEqual(CADDatumFormUI.string(finalChild, "body"),
                       CADDatumFormUI.string(followChild, "body"),
                       "the final reopen must keep the dependent body identity")
        XCTAssertTrue(CADDatumFormUI.vectorsApprox(
            CADDatumFormUI.vector(finalChild, "origin"),
            CADDatumFormUI.vector(followChild, "origin")),
            "the final reopen must keep the dependent sketch origin")
        XCTAssertTrue(CADDatumFormUI.vectorsApprox(
            CADDatumFormUI.vector(finalChild, "normal"),
            CADDatumFormUI.vector(followChild, "normal")),
            "the final reopen must keep the dependent sketch normal")
        XCTAssertTrue(CADDatumFormUI.vectorsApprox(
            CADDatumFormUI.vector(finalChild, "min"),
            CADDatumFormUI.vector(followChild, "min")),
            "the final reopen must keep the dependent body min bounds")
        XCTAssertTrue(CADDatumFormUI.vectorsApprox(
            CADDatumFormUI.vector(finalChild, "max"),
            CADDatumFormUI.vector(followChild, "max")),
            "the final reopen must keep the dependent body max bounds")
        CADDatumFormUI.assertNoReadbackError(final)

        CADDatumFormUI.openItems(final)
        CADDatumFormUI.openPlaneEdit(final, planeID: planeID)
        let finalPicker = CADDatumFormUI.revealAny(
            final, "DatumEditPoint0", in: CADDatumFormUI.formScrollContainer(final))
        XCTAssertTrue(finalPicker.exists,
                      "the reopened real edit sheet must expose saved ordered anchors: \(final.debugDescription)")
        let finalCancel = final.buttons["DatumEditCancel"]
        XCTAssertTrue(finalCancel.waitForExistence(timeout: 10))
        finalCancel.tap()
        XCTAssertTrue(CADDatumFormUI.waitForDatumEditGone(final, timeout: 20))
        CADDatumFormUI.snapshot("M07 three-point — final reopen keeps plane, anchors and downstream bounds",
                                in: final, test: self)
    }

    // MARK: - Narrow large-type form

    func testThreePointFormRemainsReachableInNarrowLargeText() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = CADDatumFormLaunch.compactThreePoint()
        defer { app.terminate() }
        CADDatumFormUI.waitForWorkbench(app)
        XCTAssertTrue(app.buttons["CADCompactMoreMenu"].waitForExistence(timeout: 20),
                      "the compact toolbar must expose its overflow: \(app.debugDescription)")

        CADDatumFormUI.openItems(app)
        let add = app.buttons["ItemsAddThreePointPlane"]
        XCTAssertTrue(add.waitForExistence(timeout: 20),
                      "the narrow Items panel must offer 3-Point Plane: \(app.debugDescription)")
        CADDatumFormUI.reveal(add, in: CADDatumFormUI.itemsPanel(app))
        XCTAssertTrue(add.isHittable,
                      "the narrow 3-Point Plane action must be reachable: \(app.debugDescription)")
        add.tap()
        CADDatumFormUI.waitForSheet(app, field: "ThreePointPlanePoint0")

        let cancel = app.buttons["ThreePointPlaneCancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10),
                      "the narrow form must expose Cancel")
        XCTAssertTrue(cancel.isHittable,
                      "the narrow form Cancel must be reachable")
        let create = app.buttons["ThreePointPlaneCreate"]
        XCTAssertTrue(create.waitForExistence(timeout: 10),
                      "the narrow form must expose Create")
        XCTAssertTrue(create.isHittable,
                      "the narrow form Create must be reachable")

        let container = CADDatumFormUI.formScrollContainer(app)
        for index in 0..<3 {
            let picker = CADDatumFormUI.revealAny(
                app, "ThreePointPlanePoint\(index)", in: container)
            XCTAssertTrue(picker.exists,
                          "the narrow form must expose point \(index + 1): \(app.debugDescription)")
            CADDatumFormUI.reveal(picker, in: container)
            XCTAssertTrue(picker.isHittable,
                          "the narrow form point \(index + 1) must be readable/hittable: \(app.debugDescription)")
        }
        CADDatumFormUI.snapshot("M07 three-point — narrow large-type form remains reachable",
                                in: app, test: self)

        cancel.tap()
        XCTAssertTrue(CADDatumFormUI.waitForCreateSheetGone(app, timeout: 20),
                      "Cancel must dismiss the narrow real form")
    }

    // MARK: - Shared flow helpers

    private func selectThreePointCandidates(_ app: XCUIApplication,
                                            point0: String,
                                            point1: String,
                                            point2: String) {
        CADDatumFormUI.selectPickerOption(
            app, pickerID: "ThreePointPlanePoint0", option: point0)
        CADDatumFormUI.selectPickerOption(
            app, pickerID: "ThreePointPlanePoint1", option: point1)
        CADDatumFormUI.selectPickerOption(
            app, pickerID: "ThreePointPlanePoint2", option: point2)
    }
}

private extension CADDatumFormUI {
    static func waitForSheet(_ app: XCUIApplication, field: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        let create = app.buttons["ThreePointPlaneCreate"]
        let target = any(app, field)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if create.exists || target.exists { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("the real three-point sheet must present \(field): \(app.debugDescription)",
                file: file, line: line)
    }
}

#endif

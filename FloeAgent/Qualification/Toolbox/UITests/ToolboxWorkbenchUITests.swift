import XCTest

final class ToolboxWorkbenchUITests: XCTestCase {
    @MainActor
    private func open(_ tool: String, anchor: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--tool", tool, "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: anchor).firstMatch.waitForExistence(timeout: 15), tool)
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Drag within the Form's content rather than the app window. An app-wide
    /// downward swipe can invoke iPad window management instead of scrolling.
    @MainActor
    private func revealInForm(_ element: XCUIElement, app: XCUIApplication, towardTop: Bool) {
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        for _ in 0..<18 {
            if element.exists && element.isHittable { return }
            let startY = towardTop ? 0.34 : 0.82
            let endY = towardTop ? 0.82 : 0.34
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: startY))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: endY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    @MainActor
    func testToolboxHomeUsesVisibleSymbolsInBothAppearancesAndKeepsTwoColumns() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["--light", "--dark"] {
            let app = XCUIApplication()
            app.launchArguments = [appearance, "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
            app.launch()
            let level = app.buttons["toolbox.tool.level"]
            let motion = app.buttons["toolbox.tool.motion"]
            XCTAssertTrue(level.waitForExistence(timeout: 15))
            XCTAssertTrue(motion.exists)
            XCTAssertGreaterThan(abs(level.frame.midX - motion.frame.midX), 200)
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "toolbox.featured").firstMatch.exists)
            capture(app, "toolbox-home" + appearance)
            app.terminate()
        }
    }

    @MainActor
    func testQRScannerCancelsAndImageRecognitionReturnsUsableContent() {
        XCUIDevice.shared.orientation = .portrait
        let app = open("qr", anchor: "toolbox.qr.scan", extra: ["--qr-fixture", "--compact", "--dark"])
        defer { app.terminate() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        addUIInterruptionMonitor(withDescription: "Qualification QR camera access") { alert in
            for title in ["允许", "Allow", "好", "OK"] {
                let button = alert.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.buttons["toolbox.qr.scan"].tap()
        let cancel = app.buttons["toolbox.qr.scan.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        if springboard.alerts.firstMatch.exists { app.tap() }
        capture(app, "qr-camera-entry-simulator")
        cancel.tap()
        XCTAssertTrue(app.buttons["toolbox.qr.read"].waitForExistence(timeout: 5))
        app.buttons["toolbox.qr.read"].tap()
        let payload = app.staticTexts["FLOE-QR-IMPORT-2026"]
        XCTAssertTrue(payload.waitForExistence(timeout: 15), "The production image reader must decode the PNG")
        let use = app.buttons.matching(identifier: "toolbox.qr.useResult").firstMatch
        for _ in 0..<3 where !use.isHittable { app.swipeUp() }
        XCTAssertTrue(use.isHittable)
        capture(app, "qr-imported-content-compact-dark")
        use.tap()
        XCTAssertFalse(app.otherElements["ShareSheet.RemoteContainerView"].exists,
                       "Use to generate must not trigger the neighboring Share action")
        app.swipeDown()
        XCTAssertEqual(app.textFields["toolbox.qr.input"].value as? String, "FLOE-QR-IMPORT-2026")
        XCTAssertTrue(app.buttons["toolbox.qr.generate"].isEnabled)
        app.buttons["toolbox.qr.generate"].tap()
        let export = app.buttons["toolbox.qr.export"]
        for _ in 0..<4 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()
        XCTAssertTrue(app.staticTexts["qualification.qr.exported"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testRecognizedWebLinkOpensOnlyFromItsOwnAction() {
        let app = open("qr", anchor: "toolbox.qr.read", extra: ["--qr-link-fixture", "--compact", "--dark"])
        defer { app.terminate() }
        app.buttons["toolbox.qr.read"].tap()
        let destination = "https://example.com/floe-toolbox?source=qr#result"
        XCTAssertTrue(app.staticTexts[destination].waitForExistence(timeout: 15))
        let use = app.buttons.matching(identifier: "toolbox.qr.useResult").firstMatch
        for _ in 0..<4 where !use.isHittable { app.swipeUp() }
        use.tap()
        XCTAssertFalse(app.staticTexts["qualification.qr.openedURL"].exists)
        XCTAssertFalse(app.otherElements["ShareSheet.RemoteContainerView"].exists)
        let link = app.descendants(matching: .any).matching(identifier: "toolbox.qr.openLink").firstMatch
        for _ in 0..<4 where !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.isHittable)
        capture(app, "qr-real-image-web-link-actions")
        link.tap()
        XCTAssertTrue(app.staticTexts["qualification.qr.openedURL"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["qualification.qr.openedURL"].label, destination)
    }

    @MainActor
    func testProductionLevelGaugeFixturesAndMotionBallLayout() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for mode in ["flat", "upright"] {
            let app = open("level", anchor: "qualification.level.gauge", extra: ["--level-fixture-" + mode, "--dark"])
            capture(app, "level-production-gauge-synthetic-" + mode)
            app.terminate()
        }
        let motion = open("motion", anchor: "toolbox.motion.start", extra: ["--light"])
        XCTAssertTrue(motion.descendants(matching: .any).matching(identifier: "toolbox.motion.bubble").firstMatch.exists)
        capture(motion, "motion-production-workbench-with-ball")
        motion.terminate()
    }

    @MainActor
    func testCameraMeasureEmptyModeChangesAndSimulatorSupportMessage() {
        let app = open("measure", anchor: "toolbox.measure.mode", extra: ["--compact", "--dark"])
        defer { app.terminate() }
        let mode = app.segmentedControls["toolbox.measure.mode"]
        mode.buttons["面积"].tap()
        XCTAssertTrue(app.buttons["toolbox.measure.close"].exists)
        XCTAssertFalse(app.buttons["toolbox.measure.close"].isEnabled)
        XCTAssertFalse(app.buttons["toolbox.measure.undo"].isEnabled)
        mode.buttons["长度"].tap()
        XCTAssertFalse(app.buttons["toolbox.measure.add"].isEnabled)
        let start = app.buttons["toolbox.measure.start"]
        if start.exists { start.tap() }
        XCTAssertTrue(app.staticTexts["此设备不支持"].waitForExistence(timeout: 5))
        capture(app, "ar-measure-real-empty-mode-flow-simulator")
        XCTAssertFalse(app.buttons["toolbox.measure.add"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "toolbox.measure.target").firstMatch.exists)
    }

    @MainActor
    func testTimekeepingQuickDurationsAndWheelEditorRemainReachable() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for compact in [false, true] {
            XCUIDevice.shared.orientation = compact ? .portrait : .landscapeLeft
            let app = open("timer", anchor: "toolbox.timer.add",
                           extra: compact ? ["--compact", "--dark", "--large-text"] : ["--light"])
            var createdTimerID: String?
            defer {
                if let id = createdTimerID {
                    let menu = app.buttons["toolbox.timer.actions." + id]
                    for _ in 0..<4 where !menu.isHittable { app.swipeUp() }
                    if menu.isHittable {
                        menu.tap()
                        let remove = app.buttons["删除"]
                        if remove.waitForExistence(timeout: 3) { remove.tap() }
                    }
                }
                app.terminate()
            }
            let add = app.buttons["toolbox.timer.add"]
            for _ in 0..<4 where !add.isHittable { app.swipeUp() }
            for value in [1, 5, 15, 25] {
                let preset = app.buttons["toolbox.timer.preset.\(value)"]
                for _ in 0..<4 where !preset.isHittable { app.swipeUp() }
                XCTAssertTrue(preset.isHittable)
                XCTAssertGreaterThanOrEqual(preset.frame.height, 44)
            }
            capture(app, compact ? "timekeeping-compact-dark-accessibility-presets" : "timekeeping-wide-light-presets")
            for _ in 0..<3 where !add.isHittable { app.swipeDown() }
            add.tap()
            for unit in ["hours", "minutes", "seconds"] {
                let wheel = app.descendants(matching: .any).matching(identifier: "toolbox.timer.duration." + unit).firstMatch
                for _ in 0..<3 where !wheel.exists { app.swipeUp() }
                XCTAssertTrue(wheel.exists, unit)
            }
            capture(app, compact ? "timekeeping-compact-dark-accessibility-wheels" : "timekeeping-wide-light-wheels")
            let titlePrefix = "toolbox.timer.title."
            let label = "QA Layout " + UUID().uuidString.prefix(8)
            let name = app.textFields["toolbox.timer.name"]
            for _ in 0..<4 where !name.isHittable { app.swipeDown() }
            name.tap()
            name.typeText(label)
            app.buttons["toolbox.timer.confirmAdd"].tap()
            let created = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", titlePrefix, label)).firstMatch
            for _ in 0..<4 where !created.exists { app.swipeUp() }
            XCTAssertTrue(created.waitForExistence(timeout: 10))
            createdTimerID = String(created.identifier.dropFirst(titlePrefix.count))
            if let id = createdTimerID {
                let toggle = app.buttons["toolbox.timer.toggle." + id]
                for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
                XCTAssertTrue(toggle.isHittable)
                XCTAssertGreaterThanOrEqual(toggle.frame.height, 44)
                toggle.tap()
                XCTAssertTrue(toggle.label.contains("继续"), toggle.label)
                // Capture settled native button content, not its crossfade.
                RunLoop.main.run(until: Date().addingTimeInterval(1))
                capture(app, compact ? "timekeeping-compact-dark-accessibility-paused-card" : "timekeeping-wide-light-paused-card")
                toggle.tap()
                XCTAssertTrue(toggle.label.contains("暂停"), toggle.label)
            }
        }
    }

    @MainActor
    func testTracerouteUsesProductionLiveRowsAndStop() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = open("traceroute", anchor: "qualification.traceroute.count", extra: ["--dark"])
        defer {
            if app.buttons["停止"].exists { app.buttons["停止"].tap() }
            app.terminate()
        }
        app.buttons["开始"].tap()
        let second = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "2 · ")).firstMatch
        let observed = second.waitForExistence(timeout: 25)
        capture(app, "traceroute-real-simulator-observations")
        XCTAssertTrue(observed, "The production probe must publish actual hop observations")
        if app.buttons["停止"].exists {
            app.buttons["停止"].tap()
            XCTAssertTrue(app.staticTexts["本次检测已停止。"].waitForExistence(timeout: 10))
            capture(app, "traceroute-real-simulator-stopped")
        } else {
            XCTAssertTrue(app.staticTexts["检测完成。"].exists, "The probe may finish before the UI can press Stop")
        }
    }

    @MainActor
    func testTracerouteEmptyDatabaseExplainsInstallationAndReturnsFromSettings() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = open("traceroute", anchor: "qualification.traceroute.count", extra: ["--dark"])
        defer { app.terminate() }
        app.buttons["开始"].tap()
        XCTAssertTrue(app.staticTexts["检测完成。"].waitForExistence(timeout: 45))
        let install = app.buttons["toolbox.traceroute.installIPDatabase"]
        revealInForm(install, app: app, towardTop: true)
        XCTAssertTrue(install.waitForExistence(timeout: 10))
        capture(app, "traceroute-real-empty-database-action")
        install.tap()
        let download = app.buttons["toolbox.ip.database.install"]
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        XCTAssertTrue(download.isEnabled)
        XCTAssertTrue(app.staticTexts["toolbox.ip.database.empty"].exists)
        capture(app, "traceroute-actual-owner-empty-database-settings")
        app.buttons["toolbox.traceroute.ipDatabase.done"].tap()
        XCTAssertTrue(app.staticTexts["qualification.traceroute.count"].exists)
    }

    @MainActor
    func testTracerouteRealDatabaseEnrichesObservedHopsAndOpensItsMap() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = open("traceroute", anchor: "qualification.traceroute.count", extra: ["--ip-default-data", "--light"])
        defer { app.terminate() }
        app.buttons["qualification.traceroute.installRetained"].tap()
        let receipt = app.staticTexts["qualification.traceroute.installReceipt"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 45))
        XCTAssertTrue(receipt.label.hasPrefix("Installed: 2026-11"), receipt.label)
        app.buttons["开始"].tap()
        XCTAssertTrue(app.staticTexts["检测完成。"].waitForExistence(timeout: 45))
        let location = app.buttons["toolbox.traceroute.location.8.8.8.8"]
        revealInForm(location, app: app, towardTop: false)
        XCTAssertTrue(location.waitForExistence(timeout: 10))
        XCTAssertTrue(location.isHittable)
        let details = app.buttons["toolbox.traceroute.details.8.8.8.8"]
        let source = app.staticTexts["toolbox.traceroute.source.8.8.8.8"]
        let hop = app.cells.containing(.button, identifier: "toolbox.traceroute.location.8.8.8.8").firstMatch
        XCTAssertTrue(details.exists)
        XCTAssertFalse(source.exists, "The complete source should be available on expansion")
        XCTAssertLessThanOrEqual(hop.frame.height, 140, "Default IP rows should stay compact at the normal tablet text size")
        let density = XCTAttachment(string: "8.8.8.8 collapsed row height: \(hop.frame.height) pt; previous same-device row: 234.5 pt")
        density.name = "traceroute-ip-row-density"
        density.lifetime = .keepAlways
        add(density)
        capture(app, "traceroute-real-db-ip-compact-hop-summary")
        details.tap()
        revealInForm(source, app: app, towardTop: false)
        XCTAssertTrue(source.waitForExistence(timeout: 5), "Full fields and source must remain available")
        // Selectable Text's AX frame includes UIKit selection padding, unlike
        // the summary Button. Check the intended full-row placement instead of
        // requiring their accessibility frames to have identical left edges.
        let form = app.collectionViews.firstMatch
        XCTAssertLessThan(source.frame.minX, form.frame.minX + form.frame.width * 0.25,
                          "Expanded information belongs below the summary, rather than in a right-hand value column")
        XCTAssertFalse(app.buttons["toolbox.traceroute.map.done"].exists, "Expanding a record must not also open its map")
        capture(app, "traceroute-real-db-ip-expanded-record")
        let dataset = app.buttons["toolbox.traceroute.dataset.8.8.8.8"]
        let version = app.staticTexts["toolbox.traceroute.version.8.8.8.8"]
        XCTAssertFalse(version.exists, "Technical dataset details stay behind their own action")
        dataset.tap()
        revealInForm(version, app: app, towardTop: false)
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        revealInForm(dataset, app: app, towardTop: true)
        dataset.tap()
        XCTAssertFalse(version.exists)
        revealInForm(details, app: app, towardTop: true)
        details.tap()
        XCTAssertFalse(source.exists)
        location.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "toolbox.traceroute.map").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["数据集未提供精度范围。"].exists)
        capture(app, "traceroute-real-db-ip-map")
        app.buttons["toolbox.traceroute.map.done"].tap()
        XCTAssertTrue(app.staticTexts["qualification.traceroute.count"].exists)
        let refresh = app.buttons["toolbox.traceroute.refreshIPInformation"]
        revealInForm(refresh, app: app, towardTop: true)
        XCTAssertTrue(refresh.exists && refresh.isHittable)
        XCTAssertTrue(refresh.isEnabled)
        refresh.tap()
        XCTAssertTrue(app.staticTexts["检测完成。"].exists)
    }

    @MainActor
    func testLevelIntegratedLayoutInWideAndCompactAppearances() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for layout in ["wide", "tablet-portrait", "compact"] {
            XCUIDevice.shared.orientation = layout == "wide" ? .landscapeLeft : .portrait
            for appearance in ["--light", "--dark"] {
                let app = open("level", anchor: "toolbox.level.bubble", extra: [appearance] + (layout == "compact" ? ["--compact"] : []))
                if layout == "tablet-portrait" {
                    XCTAssertGreaterThanOrEqual(app.windows.firstMatch.frame.width, 680,
                                               "Verify the canonical iPad's actual full-width portrait layout")
                    XCTAssertLessThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
                }
                capture(app, "level-integrated-" + layout + appearance)
                app.terminate()
            }
        }
    }

    @MainActor
    func testFirstBatchWorkbenchesOnTablet() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let tools = [("level", "toolbox.level.bubble"), ("motion", "toolbox.motion.start"),
                     ("compass", "toolbox.compass.dial"), ("ruler", "toolbox.ruler.canvas"),
                     ("measure", "toolbox.measure.mode"), ("calculator", "toolbox.calculator.expression")]
        for (tool, anchor) in tools {
            let app = open(tool, anchor: anchor)
            XCTAssertFalse(app.staticTexts["Existing App tool"].exists)
            capture(app, tool + "-tablet-landscape")
            app.terminate()
        }
    }

    @MainActor
    func testCalculatorEvaluatesAndConvertsInCompactLayout() {
        XCUIDevice.shared.orientation = .portrait
        let app = open("calculator", anchor: "toolbox.calculator.expression", extra: ["--compact"])
        let expression = app.textFields["toolbox.calculator.expression"].exists
            ? app.textFields["toolbox.calculator.expression"] : app.textViews["toolbox.calculator.expression"]
        expression.tap()
        expression.typeText("sqrt(81)+3^2")
        app.buttons["toolbox.calculator.evaluate"].tap()
        XCTAssertEqual(app.staticTexts["toolbox.calculator.result"].label, "18")
        capture(app, "calculator-compact-result")
        app.segmentedControls.buttons["单位换算"].tap()
        XCTAssertTrue(app.textFields["toolbox.converter.input"].waitForExistence(timeout: 5))
        capture(app, "converter-compact")
        app.terminate()
    }

    @MainActor
    func testLevelRemainsReadableInCompactDarkLargeType() {
        let app = open("level", anchor: "toolbox.level.bubble", extra: ["--compact", "--dark", "--large-text"])
        XCTAssertTrue(app.staticTexts["toolbox.level.unavailable"].exists || app.buttons["toolbox.level.pause"].exists)
        capture(app, "level-compact-dark-large-text")
        app.terminate()
    }

    @MainActor
    func testConverterStartsWithValidUnitsAndSwapsItsActualSelection() {
        let app = open("calculator", anchor: "toolbox.calculator.expression", extra: ["--compact"])
        defer { app.terminate() }
        app.segmentedControls.buttons["单位换算"].tap()
        let from = app.buttons["toolbox.converter.from"]
        let to = app.buttons["toolbox.converter.to"]
        XCTAssertTrue(from.waitForExistence(timeout: 5))
        let originalFrom = from.label
        let originalTo = to.label
        XCTAssertTrue(originalFrom.contains("mm"), originalFrom)
        XCTAssertTrue(originalTo.contains("cm"), originalTo)
        XCTAssertEqual(app.staticTexts["toolbox.converter.result"].label, "0.1")
        app.buttons["toolbox.converter.swap"].tap()
        XCTAssertTrue(from.label.contains("cm"), from.label)
        XCTAssertTrue(to.label.contains("mm"), to.label)
        XCTAssertEqual(app.staticTexts["toolbox.converter.result"].label, "10")
        app.buttons["toolbox.converter.category"].tap()
        app.buttons["温度"].tap()
        XCTAssertTrue(from.label.contains("°C"), from.label)
        XCTAssertTrue(to.label.contains("°F"), to.label)
        XCTAssertEqual(app.staticTexts["toolbox.converter.result"].label, "33.8")
        capture(app, "converter-valid-initial-units-swap-and-category")
    }

    @MainActor
    func testRulerPlacesSeparateHandlesAndDragsInCanvasCoordinates() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = open("ruler", anchor: "toolbox.ruler.canvas")
        defer { app.terminate() }
        let a = app.descendants(matching: .any).matching(identifier: "toolbox.ruler.handle.a").firstMatch
        let b = app.descendants(matching: .any).matching(identifier: "toolbox.ruler.handle.b").firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 5))
        XCTAssertTrue(b.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(abs(a.frame.midX - b.frame.midX), 44)
        XCTAssertGreaterThanOrEqual(a.frame.width, 44)
        XCTAssertGreaterThanOrEqual(a.frame.height, 44)
        XCTAssertEqual(a.frame.midY, b.frame.midY, accuracy: 2)
        let before = a.frame.midX
        let start = a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 80, dy: 0)))
        XCTAssertEqual(a.frame.midX, before + 80, accuracy: 6)
        app.buttons["toolbox.ruler.reset"].tap()
        XCTAssertEqual(a.frame.midX, before, accuracy: 3)
        XCTAssertTrue(app.buttons["toolbox.ruler.calibration.finish"].isEnabled)
        capture(app, "ruler-separated-draggable-handles-tablet")
        app.segmentedControls["toolbox.ruler.mode"].buttons["角度"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "toolbox.ruler.readout.angle").firstMatch.exists)
        capture(app, "ruler-angle-handles-tablet")
    }

    @MainActor
    func testPhotoCalibrationAndExportOnTablet() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = open("photoMeasure", anchor: "toolbox.photo.choose", extra: ["--photo-fixture"])
        app.buttons["toolbox.photo.choose"].tap()
        let canvas = app.descendants(matching: .any).matching(identifier: "toolbox.photo.canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45)).tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.45)).tap()
        let value = app.textFields["toolbox.photo.referenceValue"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        value.tap(); value.typeText("100")
        app.buttons["toolbox.photo.apply"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "toolbox.photo.readout").firstMatch.waitForExistence(timeout: 5))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.65)).tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.65)).tap()
        app.buttons["toolbox.photo.export"].tap()
        XCTAssertTrue(app.staticTexts["qualification.photo.exported"].waitForExistence(timeout: 10))
        capture(app, "photo-measure-calibrated-export-tablet")
        app.terminate()
    }

    @MainActor
    func testPhotoToolsInCompactDarkLargeType() {
        XCUIDevice.shared.orientation = .portrait
        let app = open("photoMeasure", anchor: "toolbox.photo.choose", extra: ["--photo-fixture", "--compact", "--dark", "--large-text"])
        app.buttons["toolbox.photo.choose"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "toolbox.photo.canvas").firstMatch.waitForExistence(timeout: 10))
        capture(app, "photo-measure-compact-dark-large-text")
        app.terminate()
    }
}

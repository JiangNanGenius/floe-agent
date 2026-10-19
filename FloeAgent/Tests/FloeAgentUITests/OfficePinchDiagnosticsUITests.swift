// SPDX-License-Identifier: MPL-2.0
import XCTest
import UIKit
import Vision

/// Diagnostic-only XCTest suite pairing the PUBLIC `XCUIElement.pinch`
/// stimulus with the DEBUG-only passive Office touch telemetry published by
/// `OfficeTouchQualificationProbe` (launch argument
/// `--office-touch-qualification`).
///
/// What this suite is:
///   * Paired controls for root's real-pinch investigation: the same actual
///     UIKit pinch the feature test performs, run once with drawing OFF and
///     once with drawing ON, in landscape and (optionally) portrait, with the
///     before/after DOM event ring, first-start samples, engine state
///     (getZoom / sectionContainer fields / pen gate state) and bounded
///     viewport numerics captured around each gesture.
///   * Evidence of the telemetry contract itself: the probe must be present,
///     parseable, same-generation, monotonic and bounded. That is what these
///     methods assert.
/// What this suite is NOT:
///   * Feature acceptance. The untouched
///     `NotesWorkspaceImportUITests.testOfficePencilToolbarToggleAndSettings`
///     retains the real 1.08 title-growth acceptance threshold. These
///     diagnostics deliberately never assert zoom success: a failing pinch is
///     the phenomenon under study, and its actual zoom delta, first-touchstart
///     shape and cancellation facts must still be recorded and delivered.
///
/// All observations attach BEFORE any assertion. Requires a Debug build (the
/// probe does not exist in Release); on a build without it the baseline wait
/// fails with an explicit "probe missing" reason instead of passing vacuously.
/// The suite is opt-in through FLOE_OFFICE_PINCH_DIAGNOSTIC_UI=1, mirroring
/// the existing pencil toolbar suite's environment gate, and runs serially on
/// root's canonical device.
@MainActor
final class OfficePinchDiagnosticsUITests: XCTestCase {
    private static let probeIdentifier = "office.touch-qualification.snapshot"
    private static let probeLaunchArgument = "--office-touch-qualification"
    /// Owned synthetic fixture created by the actual C6 UI run; reused when
    /// still present, so no duplicate documents pile into the shared library.
    private static let ownedFixtureTitle = "Pen UI 0D3972C1"

    func testRealPinchDrawingOffLandscape() throws {
        try runRealPinchDiagnostic(drawingOn: false, landscape: true)
    }

    func testRealPinchDrawingOnLandscape() throws {
        try runRealPinchDiagnostic(drawingOn: true, landscape: true)
    }

    func testRealModeratePinchDrawingOnLandscape() throws {
        try runRealPinchDiagnostic(drawingOn: true, landscape: true, pinchScale: 1.1)
    }

    /// Optional portrait variants — root chooses which selectors to execute.
    func testRealPinchDrawingOffPortrait() throws {
        try runRealPinchDiagnostic(drawingOn: false, landscape: false)
    }

    func testRealPinchDrawingOnPortrait() throws {
        try runRealPinchDiagnostic(drawingOn: true, landscape: false)
    }

    // MARK: - Paired real-pinch diagnostic

    private func runRealPinchDiagnostic(drawingOn: Bool, landscape: Bool, pinchScale: CGFloat = 1.25) throws {
        guard ProcessInfo.processInfo.environment["FLOE_OFFICE_PINCH_DIAGNOSTIC_UI"] == "1" else {
            throw XCTSkip("Opt-in Office pinch diagnostics; set FLOE_OFFICE_PINCH_DIAGNOSTIC_UI=1 in the test runner environment.")
        }
        continueAfterFailure = false
        let scaleSuffix = pinchScale == 1.25 ? "" : "-scale-\(Int((pinchScale * 100).rounded()))"
        let caseName = "draw-\(drawingOn ? "on" : "off")-\(landscape ? "landscape" : "portrait")\(scaleSuffix)"
        let ipad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true
            || UIDevice.current.userInterfaceIdiom == .pad
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        // Same product-safe launch envelope as the existing pencil suite,
        // plus the DEBUG-only telemetry argument. The probe never activates
        // without this argument; serialization stays with the root runner.
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-ui-testing",
                               "--ui-test-skip-onboarding", "--ui-test-batch-fixture",
                               Self.probeLaunchArgument]
        if ipad { app.launchArguments.append("-ui-testing-ipad") }
        app.launch()
        defer { app.terminate() }

        if !ipad {
            let sidebar = app.buttons["phone.sidebar.open"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 15)); sidebar.tap()
        }
        let notes = app.staticTexts["sidebar.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 15)); notes.tap()

        // Prefer the owned fixture; fall back to the same native product
        // create path with a fresh owned token. No store writes, no library
        // clearing — the shared device's other notes stay untouched.
        var fixtureTitle = Self.ownedFixtureTitle
        if !openFixtureDocument(app, title: fixtureTitle) {
            // The product create path opens the editor directly; do not run
            // any library lookup after it (a stray scroll/tap there would
            // touch the freshly opened editor instead of the library).
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
            fixtureTitle = "Pen UI \(token)"
            try createWordFixture(app, title: fixtureTitle)
            XCTAssertTrue(app.buttons["office.editor.back"].waitForExistence(timeout: 60),
                          "the newly created Word fixture must open the native Office editor")
        }

        let back = app.buttons["office.editor.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 60),
                      "the native Office editor must open for the diagnostic document")
        wait(for: [expectation(for: NSPredicate(format: "enabled == true AND hittable == true"),
                               evaluatedWith: back)], timeout: 60)

        // Reach the editable surface exactly like the existing suite: either
        // the pen toolbar is already there or the host Edit action opens it.
        let toggle = app.buttons["office.drawing.toggle"]
        let edit = app.buttons["office.preview.edit"]
        XCTAssertTrue(waitUntil(timeout: 60, { toggle.exists || edit.exists }),
                      "the Office surface must reach the editable pen toolbar or the host Edit action")
        if !toggle.exists {
            XCTAssertTrue(waitUntil(timeout: 30, { edit.isEnabled && edit.isHittable }),
                          "the preview's Edit action must become actionable")
            edit.tap()
            XCTAssertTrue(toggle.waitForExistence(timeout: 60),
                          "the editable toolbar must expose the pen toggle after edit entry")
        }
        XCTAssertTrue(waitUntil(timeout: 30, { toggle.exists && toggle.isEnabled && toggle.isHittable }),
                      "the pen toggle must be actionable before the drawing state is set")

        // Set the drawing state through the real toolbar control only. The
        // document legitimately opens with drawing Off (the session activates
        // with drawingMode = false), so one real tap is exactly the ON case.
        if !waitForDrawingValue(toggle, on: drawingOn, timeout: 2) {
            toggle.tap()
            XCTAssertTrue(waitForDrawingValue(toggle, on: drawingOn, timeout: 30),
                          "the real toggle must publish the case target state: \(drawingOn ? "On" : "Off")")
        }
        if drawingOn {
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 15),
                          "enabling drawing must dismiss the Office text keyboard")
        }

        // Wait for the DEBUG-only passive probe to publish its first real
        // snapshot. This proves the observability channel end to end before
        // any gesture evidence is interpreted.
        let baselineRead = readProbeSnapshot(app, timeout: 45)
        attachText(baselineRead.raw, name: "pinch-diag-\(caseName)-probe-baseline")
        XCTAssertTrue(baselineRead.ok,
                      "the DEBUG touch probe must be installed and publish ok=1 within 45s of document ready (a Release build or a missing --office-touch-qualification launch argument fails here by design); last value: \(baselineRead.raw.prefix(200))")
        guard let baseline = baselineRead.dict else { return }

        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10), "the Office WKWebView surface must be visible")
        // Record the real keyboard occupancy in both paired cases: drawing
        // OFF may keep the software keyboard covering the WKWebView while ON
        // dismisses it, so event/viewport differences must never be attributed
        // to the pen flag alone. No global Simulator keyboard setting is
        // touched — this is a pure observation.
        let keyboardBefore = keyboardFacts(app, phase: "before")
        let gestureFacts = XCTAttachment(string: """
            case=\(caseName)
            requested-orientation=\(landscape ? "landscapeLeft" : "portrait")
            requested-pinch-scale=\(pinchScale)
            xcui-device-orientation=\(XCUIDevice.shared.orientation.rawValue)
            device-orientation=\(UIDevice.current.orientation == .unknown ? "unknown" : UIDevice.current.orientation.name)
            window-frame=\(app.windows.firstMatch.frame)
            webview-frame=\(web.frame)
            toggle-value=\(((toggle.value as? String) ?? "missing"))
            \(keyboardBefore)
            baseline-probe-t=\(baseline["t"] ?? "nil")
            baseline-ring=\((baseline["ring"] as? [[String: Any]])?.count ?? -1)
            baseline-starts=\((baseline["starts"] as? [[String: Any]])?.count ?? -1)
            baseline-ns=\(baseline["ns"] ?? "nil")
            """)
        gestureFacts.name = "pinch-diag-\(caseName)-orientation-and-state"
        gestureFacts.lifetime = .keepAlways
        add(gestureFacts)

        // Observations first, all of them, BEFORE any diagnostic assertion.
        let beforePinch = web.screenshot()
        attachScreenshot(beforePinch, name: "pinch-diag-\(caseName)-web-before")
        web.pinch(withScale: pinchScale, velocity: 1)
        Thread.sleep(forTimeInterval: 1.5)
        let afterPinch = web.screenshot()
        attachScreenshot(afterPinch, name: "pinch-diag-\(caseName)-web-after")

        let afterRead = readProbeSnapshot(app, timeout: 15)
        attachText(afterRead.raw, name: "pinch-diag-\(caseName)-probe-after")
        XCTAssertTrue(afterRead.ok,
                      "the probe must still publish a snapshot after the real pinch; last value: \(afterRead.raw.prefix(200))")
        guard let after = afterRead.dict else { return }

        // OCR the document title width purely as an observed visual zoom
        // delta. Never asserted here: the untouched feature suite owns the
        // 1.08 acceptance threshold.
        var ocrFacts = "title-ocr: unavailable"
        var beforeWidth: CGFloat = -1, afterWidth: CGFloat = -1
        do {
            beforeWidth = try officeTitleBounds(in: beforePinch.image).width
            afterWidth = try officeTitleBounds(in: afterPinch.image).width
            ocrFacts = String(format: "title-ocr: before=%.6f after=%.6f ratio=%.4f",
                              beforeWidth, afterWidth, afterWidth / max(beforeWidth, 0.000001))
        } catch {
            ocrFacts = "title-ocr: unavailable (\(error.localizedDescription))"
        }

        let keyboardAfter = keyboardFacts(app, phase: "after")
        let report = pinchTelemetryReport(caseName: caseName, baseline: baseline, after: after,
                                          ocrFacts: ocrFacts, deviceOrientationFacts: gestureFacts.name,
                                          keyboardBefore: keyboardBefore, keyboardAfter: keyboardAfter)
        attachText(report, name: "pinch-diag-\(caseName)-interpretation")

        // Observe a second, independent real gesture without requiring any
        // particular visual zoom result in this diagnostic suite.
        web.pinch(withScale: 0.8, velocity: -1)
        Thread.sleep(forTimeInterval: 1.5)
        attachScreenshot(web.screenshot(), name: "pinch-diag-\(caseName)-web-after-out")
        let outRead = readProbeSnapshot(app, timeout: 15)
        attachText(outRead.raw, name: "pinch-diag-\(caseName)-probe-after-out")
        XCTAssertTrue(outRead.ok, "the probe must remain available after the second real gesture")
        guard let afterOut = outRead.dict else { return }
        XCTAssertEqual(number(afterOut["gen"]), number(baseline["gen"]),
                       "both gestures must be observed in the same document session")

        // The telemetry contract itself is what these cases verify. A broken
        // probe must fail loudly; a non-zooming pinch must not.
        XCTAssertEqual(number(after["gen"]), number(baseline["gen"]),
                       "baseline and post-pinch snapshots must come from the same probe install")
        XCTAssertEqual(number(after["v"]), 1, "the snapshot must carry the probe schema version")
        let ring = after["ring"] as? [[String: Any]] ?? []
        let starts = after["starts"] as? [[String: Any]] ?? []
        XCTAssertLessThanOrEqual(ring.count, 128, "the recent ring must stay bounded")
        XCTAssertLessThanOrEqual(starts.count, 16, "the first-start window must stay bounded")
        XCTAssertGreaterThanOrEqual(number(after["ns"]) ?? -1, Double(starts.count),
                                    "the all-start counter must cover every first-start sample kept")
        let times = ring.compactMap { number($0["t"]) }
        XCTAssertEqual(times.count, ring.count, "every ring record must carry a monotonic time")
        XCTAssertFalse(zip(times, times.dropFirst()).contains { $0 > $1 },
                       "ring times must never go backwards")
        XCTAssertLessThanOrEqual(afterRead.raw.count, 45_000,
                                 "the published snapshot must stay inside the transfer contract")
        XCTAssertNotNil(after["rtv"], "the snapshot must declare its ring-transfer-withheld count")

        // Safe exit through the product's own back/save path.
        XCTAssertTrue(waitUntil(timeout: 15, { back.isEnabled && back.isHittable }))
        back.tap()
        let create = app.navigationBars.buttons.matching(identifier: "notes.create").element(boundBy: 0)
        XCTAssertTrue(create.waitForExistence(timeout: 60),
                      "the Office editor must return to the Notes library through its safe exit")
    }

    // MARK: - Fixture navigation (product paths only)

    /// Reveal + tap the owned fixture when it is still in the library, using
    /// the exact card identity the existing suite matches on
    /// (`notes.card.<kind>.<title>.<coverSource>` under the library scroll,
    /// bounded-index query instead of a global firstMatch traversal). The
    /// grid is lazy, so reset to top and sweep before declaring absence.
    private func openFixtureDocument(_ app: XCUIApplication, title: String) -> Bool {
        let card = app.scrollViews["notes.library.scroll"].buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "notes.card.office.\(title)."))
            .element(boundBy: 0)
        let back = app.buttons["office.editor.back"]
        if card.exists && card.isHittable {
            card.tap()
            return back.waitForExistence(timeout: 60)
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
        Thread.sleep(forTimeInterval: 0.4)
        let scroll = app.scrollViews["notes.library.scroll"]
        guard scroll.waitForExistence(timeout: 5) else { return false }
        for _ in 0..<8 {
            if card.exists && card.isHittable {
                card.tap()
                return back.waitForExistence(timeout: 60)
            }
            scroll.swipeUp()
        }
        return false
    }

    /// Create the synthetic Word document through the exact product route the
    /// existing suite uses (Notes create → Office → Word 文档 → title → 创建).
    private func createWordFixture(_ app: XCUIApplication, title: String) throws {
        let create = app.navigationBars.buttons.matching(identifier: "notes.create").element(boundBy: 0)
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)], timeout: 10)
        create.tap()
        let office = app.buttons["Office"]
        XCTAssertTrue(office.waitForExistence(timeout: 10)); office.tap()
        // UIKit's nested menu retains the visible title but drops SwiftUI's
        // accessibilityIdentifier on its generated action buttons.
        let word = app.buttons["Word 文档"]
        XCTAssertTrue(word.waitForExistence(timeout: 10)); word.tap()
        let titleField = app.textFields["notes.create.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        titleField.tap()
        titleField.typeText(title)
        let createButton = app.buttons["创建"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: createButton)], timeout: 10)
        createButton.tap()
    }

    // MARK: - Probe snapshot plumbing

    private struct SnapshotRead {
        let ok: Bool
        let raw: String
        let dict: [String: Any]?
    }

    private func readProbeSnapshot(_ app: XCUIApplication, timeout: TimeInterval) -> SnapshotRead {
        let probe = app.descendants(matching: .any)
            .matching(identifier: Self.probeIdentifier).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var last = "missing"
        while Date() < deadline {
            if probe.exists, let raw = probe.value as? String {
                last = raw
                if let dict = parseJSON(raw), number(dict["ok"]) == 1 {
                    return SnapshotRead(ok: true, raw: raw, dict: dict)
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return SnapshotRead(ok: false, raw: last, dict: parseJSON(last))
    }

    private func parseJSON(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: - Interpretation report

    private func keyboardFacts(_ app: XCUIApplication, phase: String) -> String {
        let keyboard = app.keyboards.firstMatch
        let exists = keyboard.exists
        return "keyboard-\(phase): count=\(app.keyboards.count) exists=\(exists) frame=\(exists ? "\(keyboard.frame)" : "none")"
    }

    /// Compact derived facts that separate the live hypotheses: batched
    /// two-finger birth discarded by the container, a UIKit-side cancellation
    /// (pointercancel / touchcancel with no consumption), a gate-level
    /// pointer stop under drawing mode, or input that never reached web
    /// content at all. Everything numeric or structural only — no document
    /// content, URL, title or path.
    private func pinchTelemetryReport(caseName: String, baseline: [String: Any],
                                      after: [String: Any], ocrFacts: String,
                                      deviceOrientationFacts: String?,
                                      keyboardBefore: String, keyboardAfter: String) -> String {
        let baseT = number(baseline["t"]) ?? 0
        let ring = after["ring"] as? [[String: Any]] ?? []
        let newEvents = ring.filter { (number($0["t"]) ?? 0) > baseT }
        let newStarts = newEvents.filter { (($0["k"] as? String) == "ts") || (($0["k"] as? String) == "pd") }
        func describe(_ record: [String: Any]?) -> String {
            guard let record else { return "none" }
            let coords = (record["o"] as? [[Any]])?.map { point in
                "\((point.first as? NSNumber)?.doubleValue ?? -1),\((point.last as? NSNumber)?.doubleValue ?? -1)"
            }.joined(separator: "|") ?? ""
            let q = (record["q"] as? [String: Any]).map { dict in
                " q{mt:\(number(dict["mt"]) ?? -2) pmd:\(number(dict["pmd"]) ?? -2) som:\(dict["som"] ?? "nil") tei:\(number(dict["tei"]) ?? -2) z:\(number(dict["z"]) ?? -1)}"
            } ?? ""
            return "k=\(record["k"] ?? "?") t=\(number(record["t"]) ?? -1) n=\(number(record["n"]) ?? -2) c=\(number(record["c"]) ?? -2) trusted=\(number(record["tr"]) ?? -2) dp=\(number(record["dp"]) ?? -2) p=\(record["p"] ?? "nil") pi=\(number(record["pi"]) ?? -2) tgt=\(record["g"] as? [String: Any] ?? [:]) coords=\(coords)\(q)"
        }
        func counts(_ dict: [String: Any]?, _ field: String) -> String {
            guard let counts = dict?[field] as? [String: Any] else { return "missing" }
            return ["ts", "tm", "te", "tc", "pd", "pm", "pu", "pc"]
                .map { "\($0)=\(number(counts[$0]) ?? -1)" }.joined(separator: " ")
        }
        func state(_ dict: [String: Any]?) -> String {
            guard let st = dict?["st"] as? [String: Any] else { return "missing" }
            return "zoom=\(number(st["z"]) ?? -1) multiTouch=\(number(st["mt"]) ?? -2) positionOnMouseDown=\(number(st["pmd"]) ?? -2) sectionOnMouseDown=\(st["som"] ?? "nil") touchEventInProgress=\(number(st["tei"]) ?? -2) dpiScale=\(number(st["dpi"]) ?? -2)"
        }
        func viewport(_ dict: [String: Any]?) -> String {
            guard let vp = dict?["vp"] as? [String: Any] else { return "missing" }
            return "inner=\(number(vp["iw"]) ?? -1)x\(number(vp["ih"]) ?? -1) dpr=\(number(vp["dpr"]) ?? -1) visual=\(number(vp["vw"]) ?? -1)x\(number(vp["vh"]) ?? -1)@\(number(vp["vs"]) ?? -1) screen=\(number(vp["sw"]) ?? -1)x\(number(vp["sh"]) ?? -1) orientation=\(vp["so"] ?? "nil")"
        }
        func pen(_ dict: [String: Any]?) -> String {
            guard let p = dict?["pen"] as? [String: Any] else { return "nil" }
            return "drawing=\(number(p["d"]) ?? -2) activeStroke=\(number(p["as"]) ?? -2) strokes=\(number(p["str"]) ?? -2) toolState=\(p["ts"] ?? "nil")"
        }
        // First-new-start evidence is decisive, so take it from the
        // never-shrunk first-start window first and only then from the
        // transfer ring (which may withhold oldest records under pathological
        // size pressure).
        let startsNew = (after["starts"] as? [[String: Any]] ?? []).filter { (number($0["t"]) ?? 0) > baseT }
        let ringNewStarts = newEvents.filter { (($0["k"] as? String) == "ts") || (($0["k"] as? String) == "pd") }
        let startCandidates = startsNew + ringNewStarts
        let firstTouchStart = startCandidates.first { ($0["k"] as? String) == "ts" }
        let firstPointerDown = startCandidates.first { ($0["k"] as? String) == "pd" }
        let cancels = newEvents.filter { (($0["k"] as? String) == "tc") || (($0["k"] as? String) == "pc") }
        let zoomDelta = (number((after["st"] as? [String: Any])?["z"]) ?? -1)
            - (number((baseline["st"] as? [String: Any])?["z"]) ?? -1)
        return """
        case=\(caseName)
        \(ocrFacts)
        \(keyboardBefore)
        \(keyboardAfter)
        zoom-delta(before→after)=\(zoomDelta)
        baseline-state: \(state(baseline))
        after-state: \(state(after))
        baseline-viewport: \(viewport(baseline))
        after-viewport: \(viewport(after))
        baseline-pen: \(pen(baseline))
        after-pen: \(pen(after))
        new-event-count(ring)=\(newEvents.count)  new-start-count(ring)=\(newStarts.count)  new-start-count(window)=\(startsNew.count)  dropped-ring-events=\(number(after["dr"]) ?? -1)  all-starts=\(number(after["ns"]) ?? -1)
        transfer-shrink(rtv)=\(number(after["rtv"]) ?? -1)  ring-complete-for-interpretation=\((number(after["rtv"]) ?? 0) == 0 && (number(after["dr"]) ?? 0) == 0)
        first-new-touchstart: \(describe(firstTouchStart))
        first-new-pointerdown: \(describe(firstPointerDown))
        cancel-records: \(cancels.map { describe($0) }.joined(separator: " ; ").isEmpty ? "none" : cancels.map { describe($0) }.joined(separator: " ; "))
        capture-counts(after): \(counts(after, "cnt"))
        bubble-counts(after): \(counts(after, "cntB"))
        defaultPrevented-bubbles(after): \(counts(after, "cntD"))
        first-start-window(after): \((after["starts"] as? [[String: Any]] ?? []).map { describe($0) }.joined(separator: " ; ").isEmpty ? "empty" : (after["starts"] as? [[String: Any]] ?? []).map { describe($0) }.joined(separator: " ; "))
        orientation-facts-attachment=\(deviceOrientationFacts ?? "none")
        interpretation: n==2 with no later consumption ⇒ batched two-finger birth drop;
        pd/pm capture zero while ts>0 under drawing ON ⇒ gate pointer-level stop before this probe;
        tc/pc with dp=0 and few moves ⇒ UIKit-side cancellation after birth;
        zero new DOM records while the pinch visibly targeted the webview ⇒ input never reached web content (harness/targeting branch).
        """
    }

    // MARK: - Attachments / helpers

    private func attachText(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachScreenshot(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    /// Same published-value semantics as the existing suite (real localized
    /// state, never a synthetic one).
    private func waitForDrawingValue(_ toggle: XCUIElement, on: Bool, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            guard toggle.exists else { return false }
            let value = ((toggle.value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return on ? (value == "已开启" || value == "On") : (value == "已关闭" || value == "Off")
        }
    }

    /// Duplicated from the untouched feature suite because it is private
    /// there; used only to OBSERVE (never to accept) the visual zoom delta.
    private func officeTitleBounds(in image: UIImage) throws -> CGRect {
        guard let cg = image.cgImage else {
            throw NSError(domain: "OfficePinchDiagnostics", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Screenshot has no CGImage"])
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cg).perform([request])
        let title = request.results?.first { observation in
            guard let text = observation.topCandidates(1).first?.string else { return false }
            return text.replacingOccurrences(of: " ", with: "").lowercased().contains("penui")
        }
        guard let title else {
            // OCR is an optional observation here. A missing landmark must
            // not terminate the diagnostic before its event report attaches.
            throw NSError(domain: "OfficePinchDiagnostics", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Synthetic document title not visible"])
        }
        return title.boundingBox
    }
}

private extension UIDeviceOrientation {
    var name: String {
        switch self {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .faceUp: return "faceUp"
        case .faceDown: return "faceDown"
        case .unknown: return "unknown"
        @unknown default: return "unknown-default"
        }
    }
}

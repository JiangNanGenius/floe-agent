// SPDX-License-Identifier: MPL-2.0
// FloeAgentUITests — E26 native IGES open-surface import/export acceptance.
//
// Two focused flows over the SHIPPED App surfaces (no test-only banner or
// export form):
//
//   * import: the real pending IGES import proposal over an owned workspace
//     document must show its exact-open-surface preview and limitation BEFORE
//     Apply, must not mutate the document while the proposal is only pending,
//     and Apply must add the exact surface body named by the same
//     content-addressed source the banner displayed.
//   * export: the real part/assembly exchange sheet must show STEP refusing
//     the exact open surface (as a surface, not a mesh) and the part-scope
//     IGES receipt including it while excluding the mesh-only body; mixed
//     coverage must offer only the explicit "Export Included" consent action,
//     must stage nothing before it, and cancelling must leave the document
//     unchanged. The consent action itself must dismiss the sheet only after
//     the production writer returns accepted-partial bytes.
//
// Fixtures are generated inside the App by `CADIGESSurfaceUIFixture` with the
// native OCCT IGES writer over a standalone exact face plus the production
// OBJ/IGES import paths. Root owns the actual Simulator run; this file does
// not claim one.

import XCTest

@MainActor
final class CADIGESSurfaceImportExportUITests: XCTestCase {
    private enum Launch {
        static let base = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                           "-ui-testing", "-ui-testing-ipad", "--ui-test-cad-fixture"]
        static let importPreview = "--ui-test-cad-iges-surface-import"
        static let exportCoverage = "--ui-test-cad-iges-surface-export"
    }

    /// The shipped pre-Apply banner, the exact-surface limitation, and Apply.
    func testIGESSurfaceProposalShowsExactSurfaceLimitBeforeApplyAndApplyAddsIt() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = Launch.base + [Launch.importPreview]
        app.launch()
        defer { app.terminate() }
        let apply = app.buttons["cad.native.apply"]
        // Same 120 s contract, but a fixture that failed to prepare reports its
        // own error instead of surfacing as an unrelated control timeout, and a
        // banner whose controls are not addressable by their own identifiers
        // says so explicitly. The assertion itself is unchanged: the shipped
        // banner's real Apply control must exist before anything is tapped.
        switch waitForImportBanner(apply, in: app, timeout: 120) {
        case .ready:
            break
        case .fixtureFailed(let detail):
            XCTFail("the E26 fixture could not present its pending import: \(detail)")
            return
        case .timedOut:
            XCTFail("the shipped import proposal banner must appear before Apply"
                + bannerDiagnosis(in: app))
            return
        }
        let detail = app.staticTexts["cad.native.importDetail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20))
        let detailText = detail.label
        let source = try XCTUnwrap(sourceIdentity(in: detailText),
                                   "the banner must name the content-addressed IGES source: \(detailText)")
        XCTAssertTrue(detailText.contains("IGES"), detailText)
        XCTAssertTrue(detailText.contains("exact open surface"), detailText)
        XCTAssertTrue(detailText.contains("+1"), detailText)
        let limit = app.staticTexts["cad.native.importSurfaceLimit"]
        XCTAssertTrue(limit.waitForExistence(timeout: 10),
                      "the shipped banner must state the exact open-surface limitation")
        XCTAssertTrue(limit.label.contains("boolean, fillet and shell need closed solids"),
                      limit.label)
        XCTAssertTrue(app.buttons["cad.native.discard"].exists)
        CADSheetProbe.attach("E26 exact open-surface proposal before Apply", to: self)

        // A pending proposal is a draft on a throwaway copy: the saved
        // plate + mesh package must still have no surface row.
        openItems(app)
        XCTAssertTrue(itemRow(containing: "MeshOnly.obj", in: app).waitForExistence(timeout: 30))
        XCTAssertFalse(itemRow(containing: source.digest, in: app).exists,
                       "the import preview must not mutate the document before Apply")
        closeItems(app)
        XCTAssertTrue(apply.waitForExistence(timeout: 20))

        apply.tap()
        XCTAssertTrue(CADSheetProbe.waitForAbsence(apply, timeout: 120),
                      "Apply must consume the real pending proposal")
        openItems(app)
        XCTAssertTrue(itemRow(containing: source.digest, in: app).waitForExistence(timeout: 120),
                      "Apply must add the exact surface body with the same source digest")
        CADSheetProbe.attach("E26 applied exact open surface", to: self)
    }

    /// The part-scope IGES mixed receipt and its explicit partial consent.
    func testPartScopeIGESReceiptExcludesOnlyTheMeshAndNeedsExportIncluded() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = Launch.base + [Launch.exportCoverage]
        app.launch()
        defer { app.terminate() }

        // Record the real saved document: exact surface body (named after the
        // IGES source digest), mesh body and undo/redo affordances. Opening
        // the shipped Items toggle is also the workbench readiness gate.
        openItems(app)
        let surfaceRow = itemRowPrefix("ItemRow-OpenSurface-", in: app)
        XCTAssertTrue(surfaceRow.waitForExistence(timeout: 60),
                      "the saved fixture must contain its exact open-surface body")
        let surfaceIdentifier = surfaceRow.identifier
        let source = try XCTUnwrap(sourceIdentity(in: surfaceIdentifier),
                                   "the surface body row must keep the source identity: \(surfaceIdentifier)")
        XCTAssertTrue(itemRow(containing: "MeshOnly.obj", in: app).exists)
        XCTAssertTrue(app.buttons["UndoButton"].waitForExistence(timeout: 30),
                      "the workbench Undo affordance must be reachable in the host chrome")
        XCTAssertTrue(app.buttons["RedoButton"].waitForExistence(timeout: 30))
        let undoBefore = app.buttons["UndoButton"].isEnabled
        let redoBefore = app.buttons["RedoButton"].isEnabled
        closeItems(app)

        // STEP (the sheet's default) is closed-solid only: it must refuse the
        // exact open surface AS A SURFACE and the mesh-only body separately.
        openExchangeSheet(app)
        XCTAssertTrue(waitForObjects("1 / 3", in: app),
                      "STEP must include only the closed solid of the three bodies")
        let stepSurfaceReason = app.staticTexts["Open surface; STEP export here writes closed solids only."]
        XCTAssertTrue(CADSheetProbe.scrollReveal(stepSurfaceReason, in: app,
                                                 sheet: "Export", timeout: 60),
                      "STEP must refuse the exact open surface for the surface reason, not as a mesh")
        let stepMeshReason = app.staticTexts["Mesh-only; STEP needs an analytic solid."]
        XCTAssertTrue(CADSheetProbe.scrollReveal(stepMeshReason, in: app,
                                                 sheet: "Export", timeout: 60))
        let confirm = CADSheetProbe.any(app, "CADExchangeConfirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 20))
        XCTAssertTrue(CADSheetProbe.waitForLabelEquals(confirm, "Export Included"),
                      "a mixed STEP receipt must ask for explicit partial consent")
        CADSheetProbe.attach("E26 STEP refuses exact surface and mesh", to: self)

        // IGES part scope: the exact surface joins the solid, the mesh-only
        // body stays excluded, and assembly scope is not offered.
        selectIGES(in: app)
        revealObjects(in: app)
        XCTAssertTrue(waitForObjects("2 / 3", in: app),
                      "IGES must include the closed solid and the exact open surface")
        XCTAssertTrue(CADSheetProbe.waitForAbsence(stepSurfaceReason, timeout: 30),
                      "IGES must not keep the STEP surface refusal")
        // Scope is part-only for IGES: the native picker must not offer the
        // assembly plan the core refuses.
        let scope = CADSheetProbe.any(app, "CADExchangeScope")
        XCTAssertTrue(scope.waitForExistence(timeout: 20))
        CADSheetProbe.reveal(scope, in: app, sheet: "Export")
        scope.tap()
        let partByButton = app.buttons["Part / parts only"].firstMatch
        let partByMenu = app.menuItems["Part / parts only"].firstMatch
        let assemblyOffered = {
            app.buttons["Assembly (placed instances)"].exists
                || app.menuItems["Assembly (placed instances)"].exists
        }
        if partByButton.waitForExistence(timeout: 15) {
            XCTAssertFalse(assemblyOffered(), "IGES exchange here is part-scope only")
            partByButton.tap()
        } else {
            XCTAssertTrue(partByMenu.waitForExistence(timeout: 15))
            XCTAssertFalse(assemblyOffered(), "IGES exchange here is part-scope only")
            partByMenu.tap()
        }
        XCTAssertTrue(CADSheetProbe.waitForLabelEquals(confirm, "Export Included"))
        XCTAssertTrue(CADSheetProbe.waitForEnabled(confirm, timeout: 30))
        XCTAssertFalse(app.navigationBars["Save"].exists,
                       "reviewing the receipt must not stage an export")
        let meshReason = app.staticTexts["Mesh-only; IGES export needs an exact solid or surface."]
        XCTAssertTrue(CADSheetProbe.scrollReveal(meshReason, in: app,
                                                 sheet: "Export", timeout: 60),
                      "IGES must name the mesh-only exclusion reason")
        XCTAssertTrue(CADSheetProbe.scrollReveal(app.staticTexts["MeshOnly.obj"], in: app,
                                                 sheet: "Export", timeout: 60),
                      "the excluded mesh body must be named")
        CADSheetProbe.attach("E26 IGES part-scope mixed receipt before consent", to: self)

        // Sheet Cancel writes nothing: the saved surface identity, mesh row
        // and undo/redo affordances are exactly as recorded.
        app.navigationBars["Export"].buttons["Cancel"].tap()
        XCTAssertTrue(CADSheetProbe.waitForAbsence(app.navigationBars["Export"], timeout: 30))
        XCTAssertFalse(app.navigationBars["Save"].exists)
        XCTAssertEqual(app.buttons["UndoButton"].isEnabled, undoBefore)
        XCTAssertEqual(app.buttons["RedoButton"].isEnabled, redoBefore)
        openItems(app)
        let surfaceAfter = itemRow(containing: source.digest, in: app)
        XCTAssertTrue(surfaceAfter.waitForExistence(timeout: 30),
                      "cancelling export review must leave the exact surface body untouched")
        XCTAssertEqual(surfaceAfter.identifier, surfaceIdentifier)
        XCTAssertTrue(itemRow(containing: "MeshOnly.obj", in: app).exists)
        closeItems(app)

        // The explicit consent action must reach the production accepted-partial
        // IGES writer: the sheet dismisses only after real bytes are produced.
        openExchangeSheet(app)
        selectIGES(in: app)
        XCTAssertTrue(waitForObjects("2 / 3", in: app))
        let confirmAgain = CADSheetProbe.any(app, "CADExchangeConfirm")
        XCTAssertTrue(confirmAgain.waitForExistence(timeout: 20))
        XCTAssertTrue(CADSheetProbe.waitForLabelEquals(confirmAgain, "Export Included"))
        XCTAssertTrue(CADSheetProbe.waitForEnabled(confirmAgain, timeout: 30))
        confirmAgain.tap()
        XCTAssertTrue(CADSheetProbe.waitForAbsence(app.navigationBars["Export"], timeout: 90),
                      "Export Included must dismiss only after nativePartExport accepted the partial IGES selection")
        // The system save picker is the remaining OS step; when the host
        // presents it, cancel it so this run writes no file.
        let saveBar = app.navigationBars["Save"]
        if saveBar.waitForExistence(timeout: 20) {
            saveBar.buttons["Cancel"].tap()
            XCTAssertTrue(CADSheetProbe.waitForAbsence(saveBar, timeout: 30))
        }
    }

    // MARK: - Fixture/UI helpers

    private func openExchangeSheet(_ app: XCUIApplication) {
        XCTAssertTrue(CADSheetProbe.openToolbarAction("ExportMenu", label: "Export", in: app),
                      "the workbench toolbar must expose the real Export menu")
        // Wait for the menu content instead of sampling `.exists` while the
        // system menu is still animating; identifier first, shipped label next.
        let byIdentifier = app.buttons["ExportExchange"].firstMatch
        if byIdentifier.waitForExistence(timeout: 10) {
            byIdentifier.tap()
        } else {
            let byLabel = app.buttons["Export Model…"].firstMatch
            XCTAssertTrue(byLabel.waitForExistence(timeout: 15),
                          "the Export menu must offer the real part/assembly exchange sheet")
            byLabel.tap()
        }
        XCTAssertTrue(app.navigationBars["Export"].waitForExistence(timeout: 30),
                      "the shipped exchange Form must present")
        CADSheetProbe.expandSheet("Export", in: app)
    }

    private func revealObjects(in app: XCUIApplication) {
        let row = CADSheetProbe.labeledRow("Objects", in: app)
        if row.exists {
            CADSheetProbe.reveal(row, in: app, sheet: "Export")
        }
    }

    private func selectIGES(in app: XCUIApplication) {
        let format = CADSheetProbe.any(app, "CADExchangeFormat")
        XCTAssertTrue(format.waitForExistence(timeout: 20))
        // The picker sits at the top of the Form; reveal it even if the STEP
        // receipt walk left the Form scrolled to the excluded rows.
        CADSheetProbe.reveal(format, in: app, sheet: "Export")
        format.tap()
        let byButton = app.buttons["IGES (exact solids + surfaces)"].firstMatch
        if byButton.waitForExistence(timeout: 20) {
            byButton.tap()
            return
        }
        let byMenu = app.menuItems["IGES (exact solids + surfaces)"].firstMatch
        XCTAssertTrue(byMenu.waitForExistence(timeout: 20),
                      "the native format picker must offer IGES")
        byMenu.tap()
    }

    private func openItems(_ app: XCUIApplication) {
        toggleItems(app)
        XCTAssertTrue(CADSheetProbe.any(app, "ItemsPanel").waitForExistence(timeout: 30),
                      "the real Items panel must open")
    }

    private func closeItems(_ app: XCUIApplication) {
        toggleItems(app)
        XCTAssertTrue(CADSheetProbe.waitForAbsence(CADSheetProbe.any(app, "ItemsPanel"),
                                                   timeout: 20))
    }

    /// Items lives in the workbench toolbar; the host preview adds its own
    /// toolbar group, so use the system overflow when the bar is full (same
    /// native route as `CADSheetProbe.openToolbarAction`).
    private func toggleItems(_ app: XCUIApplication) {
        let direct = app.buttons["ItemsButton"].firstMatch
        if direct.waitForExistence(timeout: 60) && direct.isHittable {
            direct.tap()
            return
        }
        XCTAssertTrue(CADSheetProbe.openToolbarAction("ItemsButton", label: "Items", in: app),
                      "the workbench must expose the real Items toggle")
    }

    private func itemRow(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@",
                        "ItemRow-", text)
        ).firstMatch
    }

    private func itemRowPrefix(_ prefix: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        ).firstMatch
    }

    /// Poll the live `Objects` LabeledContent row. The row is one semantic
    /// element whose text can be published as label and/or value.
    private func waitForObjects(_ expected: String, in app: XCUIApplication,
                                timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let row = CADSheetProbe.labeledRow("Objects", in: app)
            if row.exists && CADSheetProbe.labeledText(row).contains(expected) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    /// The fixture names its IGES source `OpenSurface-<sha256 prefix 12>.igs`;
    /// the production banner displays that exact file name and the applied
    /// body keeps it, so both ends are tied to the same content digest.
    private func sourceIdentity(in text: String) -> (name: String, digest: String)? {
        guard let range = text.range(of: #"OpenSurface-[0-9a-fA-F]{12}\.igs"#,
                                     options: .regularExpression) else { return nil }
        let name = String(text[range])
        let digest = name
            .replacingOccurrences(of: "OpenSurface-", with: "")
            .replacingOccurrences(of: ".igs", with: "")
        guard digest.count == 12 else { return nil }
        return (name, digest)
    }

    // MARK: - Import banner diagnostics

    private enum ImportBannerState {
        case ready
        /// The DEBUG harness reported its own preparation error. The exact
        /// message travels with the failure so the next run diagnoses the
        /// launch instead of waiting out the control timeout.
        case fixtureFailed(String)
        case timedOut
    }

    /// Wait for the shipped Apply control while distinguishing "the fixture
    /// never prepared" from "the shipped banner is not addressable". This does
    /// not relax the contract or convert a failure into a pass.
    private func waitForImportBanner(_ apply: XCUIElement, in app: XCUIApplication,
                                     timeout: TimeInterval) -> ImportBannerState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if apply.exists { return .ready }
            if let detail = fixtureFailure(in: app) { return .fixtureFailed(detail) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return apply.exists ? .ready : .timedOut
    }

    /// The DEBUG harness presents `CAD fixture failed` plus the exact error
    /// when `CADIGESSurfaceUIFixture.prepare` throws. Read those two shipped
    /// labels (they are stable and already asserted elsewhere) rather than
    /// inventing a test-only failure channel.
    private func fixtureFailure(in app: XCUIApplication) -> String? {
        let heading = "CAD fixture failed"
        guard app.staticTexts[heading].exists else { return nil }
        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label)
        guard let index = labels.firstIndex(of: heading) else { return heading }
        return labels.dropFirst(index + 1).first { $0 != heading } ?? heading
    }

    /// Appended to a timed-out Apply wait so the run states which real
    /// boundary failed: the fixture never reached the preview, or the shipped
    /// banner exists but its children answer only to the container identifier
    /// (the accessibility-identifier shadowing regression).
    private func bannerDiagnosis(in app: XCUIApplication) -> String {
        var parts: [String] = []
        if app.staticTexts["Preparing CAD fixture…"].exists {
            parts.append("the fixture was still preparing")
        }
        if app.buttons["cad.native.proposalBanner"].exists {
            parts.append("the shipped proposal banner is present but its controls answer only "
                + "to cad.native.proposalBanner instead of their own identifiers")
        }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: "; ")))"
    }
}

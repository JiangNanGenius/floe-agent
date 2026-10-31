// SPDX-License-Identifier: MPL-2.0
// FloeAgentUITests — native scene control qualification.
//
// This is the one bounded native-UI expectation for VIEW-GLTF-SCENES: open the
// REAL product attachment preview over an owned glTF scene (two scenes, four
// clips, instances, texture, source camera) and drive the REAL native control
// bar. The readiness probe reports the live page's typed scene state, so a
// static first frame, a title-only navigation or a Quick Look window cannot
// satisfy the assertions.
//
// The App-host `EngineeringSceneResourceWitnessTests` owns the deeper render /
// decoder / resource-association witnesses. This file only proves the native
// controls are reachable and actually change the live WebGL scene state; Root
// owns the actual Simulator run and visual judgment.
//
// Fixture: `Tests/Fixtures/EngineeringScene/scene-hierarchy.glb` (Floe-owned,
// MPL-2.0; see SOURCES.md). No production code is mocked and no file is
// rewritten by the App.

#if canImport(XCTest)
import XCTest
import CryptoKit
import Foundation

@MainActor
final class EngineeringPreviewSceneControlUITests: XCTestCase {
    private var attachmentID = ""
    private let assetEnvironmentKey = "FLOE_ENGINEERING_ENTRY_GLB_B64"
    private let assetSHAEnvironmentKey = "FLOE_ENGINEERING_ENTRY_GLB_SHA256"
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let app { app.terminate() }
        app = nil
    }

    func testSceneControlsDriveRealPlaybackClipSceneAndFit() throws {
        let bytes = try fixtureBytes()
        let digest = sha256(bytes)
        let identityBytes = Array(SHA256.hash(data: Data(
            "floe-engineering-entry|\(digest)|3".utf8)))
        attachmentID = UUID(uuid: (
            identityBytes[0], identityBytes[1], identityBytes[2], identityBytes[3],
            identityBytes[4], identityBytes[5], identityBytes[6], identityBytes[7],
            identityBytes[8], identityBytes[9], identityBytes[10], identityBytes[11],
            identityBytes[12], identityBytes[13], identityBytes[14], identityBytes[15])).uuidString
        guard let packedNS = try? (bytes as NSData).compressed(using: .zlib) else {
            XCTFail("the owned scene fixture could not be compressed for the launch environment")
            return
        }
        let packed = packedNS as Data
        let app = launch(packedBase64: packed.base64EncodedString(), digest: digest)

        let chip = app.buttons["thread.attachment.\(attachmentID)"]
        for _ in 0..<3 where !chip.exists { app.swipeDown() }
        XCTAssertTrue(chip.waitForExistence(timeout: 90),
                      "the real chat attachment chip must be reachable")
        chip.tap()

        let preview = app.descendants(matching: .any)["file.preview.engineering"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 120),
                      "the shared engineering preview must be mounted")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 60),
                      "the preview must contain its real WKWebView")
        let readiness = app.descendants(matching: .any)["engineering.scene.readiness"].firstMatch
        XCTAssertTrue(readiness.waitForExistence(timeout: 60),
                      "the live scene state probe must be mounted")
        try waitFor(readiness, containing: [
            "ready=true", "source=\(digest)", "scenes=2", "clips=4",
            "meshes=3", "instanced=1", "textures=1",
        ], timeout: 120)
        XCTAssertTrue(app.descendants(matching: .any)["engineering.scene.controls"]
            .firstMatch.waitForExistence(timeout: 30),
                      "the native scene control bar must be mounted")

        let playPause = app.buttons["engineering.scene.playPause"].firstMatch
        XCTAssertTrue(playPause.waitForExistence(timeout: 20))
        let clipMenu = app.buttons["engineering.scene.clip"].firstMatch
        let sceneMenu = app.buttons["engineering.scene.selection"].firstMatch
        XCTAssertTrue(clipMenu.waitForExistence(timeout: 20),
                      "the real clip menu must be available")
        XCTAssertTrue(sceneMenu.waitForExistence(timeout: 20),
                      "the real scene menu must be available for a two-scene asset")
        for identifier in ["engineering.scene.speed", "engineering.scene.loop",
                           "engineering.scene.camera", "engineering.scene.fit"] {
            XCTAssertTrue(app.buttons[identifier].firstMatch.waitForExistence(timeout: 20),
                          "\(identifier) must be present for the live scene")
        }
        attachScreenshot("scene-controls-initial")

        // Play/pause must change the LIVE page's playing flag.
        playPause.tap()
        try waitFor(readiness, containing: ["playing=false"], timeout: 20)
        attachScreenshot("scene-controls-paused")

        // Clip selection must change the active clip in the live mixer.
        clipMenu.tap()
        let scaleStep = menuItem(app, label: "ScaleStep")
        XCTAssertTrue(scaleStep.waitForExistence(timeout: 20),
                      "the real clip menu must list the ScaleStep clip")
        scaleStep.tap()
        try waitFor(readiness, containing: ["clip=1"], timeout: 30)
        attachScreenshot("scene-controls-clip")

        // Scene selection must move to the second actual glTF scene.
        sceneMenu.tap()
        let alternative = menuItem(app, label: "Alternative")
        XCTAssertTrue(alternative.waitForExistence(timeout: 20),
                      "the real scene menu must list the Alternative scene")
        alternative.tap()
        try waitFor(readiness, containing: ["scene=1", "meshes=1"], timeout: 45)
        attachScreenshot("scene-controls-scene-1")

        // Fit stays a real command on the live scene.
        app.buttons["engineering.scene.fit"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["engineering.scene.controls"]
            .firstMatch.exists, "the control bar must remain available")
    }

    // MARK: - Helpers

    private func fixtureBytes() throws -> Data {
        guard let root = Bundle(for: SceneControlFixtureAnchor.self).url(
            forResource: "EngineeringScene", withExtension: nil),
              let data = try? Data(contentsOf:
                root.appendingPathComponent("scene-hierarchy.glb")),
              !data.isEmpty else {
            XCTFail("the owned EngineeringScene fixture is not in the UI test bundle")
            throw WaitFailure.timedOut
        }
        return data
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func launch(packedBase64: String, digest: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-ui-testing",
            "-ui-testing-ipad",
            "--ui-test-engineering-entry-fixture",
            "--ui-test-engineering-entry-route=attachment",
        ]
        app.launchEnvironment[assetEnvironmentKey] = packedBase64
        app.launchEnvironment[assetSHAEnvironmentKey] = digest
        app.launchEnvironment["FLOE_ENGINEERING_ENTRY_ISOLATE_ASSET"] = "1"
        app.launch()
        self.app = app
        let fixture = app.descendants(matching: .any)["engineeringEntryFixture"].firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 60),
                      "the engineering entry fixture must launch")
        let prepared = NSPredicate { object, _ in
            guard let element = object as? XCUIElement,
                  let value = element.value as? String else { return false }
            return value == "ready" || value == "failed"
        }
        let expectation = XCTNSPredicateExpectation(predicate: prepared, object: fixture)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 60), .completed,
                       "fixture preparation must finish")
        if (fixture.value as? String) == "failed" {
            let failure = app.descendants(matching: .any)["engineeringEntryFixture.error"]
                .firstMatch
            XCTFail("engineering entry fixture failed: \(failure.exists ? failure.label : app.debugDescription)")
        }
        return app
    }

    /// SwiftUI Menu items surface as buttons; keep a static-text fallback for
    /// iOS accessibility-tree changes rather than weakening the assertion.
    private func menuItem(_ app: XCUIApplication, label: String) -> XCUIElement {
        let button = app.buttons[label].firstMatch
        if button.waitForExistence(timeout: 2) { return button }
        return app.staticTexts[label].firstMatch
    }

    private func waitFor(_ element: XCUIElement, containing fragments: [String],
                         timeout: TimeInterval,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement,
                  let value = element.value as? String else { return false }
            return fragments.allSatisfy(value.contains)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed,
                       "scene state did not reach \(fragments); value=\(String(describing: element.value))",
                       file: file, line: line)
        if result != .completed { throw WaitFailure.timedOut }
    }

    private enum WaitFailure: Error { case timedOut }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
/// Anchors `Bundle(for:)` to the UI test bundle that carries the fixture.
private final class SceneControlFixtureAnchor: NSObject {}
#endif

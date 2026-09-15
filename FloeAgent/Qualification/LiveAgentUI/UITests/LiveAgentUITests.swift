import XCTest
import UIKit

/// Drives the separately installed, immutable Floe App. The tiny harness is
/// only an XCTest runner; it never supplies a model response or a tool result.
@MainActor final class LiveAgentUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "org.floeagent.ios")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.terminate()
        XCUIDevice.shared.orientation = .landscapeLeft
    }
    override func tearDownWithError() throws {
        UIPasteboard.general.items = []
        app.terminate()
    }

    /// Run before recording. A runner environment variable goes directly to a
    /// local pasteboard, then the App's SecureField and existing Keychain store.
    /// Never typeText(key): XCTest activity logs can include typed characters.
    func testConfigureAuthorizedCredential() throws {
        guard let key = ProcessInfo.processInfo.environment["FLOE_LIVE_AGENT_KEY"],
              key.count >= 16 else { throw NSError(domain: "Missing authorized credential", code: 1) }
        UIPasteboard.general.setItems([["public.utf8-plain-text": key]], options: [
            .localOnly: true, .expirationDate: Date().addingTimeInterval(180)
        ])
        app.launch()
        let settings = app.buttons["sidebar.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 45)); settings.tap()
        let providers = app.descendants(matching: .any).matching(identifier: "settings.section.providers").firstMatch
        XCTAssertTrue(providers.waitForExistence(timeout: 10)); providers.tap()
        let provider = app.buttons.containing(.staticText, identifier: "Volcengine Ark Demo").firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 15)); provider.tap()
        let sync = app.switches.matching(NSPredicate(format:
            "label == 'Sync via iCloud Keychain' OR label == '通过 iCloud 钥匙串同步'")).firstMatch
        for _ in 0..<4 where !sync.isHittable { app.swipeUp() }
        XCTAssertTrue(sync.isHittable)
        if sync.value as? String == "1" {
            // SwiftUI exposes the full form row as a Switch. Its midpoint can
            // hit the label rather than the thumb on iPad; target the control.
            sync.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        }
        let syncOff = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: sync)
        XCTAssertEqual(XCTWaiter.wait(for: [syncOff], timeout: 5), .completed)
        let field = app.secureTextFields["providers.api_key"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        for _ in 0..<4 where !field.isHittable { app.swipeDown() }
        XCTAssertTrue(field.isHittable)
        let emptyValue = field.value as? String
        field.tap()
        field.press(forDuration: 1.1)
        let paste = app.buttons.matching(NSPredicate(format:
            "(label == 'Paste' OR label == '粘贴') AND identifier != 'assistantPaste:forEvent:'")).firstMatch
        let menuPaste = app.menuItems.matching(NSPredicate(format: "label == 'Paste' OR label == '粘贴'")).firstMatch
        if menuPaste.waitForExistence(timeout: 2) { menuPaste.tap() }
        else {
            if !paste.waitForExistence(timeout: 3) {
                print(app.debugDescription.replacingOccurrences(of: key, with: "[redacted]"))
            }
            XCTAssertTrue(paste.exists); paste.tap()
        }
        let allowPaste = app.buttons.matching(NSPredicate(format: "label == 'Allow Paste' OR label == '允许粘贴'")).firstMatch
        if allowPaste.waitForExistence(timeout: 2) { allowPaste.tap() }
        // Assert presence only, without interpolating any field value into logs.
        let filled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (field.value as? String)?.count == key.count && field.value as? String != emptyValue
        }, object: field)
        let fillResult = XCTWaiter.wait(for: [filled], timeout: 5)
        if fillResult != .completed {
            print(app.debugDescription.replacingOccurrences(of: key, with: "[redacted]"))
        }
        XCTAssertEqual(fillResult, .completed)
        app.buttons["action.save"].tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 20), .completed)
        XCTAssertTrue(provider.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !provider.label.contains("Waiting for secret") && !provider.label.contains("等待密钥")
        }, object: provider)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }

    func testLiveMarkdownCreationAndReadback() throws {
        app.launch()
        let input = app.textFields["composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 45))
        capture("live-agent-ready")
        input.tap()
        input.typeText("Please create review-demo.md in this task workspace using workspace.createFile, then use workspace.readFile to read it back. Write a short bilingual Markdown note titled 'Floe Agent Demo' with three checklist items about reading, writing and verifying files. Include the exact marker FLOE-LIVE-173. Only these two file operations are needed; do not browse, install packages, generate images or videos, or call another model. After the readback, briefly confirm the saved file in Chinese and English.")
        app.buttons["composer.send"].tap()
        capture("live-agent-request-sent")
        let completed = app.descendants(matching: .any).matching(identifier: "thread.run_state.completed").firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 240))
        capture("live-agent-completed")
        let file = app.buttons.matching(NSPredicate(format: "label CONTAINS 'review-demo.md'")).firstMatch
        if file.exists && file.isHittable { file.tap(); capture("live-agent-output-preview") }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

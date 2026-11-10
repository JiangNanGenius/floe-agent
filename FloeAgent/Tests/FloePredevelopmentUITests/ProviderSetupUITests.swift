// SPDX-License-Identifier: MPL-2.0
import XCTest
@MainActor final class ProviderSetupUITests:XCTestCase {
    private let app=XCUIApplication(bundleIdentifier:"org.floeagent.ios")
    override func setUpWithError() throws {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments=["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN","-ui-testing","-ui-testing-ipad","--ui-test-skip-onboarding"];app.launch()
    }
    override func tearDownWithError() throws { app.terminate();XCUIDevice.shared.orientation = .portrait }
    override func record(_ issue:XCTIssue) {
        // XCTest calls this synchronous override outside the test actor.
        // Use its direct screenshot attachment API, as in NativeWorkflowsUITests.
        let attachment=XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        attachment.name="Provider setup issue";attachment.lifetime = .keepAlways
        add(attachment);super.record(issue)
    }
    private func capture(_ name:String) { let a=XCTAttachment(screenshot:XCUIScreen.main.screenshot());a.name=name;a.lifetime = .keepAlways;add(a) }
    private func replace(_ field:XCUIElement,with text:String) {
        XCTAssertTrue(field.waitForExistence(timeout:10))
        let original=field.value as? String ?? ""
        let count=original == field.placeholderValue ? 0 : original.count
        field.coordinate(withNormalizedOffset:.init(dx:0.95,dy:0.5)).tap()
        // Clearing the pre-filled endpoint and entering a replacement are
        // separate real keyboard edits. Confirm UIKit consumed the deletion
        // before asking XCTest to type the complete new endpoint in one burst.
        // There is no input retry, clipboard, binding write or character throttle:
        // a dropped character still fails the original full-value assertion.
        if count > 0 {
            field.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:count))
            let empty=XCTNSPredicateExpectation(predicate:NSPredicate { _, _ in
                let value=field.value as? String ?? ""
                return value.isEmpty || value == field.placeholderValue
            },object:nil)
            XCTAssertEqual(XCTWaiter.wait(for:[empty],timeout:5),.completed,
                "Native keyboard must finish clearing the endpoint before replacement")
        }
        field.typeText(text)
        XCTAssertTrue(waitForValue(text, in:field), "The complete endpoint must arrive through native keyboard input")
        XCTAssertEqual(field.value as? String,text)
    }
    private func waitForValue(_ expected:String,in field:XCUIElement) -> Bool {
        let value=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@",expected),object:field)
        return XCTWaiter.wait(for:[value],timeout:5) == .completed
    }
    func testInvalidEndpointShowsItsInlineCorrectionAndCancelDoesNotSave() {
        let settings=app.buttons["sidebar.settings"];XCTAssertTrue(settings.waitForExistence(timeout:25));settings.tap()
        let providers=app.descendants(matching:.any)["settings.section.providers"].firstMatch
        XCTAssertTrue(providers.waitForExistence(timeout:15));providers.tap()
        // Existing pending catalog review may appear; defer it without
        // acknowledging or applying any user's saved provider configuration.
        if app.alerts.firstMatch.waitForExistence(timeout:2) {
            let cancel=app.alerts.firstMatch.buttons.matching(NSPredicate(format:"label != %@","查看更新")).firstMatch
            XCTAssertTrue(cancel.exists);cancel.tap()
        }
        let add=app.buttons["providers.add"];XCTAssertTrue(add.waitForExistence(timeout:15));add.tap()
        let chat=app.buttons["providers.add.conversation"].firstMatch;XCTAssertTrue(chat.waitForExistence(timeout:10));chat.tap()
        let url=app.textFields["providers.base_url"]
        replace(url,with:"http://")
        app.buttons["action.save"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout:10))
        capture("Provider rejected save has an actionable message")
        app.alerts.firstMatch.buttons.firstMatch.tap()
        let warning="请输入有效的接口地址，例如 https://api.example.com/v1"
        let issue=app.descendants(matching:.any).matching(NSPredicate(format:"label == %@",warning)).firstMatch
        XCTAssertTrue(issue.waitForExistence(timeout:10))
        XCTAssertTrue(issue.isHittable,"The actual endpoint correction must be visible after dismissing the alert")
        XCTAssertGreaterThan(issue.frame.height,0);XCTAssertLessThanOrEqual(issue.frame.height,80)
        XCTAssertGreaterThanOrEqual(issue.frame.minY,url.frame.maxY-2)
        XCTAssertLessThanOrEqual(issue.frame.maxY,url.frame.maxY+100,"The warning must be directly under its endpoint field")
        capture("Endpoint finding is shown under the actual field")
        replace(url,with:"https://example.invalid/v1")
        XCTAssertTrue(issue.waitForNonExistence(timeout:5),"Correcting the actual endpoint must remove its old warning")
        let cancel=app.buttons["action.cancel"];XCTAssertTrue(cancel.exists);cancel.tap()
        XCTAssertTrue(add.waitForExistence(timeout:10))
        capture("Cancel returns to the original provider list without saving")
    }
}

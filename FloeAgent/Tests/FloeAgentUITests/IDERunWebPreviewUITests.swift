// SPDX-License-Identifier: MPL-2.0
//
// Native acceptance for the IDE web-service terminal's browser shortcut.
//
// The DEBUG fixture presents the REAL `IDEServiceRunTerminalView`,
// `IDERunTerminalView` and `BrowserView` over an in-memory fake
// `exec.localService` job. The page is served by a native HTTP listener owned
// by this test process on loopback. No Linux service, durable job, database
// row, user workspace, provider or microphone is touched; this is UI evidence,
// not proof of actual guest-service execution.
//
// Asserts:
//   * the Browser action lives in the web-service terminal's top-right and is
//     enabled only for a ready endpoint;
//   * it opens the exact selected page (address + rendered marker) through the
//     existing in-app browser;
//   * closing the browser preview never stops the service, while Stop disables
//     the action;
//   * an ordinary run terminal has no browser action at all.

#if canImport(UIKit)
import XCTest
import Network
import UIKit

@MainActor
final class IDERunWebPreviewUITests: XCTestCase {
    private let markerToken = String(UUID().uuidString.prefix(8))

    func testServiceTerminalBrowserShortcutAndOrdinaryTerminalHasNoAction() async throws {
        continueAfterFailure = false
        let server = try await PreviewServer.start(marker: marker)
        defer { server.stop() }
        let url = "http://127.0.0.1:\(server.port)/web-preview-\(markerToken).html"

        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-ui-testing",
            "--ui-test-ide-web-preview-fixture"
        ]
        app.launchEnvironment["FLOE_IDE_WEB_PREVIEW_FIXTURE_URL"] = url
        app.launch()
        defer { app.terminate() }

        let serviceEntry = app.buttons["fixture.serviceTerminal"]
        XCTAssertTrue(
            serviceEntry.waitForExistence(timeout: 30),
            "the native fixture must expose the real service terminal"
        )
        serviceEntry.tap()

        let browserAction = app.buttons["workspace.ide.service.terminal.browser"]
        XCTAssertTrue(
            browserAction.waitForExistence(timeout: 20),
            "the web-service terminal must expose its top-right browser action"
        )
        XCTAssertTrue(
            browserAction.isEnabled,
            "a verified running endpoint must enable the browser action"
        )
        XCTAssertGreaterThan(
            browserAction.frame.midX, app.windows.firstMatch.frame.midX,
            "the browser action must sit in the terminal's top-right"
        )
        capture("ide-service-terminal-ready")

        browserAction.tap()
        let address = app.textFields["browser.address"]
        XCTAssertTrue(
            address.waitForExistence(timeout: 20),
            "the existing in-app browser must be presented"
        )
        XCTAssertEqual(
            address.value as? String, url,
            "the browser action must open the exact current endpoint, including its page"
        )
        XCTAssertTrue(
            waitForWebMarker(app, marker: marker, timeout: 30),
            "the browser must render the current ready page's marker"
        )
        capture("ide-service-browser-page")

        let done = app.buttons["workspace.ide.service.preview.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()

        XCTAssertTrue(browserAction.waitForExistence(timeout: 10))
        XCTAssertTrue(
            browserAction.isEnabled,
            "closing the browser preview must not stop or stale the service"
        )

        // Closing the terminal is NOT a stop: reopening must show the same
        // live service and its enabled browser action.
        let close = app.buttons["workspace.ide.service.terminal.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(serviceEntry.waitForExistence(timeout: 10))
        serviceEntry.tap()
        XCTAssertTrue(browserAction.waitForExistence(timeout: 15))
        XCTAssertTrue(
            browserAction.isEnabled,
            "closing the service terminal must not stop the durable service"
        )
        capture("ide-service-terminal-reopened-after-close")

        let stop = app.buttons["workspace.ide.service.terminal.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()

        let stopped = expectation(
            for: NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "已停止", "stopped"),
            evaluatedWith: app.staticTexts["workspace.ide.service.terminal.status"]
        )
        await fulfillment(of: [stopped], timeout: 15)
        let disabled = expectation(
            for: NSPredicate(format: "enabled == false"), evaluatedWith: browserAction
        )
        await fulfillment(of: [disabled], timeout: 15)
        capture("ide-service-terminal-stopped")

        let closeAfterStop = app.buttons["workspace.ide.service.terminal.close"]
        XCTAssertTrue(closeAfterStop.waitForExistence(timeout: 10))
        closeAfterStop.tap()

        let ordinary = app.buttons["fixture.runTerminal"]
        XCTAssertTrue(ordinary.waitForExistence(timeout: 10))
        ordinary.tap()
        XCTAssertTrue(
            app.buttons["workspace.ide.run.terminal.close"].waitForExistence(timeout: 15),
            "the ordinary run terminal must be the presented surface"
        )
        XCTAssertTrue(app.buttons["workspace.ide.run.terminal.stop"].exists)
        XCTAssertFalse(
            app.buttons["workspace.ide.service.terminal.browser"].exists,
            "an ordinary run terminal must never expose the web-service browser action"
        )
        XCTAssertFalse(
            app.buttons["workspace.ide.run.terminal.browser"].exists,
            "no separate ordinary-terminal browser action may exist"
        )
        capture("ide-ordinary-run-terminal-no-browser")
    }

    private var marker: String { "FLOE-IDE-PREVIEW-\(markerToken)" }

    private func waitForWebMarker(
        _ app: XCUIApplication, marker: String, timeout: TimeInterval
    ) -> Bool {
        let label = NSPredicate(format: "label == %@", marker)
        let webMarker = app.webViews.staticTexts.matching(label).firstMatch
        let plainMarker = app.staticTexts.matching(label).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if webMarker.exists || plainMarker.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// One-loopback HTTP server for the fixture page. It is not a service manager:
/// it only answers requests so the existing in-app browser can prove it loaded
/// the selected page. No credentials, external hosts or app data are involved.
private final class PreviewServer: @unchecked Sendable {
    enum StartError: Error {
        case listenerDidNotBecomeReady
    }

    private let listener: NWListener
    private let queue: DispatchQueue
    let port: UInt16

    private init(listener: NWListener, queue: DispatchQueue, port: UInt16) {
        self.listener = listener
        self.queue = queue
        self.port = port
    }

    static func start(marker: String) async throws -> PreviewServer {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "floe.ide.web-preview.fixture")

        let body = "<!doctype html><html><head><meta charset=\"utf-8\">" +
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head>" +
            "<body><h1 id=\"marker\">\(marker)</h1></body></html>"
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        let headerData = Data(header.utf8)

        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                connection.send(
                    content: headerData + bodyData,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        }
        listener.start(queue: queue)

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let readyPort = listener.port?.rawValue {
                return PreviewServer(listener: listener, queue: queue, port: readyPort)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        listener.cancel()
        throw StartError.listenerDidNotBecomeReady
    }

    func stop() {
        listener.cancel()
    }
}
#endif

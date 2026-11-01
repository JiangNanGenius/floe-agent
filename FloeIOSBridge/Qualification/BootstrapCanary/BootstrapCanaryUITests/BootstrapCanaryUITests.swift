import XCTest
import UIKit

@MainActor
final class BootstrapCanaryUITests: XCTestCase {
    private let files = TestFiles()
    private var heartbeat: CanaryHeartbeat!
    private var processedIDs = Set<String>()
    private var lastInvalidSignature: String?
    private var stopRequested = false
    private var testBundlePath = "<missing>"
    private var testBundleIdentifier = "<missing>"
    private var containsUITests = false
    private var bundleIdentifierMatchesHost = false

    func testCanarySession() throws {
        continueAfterFailure = true
        executionTimeAllowance = 3600
        files.ensureDirectories()
        files.log("test_method_entered name=\(name) pid=\(ProcessInfo.processInfo.processIdentifier)")

        let environment = ProcessInfo.processInfo.environment
        if let environmentPath = environment["XCTestBundlePath"], !environmentPath.isEmpty {
            testBundlePath = environmentPath
        }
        let infoPath = testBundlePath + "/Info.plist"
        if let info = NSDictionary(contentsOfFile: infoPath) as? [String: Any] {
            testBundleIdentifier = info["CFBundleIdentifier"] as? String ?? "<missing>"
            containsUITests = (info["XCTContainsUITests"] as? NSNumber)?.boolValue ?? false
        }
        let hostBundleIdentifier = Bundle.main.bundleIdentifier ?? "<missing>"
        bundleIdentifierMatchesHost = testBundleIdentifier == hostBundleIdentifier

        let ready: [String: Any] = [
            "ready": true,
            "authoredBy": "XCTest test method",
            "testMethod": name,
            "testBundlePath": testBundlePath,
            "testBundleIdentifier": testBundleIdentifier,
            "hostBundleIdentifier": hostBundleIdentifier,
            "bundleIdentifierMatchesHost": bundleIdentifierMatchesHost,
            "XCTContainsUITests": containsUITests,
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "threadIsMain": Thread.isMainThread,
            "xctestCaseClassLoaded": NSClassFromString("XCTestCase") != nil,
            "xcuiApplicationClassLoaded": NSClassFromString("XCUIApplication") != nil,
            "readyAt": files.timestamp(),
        ]
        files.writeJSON(ready, to: files.readyURL)
        files.log(
            "engine_ready_marker_written bundleID=\(testBundleIdentifier) " +
            "hostBundleID=\(hostBundleIdentifier) matches=\(bundleIdentifierMatchesHost) " +
            "containsUITests=\(containsUITests)"
        )

        heartbeat = CanaryHeartbeat(files: files, testMethod: name)
        heartbeat.start()
        files.log("heartbeat_started interval=2.0s source=xctest-dispatch-timer")

        while !stopRequested {
            autoreleasepool {
                processCommandIfPresent()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
            }
        }

        heartbeat.stop()
        writeFinal(reason: "stop-command")
        files.log("test_method_exiting reason=stop-command")
    }

    private func processCommandIfPresent() {
        guard let command = files.readCommand() else { return }
        guard let identifier = command["id"] as? String, !identifier.isEmpty else {
            logInvalidOnce(reason: "missing-id", command: command)
            return
        }
        guard let action = command["action"] as? String, !action.isEmpty else {
            let result = baseResult(identifier: identifier, action: "<missing>").merging([
                "status": "invalid",
                "authoredBy": "xctest-test-method",
                "error": ["message": "command has no action"],
            ]) { _, new in new }
            writeResult(result, identifier: identifier)
            files.moveCommandToProcessed(identifier: identifier)
            return
        }
        guard !processedIDs.contains(identifier) else { return }
        processedIDs.insert(identifier)
        files.log("command_received id=\(identifier) action=\(action)")

        var result = baseResult(identifier: identifier, action: action)
        switch action {
        case "status":
            result["status"] = "ok"
            result["details"] = statusDetails()
        case "screenshot":
            result.merge(screenshotResult(identifier: identifier)) { _, new in new }
        case "open_settings":
            result.merge(openSettingsResult()) { _, new in new }
        case "tap_general":
            result.merge(tapGeneralResult()) { _, new in new }
        case "home":
            result.merge(homeResult()) { _, new in new }
        case "stop":
            stopRequested = true
            result["status"] = "ok"
            result["details"] = [
                "message": "engine will return from the test method and the XCTest driver will exit",
                "heartbeat": heartbeat.snapshot(),
            ]
        default:
            result["status"] = "unsupported"
            result["error"] = ["message": "unsupported action: \(action)"]
        }

        writeResult(result, identifier: identifier)
        files.moveCommandToProcessed(identifier: identifier)
    }

    private func baseResult(identifier: String, action: String) -> [String: Any] {
        return [
            "id": identifier,
            "action": action,
            "authoredBy": "xctest-test-method",
            "testMethod": name,
            "processedAt": files.timestamp(),
            "hostBundleIdentifier": Bundle.main.bundleIdentifier ?? "<missing>",
            "testBundleIdentifier": testBundleIdentifier,
            "testBundlePath": testBundlePath,
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "threadIsMain": Thread.isMainThread,
            "heartbeat": heartbeat.snapshot(),
        ]
    }

    private func writeResult(_ result: [String: Any], identifier: String) {
        let safeIdentifier = TestFiles.safeIdentifier(identifier)
        let resultURL = files.baseURL.appendingPathComponent("result-\(safeIdentifier).json")
        let written = files.writeJSON(result, to: resultURL)
        files.log(
            "command_result id=\(identifier) action=\(result["action"] ?? "?") " +
            "status=\(result["status"] ?? "?") written=\(written)"
        )
        if !written {
            files.log("command_result_not_moved id=\(identifier) reason=result-write-failed")
        }
    }

    private func statusDetails() -> [String: Any] {
        var details: [String: Any] = [
            "heartbeat": heartbeat.snapshot(),
            "readyMarker": files.readyURL.path,
            "testBundleIdentifier": testBundleIdentifier,
            "hostBundleIdentifier": Bundle.main.bundleIdentifier ?? "<missing>",
            "bundleIdentifierMatchesHost": bundleIdentifierMatchesHost,
            "XCTContainsUITests": containsUITests,
            "xcuiApplicationClassLoaded": NSClassFromString("XCUIApplication") != nil,
            "xcuiScreenClassLoaded": NSClassFromString("XCUIScreen") != nil,
            "xcuiDeviceClassLoaded": NSClassFromString("XCUIDevice") != nil,
        ]
        if Thread.isMainThread {
            details["applicationState"] = applicationStateName(UIApplication.shared.applicationState)
        } else {
            details["applicationState"] = "unavailable-on-background-thread"
        }
        return details
    }

    private func screenshotResult(identifier: String) -> [String: Any] {
        var screenshot: XCUIScreenshot?
        let stageErrors = NSMutableDictionary()
        if let error = capture(stage: "screenshot", into: stageErrors, body: {
            screenshot = XCUIScreen.main.screenshot()
        }) {
            return ["status": "error", "error": errorInfo(error), "details": ["stageErrors": stageErrors]]
        }
        guard let screenshot else {
            return ["status": "error", "error": ["message": "XCUIScreen.main.screenshot returned no screenshot"]]
        }
        let data = screenshot.pngRepresentation
        guard !data.isEmpty else {
            return ["status": "error", "error": ["message": "screenshot PNG representation was empty"]]
        }
        let safeIdentifier = TestFiles.safeIdentifier(identifier)
        let fileName = "screenshot-\(safeIdentifier).png"
        do {
            try files.writeData(data, to: files.baseURL.appendingPathComponent(fileName))
        } catch {
            return ["status": "error", "error": errorInfo(error as NSError)]
        }
        let image = screenshot.image
        return [
            "status": "ok",
            "screenshotFile": fileName,
            "screenshotBytes": data.count,
            "pixelWidth": Int(image.size.width * image.scale),
            "pixelHeight": Int(image.size.height * image.scale),
            "details": [
                "path": files.baseURL.appendingPathComponent(fileName).path,
                "stageErrors": stageErrors,
            ],
        ]
    }

    private func openSettingsResult() -> [String: Any] {
        let app = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let stageErrors = NSMutableDictionary()
        var foreground = false
        var launchUsed = false

        if let error = capture(stage: "activate", into: stageErrors, body: {
            app.activate()
        }) {
            return ["status": "error", "error": errorInfo(error), "details": ["stageErrors": stageErrors]]
        }
        _ = capture(stage: "wait-after-activate", into: stageErrors, body: {
            foreground = app.wait(for: .runningForeground, timeout: 15)
        })
        if !foreground {
            launchUsed = true
            _ = capture(stage: "launch", into: stageErrors, body: {
                app.launch()
            })
            _ = capture(stage: "wait-after-launch", into: stageErrors, body: {
                foreground = app.wait(for: .runningForeground, timeout: 15)
            })
        }

        var state = "unknown"
        _ = capture(stage: "read-state", into: stageErrors, body: {
            state = self.stateName(app.state)
        })
        let resultStatus = foreground ? "ok" : "error"
        var result: [String: Any] = [
            "status": resultStatus,
            "details": [
                "bundleIdentifier": "com.apple.Preferences",
                "foreground": foreground,
                "state": state,
                "launchUsed": launchUsed,
                "stageErrors": stageErrors,
            ],
        ]
        if !foreground {
            result["error"] = ["message": "Settings did not reach runningForeground"]
        }
        return result
    }

    private func tapGeneralResult() -> [String: Any] {
        let app = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let stageErrors = NSMutableDictionary()
        var currentState = "unknown"
        _ = capture(stage: "read-state", into: stageErrors, body: {
            currentState = self.stateName(app.state)
        })
        guard currentState == "runningForeground" else {
            return [
                "status": "not_foreground",
                "error": ["message": "Settings is not in the foreground; run open_settings first"],
                "details": ["state": currentState, "stageErrors": stageErrors],
            ]
        }

        var search = GeneralSearch()
        if let error = capture(stage: "find-general", into: stageErrors, body: {
            search = self.findGeneral(in: app)
        }) {
            return ["status": "error", "error": errorInfo(error), "details": ["stageErrors": stageErrors]]
        }

        if search.candidates.isEmpty {
            let alreadyOpen = capture(stage: "check-already-open", into: stageErrors, body: {
                search.alreadyOpen = app.staticTexts["About"].exists || app.staticTexts["关于本机"].exists
            }) == nil && search.alreadyOpen
            return [
                "status": "not_found",
                "error": ["message": "No unambiguous General/通用 element was found"],
                "details": [
                    "candidates": search.candidates,
                    "stageErrors": stageErrors,
                    "note": alreadyOpen
                        ? "The General pane already appears to be open; no blind tap was attempted."
                        : "Check the device language and visible Settings layout.",
                ],
            ]
        }

        if search.candidates.count > 1 || search.element == nil {
            return [
                "status": "ambiguous",
                "error": ["message": "More than one hittable General/通用 candidate was found; refusing to guess"],
                "details": [
                    "strategy": search.strategy ?? "<none>",
                    "candidates": search.candidates,
                    "stageErrors": stageErrors,
                ],
            ]
        }

        guard let element = search.element else {
            return [
                "status": "not_found",
                "error": ["message": "No tappable General/通用 element was found"],
                "details": ["candidates": search.candidates, "stageErrors": stageErrors],
            ]
        }

        if let error = capture(stage: "tap-general", into: stageErrors, body: {
            element.tap()
        }) {
            return [
                "status": "error",
                "error": errorInfo(error),
                "details": [
                    "strategy": search.strategy ?? "<none>",
                    "candidates": search.candidates,
                    "stageErrors": stageErrors,
                ],
            ]
        }

        var verified = false
        var destinationLabel: String?
        _ = capture(stage: "verify-destination", into: stageErrors, body: {
            let destinationLabels = ["About", "关于本机", "Software Update", "软件更新", "关于"]
            for label in destinationLabels {
                let candidate = app.staticTexts[label]
                if candidate.waitForExistence(timeout: 2) {
                    verified = true
                    destinationLabel = label
                    break
                }
            }
        })

        return [
            "status": "ok",
            "details": [
                "strategy": search.strategy ?? "<none>",
                "tappedElement": search.candidates.first ?? [:],
                "candidates": search.candidates,
                "destinationVerified": verified,
                "destinationLabel": destinationLabel ?? "",
                "stageErrors": stageErrors,
            ],
        ]
    }

    private func homeResult() -> [String: Any] {
        let stateBefore = applicationStateName(UIApplication.shared.applicationState)
        let stageErrors = NSMutableDictionary()
        let error = capture(stage: "press-home", into: stageErrors, body: {
            XCUIDevice.shared.press(.home)
        })
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
        let stateAfter = applicationStateName(UIApplication.shared.applicationState)
        var result: [String: Any] = [
            "status": error == nil ? "ok" : "error",
            "details": [
                "stateBefore": stateBefore,
                "stateAfter": stateAfter,
                "note": "Heartbeat file gaps while backgrounded distinguish scheduling from suspension.",
                "stageErrors": stageErrors,
            ],
        ]
        if let error {
            result["error"] = errorInfo(error)
        }
        return result
    }

    private struct GeneralSearch {
        var element: XCUIElement?
        var strategy: String?
        var candidates: [[String: Any]] = []
        var alreadyOpen = false
    }

    private func findGeneral(in app: XCUIApplication) -> GeneralSearch {
        let labels = ["General", "通用"]
        let predicate = NSPredicate(format: "label IN %@", labels)
        let strategies: [(String, XCUIElementQuery)] = [
            ("cell", app.cells),
            ("staticText", app.staticTexts),
            ("button", app.buttons),
            ("any", app.descendants(matching: .any)),
        ]

        var unhittable: [[String: Any]] = []
        for (name, query) in strategies {
            let matches = query.matching(predicate).allElementsBoundByIndex
            var hittableElements: [XCUIElement] = []
            var hittableInfos: [[String: Any]] = []
            for element in matches where element.exists {
                let info = elementInfo(element, strategy: name)
                if element.isHittable {
                    hittableElements.append(element)
                    hittableInfos.append(info)
                } else {
                    unhittable.append(info)
                }
            }
            let unique = deduplicate(hittableElements)
            if unique.count == 1 {
                var search = GeneralSearch()
                search.element = unique[0]
                search.strategy = name
                search.candidates = deduplicateInfos(hittableInfos)
                return search
            }
            if unique.count > 1 {
                var search = GeneralSearch()
                search.strategy = name
                search.candidates = deduplicateInfos(hittableInfos)
                return search
            }
        }

        var search = GeneralSearch()
        search.candidates = deduplicateInfos(unhittable)
        return search
    }

    private func frameString(_ frame: CGRect) -> String {
        return "\(frame.origin.x),\(frame.origin.y),\(frame.size.width),\(frame.size.height)"
    }

    private func elementInfo(_ element: XCUIElement, strategy: String) -> [String: Any] {
        return [
            "strategy": strategy,
            "elementType": String(describing: element.elementType),
            "label": element.label,
            "identifier": element.identifier,
            "enabled": element.isEnabled,
            "hittable": element.isHittable,
            "frame": frameString(element.frame),
        ]
    }

    private func deduplicate(_ elements: [XCUIElement]) -> [XCUIElement] {
        var seen = Set<String>()
        var output: [XCUIElement] = []
        for element in elements {
            let key = "\(element.label)|\(frameString(element.frame))"
            if seen.insert(key).inserted {
                output.append(element)
            }
        }
        return output
    }

    private func deduplicateInfos(_ infos: [[String: Any]]) -> [[String: Any]] {
        var seen = Set<String>()
        var output: [[String: Any]] = []
        for info in infos {
            let key = "\(info["label"] ?? "")|\(info["frame"] ?? "")"
            if seen.insert(key).inserted {
                output.append(info)
            }
        }
        return output
    }

    private func capture(stage: String, into errors: NSMutableDictionary, body: @escaping () -> Void) -> NSError? {
        var error: NSError?
        let completed = FBCatchException(body, &error)
        if !completed {
            let resolved = error ?? NSError(
                domain: "org.floeagent.iosbridge.canary",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "unknown Objective-C exception"]
            )
            errors[stage] = resolved.localizedDescription
            files.log("exception stage=\(stage) message=\(resolved.localizedDescription)")
            return resolved
        }
        return nil
    }

    private func errorInfo(_ error: NSError) -> [String: Any] {
        var info: [String: Any] = [
            "domain": error.domain,
            "code": error.code,
            "message": error.localizedDescription,
        ]
        if let exceptionName = error.userInfo["exceptionName"] {
            info["exceptionName"] = exceptionName
        }
        if let callStack = error.userInfo["callStack"] {
            info["callStack"] = callStack
        }
        return info
    }

    private func logInvalidOnce(reason: String, command: [String: Any]) {
        let signature = "\(reason)|\(command.count)|\(command.keys.sorted().joined(separator: ","))"
        guard signature != lastInvalidSignature else { return }
        lastInvalidSignature = signature
        files.log("command_invalid reason=\(reason) keys=\(command.keys.sorted())")
    }

    private func applicationStateName(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    private func stateName(_ state: XCUIApplication.State) -> String {
        switch state {
        case .unknown: return "unknown"
        case .notRunning: return "notRunning"
        case .runningBackgroundSuspended: return "runningBackgroundSuspended"
        case .runningBackground: return "runningBackground"
        case .runningForeground: return "runningForeground"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    private func writeFinal(reason: String) {
        let final: [String: Any] = [
            "finished": true,
            "finishedAt": files.timestamp(),
            "reason": reason,
            "testMethod": name,
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "heartbeat": heartbeat.snapshot(),
        ]
        files.writeJSON(final, to: files.finalURL)
    }
}

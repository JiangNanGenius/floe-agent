import XCTest

@MainActor private final class CreatedClockTimers {
    var ids: [String] = []
}

private struct NativeClockReadback {
    var remaining: Double
    var observedAt: Date
    var generation: UInt64
    var observation: UInt64
}

final class TimekeepingUITests: XCTestCase {
    @MainActor func testManageOwnAlarmAuthorization() async throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--alarm-settings-probe", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        let status = app.staticTexts["qualification.alarmProbe.authorization"]
        let openSettings = app.buttons["qualification.alarmProbe.openSettings"]
        guard await waitUntil(timeout: 15, { status.exists && openSettings.isHittable }) else {
            keep(app, "timekeeping-alarm-probe-not-loaded"); XCTFail("The read-only alarm settings probe did not load"); return
        }
        XCTAssertFalse(app.alerts.firstMatch.exists, "The settings probe must not request authorization")
        keep(app, "timekeeping-alarm-probe-before")
        openSettings.tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        guard await waitUntil(timeout: 15, { settings.state == .runningForeground }) else {
            keep(settings, "timekeeping-alarm-settings-not-opened"); XCTFail("Open App Settings did not reach Settings"); return
        }
        // Capture the actual page before inspecting or changing any permission.
        keep(settings, "timekeeping-alarm-settings-before")
        let managed = await enableOwnAlarmPermission(in: settings)
        app.activate()
        var authorized = false
        if managed { authorized = await waitUntil(timeout: 15, { status.exists && status.label == "authorized" }) }
        keep(app, "timekeeping-alarm-probe-after")
        if managed { XCTAssertTrue(authorized, "The raw AlarmManager state did not become authorized after the specific Alarms setting") }
    }

    @MainActor func testAlarmKitTimerStartPauseResumeAndRelaunch() async throws {
        try await withQualifiedApp { app, created in
            guard await self.waitUntil(timeout: 15, { app.buttons["toolbox.timer.add"].isEnabled }) else {
                XCTFail("The timer workbench did not load"); return
            }
            self.assertNoPermissionPrompt(app)
            guard let id = await self.addTimer("QA Native " + UUID().uuidString.prefix(6), ring: true, in: app) else { return }
            created.ids.append(id)
            guard let running = await self.requireNative(app, timerID: id, phase: "running") else { return }
            let reminder = self.reminderSwitch(id, in: app)
            XCTAssertEqual(reminder.value as? String, "1", "New timers must enable Ring by default")
            guard await self.requireCountdownDecrease(app, timerID: id) else { return }
            self.keep(app, "timekeeping-native-started")

            let toggle = app.buttons["toolbox.timer.toggle." + id]
            self.reveal(toggle, in: app); toggle.tap()
            guard let paused = await self.requireNative(app, timerID: id, phase: "paused", after: running) else { return }
            XCTAssertTrue(["继续", "Resume"].contains(toggle.label))
            XCTAssertEqual(reminder.value as? String, "1", "Pause must retain the same enabled system timer")
            let pausedReading = self.countdownSeconds(id, in: app)
            try await Task.sleep(for: .seconds(2))
            XCTAssertEqual(self.countdownSeconds(id, in: app), pausedReading, "A native paused countdown must stay still")
            self.keep(app, "timekeeping-native-paused")

            self.reveal(toggle, in: app); toggle.tap()
            guard let resumed = await self.requireNative(app, timerID: id, phase: "running", after: paused) else { return }
            XCTAssertTrue(["暂停", "Pause"].contains(toggle.label))
            XCTAssertLessThanOrEqual(resumed.remaining, paused.remaining + 2, "Resume must not restart the full duration")
            guard await self.requireCountdownDecrease(app, timerID: id) else { return }
            self.keep(app, "timekeeping-native-resumed")

            app.terminate()
            try await Task.sleep(for: .seconds(2))
            app.launch()
            guard let reopened = await self.requireNative(app, timerID: id, phase: "running") else { return }
            XCTAssertEqual(reopened.generation, resumed.generation, "Relaunch must restore this timer without another user action")
            XCTAssertLessThan(reopened.remaining, resumed.remaining, "The native countdown must continue while the app is absent")
            XCTAssertTrue(["暂停", "Pause"].contains(app.buttons["toolbox.timer.toggle." + id].label))
            guard await self.requireCountdownDecrease(app, timerID: id) else { return }
            self.keep(app, "timekeeping-native-reopened")
        }
    }

    @MainActor func testStopwatchLapsAndCountdownSurviveRelaunch() async throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        try await withQualifiedApp { app, created in
            let start = app.buttons["toolbox.timer.stopwatch.start"]
            guard await self.waitUntil(timeout: 15, { start.isEnabled && app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }) else {
                XCTFail("The landscape stopwatch did not load"); return
            }
            self.assertNoPermissionPrompt(app)
            app.buttons["toolbox.timer.stopwatch.reset"].tap()
            start.tap()
            app.buttons["toolbox.timer.stopwatch.lap"].tap()
            start.tap()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "toolbox.timer.laps").firstMatch.exists)

            guard let id = await self.addTimer("QA Silent A " + UUID().uuidString.prefix(6), ring: false, in: app) else { return }
            created.ids.append(id)
            guard let second = await self.addTimer("QA Silent B " + UUID().uuidString.prefix(6), ring: false, in: app) else { return }
            created.ids.append(second)
            let toggle = app.buttons["toolbox.timer.toggle." + id]
            self.reveal(toggle, in: app); toggle.tap()
            guard await self.waitUntil({ ["继续", "Resume"].contains(toggle.label) }) else {
                XCTFail("The silent timer did not pause"); return
            }
            let paused = self.countdownSeconds(id, in: app)
            XCTAssertNotNil(paused)
            let readings = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "toolbox.timer.remaining.")).allElementsBoundByIndex
            XCTAssertGreaterThanOrEqual(readings.count, 2)
            if readings.count >= 2 {
                self.reveal(readings[0], in: app)
                XCTAssertEqual(readings[0].frame.minY, readings[1].frame.minY, accuracy: 2)
            }
            self.keep(app, "timekeeping-tablet-landscape")
            try await Task.sleep(for: .seconds(1))
            app.terminate(); app.launch()
            self.reveal(app.buttons["toolbox.timer.toggle." + id], in: app)
            guard await self.waitUntil(timeout: 15, { app.buttons["toolbox.timer.toggle." + id].exists }) else {
                XCTFail("The saved silent timer did not reopen"); return
            }
            XCTAssertTrue(["继续", "Resume"].contains(app.buttons["toolbox.timer.toggle." + id].label))
            XCTAssertEqual(self.countdownSeconds(id, in: app), paused)
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "toolbox.timer.laps").firstMatch.exists)
            self.keep(app, "timekeeping-reopened")
        }
    }

    @MainActor func testCompactDarkLargeType() async throws {
        try await withQualifiedApp(extraArguments: ["--compact", "--dark", "--large-text"]) { app, created in
            guard await self.waitUntil(timeout: 15, { app.buttons["toolbox.timer.add"].isEnabled }) else {
                XCTFail("The compact workbench did not load"); return
            }
            self.assertNoPermissionPrompt(app)
            guard let id = await self.addTimer("QA Compact " + UUID().uuidString.prefix(6), ring: false, in: app) else { return }
            created.ids.append(id)
            let toggle = app.buttons["toolbox.timer.toggle." + id]
            let reading = app.descendants(matching: .any).matching(identifier: "toolbox.timer.remaining." + id).firstMatch
            self.reveal(toggle, in: app)
            XCTAssertTrue(toggle.isHittable)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(toggle.frame))
            XCTAssertTrue(reading.exists)
            XCTAssertLessThanOrEqual(reading.frame.width, 390)
            XCTAssertEqual(self.reminderSwitch(id, in: app).value as? String, "0")
            self.keep(app, "timekeeping-compact-dark-large-text")
        }
    }

    @MainActor private func withQualifiedApp(
        extraArguments: [String] = [],
        body: @MainActor (XCUIApplication, CreatedClockTimers) async throws -> Void
    ) async throws {
        let app = XCUIApplication()
        guard await clearOwnedAlarms(app) else { return }
        app.launchArguments = extraArguments + ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let created = CreatedClockTimers()
        do {
            try await body(app, created)
        } catch {
            keep(app, "timekeeping-unexpected-failure")
            await removeCreatedTimers(created.ids, in: app)
            _ = await clearOwnedAlarms(app)
            throw error
        }
        await removeCreatedTimers(created.ids, in: app)
        _ = await clearOwnedAlarms(app)
    }

    @MainActor private func addTimer(_ name: String, ring: Bool, in app: XCUIApplication) async -> String? {
        let add = app.buttons["toolbox.timer.add"]
        guard reveal(add, in: app) else { keep(app, "timekeeping-add-not-visible"); XCTFail("The Add button was not reachable"); return nil }
        add.tap()
        let field = app.textFields["toolbox.timer.name"]
        guard await waitUntil({ field.exists }), let form = timerEditorForm(in: app) else {
            keep(app, "timekeeping-editor-not-found"); XCTFail("The timer editor Form did not open"); return nil
        }
        // The workbench behind the sheet also contains Ring switches. Only query this Form.
        let choice = form.switches.matching(NSPredicate(format: "label IN %@", ["到时响铃", "Ring when finished"])).firstMatch
        guard reveal(choice, in: app, scrolling: form), let value = choice.value as? String, ["0", "1"].contains(value) else {
            keep(app, "timekeeping-editor-ring-not-found"); XCTFail("The timer editor must expose its own Ring choice"); return nil
        }
        if ring && value != "1" {
            keep(app, "timekeeping-editor-ring-default"); XCTFail("Ring must be enabled for a newly opened timer editor"); return nil
        }
        if !ring && value == "1" {
            let controls = choice.switches.allElementsBoundByIndex
            guard controls.count == 1, reveal(controls[0], in: app, scrolling: form), controls[0].isHittable else {
                keep(app, "timekeeping-editor-ring-control-not-found"); XCTFail("The Form Ring row must expose one hittable native switch"); return nil
            }
            keep(app, "timekeeping-editor-ring-before")
            controls[0].tap()
        }
        guard await waitUntil({ choice.value as? String == (ring ? "1" : "0") }) else {
            keep(app, "timekeeping-editor-ring-not-set"); XCTFail("The editor Ring choice did not reach the requested value"); return nil
        }
        if !ring && value == "1" { keep(app, "timekeeping-editor-ring-after") }
        guard reveal(field, in: app, scrolling: form) else {
            keep(app, "timekeeping-editor-name-not-visible"); XCTFail("The editor name field was not reachable"); return nil
        }
        field.tap()
        if let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(name)
        guard await waitUntil({ field.value as? String == name }) else {
            keep(app, "timekeeping-editor-name-not-entered"); XCTFail("The editor did not retain the exact timer name"); return nil
        }
        let confirm = app.buttons["toolbox.timer.confirmAdd"]
        guard confirm.isHittable && confirm.isEnabled else {
            keep(app, "timekeeping-editor-confirm-unavailable"); XCTFail("The timer editor could not confirm creation"); return nil
        }
        confirm.tap()
        if ring { allowAlarmAuthorizationIfPresent() }
        let prefix = "toolbox.timer.title."
        let title = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", prefix, name)).firstMatch
        // New cards are appended to a LazyVGrid; offscreen titles may not exist in AX yet.
        guard await waitUntil({ !field.exists }), reveal(title, in: app) else {
            keep(app, "timekeeping-created-timer-not-found"); XCTFail("The named timer was not found after creation and scrolling"); return nil
        }
        guard title.identifier.hasPrefix(prefix), UUID(uuidString: String(title.identifier.dropFirst(prefix.count))) != nil else {
            keep(app, "timekeeping-created-timer-id-missing")
            XCTFail("The timer title did not expose its real timer UUID"); return nil
        }
        return String(title.identifier.dropFirst(prefix.count))
    }

    @MainActor private func timerEditorForm(in app: XCUIApplication) -> XCUIElement? {
        // SwiftUI Form can expose a collection, table, or scroll view across SDKs.
        // Keep the resolved container index so scrolling its name row away does not lose it.
        for query in [app.collectionViews, app.tables, app.scrollViews] {
            if let form = query.allElementsBoundByIndex.first(where: { $0.textFields["toolbox.timer.name"].exists }) { return form }
        }
        return nil
    }

    @MainActor private func requireNative(
        _ app: XCUIApplication, timerID: String, phase: String, after previous: NativeClockReadback? = nil
    ) async -> NativeClockReadback? {
        let ready = await waitUntil(timeout: 20) {
            guard let value = self.nativeReadback(timerID, phase: phase, in: app) else { return false }
            return previous.map { value.generation > $0.generation && value.observation > $0.observation } ?? true
        }
        guard ready, let value = nativeReadback(timerID, phase: phase, in: app) else {
            let prefixes = ["phase", "remaining", "observedAt", "generation", "observation"]
            let details = prefixes.map { key in
                let element = app.staticTexts["qualification.native." + key + "." + timerID]
                return key + "=" + (element.exists ? element.label : "missing")
            }.joined(separator: " ")
            let evidence = XCTAttachment(string: details); evidence.name = "native-timer-readback-failure"; evidence.lifetime = .keepAlways; add(evidence)
            keep(app, "timekeeping-native-unverified")
            let warning = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["系统计时器尚未确认", "System timer not confirmed"]))
            let issue = app.descendants(matching: .any).matching(identifier: "toolbox.timer.issue").firstMatch
            XCTAssertTrue(warning.firstMatch.exists || issue.exists, "Unavailable native timing must remain a visible recoverable limitation")
            XCTFail("Native \(phase) with a real timeline was not confirmed: \(details). Local labels are not substitute evidence.")
            return nil
        }
        reveal(app.descendants(matching: .any).matching(identifier: "toolbox.timer.remaining." + timerID).firstMatch, in: app)
        let reading = countdownSeconds(timerID, in: app)
        XCTAssertNotNil(reading, "The app must display this native timer's countdown")
        // The bridge reports a native snapshot, not a ticking AX value. Account for
        // time since that exact observation while retaining the real timeline check.
        let elapsed = phase == "running" ? max(0, Date().timeIntervalSince(value.observedAt)) : 0
        if let reading { XCTAssertEqual(Double(reading), max(0, value.remaining - elapsed), accuracy: 3) }
        return value
    }

    @MainActor private func nativeReadback(_ id: String, phase: String, in app: XCUIApplication) -> NativeClockReadback? {
        let status = app.staticTexts["qualification.native.phase." + id]
        let amount = app.staticTexts["qualification.native.remaining." + id]
        let observedAt = app.staticTexts["qualification.native.observedAt." + id]
        let generation = app.staticTexts["qualification.native.generation." + id]
        let observation = app.staticTexts["qualification.native.observation." + id]
        guard status.exists, status.label == phase, amount.exists, observedAt.exists, generation.exists, observation.exists,
              let remaining = Double(amount.label), remaining.isFinite, remaining > 0,
              let timestamp = Double(observedAt.label), timestamp.isFinite,
              timestamp <= Date().timeIntervalSince1970 + 1,
              let sequence = UInt64(generation.label), let count = UInt64(observation.label), count > 0 else { return nil }
        return NativeClockReadback(remaining: remaining, observedAt: Date(timeIntervalSince1970: timestamp), generation: sequence, observation: count)
    }

    @MainActor private func requireCountdownDecrease(_ app: XCUIApplication, timerID: String) async -> Bool {
        guard let initial = countdownSeconds(timerID, in: app), initial > 0 else { XCTFail("The countdown is not visible"); return false }
        let decreases = await waitUntil(timeout: 8) { self.countdownSeconds(timerID, in: app).map { $0 < initial && $0 > 0 } ?? false }
        if !decreases { keep(app, "timekeeping-countdown-not-advancing"); XCTFail("The running native timer's visible countdown did not advance") }
        return decreases
    }

    @MainActor private func countdownSeconds(_ id: String, in app: XCUIApplication) -> Int? {
        let element = app.descendants(matching: .any).matching(identifier: "toolbox.timer.remaining." + id).firstMatch
        guard element.exists else { return nil }
        let labels = [element.label] + element.staticTexts.allElementsBoundByIndex.map(\.label)
        guard let pattern = try? NSRegularExpression(pattern: "([0-9]{2,}):([0-9]{2}):([0-9]{2})") else { return nil }
        for label in labels {
            guard let match = pattern.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) else { continue }
            let parts = (1...3).compactMap { Range(match.range(at: $0), in: label).flatMap { Int(label[$0]) } }
            if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        }
        return nil
    }

    @MainActor private func reminderSwitch(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.switches["toolbox.timer.reminder." + id].firstMatch
    }

    @MainActor private func enableOwnAlarmPermission(in settings: XCUIApplication) async -> Bool {
        // This qualification target's actual CFBundleName is its PRODUCT_NAME.
        let ownName = "FloeTimekeepingQualification"
        let labels = ["闹钟", "Alarms", "允许闹钟", "Allow Alarms"]
        let explicitAlarm = NSPredicate(format: "label IN %@", labels)
        let ownPage = { settings.navigationBars[ownName].exists || settings.navigationBars.staticTexts[ownName].exists }
        if !ownPage() {
            // R17 captured the standard URL landing on the initial Settings page.
            // Its observed Apps sidebar item is safe navigation; permission controls
            // remain gated by the exact app title below.
            let apps = settings.buttons["com.apple.settings.apps"]
            guard apps.exists && apps.isHittable else {
                keep(settings, "timekeeping-alarm-settings-apps-unreachable")
                XCTFail("Settings did not expose its observed Apps navigation item; no permission was changed"); return false
            }
            apps.tap()
            keep(settings, "timekeeping-alarm-settings-apps-list")
            let ownRow = settings.cells.containing(.staticText, identifier: ownName).firstMatch
            let ownButton = settings.buttons[ownName].firstMatch
            for _ in 0..<6 {
                if ownButton.isHittable { ownButton.tap(); break }
                if ownRow.isHittable { ownRow.tap(); break }
                let collections = settings.collectionViews.allElementsBoundByIndex
                guard let list = collections.max(by: { $0.frame.width < $1.frame.width }) else { break }
                list.swipeUp()
            }
            keep(settings, "timekeeping-alarm-settings-apps-navigation-result")
        }
        guard ownPage() else {
            keep(settings, "timekeeping-alarm-settings-unconfirmed-app"); XCTFail("Settings did not identify this qualification app; no permission was changed"); return false
        }
        var choices = settings.switches.matching(explicitAlarm).allElementsBoundByIndex
        var enteredAlarmPage = false
        if choices.isEmpty {
            let rows = settings.cells.allElementsBoundByIndex.filter { row in
                row.staticTexts.allElementsBoundByIndex.contains { labels.contains($0.label) }
            }
            guard rows.count == 1 else {
                keep(settings, "timekeeping-alarm-settings-no-explicit-item"); XCTFail("The confirmed app page did not expose one explicit Alarms permission item"); return false
            }
            choices = rows[0].switches.allElementsBoundByIndex
            if choices.isEmpty {
                guard ownPage(), rows[0].isHittable else {
                    keep(settings, "timekeeping-alarm-settings-item-not-reachable"); XCTFail("The app's explicit Alarms permission row was not reachable"); return false
                }
                rows[0].tap()
                keep(settings, "timekeeping-alarm-settings-permission-page")
                guard await waitUntil({
                    settings.navigationBars.matching(explicitAlarm).buttons[ownName].exists
                }) else {
                    keep(settings, "timekeeping-alarm-settings-unconfirmed-permission-page"); XCTFail("The Alarms page did not retain a verified link to this app; no permission was changed"); return false
                }
                enteredAlarmPage = true
                choices = settings.switches.matching(explicitAlarm).allElementsBoundByIndex
            }
        }
        let confirmedPage = enteredAlarmPage
            ? settings.navigationBars.matching(explicitAlarm).buttons[ownName].exists : ownPage()
        guard confirmedPage, choices.count == 1, let value = choices[0].value as? String, ["0", "1"].contains(value) else {
            keep(settings, "timekeeping-alarm-settings-no-unique-switch"); XCTFail("No unique explicit Alarms switch was available on this app's verified page"); return false
        }
        if value == "0" {
            let children = choices[0].switches.allElementsBoundByIndex
            guard children.count <= 1 else {
                keep(settings, "timekeeping-alarm-settings-ambiguous-control"); XCTFail("The app's Alarms control was ambiguous; no permission was changed"); return false
            }
            let control = children.first ?? choices[0]
            guard control.isHittable else {
                keep(settings, "timekeeping-alarm-settings-control-not-reachable"); XCTFail("The app's Alarms switch was not reachable"); return false
            }
            control.tap()
        }
        let enabled = await waitUntil({ choices[0].value as? String == "1" })
        keep(settings, "timekeeping-alarm-settings-after")
        if !enabled { XCTFail("The specific Alarms setting did not become enabled") }
        return enabled
    }

    @MainActor private func assertNoPermissionPrompt(_ app: XCUIApplication) {
        XCTAssertFalse(app.alerts.firstMatch.exists, "Opening the workbench must not request alarm authorization")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists,
            "Only explicit creation of a ringing timer may request system authorization")
    }

    @MainActor private func allowAlarmAuthorizationIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["允许", "允许闹钟", "Allow", "Allow Alarms"])).firstMatch
        if allow.waitForExistence(timeout: 4) { allow.tap() }
    }

    @MainActor private func removeCreatedTimers(_ ids: [String], in app: XCUIApplication) async {
        guard app.state == .runningForeground else { return }
        for id in ids {
            let actions = app.buttons["toolbox.timer.actions." + id]
            guard reveal(actions, in: app) else {
                keep(app, "timekeeping-test-record-cleanup-failed"); XCTFail("Could not reach the timer created by this test for deletion"); continue
            }
            actions.tap()
            let delete = app.buttons.matching(NSPredicate(format: "label IN %@", ["删除", "Delete"])).firstMatch
            guard await waitUntil({ delete.isHittable }) else { keep(app, "timekeeping-test-record-cleanup-failed"); XCTFail("Could not delete the timer created by this test"); continue }
            delete.tap()
            if !(await waitUntil({ !app.buttons["toolbox.timer.actions." + id].exists })) { XCTFail("The test timer record was not removed") }
        }
    }

    /// This command uses only ToolboxTimerReminders' miniApp-owned ledger.
    /// A timeout is a cleanup failure, never evidence that alarms disappeared.
    @MainActor private func clearOwnedAlarms(_ app: XCUIApplication) async -> Bool {
        // Cleanup must still await its real receipt if the test task was cancelled.
        let cleanup = Task { @MainActor in
            app.terminate()
            app.launchArguments = ["--clear-test-reminders", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
            app.launch()
            let cleared = app.staticTexts["qualification.notifications.cleared"]
            let complete = await self.waitUntil(timeout: 15, { cleared.exists })
            if !complete {
                self.keep(app, "timekeeping-owned-alarm-cleanup-failed")
                XCTFail("Manual miniApp alarm cleanup was not confirmed; owned native alarms may remain")
            }
            app.terminate()
            return complete
        }
        return await cleanup.value
    }

    @MainActor private func waitUntil(timeout: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while !condition() {
            guard clock.now < deadline, !Task.isCancelled else { return false }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return true
    }

    @MainActor private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways; add(hierarchy)
    }

    @MainActor @discardableResult private func reveal(
        _ target: XCUIElement, in app: XCUIApplication, scrolling container: XCUIElement? = nil
    ) -> Bool {
        let scroll = container ?? app.scrollViews.containing(.button, identifier: "toolbox.timer.add").firstMatch
        for _ in 0..<8 {
            if target.isHittable { return true }
            guard scroll.exists else { return false }
            let above = target.exists && target.frame.midY < scroll.frame.minY + 100
            let start = above ? 0.3 : 0.85, end = above ? 0.85 : 0.3
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start))
                .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: end)))
        }
        return target.isHittable
    }
}

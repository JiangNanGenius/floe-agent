// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeAndroidCore

final class AndroidExecutionGuidanceTests: XCTestCase {
    func testPlayTaskGetsCLIContextWithoutAdvertisingPhoneControl() {
        let notes = AndroidExecutionGuidance.workspaceNotes(
            temporary: false, isNotes: false,
            availableTools: ["exec.shell", "workspace.readFile"])
        XCTAssertEqual(notes, [AndroidExecutionGuidance.commandLine])
    }

    func testFullTaskRetainsPhoneBoundaryAlongsideCLIContext() {
        let notes = AndroidExecutionGuidance.workspaceNotes(
            temporary: false, isNotes: false,
            availableTools: ["exec.shell", "system.access.status", "phone.observe"])
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes.first, AndroidExecutionGuidance.commandLine)
        XCTAssertEqual(notes.last, AndroidExecutionGuidance.phone)
        XCTAssertTrue(notes.last?.contains("not VNC or a Linux desktop") == true)
    }

    func testMissingCapabilitiesNotesAndTemporaryRunsKeepTheirCeilings() {
        let all: Set<String> = ["exec.shell", "system.access.status"]
        XCTAssertTrue(AndroidExecutionGuidance.workspaceNotes(
            temporary: true, isNotes: false, availableTools: all).isEmpty)
        XCTAssertTrue(AndroidExecutionGuidance.workspaceNotes(
            temporary: false, isNotes: true, availableTools: all).isEmpty)
        XCTAssertTrue(AndroidExecutionGuidance.workspaceNotes(
            temporary: false, isNotes: false, availableTools: ["web.search"]).isEmpty)
    }

    func testGraphicsStatusRetainsActualEnvironmentAndDisplayForManualHandoff() {
        let snapshot = C01LinuxEnvironmentSnapshot(
            phase: .ready, environmentID: "project-env", runtimeActive: true,
            componentMatches: true, readinessQualified: true, installed: true,
            graphics: .init(display: ":27", mode: "singleApplication",
                            width: 960, height: 1280,
                            workspaceID: "project-workspace", runtimeGeneration: "generation-2"))
        let text = C01LinuxEnvironmentRendering.text(snapshot)
        XCTAssertTrue(text.contains("environmentID=project-env"))
        XCTAssertTrue(text.contains("graphics.display=:27"))
        XCTAssertTrue(text.contains("DISPLAY=:27 for user handoff"))
        XCTAssertTrue(text.contains("Prefer exec.shell and command-line tools"))
        XCTAssertTrue(text.contains("primarily for the user to operate manually"))
        XCTAssertTrue(text.contains("not proof the file was saved"))
        XCTAssertEqual(C01LinuxEnvironmentRendering.exitStatus(snapshot), 0)
    }
}

// FloeToolsTests — Linux lifecycle names route to the guest and their schemas
// are well-formed. The tool implementations live in FloeExecution; here we pin
// the FloeTools-side routing/discovery contract that the app and deferred
// discovery rely on.

import Foundation
import XCTest
import FloeTools

final class LinuxLifecycleRoutingTests: XCTestCase {

    /// Lifecycle tools are routed to the Linux guest backend.
    func testLifecycleNamesRouteToGuest() {
        let names = [
            "environment.startLinux",
            "environment.linuxStatus",
            "environment.stopLinux",
            "environment.softRestartLinux",
            "environment.hardRestartLinux",
        ]
        for name in names {
            let decision = CapabilityExecutionRouter.decision(for: name)
            XCTAssertEqual(decision.backend, .linuxGuest, "\(name) must run in the Linux guest")
            XCTAssertEqual(decision.toolName, name)
        }
    }

    /// Status is a read-only intent; the others are control operations.
    func testStatusWorkloadAndBackends() {
        let status = CapabilityExecutionRouter.decision(for: "environment.linuxStatus")
        XCTAssertEqual(status.workload, .cli)
        for name in [
            "environment.startLinux", "environment.stopLinux",
            "environment.softRestartLinux", "environment.hardRestartLinux",
        ] {
            XCTAssertEqual(CapabilityExecutionRouter.decision(for: name).backend, .linuxGuest)
        }
    }

    /// Interpreter classification sees lifecycle tools as guest-owned so the
    /// native-first policy keeps them in the guest group.
    func testInterpreterClassification() {
        for name in [
            "environment.startLinux", "environment.hardRestartLinux",
            "environment.stopLinux",
        ] {
            XCTAssertTrue(ToolRoutingPolicy.isInterpreterTool(name), "\(name) is guest-owned")
        }
    }
}

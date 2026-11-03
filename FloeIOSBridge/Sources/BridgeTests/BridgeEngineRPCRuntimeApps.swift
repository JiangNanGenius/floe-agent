import Foundation
import UIKit
import XCTest
import BridgeCore

@MainActor
extension BridgeEngineRPCRuntime {

    // MARK: - home

    func home(permit: BridgeRPCDispatchPermit,
              generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let current = currentForegroundBundleIdentifier()
        let sourceBundle = (current == "com.apple.springboard")
            ? state.lastControlledBundleIdentifier
            : (current ?? state.lastControlledBundleIdentifier)
        let sourceApp = sourceBundle.map { XCUIApplication(bundleIdentifier: $0) }
        let sourceBefore = sourceApp.map { stateName($0) } ?? "unknown"
        let springboardBefore = stateName(springboard)
        let hostBefore = applicationStateName(UIApplication.shared.applicationState)
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
        let press = sdk.call(stage: "home") {
            XCUIDevice.shared.press(.home)
        }
        if press.error != nil || press.outcome.recordedIssueCount > 0 {
            return .sideEffectUnknown(
                code: "home_outcome_unknown",
                message: "The Home press was entered but did not return cleanly; whether the device reached Home is unknown."
            )
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "Home was pressed but the engine lifecycle changed; the final screen is unknown.")
        }
        let sourceAfter = sourceApp.map { stateName($0) } ?? "unknown"
        let springboardAfter = stateName(springboard)
        let hostAfter = applicationStateName(UIApplication.shared.applicationState)
        let observation = BridgeHomeObservation(
            sourceBundleIdentifier: sourceBundle,
            sourceStateBefore: sourceBefore,
            sourceStateAfter: sourceAfter,
            springboardStateBefore: springboardBefore,
            springboardStateAfter: springboardAfter,
            hostStateBefore: hostBefore,
            hostStateAfter: hostAfter,
            pressReturned: true
        )
        let assessment = BridgeHomeEvidence.assess(observation)
        var foreground = BRCurrentForegroundBundleID()
        if springboardAfter == "runningForeground" {
            foreground = "com.apple.springboard"
        }
        var result: [String: BridgeRPCJSONValue] = [
            "message": .string(assessment.actualHomeObserved
                               ? "Home pressed and SpringBoard is frontmost."
                               : "Home press dispatched but Home was not independently observed."),
            "foreground_app": foreground.map { .string($0) } ?? .null,
            "previous_app": sourceBundle.map { .string($0) } ?? .null,
            "home_evidence": .string(assessment.homeEvidence),
            "springboard_state": .string(springboardAfter),
            "source_state": .string(sourceAfter),
        ]
        guard assessment.actualHomeObserved else {
            return .sideEffectUnknown(
                code: "home_unverified",
                message: "The Home press returned but no actual SpringBoard foreground was observed. The screen state is unknown."
            )
        }
        result["destination_verified"] = .bool(true)
        return .success(.object(result))
    }

    // MARK: - lock / unlock / is_locked

    func lockScreen(permit: BridgeRPCDispatchPermit,
                    generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        switch lockState() {
        case .unavailable:
            return methodNotAvailable("The SpringBoard lock-state notification is unavailable.")
        case .locked:
            return .success(.object(["message": .string("The screen is already locked."),
                                     "locked": .bool(true),
                                     "lock_state": .string("locked")]))
        case .unknown:
            return .sideEffectUnknown(
                code: "lock_state_unknown",
                message: "The lock state could not be read; the lock button was not pressed and no state is claimed."
            )
        case .unlocked:
            break
        }
        guard BRLockButtonAvailable() else {
            return methodNotAvailable("The private lock-button path is unavailable.")
        }
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
        guard BRPressLockButton() else {
            return failure(-32000, "The lock button press was not accepted.")
        }
        var locked = false
        for _ in 0..<30 {
            if lockState() == .locked { locked = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard locked else {
            return .sideEffectUnknown(code: "lock_state_unknown",
                                      message: "The lock button was pressed but the lock state was not observed in time.")
        }
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "The lock was dispatched but the engine lifecycle changed; the final state is unknown.")
        }
        return .success(.object(["message": .string("The screen is locked."),
                                 "locked": .bool(true),
                                 "lock_state": .string("locked")]))
    }

    func unlockScreen(permit: BridgeRPCDispatchPermit,
                      generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        switch lockState() {
        case .unavailable:
            return methodNotAvailable("The SpringBoard lock-state notification is unavailable.")
        case .unlocked:
            return .success(.object(["message": .string("The screen is already unlocked."),
                                     "locked": .bool(false),
                                     "lock_state": .string("unlocked")]))
        case .unknown:
            return .sideEffectUnknown(
                code: "lock_state_unknown",
                message: "The lock state could not be read; the Home button was not pressed and no state is claimed."
            )
        case .locked:
            break
        }
        for _ in 0..<2 {
            guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
            let press = sdk.call(stage: "unlock-home") {
                XCUIDevice.shared.press(.home)
            }
            if press.error != nil || press.outcome.recordedIssueCount > 0 {
                return .sideEffectUnknown(code: "unlock_outcome_unknown",
                                          message: "The Home press was entered but did not return cleanly; the lock state is unknown.")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        var unlocked = false
        for _ in 0..<30 {
            if lockState() == .unlocked { unlocked = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard unlocked else {
            return failure(-32000,
                           "The screen is still locked. A passcode or authorization prompt is never automated.")
        }
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "The unlock was dispatched but the engine lifecycle changed; the final state is unknown.")
        }
        return .success(.object(["message": .string("The screen is awake and unlocked."),
                                 "locked": .bool(false),
                                 "lock_state": .string("unlocked")]))
    }

    func isLocked(permit: BridgeRPCDispatchPermit,
                  generation: UInt64) throws -> BridgeRPCExecutionOutcome {
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        let state = lockState()
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
        switch state {
        case .unavailable:
            return methodNotAvailable("The SpringBoard lock-state notification is unavailable.")
        case .unknown:
            return .failure(BridgeRPCError(
                code: -32000,
                message: "The lock state could not be read; locked/unlocked is unknown.",
                data: ["lock_state": .string("unknown")]
            ))
        case .locked:
            return .success(.bool(true))
        case .unlocked:
            return .success(.bool(false))
        }
    }

    // MARK: - launch / activate / terminate

    func launchApp(_ params: BridgeEngineParameters,
                   permit: BridgeRPCDispatchPermit,
                   generation: UInt64) throws -> BridgeRPCExecutionOutcome {
        let bundle = try params.requiredString("bundle_id", maximumBytes: 256)
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        let app = XCUIApplication(bundleIdentifier: bundle)
        let before = stateName(app)
        let launchUsed = before == "notRunning"
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
        let call = sdk.call(stage: "launch-app") {
            if before == "notRunning" {
                app.launch()
            } else {
                app.activate()
            }
        }
        if call.error != nil || call.outcome.recordedIssueCount > 0 {
            return .sideEffectUnknown(
                code: "launch_outcome_unknown",
                message: "The launch/activate call was entered but did not return cleanly; whether the app opened is unknown."
            )
        }
        var foreground = false
        let waitResult = sdk.call(stage: "launch-wait") {
            foreground = app.wait(for: .runningForeground, timeout: 10)
        }
        guard waitResult.error == nil, waitResult.outcome.recordedIssueCount == 0 else {
            return .sideEffectUnknown(code: "launch_outcome_unknown",
                                      message: "The launch call returned but foreground state could not be read.")
        }
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "The launch was dispatched but the engine lifecycle changed; the final state is unknown.")
        }
        guard foreground else {
            return .sideEffectUnknown(code: "launch_unverified",
                                      message: "The app did not reach runningForeground in time; its state is unknown.")
        }
        markControlled(bundle)
        return .success(.object([
            "message": .string(launchUsed ? "App launched and is in the foreground." : "App activated and is in the foreground."),
            "bundle_id": .string(bundle),
            "hint": .string(launchUsed ? "launch was used because the app was not running." : "activate was used because the app was already running."),
        ]))
    }

    func activateApp(_ params: BridgeEngineParameters,
                     permit: BridgeRPCDispatchPermit,
                     generation: UInt64) throws -> BridgeRPCExecutionOutcome {
        let bundle = try params.requiredString("bundle_id", maximumBytes: 256)
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        let app = XCUIApplication(bundleIdentifier: bundle)
        let before = stateName(app)
        guard before != "notRunning" else {
            return failure(-32000, "The app is not running; use launch_app to start it.")
        }
        if before == "runningForeground" {
            markControlled(bundle)
            return .success(.object(["message": .string("The app is already in the foreground."),
                                     "bundle_id": .string(bundle)]))
        }
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
        let call = sdk.call(stage: "activate-app") { app.activate() }
        if call.error != nil || call.outcome.recordedIssueCount > 0 {
            return .sideEffectUnknown(
                code: "activate_outcome_unknown",
                message: "The activate call was entered but did not return cleanly; whether the app came forward is unknown."
            )
        }
        var foreground = false
        let waitResult = sdk.call(stage: "activate-wait") {
            foreground = app.wait(for: .runningForeground, timeout: 10)
        }
        guard waitResult.error == nil, waitResult.outcome.recordedIssueCount == 0 else {
            return .sideEffectUnknown(code: "activate_outcome_unknown",
                                      message: "The activate call returned but foreground state could not be read.")
        }
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "The activation was dispatched but the engine lifecycle changed; the final state is unknown.")
        }
        guard foreground else {
            return .sideEffectUnknown(code: "activate_unverified",
                                      message: "The app did not reach runningForeground in time; its state is unknown.")
        }
        markControlled(bundle)
        return .success(.object([
            "message": .string("App activated and is in the foreground."),
            "bundle_id": .string(bundle),
        ]))
    }

    func terminateApp(_ params: BridgeEngineParameters,
                      permit: BridgeRPCDispatchPermit,
                      generation: UInt64) throws -> BridgeRPCExecutionOutcome {
        let bundle = try params.requiredString("bundle_id", maximumBytes: 256)
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        let app = XCUIApplication(bundleIdentifier: bundle)
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
        let call = sdk.call(stage: "terminate-app") { app.terminate() }
        if call.error != nil || call.outcome.recordedIssueCount > 0 {
            return .sideEffectUnknown(
                code: "terminate_outcome_unknown",
                message: "The terminate call was entered but did not return cleanly; whether the app stopped is unknown."
            )
        }
        var stopped = false
        let waitResult = sdk.call(stage: "terminate-wait") {
            stopped = app.wait(for: .notRunning, timeout: 5)
        }
        guard waitResult.error == nil, waitResult.outcome.recordedIssueCount == 0 else {
            return .sideEffectUnknown(code: "terminate_outcome_unknown",
                                      message: "The terminate call returned but the app state could not be read.")
        }
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "The terminate was dispatched but the engine lifecycle changed; the final state is unknown.")
        }
        guard stopped else {
            return .sideEffectUnknown(code: "terminate_unverified",
                                      message: "The app did not report notRunning in time; its state is unknown.")
        }
        if state.lastControlledBundleIdentifier == bundle {
            state.setLastControlled(nil)
        }
        return .success(.object([
            "message": .string("App terminated."),
            "bundle_id": .string(bundle),
        ]))
    }

    func applicationStateName(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}

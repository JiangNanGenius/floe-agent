import Foundation
import UIKit
import XCTest
import BridgeCore

@MainActor
extension BridgeEngineRPCRuntime {

    enum ClearResult {
        case success(Bool)
        case failure(BridgeRPCExecutionOutcome)
    }

    enum KeyboardResult {
        case success
        case failure(BridgeRPCExecutionOutcome)
    }

    struct InputFocus {
        var element: XCUIElement
        var candidate: BridgeEngineElementCandidate
        var secure: Bool
        var beforeValue: String?
        var beforeTrusted: Bool
        var beforeObservation: BridgeTextBeforeValue.Observation
    }

    // MARK: - type

    func typeText(params: BridgeEngineParameters,
                  permit: BridgeRPCDispatchPermit,
                  generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        let text = try params.string("text", maximumBytes: 8_192)
        let clear = try params.bool("clear") ?? false
        let submit = try params.bool("submit") ?? false
        let via = try params.option("via", allowed: ["keyboard"], default: nil)
        let x = try params.double("x")
        let y = try params.double("y")
        _ = try params.bool("settle")
        _ = try params.number("settle_timeout", default: 2, range: 0...3)
        _ = try params.bool("fast")
        guard text != nil || clear else {
            throw BridgeEngineParameterError("type requires 'text' (or clear:true to only empty the field).")
        }
        if (text?.isEmpty ?? true) && !clear {
            throw BridgeEngineParameterError("type requires non-empty text, or clear:true to empty the field.")
        }
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        guard let authorization = activeAuthorization, authorization.isActive else {
            return permissionDenied("The per-invocation authorization context is unavailable; no text was typed.")
        }
        guard let bundle = currentForegroundBundleIdentifier() else {
            return failure(-32000, "No foreground app was observed; no text was typed.")
        }
        guard !isLocked() else {
            return permissionDenied("The screen is locked; lock-screen and passcode input is never automated.")
        }
        guard !systemAuthorizationSurfacePresent() else {
            return permissionDenied("System authorization, passcode and SpringBoard input is never automated.")
        }
        let app = XCUIApplication(bundleIdentifier: bundle)
        guard stateName(app) == "runningForeground" else {
            return failure(-32000, "The target app is not in the foreground; no text was typed.")
        }
        guard let metrics = sdk.screenMetrics() else {
            return failure(-32000, "The screen metrics could not be read; no text was typed.")
        }
        var focusTapPoint: BridgeEnginePoint?
        if let x, let y {
            switch resolvedPoint(x: x, y: y, metrics: metrics) {
            case .success(let point): focusTapPoint = point
            case .failure(let outcome): return outcome
            }
        } else if x != nil || y != nil {
            throw BridgeEngineParameterError("type requires both x and y when focusing by point.")
        }

        if let point = focusTapPoint {
            guard let frame = appFrame(app),
                  BridgeEngineGeometry.contains(frame, point: point, tolerance: 1),
                  let offset = BridgeEngineGeometry.normalizedOffset(point: point, in: frame) else {
                return failure(-32000, "The focus point is outside the app; no text was typed.")
            }
            let coordinate = app.coordinate(withNormalizedOffset: CGVector(dx: offset.dx, dy: offset.dy))
            if let outcome = performTouch(stage: "type-focus",
                                          targetBundle: bundle,
                                          permit: permit,
                                          generation: generation,
                                          {
                coordinate.tap()
            }) { return outcome }
            try? await Task.sleep(for: .milliseconds(300))
            guard stepAllowed(permit, generation: generation) else {
                return .sideEffectUnknown(code: "lifecycle_changed",
                                          message: "The focus tap was dispatched but the engine lifecycle changed; the input result is unknown.")
            }
        }

        guard let focus = try await resolveInputFocus(app: app,
                                                      bundle: bundle,
                                                      permit: permit,
                                                      generation: generation) else {
            return failure(-32000, "No focused text field could be verified; no text was typed.")
        }
        guard !systemAuthorizationSurfacePresent() else {
            return permissionDenied("System authorization, passcode and SpringBoard input is never automated.")
        }
        let decision = BridgeEngineInputPolicy.decide(
            screenLocked: isLocked(),
            bundleIdentifier: bundle,
            focusedEditable: true,
            focusedSecure: focus.secure,
            sensitiveInputGranted: authorization.sensitiveInputGranted,
            redactedTypingAvailable: capabilities.contains(.redactedTyping)
        )
        guard decision.allowed else {
            if decision.requiresSensitiveGrant && !authorization.sensitiveInputGranted {
                return permissionDenied("sensitive_input_required")
            }
            if focus.secure && !capabilities.contains(.redactedTyping) {
                return methodNotAvailable("Secure input needs the SDK's redacted typing path, which is unavailable.")
            }
            return permissionDenied(decision.reason)
        }
        if decision.usesRedactedTyping && !capabilities.contains(.redactedTyping) {
            return methodNotAvailable("The redacted typing path is unavailable; plaintext fallback is refused.")
        }
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }

        if clear {
            switch try await clearFocusedText(focus, targetBundle: bundle, permit: permit, generation: generation) {
            case .success(let verified):
                if !verified && !focus.secure {
                    return failure(-32000, "The field did not become empty; the clear result is unknown.")
                }
            case .failure(let outcome):
                return outcome
            }
        }

        var typeResult: BridgeEngineSDKCallResult?
        var keyboardUsed = false
        if let text, !text.isEmpty {
            if via == "keyboard" {
                switch try await typeOnScreenKeyboard(text: text,
                                                      app: app,
                                                      bundle: bundle,
                                                      permit: permit,
                                                      generation: generation) {
                case .success:
                    keyboardUsed = true
                case .failure(let outcome):
                    return outcome
                }
            } else {
                guard capabilities.contains(.redactedTyping) else {
                    return methodNotAvailable("The redacted typing path is unavailable; plaintext fallback is refused.")
                }
                guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
                var typed = false
                var typeError: NSError?
                let guarded = guardedCall(stage: "type",
                                          targetBundle: bundle,
                                          permit: permit,
                                          generation: generation) {
                    sdk.call(stage: "type", sensitive: true) {
                        typed = BRTypeTextRedacted(text, &typeError)
                    }
                }
                let result: BridgeEngineSDKCallResult
                switch guarded {
                case .denied(let outcome):
                    return outcome
                case .value(let value):
                    result = value
                }
                typeResult = result
                if !typed || typeError != nil || result.error != nil || result.outcome.recordedIssueCount > 0 {
                    return .sideEffectUnknown(
                        code: "text_outcome_unknown",
                        message: "The text input call was entered but did not return cleanly; the actual field value is unknown."
                    )
                }
            }
        }

        if submit {
            guard capabilities.contains(.redactedTyping) else {
                return methodNotAvailable("Submit requires the redacted key-event path, which is unavailable.")
            }
            guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
            var submitted = false
            var submitError: NSError?
            let guarded = guardedCall(stage: "submit",
                                      targetBundle: bundle,
                                      permit: permit,
                                      generation: generation) {
                sdk.call(stage: "submit", sensitive: true) {
                    submitted = BRTypeTextRedacted("\n", &submitError)
                }
            }
            let result: BridgeEngineSDKCallResult
            switch guarded {
            case .denied(let outcome):
                return outcome
            case .value(let value):
                result = value
            }
            if !submitted || submitError != nil || result.error != nil || result.outcome.recordedIssueCount > 0 {
                return .sideEffectUnknown(
                    code: "submit_outcome_unknown",
                    message: "The Return key was entered but did not return cleanly; whether it submitted is unknown."
                )
            }
        }

        try? await Task.sleep(for: .milliseconds(150))
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "Text was dispatched but the engine lifecycle changed; the final field value is unknown.")
        }
        let afterValue = focus.secure ? nil : sdk.nonSecureValue(of: focus.element, app: app)
        let expected: String?
        if clear {
            expected = text ?? ""
        } else if focus.beforeTrusted, let before = focus.beforeValue {
            expected = before + (text ?? "")
        } else {
            // An inaccessible before value means we cannot distinguish an
            // append from a replacement. Never upgrade that to a verified
            // value equality claim.
            expected = nil
        }
        let actualValueVerified: Bool
        var valueBytes: Int?
        var expectedBytes: Int?
        if let afterValue {
            valueBytes = afterValue.utf8.count
            expectedBytes = expected?.utf8.count
            if let expected {
                actualValueVerified = afterValue == expected
            } else {
                actualValueVerified = false
            }
        } else {
            actualValueVerified = false
        }
        let dispatchClaim = typeResult?.outcome.textDispatchClaim(actualValueVerified: actualValueVerified)
            ?? "true"
        var result: [String: BridgeRPCJSONValue] = [
            "message": .string(text == nil || text == ""
                               ? "Focused field cleared."
                               : (actualValueVerified
                                  ? "Text dispatched and the field value was verified."
                                  : "Text dispatched; the actual field value was not verified.")),
            "via": .string(keyboardUsed ? "keyboard" : "direct"),
            "textDispatched": .string(dispatchClaim),
            "actualValueVerified": .bool(actualValueVerified),
            "secureField": .bool(focus.secure),
            "beforeValueObservation": .string(focus.beforeObservation.rawValue),
            "bundle_id": .string(bundle),
        ]
        if let valueBytes { result["valueUTF8Bytes"] = .int(valueBytes) }
        if let expectedBytes { result["expectedUTF8Bytes"] = .int(expectedBytes) }
        if focus.secure {
            result["redacted"] = .bool(true)
            result["note"] = .string("Secure field input used the redacted typing path; no value is read back.")
        } else if !actualValueVerified {
            result["warning"] = .string("The input call returned but the field value did not match the expected result. Read the screen before retrying.")
        }
        if clear && text == nil {
            result["message"] = .string(focus.secure && !actualValueVerified
                                        ? "Clear dispatched; the secure value is not read back."
                                        : "Focused field cleared.")
        }
        markControlled(bundle)
        return .success(.object(result))
    }

    // MARK: - clear_text

    func clearText(permit: BridgeRPCDispatchPermit,
                   generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        guard let authorization = activeAuthorization, authorization.isActive else {
            return permissionDenied("The per-invocation authorization context is unavailable; no field was cleared.")
        }
        guard let bundle = currentForegroundBundleIdentifier() else {
            return failure(-32000, "No foreground app was observed; no field was cleared.")
        }
        guard !isLocked() else {
            return permissionDenied("The screen is locked; lock-screen and passcode input is never automated.")
        }
        guard !systemAuthorizationSurfacePresent() else {
            return permissionDenied("System authorization, passcode and SpringBoard input is never automated.")
        }
        let app = XCUIApplication(bundleIdentifier: bundle)
        guard stateName(app) == "runningForeground" else {
            return failure(-32000, "The target app is not in the foreground; no field was cleared.")
        }
        guard let focus = try await resolveInputFocus(app: app,
                                                      bundle: bundle,
                                                      permit: permit,
                                                      generation: generation) else {
            return failure(-32000, "No focused text field could be verified; no field was cleared.")
        }
        guard !systemAuthorizationSurfacePresent() else {
            return permissionDenied("System authorization, passcode and SpringBoard input is never automated.")
        }
        let decision = BridgeEngineInputPolicy.decide(
            screenLocked: isLocked(),
            bundleIdentifier: bundle,
            focusedEditable: true,
            focusedSecure: focus.secure,
            sensitiveInputGranted: authorization.sensitiveInputGranted,
            redactedTypingAvailable: true
        )
        guard decision.allowed else {
            if decision.requiresSensitiveGrant && !authorization.sensitiveInputGranted {
                return permissionDenied("sensitive_input_required")
            }
            return permissionDenied(decision.reason)
        }
        let verified: Bool
        switch try await clearFocusedText(focus, targetBundle: bundle, permit: permit, generation: generation) {
        case .success(let value): verified = value
        case .failure(let outcome): return outcome
        }
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "The clear was dispatched but the engine lifecycle changed; the final value is unknown.")
        }
        if !verified && !focus.secure {
            return failure(-32000, "The field did not become empty; the clear result is unknown.")
        }
        markControlled(bundle)
        return .success(.object([
            "message": .string(verified ? "Focused field cleared." : "Clear dispatched; the secure value cannot be read back."),
            "actualValueVerified": .bool(verified),
            "secureField": .bool(focus.secure),
            "bundle_id": .string(bundle),
        ]))
    }

    // MARK: - focus resolution

    func resolveInputFocus(app: XCUIApplication,
                           bundle: String,
                           permit: BridgeRPCDispatchPermit,
                           generation: UInt64) async throws -> InputFocus? {
        guard stepAllowed(permit, generation: generation) else { throw SettleFence(outcome: .failure(.fenced)) }
        guard let fields = sdk.focusedFields(app: app), fields.count == 1, let chosen = fields.first else {
            return nil
        }
        guard stepAllowed(permit, generation: generation) else { throw SettleFence(outcome: .failure(.fenced)) }
        let rawValue = chosen.candidate.isSecure ? nil : sdk.nonSecureValue(of: chosen.element, app: app)
        let before = BridgeTextBeforeValueClassifier.classify(
            rawValue: rawValue,
            placeholderValue: chosen.placeholderValue,
            secure: chosen.candidate.isSecure
        )
        return InputFocus(
            element: chosen.element,
            candidate: chosen.candidate,
            secure: chosen.candidate.isSecure,
            beforeValue: before.value,
            beforeTrusted: before.trusted,
            beforeObservation: before.observation
        )
    }

    /// Clears the focused field with key events only. Ordinary fields are
    /// verified empty; secure fields return false because the value is never
    /// read back. A thrown/issue-recorded call is an unknown side effect.
    func clearFocusedText(_ focus: InputFocus,
                          targetBundle: String,
                          permit: BridgeRPCDispatchPermit,
                          generation: UInt64) async throws -> ClearResult {
        guard stepAllowed(permit, generation: generation) else {
            return .failure(.failure(.fenced))
        }
        let app = XCUIApplication(bundleIdentifier: targetBundle)
        var mutated = false
        func refusal(_ outcome: BridgeRPCExecutionOutcome) -> ClearResult {
            if mutated {
                return .failure(.sideEffectUnknown(
                    code: "clear_outcome_unknown",
                    message: "A clear step was refused after the field was partly modified; the final value is unknown."
                ))
            }
            return .failure(outcome)
        }
        if !focus.secure, focus.beforeTrusted, let before = focus.beforeValue, before.count <= 200 {
            let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: before.count)
            if !deletes.isEmpty {
                var deleted = false
                var deleteError: NSError?
                let guarded = guardedCall(stage: "clear-delete",
                                          targetBundle: targetBundle,
                                          permit: permit,
                                          generation: generation) {
                    sdk.call(stage: "clear-delete", sensitive: true) {
                        deleted = BRTypeTextRedacted(deletes, &deleteError)
                    }
                }
                let result: BridgeEngineSDKCallResult
                switch guarded {
                case .denied(let outcome):
                    return refusal(outcome)
                case .value(let value):
                    result = value
                }
                mutated = true
                if !deleted || deleteError != nil || result.error != nil || result.outcome.recordedIssueCount > 0 {
                    return .failure(.sideEffectUnknown(
                        code: "clear_outcome_unknown",
                        message: "The clear key events were entered but did not return cleanly; the field value is unknown."
                    ))
                }
                try? await Task.sleep(for: .milliseconds(120))
                guard stepAllowed(permit, generation: generation) else {
                    return .failure(.sideEffectUnknown(
                        code: "lifecycle_changed",
                        message: "The clear was dispatched but the engine lifecycle changed; the final value is unknown."
                    ))
                }
                guard let after = sdk.nonSecureValue(of: focus.element, app: app) else {
                    return .failure(.sideEffectUnknown(
                        code: "clear_outcome_unknown",
                        message: "The clear key events were dispatched but the field value could not be read back."
                    ))
                }
                return .success(after.isEmpty)
            }
        }
        // Select-all + delete is the fallback when the before value is not
        // readable (or is secure). It never types user text.
        let guardedSelect = guardedCall(stage: "clear-select-all",
                                        targetBundle: targetBundle,
                                        permit: permit,
                                        generation: generation) {
            sdk.call(stage: "clear-select-all", sensitive: true) {
                focus.element.typeKey("a", modifierFlags: .command)
            }
        }
        let selectResult: BridgeEngineSDKCallResult
        switch guardedSelect {
        case .denied(let outcome):
            return refusal(outcome)
        case .value(let value):
            selectResult = value
        }
        mutated = true
        if selectResult.error != nil || selectResult.outcome.recordedIssueCount > 0 {
            return .failure(.sideEffectUnknown(
                code: "clear_outcome_unknown",
                message: "The select-all key event was entered but did not return cleanly; the field value is unknown."
            ))
        }
        guard stepAllowed(permit, generation: generation) else {
            return .failure(.sideEffectUnknown(
                code: "lifecycle_changed",
                message: "The clear was dispatched but the engine lifecycle changed; the final value is unknown."
            ))
        }
        let guardedDelete = guardedCall(stage: "clear-delete-key",
                                        targetBundle: targetBundle,
                                        permit: permit,
                                        generation: generation) {
            sdk.call(stage: "clear-delete-key", sensitive: true) {
                focus.element.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
            }
        }
        let deleteResult: BridgeEngineSDKCallResult
        switch guardedDelete {
        case .denied(let outcome):
            return refusal(outcome)
        case .value(let value):
            deleteResult = value
        }
        if deleteResult.error != nil || deleteResult.outcome.recordedIssueCount > 0 {
            return .failure(.sideEffectUnknown(
                code: "clear_outcome_unknown",
                message: "The delete key event was entered but did not return cleanly; the field value is unknown."
            ))
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard stepAllowed(permit, generation: generation) else {
            return .failure(.sideEffectUnknown(
                code: "lifecycle_changed",
                message: "The clear was dispatched but the engine lifecycle changed; the final value is unknown."
            ))
        }
        if focus.secure { return .success(false) }
        guard let after = sdk.nonSecureValue(of: focus.element, app: app) else {
            return .failure(.sideEffectUnknown(
                code: "clear_outcome_unknown",
                message: "The clear was dispatched but the field value could not be read back."
            ))
        }
        return .success(after.isEmpty)
    }

    // MARK: - on-screen keyboard path

    /// Taps actual on-screen keys for lowercase letters, uppercase letters,
    /// digits, space and return. Unsupported characters are refused before
    /// any key is tapped so a partial wrong value is never left behind. The
    /// live per-invocation guard runs before every actual key tap.
    func typeOnScreenKeyboard(text: String,
                              app: XCUIApplication,
                              bundle: String,
                              permit: BridgeRPCDispatchPermit,
                              generation: UInt64) async throws -> KeyboardResult {
        var keys: [(key: String, shift: Bool)] = []
        for scalar in text {
            if scalar == " " {
                keys.append(("space", false))
            } else if scalar == "\n" {
                keys.append(("return", false))
            } else if scalar.isNumber {
                keys.append((String(scalar), false))
            } else if scalar.isLetter {
                let lower = String(scalar).lowercased()
                keys.append((lower, String(scalar) != lower))
            } else {
                throw BridgeEngineParameterError(
                    "via:\"keyboard\" supports letters, digits, space and return only; no keys were tapped."
                )
            }
        }
        // Preflight every key before the first tap.
        for entry in keys {
            if keyElement(app, entry.key) == nil {
                return .failure(methodNotAvailable("The on-screen keyboard does not expose the '\(entry.key)' key."))
            }
            if entry.shift && keyElement(app, "shift") == nil {
                return .failure(methodNotAvailable("The on-screen keyboard does not expose the shift key."))
            }
        }
        var tappedAny = false
        func refusal(_ outcome: BridgeRPCExecutionOutcome) -> KeyboardResult {
            if tappedAny {
                return .failure(.sideEffectUnknown(
                    code: "keyboard_outcome_unknown",
                    message: "Some on-screen keys were tapped before a later key was refused; the partial field value is unknown."
                ))
            }
            return .failure(outcome)
        }
        for entry in keys {
            guard stepAllowed(permit, generation: generation) else {
                if tappedAny {
                    return .failure(.sideEffectUnknown(
                        code: "keyboard_outcome_unknown",
                        message: "Some on-screen keys were tapped before the engine lifecycle changed; the partial field value is unknown."
                    ))
                }
                return .failure(.failure(.fenced))
            }
            if entry.shift, let shift = keyElement(app, "shift") {
                let guarded = guardedCall(stage: "keyboard-shift",
                                          targetBundle: bundle,
                                          permit: permit,
                                          generation: generation) {
                    sdk.call(stage: "keyboard-shift", sensitive: true) { shift.tap() }
                }
                let result: BridgeEngineSDKCallResult
                switch guarded {
                case .denied(let outcome):
                    return refusal(outcome)
                case .value(let value):
                    result = value
                }
                if result.error != nil || result.outcome.recordedIssueCount > 0 {
                    return .failure(.sideEffectUnknown(
                        code: "keyboard_outcome_unknown",
                        message: "An on-screen key tap did not return cleanly; the partial field value is unknown."
                    ))
                }
                tappedAny = true
            }
            guard let key = keyElement(app, entry.key) else {
                return .failure(.sideEffectUnknown(
                    code: "keyboard_key_missing",
                    message: "An on-screen key disappeared after preflight; the partial field value is unknown."
                ))
            }
            let guardedKey = guardedCall(stage: "keyboard-key",
                                         targetBundle: bundle,
                                         permit: permit,
                                         generation: generation) {
                sdk.call(stage: "keyboard-key", sensitive: true) { key.tap() }
            }
            let result: BridgeEngineSDKCallResult
            switch guardedKey {
            case .denied(let outcome):
                return refusal(outcome)
            case .value(let value):
                result = value
            }
            if result.error != nil || result.outcome.recordedIssueCount > 0 {
                return .failure(.sideEffectUnknown(
                    code: "keyboard_outcome_unknown",
                    message: "An on-screen key tap did not return cleanly; the partial field value is unknown."
                ))
            }
            tappedAny = true
            if entry.shift, let shift = keyElement(app, "shift") {
                let guardedOff = guardedCall(stage: "keyboard-shift-off",
                                             targetBundle: bundle,
                                             permit: permit,
                                             generation: generation) {
                    sdk.call(stage: "keyboard-shift-off", sensitive: true) { shift.tap() }
                }
                let off: BridgeEngineSDKCallResult
                switch guardedOff {
                case .denied(let outcome):
                    return refusal(outcome)
                case .value(let value):
                    off = value
                }
                if off.error != nil || off.outcome.recordedIssueCount > 0 {
                    return .failure(.sideEffectUnknown(
                        code: "keyboard_outcome_unknown",
                        message: "The shift key tap did not return cleanly; the partial field value is unknown."
                    ))
                }
            }
        }
        return .success
    }

    func keyElement(_ app: XCUIApplication, _ name: String) -> XCUIElement? {
        let element = app.keyboards.keys[name]
        var exists = false
        let result = sdk.call(stage: "keyboard-query", sensitive: true) {
            exists = element.exists
        }
        guard result.error == nil, result.outcome.recordedIssueCount == 0, exists else { return nil }
        return element
    }
}

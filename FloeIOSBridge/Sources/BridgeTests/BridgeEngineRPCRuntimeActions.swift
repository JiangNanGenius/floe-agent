import Foundation
import UIKit
import XCTest
import BridgeCore

@MainActor
extension BridgeEngineRPCRuntime {

    struct ResolvedTapTarget {
        var point: BridgeEnginePoint
        var note: String?
        var bundleIdentifier: String
    }

    enum TapResolution {
        case success(ResolvedTapTarget)
        case failure(BridgeRPCExecutionOutcome)
    }

    enum PointResolution {
        case success(BridgeEnginePoint)
        case failure(BridgeRPCExecutionOutcome)
    }

    enum SettleStepResult {
        case success(SettleReport?)
        case failure(BridgeRPCExecutionOutcome)
    }

    struct SettleReport {
        var stable: Bool
        var changed: Bool?
        var waitedMilliseconds: Int
        var samples: Int
    }

    // MARK: - Shared coordinate/ref helpers

    func metricsForAction(_ permit: BridgeRPCDispatchPermit,
                          generation: UInt64) -> (metrics: BridgeEngineScreenMetrics, app: XCUIApplication)? {
        guard stepAllowed(permit, generation: generation),
              let capture = sdk.captureScreen() else { return nil }
        guard let bundle = currentForegroundBundleIdentifier() else { return nil }
        return (capture.metrics, XCUIApplication(bundleIdentifier: bundle))
    }

    func resolvedPoint(x: Double, y: Double,
                       metrics: BridgeEngineScreenMetrics) -> PointResolution {
        switch BridgeEngineGeometry.resolvePoint(x: x, y: y, metrics: metrics) {
        case .resolved(let point):
            return .success(point)
        case .outOfRange(let validX, let validY):
            return .failure(failure(-32602,
                                    "Coordinates are outside the screen in points.",
                                    reason: String(format: "valid x %.0f...%.0f, valid y %.0f...%.0f",
                                                   validX.lowerBound, validX.upperBound,
                                                   validY.lowerBound, validY.upperBound)))
        }
    }

    func resolveRef(_ refID: String,
                    permit: BridgeRPCDispatchPermit,
                    generation: UInt64) -> TapResolution {
        guard let ref = refs.resolve(refID) else {
            return .failure(invalidParams("Unknown element ref '\(refID)'. Read find_element again."))
        }
        let app = XCUIApplication(bundleIdentifier: ref.bundleIdentifier)
        guard stateName(app) == "runningForeground" else {
            return .failure(failure(-32000,
                                    "The ref's app is no longer in the foreground; no action was taken.",
                                    reason: "activate_app first or find the element again."))
        }
        guard stepAllowed(permit, generation: generation) else { return .failure(.failure(.fenced)) }
        guard let root = sdk.snapshot(of: app) else {
            return .failure(failure(-32000, "The ref's app tree could not be read; no action was taken."))
        }
        guard stepAllowed(permit, generation: generation) else { return .failure(.failure(.fenced)) }
        let candidates = sdk.candidates(in: root, bundleIdentifier: ref.bundleIdentifier)
        let matches: [BridgeEngineElementCandidate]
        if !ref.identifier.isEmpty {
            matches = candidates.filter {
                $0.identifier == ref.identifier
                    && BridgeEngineElementType.matches($0.type, elementType: ref.type)
            }
        } else if !ref.label.isEmpty {
            matches = candidates.filter {
                $0.label == ref.label
                    && BridgeEngineElementType.matches($0.type, elementType: ref.type)
            }
        } else {
            matches = []
        }
        if matches.count == 1, !matches[0].frame.isEmpty {
            return .success(ResolvedTapTarget(
                point: BridgeEngineGeometry.center(of: matches[0].frame),
                note: nil,
                bundleIdentifier: ref.bundleIdentifier
            ))
        }
        if matches.count > 1 {
            return .failure(invalidParams("The ref now matches multiple elements; no action was taken."))
        }
        if !ref.frame.isEmpty {
            return .success(ResolvedTapTarget(
                point: BridgeEngineGeometry.center(of: ref.frame),
                note: "The element was not re-found; the stored frame center was used and may be stale.",
                bundleIdentifier: ref.bundleIdentifier
            ))
        }
        return .failure(invalidParams("The ref's element no longer exists and has no usable stored frame."))
    }

    func appFrameAndOffset(app: XCUIApplication,
                           point: BridgeEnginePoint,
                           permit: BridgeRPCDispatchPermit,
                           generation: UInt64) -> (XCUICoordinate, BridgeUIRect)? {
        guard stepAllowed(permit, generation: generation),
              let frame = appFrame(app),
              frame.width > 1, frame.height > 1,
              BridgeEngineGeometry.contains(frame, point: point, tolerance: 1) else { return nil }
        guard let offset = BridgeEngineGeometry.normalizedOffset(point: point, in: frame) else { return nil }
        let coordinate = app.coordinate(withNormalizedOffset: CGVector(dx: offset.dx, dy: offset.dy))
        return (coordinate, frame)
    }

    /// Executes one synthesized touch and classifies what is actually known.
    /// Returns nil only after a clean return; a thrown or issue-recording call
    /// is an unknown side effect, never a success. The same live
    /// per-invocation guard runs immediately before the SDK call.
    func performTouch(stage: String,
                      targetBundle: String,
                      permit: BridgeRPCDispatchPermit,
                      generation: UInt64,
                      _ body: @escaping () -> Void) -> BridgeRPCExecutionOutcome? {
        switch guardedCall(stage: stage,
                           targetBundle: targetBundle,
                           permit: permit,
                           generation: generation,
                           { sdk.call(stage: stage) { body() } }) {
        case .denied(let outcome):
            return outcome
        case .value(let result):
            if result.error != nil || result.outcome.recordedIssueCount > 0 {
                return .sideEffectUnknown(
                    code: "touch_outcome_unknown",
                    message: "The touch call was entered but did not return cleanly; whether it took effect is unknown. Do not retry blindly."
                )
            }
            return nil
        }
    }

    func settleReport(before: [UInt8]?,
                      requested: Bool,
                      timeout: TimeInterval,
                      permit: BridgeRPCDispatchPermit,
                      generation: UInt64) async -> SettleStepResult {
        guard requested else { return .success(nil) }
        let started = Date()
        var last = before
        var changed: Bool = false
        var stable = false
        var stableFrames = 0
        var samples = 0
        let deadline = started.addingTimeInterval(max(0, timeout))
        while Date() < deadline {
            guard stepAllowed(permit, generation: generation) else {
                return .failure(.failure(.fenced))
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard stepAllowed(permit, generation: generation) else {
                return .failure(.failure(.fenced))
            }
            guard let capture = sdk.captureScreen(),
                  let fingerprint = sdk.fingerprint(capture.image) else { break }
            samples += 1
            if let previous = last {
                let difference = sdk.screenDifference(previous, fingerprint)
                if difference > 0.02 {
                    changed = true
                    stableFrames = 0
                } else {
                    stableFrames += 1
                    if stableFrames >= 2 {
                        stable = true
                        last = fingerprint
                        break
                    }
                }
            }
            last = fingerprint
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        return .success(SettleReport(stable: stable,
                                     changed: last == nil ? nil : changed,
                                     waitedMilliseconds: elapsed,
                                     samples: samples))
    }

    func settleJSON(_ report: SettleReport?) -> BridgeRPCJSONValue? {
        guard let report else { return nil }
        return .object([
            "stable": .bool(report.stable),
            "changed": report.changed.map { .bool($0) } ?? .null,
            "waited_ms": .int(report.waitedMilliseconds),
            "samples": .int(report.samples),
            "basis": .string("16x16 screen fingerprint"),
        ])
    }

    func captureBaseline(permit: BridgeRPCDispatchPermit,
                         generation: UInt64) -> [UInt8]? {
        guard stepAllowed(permit, generation: generation),
              let capture = sdk.captureScreen() else { return nil }
        return sdk.fingerprint(capture.image)
    }

    // MARK: - tap / double_tap / long_press

    func tap(_ params: BridgeEngineParameters,
             permit: BridgeRPCDispatchPermit,
             generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        let settle = try BridgeEngineSettleParameters.parse(params)
        let refID = try params.string("ref", maximumBytes: 128)
        let x = try params.double("x")
        let y = try params.double("y")
        _ = try params.bool("fast")
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        guard let app = targetApp(nil) else {
            return failure(-32000, "No foreground app was observed; no tap was performed.")
        }
        guard let metrics = sdk.screenMetrics() else {
            return failure(-32000, "The screen metrics could not be read; no tap was performed.")
        }
        let baseline = settle.requested ? captureBaseline(permit: permit, generation: generation) : nil
        let target: ResolvedTapTarget
        if let refID {
            switch resolveRef(refID, permit: permit, generation: generation) {
            case .success(let value): target = value
            case .failure(let outcome): return outcome
            }
        } else {
            guard let x, let y else {
                throw BridgeEngineParameterError("tap requires either ref or both x and y points.")
            }
            switch resolvedPoint(x: x, y: y, metrics: metrics) {
            case .success(let point):
                target = ResolvedTapTarget(point: point, note: nil,
                                           bundleIdentifier: app.bundle)
            case .failure(let outcome):
                return outcome
            }
        }
        let tapApp = XCUIApplication(bundleIdentifier: target.bundleIdentifier)
        guard stateName(tapApp) == "runningForeground" else {
            return failure(-32000, "The target app is not in the foreground; no tap was performed.")
        }
        guard let (coordinate, _) = appFrameAndOffset(app: tapApp,
                                                      point: target.point,
                                                      permit: permit,
                                                      generation: generation) else {
            return failure(-32000, "The tap point is outside the target app; no tap was performed.")
        }
        if let outcome = performTouch(stage: "tap", targetBundle: target.bundleIdentifier, permit: permit, generation: generation, {
            coordinate.tap()
        }) { return outcome }
        let settled = await settleAfterMutation(settle,
                                                before: baseline,
                                                permit: permit,
                                                generation: generation)
        if let fence = settled.fence { return fence }
        let settleResult = settled.report
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "The tap was dispatched but the engine lifecycle changed; the effect is unknown.")
        }
        markControlled(target.bundleIdentifier)
        var result: [String: BridgeRPCJSONValue] = [
            "message": .string("Tap dispatched at \(Int(target.point.x)),\(Int(target.point.y)) points."),
            "screen": screenJSON(metrics),
            "coordinate_space": .string("points"),
            "tap_dispatched": .bool(true),
        ]
        if let note = target.note { result["note"] = .string(note) }
        if let settleValue = settleJSON(settleResult) { result["settle"] = settleValue }
        return .success(.object(result))
    }

    /// Settle is optional and returns nil only when the lifecycle was fenced.
    func awaitSettle(_ parameters: BridgeEngineSettleParameters,
                     before: [UInt8]?,
                     permit: BridgeRPCDispatchPermit,
                     generation: UInt64) async throws -> SettleReport? {
        let result = await settleReport(before: before,
                                        requested: parameters.requested,
                                        timeout: parameters.timeout,
                                        permit: permit,
                                        generation: generation)
        switch result {
        case .success(let report): return report
        case .failure(let outcome): throw SettleFence(outcome: outcome)
        }
    }

    struct SettleFence: Error {
        let outcome: BridgeRPCExecutionOutcome
    }

    /// Settle after a mutation. A fence here means the action was already
    /// dispatched; it must never be reported as a clean not-dispatched failure.
    func settleAfterMutation(_ parameters: BridgeEngineSettleParameters,
                             before: [UInt8]?,
                             permit: BridgeRPCDispatchPermit,
                             generation: UInt64) async -> (report: SettleReport?, fence: BridgeRPCExecutionOutcome?) {
        do {
            let report = try await awaitSettle(parameters,
                                               before: before,
                                               permit: permit,
                                               generation: generation)
            return (report, nil)
        } catch let fence as SettleFence {
            switch fence.outcome {
            case .failure:
                return (nil, .sideEffectUnknown(
                    code: "lifecycle_changed",
                    message: "The action was dispatched but the engine lifecycle changed while observing the screen; the effect is unknown."
                ))
            case .sideEffectUnknown, .success:
                return (nil, fence.outcome)
            }
        } catch {
            return (nil, .failure(BridgeRPCError(code: BridgeRPCError.internalError.code,
                                                message: "The action settle failed.")))
        }
    }

    func doubleTap(_ params: BridgeEngineParameters,
                   permit: BridgeRPCDispatchPermit,
                   generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        let settle = try BridgeEngineSettleParameters.parse(params)
        let refID = try params.string("ref", maximumBytes: 128)
        let x = try params.double("x")
        let y = try params.double("y")
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        guard let app = targetApp(nil), let metrics = sdk.screenMetrics() else {
            return failure(-32000, "No foreground app or screen metrics; no double tap was performed.")
        }
        let baseline = settle.requested ? captureBaseline(permit: permit, generation: generation) : nil
        let target: ResolvedTapTarget
        switch try resolvePointTarget(refID: refID, x: x, y: y, metrics: metrics,
                                      appBundle: app.bundle,
                                      permit: permit, generation: generation) {
        case .success(let value): target = value
        case .failure(let outcome): return outcome
        }
        let tapApp = XCUIApplication(bundleIdentifier: target.bundleIdentifier)
        guard stateName(tapApp) == "runningForeground",
              let frame = appFrame(tapApp),
              BridgeEngineGeometry.contains(frame, point: target.point, tolerance: 1),
              let offset = BridgeEngineGeometry.normalizedOffset(point: target.point, in: frame) else {
            return failure(-32000, "The target app or point is not usable; no double tap was performed.")
        }
        let coordinate = tapApp.coordinate(withNormalizedOffset: CGVector(dx: offset.dx, dy: offset.dy))
        if let outcome = performTouch(stage: "double-tap", targetBundle: target.bundleIdentifier, permit: permit, generation: generation, {
            coordinate.doubleTap()
        }) { return outcome }
        let settled = await settleAfterMutation(settle, before: baseline,
                                                permit: permit, generation: generation)
        if let fence = settled.fence { return fence }
        let report = settled.report
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "The double tap was dispatched but the engine lifecycle changed; the effect is unknown.")
        }
        var result: [String: BridgeRPCJSONValue] = [
            "message": .string("Double tap dispatched."),
            "screen": screenJSON(metrics),
            "tap_dispatched": .bool(true),
        ]
        if let report, let value = settleJSON(report) { result["settle"] = value }
        return .success(.object(result))
    }

    func longPress(_ params: BridgeEngineParameters,
                   permit: BridgeRPCDispatchPermit,
                   generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        let settle = try BridgeEngineSettleParameters.parse(params)
        let duration = try params.number("duration", default: 1.0, range: 0.1...10.0)
        let refID = try params.string("ref", maximumBytes: 128)
        let x = try params.double("x")
        let y = try params.double("y")
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        guard let app = targetApp(nil), let metrics = sdk.screenMetrics() else {
            return failure(-32000, "No foreground app or screen metrics; no long press was performed.")
        }
        let baseline = settle.requested ? captureBaseline(permit: permit, generation: generation) : nil
        let target: ResolvedTapTarget
        switch try resolvePointTarget(refID: refID, x: x, y: y, metrics: metrics,
                                      appBundle: app.bundle,
                                      permit: permit, generation: generation) {
        case .success(let value): target = value
        case .failure(let outcome): return outcome
        }
        let tapApp = XCUIApplication(bundleIdentifier: target.bundleIdentifier)
        guard stateName(tapApp) == "runningForeground",
              let frame = appFrame(tapApp),
              BridgeEngineGeometry.contains(frame, point: target.point, tolerance: 1),
              let offset = BridgeEngineGeometry.normalizedOffset(point: target.point, in: frame) else {
            return failure(-32000, "The target app or point is not usable; no long press was performed.")
        }
        let coordinate = tapApp.coordinate(withNormalizedOffset: CGVector(dx: offset.dx, dy: offset.dy))
        if let outcome = performTouch(stage: "long-press", targetBundle: target.bundleIdentifier, permit: permit, generation: generation, {
            coordinate.press(forDuration: duration)
        }) { return outcome }
        let settled = await settleAfterMutation(settle, before: baseline,
                                                permit: permit, generation: generation)
        if let fence = settled.fence { return fence }
        let report = settled.report
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "The long press was dispatched but the engine lifecycle changed; the effect is unknown.")
        }
        var result: [String: BridgeRPCJSONValue] = [
            "message": .string("Long press dispatched."),
            "screen": screenJSON(metrics),
            "duration": .double(duration),
            "tap_dispatched": .bool(true),
        ]
        if let report, let value = settleJSON(report) { result["settle"] = value }
        return .success(.object(result))
    }

    func resolvePointTarget(refID: String?,
                            x: Double?,
                            y: Double?,
                            metrics: BridgeEngineScreenMetrics,
                            appBundle: String,
                            permit: BridgeRPCDispatchPermit,
                            generation: UInt64) throws -> TapResolution {
        if let refID {
            return resolveRef(refID, permit: permit, generation: generation)
        }
        guard let x, let y else {
            throw BridgeEngineParameterError("This action requires either ref or both x and y points.")
        }
        switch resolvedPoint(x: x, y: y, metrics: metrics) {
        case .success(let point):
            return .success(ResolvedTapTarget(point: point, note: nil, bundleIdentifier: appBundle))
        case .failure(let outcome):
            return .failure(outcome)
        }
    }

    // MARK: - swipe / page / scroll / drag

    func swipe(_ params: BridgeEngineParameters,
               permit: BridgeRPCDispatchPermit,
               generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        let settle = try BridgeEngineSettleParameters.parse(params)
        let direction = try params.option("direction", allowed: ["up", "down", "left", "right"], default: "up") ?? "up"
        let requestedDistance = try params.double("distance")
        if let requestedDistance, !(1...10_000).contains(requestedDistance) {
            throw BridgeEngineParameterError("Parameter 'distance' must be between 1 and 10000 points.")
        }
        let velocity = try params.option("velocity", allowed: ["fast", "flick", "normal", "slow", "precise"], default: "normal") ?? "normal"
        let x = try params.double("x")
        let y = try params.double("y")
        if (x != nil) != (y != nil) {
            throw BridgeEngineParameterError("swipe requires both x and y, or neither.")
        }
        _ = try params.bool("fast")
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        guard let app = targetApp(nil), let metrics = sdk.screenMetrics() else {
            return failure(-32000, "No foreground app or screen metrics; no swipe was performed.")
        }
        let startPoint: BridgeEnginePoint
        if let x, let y {
            switch resolvedPoint(x: x, y: y, metrics: metrics) {
            case .success(let point): startPoint = point
            case .failure(let outcome): return outcome
            }
        } else {
            startPoint = BridgeEnginePoint(x: metrics.pointWidth / 2, y: metrics.pointHeight / 2)
        }
        let defaultTravel = min(metrics.pointWidth, metrics.pointHeight) * 0.5
        let travel = min(max(requestedDistance ?? defaultTravel, 1),
                         max(metrics.pointWidth, metrics.pointHeight) * 0.9)
        var endPoint = startPoint
        switch direction {
        case "up": endPoint.y -= travel
        case "down": endPoint.y += travel
        case "left": endPoint.x -= travel
        case "right": endPoint.x += travel
        default: break
        }
        endPoint.x = min(max(endPoint.x, 2), metrics.pointWidth - 2)
        endPoint.y = min(max(endPoint.y, 2), metrics.pointHeight - 2)
        let gestureVelocity = Self.gestureVelocity(velocity)
        let baseline = settle.requested ? captureBaseline(permit: permit, generation: generation) : nil
        guard stateName(app.app) == "runningForeground",
              let frame = appFrame(app.app),
              let clampedStart = BridgeEngineGeometry.clamped(startPoint, to: frame),
              let clampedEnd = BridgeEngineGeometry.clamped(endPoint, to: frame),
              let startOffset = BridgeEngineGeometry.normalizedOffset(point: clampedStart, in: frame),
              let endOffset = BridgeEngineGeometry.normalizedOffset(point: clampedEnd, in: frame) else {
            return failure(-32000, "The swipe endpoints are outside the app; no swipe was performed.")
        }
        let startCoordinate = app.app.coordinate(withNormalizedOffset: CGVector(dx: startOffset.dx, dy: startOffset.dy))
        let endCoordinate = app.app.coordinate(withNormalizedOffset: CGVector(dx: endOffset.dx, dy: endOffset.dy))
        if let outcome = performTouch(stage: "swipe", targetBundle: app.bundle, permit: permit, generation: generation, {
            startCoordinate.press(forDuration: 0.05,
                                  thenDragTo: endCoordinate,
                                  withVelocity: gestureVelocity,
                                  thenHoldForDuration: 0)
        }) { return outcome }
        let settled = await settleAfterMutation(settle, before: baseline,
                                                permit: permit, generation: generation)
        if let fence = settled.fence { return fence }
        let report = settled.report
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "The swipe was dispatched but the engine lifecycle changed; the effect is unknown.")
        }
        markControlled(app.bundle)
        var result: [String: BridgeRPCJSONValue] = [
            "message": .string("Swipe dispatched."),
            "from": .object(["x": .double(clampedStart.x), "y": .double(clampedStart.y)]),
            "to": .object(["x": .double(clampedEnd.x), "y": .double(clampedEnd.y)]),
            "velocity": .string(velocity),
            "coordinate_space": .string("points"),
            "swipe_dispatched": .bool(true),
        ]
        if let report, let value = settleJSON(report) { result["settle"] = value }
        return .success(.object(result))
    }

    static func gestureVelocity(_ name: String) -> XCUIGestureVelocity {
        switch name {
        case "fast", "flick": return .fast
        case "slow", "precise": return .slow
        default: return .default
        }
    }

    /// One full-page gesture. Used by page/collect/scroll_to_element.
    func pageOnce(direction: String,
                  metrics: BridgeEngineScreenMetrics,
                  app: XCUIApplication,
                  bundle: String,
                  permit: BridgeRPCDispatchPermit,
                  generation: UInt64) -> BridgeRPCExecutionOutcome? {
        let startY = direction == "down" ? metrics.pointHeight * 0.82 : metrics.pointHeight * 0.18
        let endY = direction == "down" ? metrics.pointHeight * 0.18 : metrics.pointHeight * 0.82
        guard let frame = appFrame(app),
              let clampedStart = BridgeEngineGeometry.clamped(
                BridgeEnginePoint(x: metrics.pointWidth / 2, y: startY), to: frame),
              let clampedEnd = BridgeEngineGeometry.clamped(
                BridgeEnginePoint(x: metrics.pointWidth / 2, y: endY), to: frame),
              let startOffset = BridgeEngineGeometry.normalizedOffset(point: clampedStart, in: frame),
              let endOffset = BridgeEngineGeometry.normalizedOffset(point: clampedEnd, in: frame) else {
            return failure(-32000, "The app frame is not usable; no page gesture was performed.")
        }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: startOffset.dx, dy: startOffset.dy))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: endOffset.dx, dy: endOffset.dy))
        return performTouch(stage: "page", targetBundle: bundle, permit: permit, generation: generation) {
            start.press(forDuration: 0.05,
                        thenDragTo: end,
                        withVelocity: .default,
                        thenHoldForDuration: 0)
        }
    }

    func page(_ params: BridgeEngineParameters,
              permit: BridgeRPCDispatchPermit,
              generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        let settleParameters = try BridgeEngineSettleParameters.parse(params)
        let direction = try params.option("direction", allowed: ["up", "down"], default: "down") ?? "down"
        let distance = try params.integer("distance", default: 1, range: 1...5)
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        guard let app = targetApp(nil), let metrics = sdk.screenMetrics() else {
            return failure(-32000, "No foreground app or screen metrics; no page was performed.")
        }
        var moved = false
        var movementObserved = false
        for index in 0..<distance {
            guard stepAllowed(permit, generation: generation) else {
                return index == 0 ? .failure(.fenced) : .sideEffectUnknown(
                    code: "lifecycle_changed",
                    message: "Some pages were dispatched before the lifecycle changed; the final position is unknown."
                )
            }
            let before = sdk.captureScreen().flatMap { sdk.fingerprint($0.image) }
            if let outcome = pageOnce(direction: direction, metrics: metrics, app: app.app, bundle: app.bundle,
                                      permit: permit, generation: generation) {
                return outcome
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard stepAllowed(permit, generation: generation) else {
                return .sideEffectUnknown(code: "lifecycle_changed",
                                          message: "A page was dispatched before the lifecycle changed; the final position is unknown.")
            }
            if let before, let afterCapture = sdk.captureScreen(),
               let after = sdk.fingerprint(afterCapture.image) {
                movementObserved = true
                if sdk.screenDifference(before, after) > 0.02 {
                    moved = true
                }
            }
        }
        let settled = await settleAfterMutation(settleParameters,
                                                before: nil,
                                                permit: permit,
                                                generation: generation)
        if let fence = settled.fence { return fence }
        let report = settled.report
        var result: [String: BridgeRPCJSONValue] = [
            "message": .string("Page gesture dispatched \(distance) time(s)."),
            "screen": screenJSON(metrics),
            "moved": .bool(moved),
            "pages": .int(distance),
        ]
        markControlled(app.bundle)
        if !moved {
            if movementObserved {
                result["at_end"] = .bool(true)
                result["hint"] = .string("No visible screen change was observed; this may be the end (or the page cannot scroll). Read before concluding.")
            } else {
                result["hint"] = .string("The page was dispatched but screen movement could not be measured; read before concluding.")
            }
        }
        if let report, let value = settleJSON(report) { result["settle"] = value }
        return .success(.object(result))
    }

    func legacyScroll(_ params: BridgeEngineParameters,
                      permit: BridgeRPCDispatchPermit,
                      generation: UInt64) throws -> BridgeRPCExecutionOutcome {
        _ = try BridgeEngineSettleParameters.parse(params)
        let direction = try params.option("direction", allowed: ["up", "down", "left", "right"], default: "up") ?? "up"
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        guard let app = targetApp(nil), let metrics = sdk.screenMetrics() else {
            return failure(-32000, "No foreground app or screen metrics; no scroll was performed.")
        }
        let start: BridgeEnginePoint
        let end: BridgeEnginePoint
        let midY = metrics.pointHeight / 2
        let midX = metrics.pointWidth / 2
        switch direction {
        case "down":
            start = BridgeEnginePoint(x: midX, y: metrics.pointHeight * 0.75)
            end = BridgeEnginePoint(x: midX, y: metrics.pointHeight * 0.25)
        case "up":
            start = BridgeEnginePoint(x: midX, y: metrics.pointHeight * 0.25)
            end = BridgeEnginePoint(x: midX, y: metrics.pointHeight * 0.75)
        case "left":
            start = BridgeEnginePoint(x: metrics.pointWidth * 0.8, y: midY)
            end = BridgeEnginePoint(x: metrics.pointWidth * 0.2, y: midY)
        default:
            start = BridgeEnginePoint(x: metrics.pointWidth * 0.2, y: midY)
            end = BridgeEnginePoint(x: metrics.pointWidth * 0.8, y: midY)
        }
        guard let frame = appFrame(app.app),
              let clampedStart = BridgeEngineGeometry.clamped(start, to: frame),
              let clampedEnd = BridgeEngineGeometry.clamped(end, to: frame),
              let startOffset = BridgeEngineGeometry.normalizedOffset(point: clampedStart, in: frame),
              let endOffset = BridgeEngineGeometry.normalizedOffset(point: clampedEnd, in: frame) else {
            return failure(-32000, "The app frame is not usable; no scroll was performed.")
        }
        let startCoordinate = app.app.coordinate(withNormalizedOffset: CGVector(dx: startOffset.dx, dy: startOffset.dy))
        let endCoordinate = app.app.coordinate(withNormalizedOffset: CGVector(dx: endOffset.dx, dy: endOffset.dy))
        if let outcome = performTouch(stage: "scroll", targetBundle: app.bundle, permit: permit, generation: generation, {
            startCoordinate.press(forDuration: 0.05,
                                  thenDragTo: endCoordinate,
                                  withVelocity: .default,
                                  thenHoldForDuration: 0)
        }) { return outcome }
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "The scroll was dispatched but the engine lifecycle changed; the effect is unknown.")
        }
        markControlled(app.bundle)
        return .success(.object([
            "message": .string("Scroll dispatched. Use swipe or page for bounded scrolling."),
            "scroll_dispatched": .bool(true),
        ]))
    }

    func drag(_ params: BridgeEngineParameters,
              permit: BridgeRPCDispatchPermit,
              generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        let settle = try BridgeEngineSettleParameters.parse(params)
        let duration = try params.number("duration", default: 1.0, range: 0.1...10.0)
        let pointsValues = try params.array("points")
        let fromX = try params.double("from_x")
        let fromY = try params.double("from_y")
        let toX = try params.double("to_x")
        let toY = try params.double("to_y")
        let fromRef = try params.string("from_ref", maximumBytes: 128)
        let toRef = try params.string("to_ref", maximumBytes: 128)
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        guard let app = targetApp(nil), let metrics = sdk.screenMetrics() else {
            return failure(-32000, "No foreground app or screen metrics; no drag was performed.")
        }
        var screenPoints: [BridgeEnginePoint] = []
        if let pointsValues {
            guard (2...64).contains(pointsValues.count) else {
                throw BridgeEngineParameterError("drag points must contain 2...64 {x,y} objects.")
            }
            guard fromX == nil, fromY == nil, toX == nil, toY == nil,
                  fromRef == nil, toRef == nil else {
                throw BridgeEngineParameterError("drag points cannot be combined with endpoints or refs.")
            }
            for value in pointsValues {
                guard let object = value.objectValue,
                      let x = object["x"]?.doubleValue,
                      let y = object["y"]?.doubleValue else {
                    throw BridgeEngineParameterError("Each drag point requires numeric x and y.")
                }
                switch resolvedPoint(x: x, y: y, metrics: metrics) {
                case .success(let point): screenPoints.append(point)
                case .failure(let outcome): return outcome
                }
            }
        } else if let fromRef, let toRef {
            switch resolveRef(fromRef, permit: permit, generation: generation) {
            case .success(let resolved): screenPoints.append(resolved.point)
            case .failure(let outcome): return outcome
            }
            switch resolveRef(toRef, permit: permit, generation: generation) {
            case .success(let resolved): screenPoints.append(resolved.point)
            case .failure(let outcome): return outcome
            }
        } else if let fromX, let fromY, let toX, let toY {
            switch resolvedPoint(x: fromX, y: fromY, metrics: metrics) {
            case .success(let point): screenPoints.append(point)
            case .failure(let outcome): return outcome
            }
            switch resolvedPoint(x: toX, y: toY, metrics: metrics) {
            case .success(let point): screenPoints.append(point)
            case .failure(let outcome): return outcome
            }
        } else {
            throw BridgeEngineParameterError("drag requires points, from_ref/to_ref, or from_x/from_y/to_x/to_y.")
        }
        guard let frame = appFrame(app.app),
              BridgeEngineGeometry.contains(frame, point: screenPoints[0], tolerance: 1),
              let firstOffset = BridgeEngineGeometry.normalizedOffset(point: screenPoints[0], in: frame) else {
            return failure(-32000, "The drag start is outside the app; no drag was performed.")
        }
        let baseline = settle.requested ? captureBaseline(permit: permit, generation: generation) : nil
        guard screenPoints.allSatisfy({
            BridgeEngineGeometry.contains(frame, point: $0, tolerance: 1)
        }) else {
            return failure(-32000, "A drag waypoint is outside the app; no drag was performed.")
        }
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
        if screenPoints.count > 2 {
            guard BRContinuousDragAvailable() else {
                return methodNotAvailable("The private continuous-drag path is unavailable; use two-point endpoints or swipe.")
            }
            let values = screenPoints.map { NSValue(cgPoint: CGPoint(x: $0.x, y: $0.y)) }
            var dragError: NSError?
            var dragged = false
            let guarded = guardedCall(stage: "continuous-drag",
                                      targetBundle: app.bundle,
                                      permit: permit,
                                      generation: generation) {
                sdk.call(stage: "continuous-drag") {
                    dragged = BRContinuousDrag(values, duration, &dragError)
                }
            }
            let result: BridgeEngineSDKCallResult
            switch guarded {
            case .denied(let outcome):
                return outcome
            case .value(let value):
                result = value
            }
            if !dragged || result.error != nil || result.outcome.recordedIssueCount > 0 || dragError != nil {
                return .sideEffectUnknown(code: "drag_outcome_unknown",
                                          message: "The continuous drag was entered but did not return cleanly; the effect is unknown.")
            }
        } else {
            guard BridgeEngineGeometry.contains(frame, point: screenPoints[1], tolerance: 1),
                  let lastOffset = BridgeEngineGeometry.normalizedOffset(point: screenPoints[1], in: frame) else {
                return failure(-32000, "The drag end is outside the app; no drag was performed.")
            }
            let start = app.app.coordinate(withNormalizedOffset: CGVector(dx: firstOffset.dx, dy: firstOffset.dy))
            let end = app.app.coordinate(withNormalizedOffset: CGVector(dx: lastOffset.dx, dy: lastOffset.dy))
            if let outcome = performTouch(stage: "drag", targetBundle: app.bundle, permit: permit, generation: generation, {
                start.press(forDuration: 0.05,
                            thenDragTo: end,
                            withVelocity: .default,
                            thenHoldForDuration: 0)
            }) { return outcome }
        }
        let settled = await settleAfterMutation(settle, before: baseline,
                                                permit: permit, generation: generation)
        if let fence = settled.fence { return fence }
        let report = settled.report
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "The drag was dispatched but the engine lifecycle changed; the effect is unknown.")
        }
        var result: [String: BridgeRPCJSONValue] = [
            "message": .string("Drag dispatched."),
            "screen": screenJSON(metrics),
            "drag_dispatched": .bool(true),
            "waypoint_count": .int(screenPoints.count),
        ]
        if let report, let value = settleJSON(report) { result["settle"] = value }
        return .success(.object(result))
    }

    // MARK: - wait

    func wait(_ params: BridgeEngineParameters,
              permit: BridgeRPCDispatchPermit,
              generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        let duration = try params.number("duration", default: 0.5, range: 0...30)
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
            let remaining = deadline.timeIntervalSinceNow
            let slice = min(0.1, max(0, remaining))
            if slice > 0 {
                try? await Task.sleep(for: .milliseconds(Int(slice * 1_000)))
            } else {
                break
            }
        }
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
        return .success(.object(["message": .string("Waited \(duration)s.")]))
    }
}

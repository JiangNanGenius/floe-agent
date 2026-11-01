import Foundation
import UIKit
import XCTest
import BridgeCore

@MainActor
extension BridgeEngineRPCRuntime {

    struct LocatedElement {
        var bundleIdentifier: String
        var app: XCUIApplication
        var match: BridgeEngineElementMatch
        var ref: BridgeEngineElementRef
    }

    enum LocatedResult {
        case success(LocatedElement)
        case failure(BridgeRPCExecutionOutcome)
    }

    /// Finds exactly one element or returns a terminal outcome. Ambiguity is
    /// never guessed into a tap.
    func locateUniqueElement(query: String,
                             mode: BridgeEngineMatchMode,
                             elementType: String?,
                             requestedBundle: String?,
                             createRef: Bool,
                             permit: BridgeRPCDispatchPermit,
                             generation: UInt64) -> LocatedResult {
        guard let target = targetApp(requestedBundle) else {
            return .failure(failure(-32000, "No foreground app was observed; no element was searched."))
        }
        guard stateName(target.app) == "runningForeground" else {
            return .failure(failure(-32000, "The target app is not in the foreground; no element was searched."))
        }
        guard let root = sdk.snapshot(of: target.app) else {
            return .failure(failure(-32000, "The accessibility tree could not be read."))
        }
        guard stepAllowed(permit, generation: generation) else {
            return .failure(.failure(.fenced))
        }
        let candidates = sdk.candidates(in: root, bundleIdentifier: target.bundle)
        let matches = BridgeEngineElementSelector.matches(candidates: candidates,
                                                          query: query,
                                                          mode: mode,
                                                          elementType: elementType)
        switch BridgeEngineElementSelector.selectUnique(matches) {
        case .missing:
            return .failure(failure(-32000, "No element matched the query."))
        case .ambiguous(let count):
            return .failure(failure(-32602,
                                    "Multiple elements matched; no action was taken.",
                                    reason: "match_count=\(count)"))
        case .unique(let match):
            let ref: BridgeEngineElementRef
            if createRef {
                ref = refs.store(bundleIdentifier: target.bundle, candidate: match.candidate)
            } else {
                ref = BridgeEngineElementRef(id: "",
                                             bundleIdentifier: target.bundle,
                                             identifier: match.candidate.identifier,
                                             label: match.candidate.label,
                                             type: match.candidate.type,
                                             frame: match.candidate.frame)
            }
            return .success(LocatedElement(bundleIdentifier: target.bundle,
                                           app: target.app,
                                           match: match,
                                           ref: ref))
        }
    }

    func tapElement(_ params: BridgeEngineParameters,
                    permit: BridgeRPCDispatchPermit,
                    generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        let settle = try BridgeEngineSettleParameters.parse(params)
        let query = try params.requiredString("element_id", maximumBytes: 4_096)
        guard !query.isEmpty else {
            throw BridgeEngineParameterError("Parameter 'element_id' must not be empty.")
        }
        let mode: BridgeEngineMatchMode = (try params.option("match",
                                                             allowed: ["exact", "contains"],
                                                             default: "exact") ?? "exact") == "exact" ? .exact : .contains
        let type = try params.string("element_type", maximumBytes: 128)
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        let located: LocatedElement
        switch locateUniqueElement(query: query,
                                   mode: mode,
                                   elementType: type,
                                   requestedBundle: nil,
                                   createRef: false,
                                   permit: permit,
                                   generation: generation) {
        case .success(let value): located = value
        case .failure(let outcome): return outcome
        }
        guard let metrics = sdk.screenMetrics(),
              let frame = appFrame(located.app),
              BridgeEngineGeometry.contains(frame, point: BridgeEngineGeometry.center(of: located.match.candidate.frame), tolerance: 1),
              let offset = BridgeEngineGeometry.normalizedOffset(
                point: BridgeEngineGeometry.center(of: located.match.candidate.frame),
                in: frame) else {
            return failure(-32000, "The element has no usable on-screen frame; no tap was performed.")
        }
        let baseline = settle.requested ? captureBaseline(permit: permit, generation: generation) : nil
        let coordinate = located.app.coordinate(withNormalizedOffset: CGVector(dx: offset.dx, dy: offset.dy))
        if let outcome = performTouch(stage: "tap-element",
                                      targetBundle: located.bundleIdentifier,
                                      permit: permit,
                                      generation: generation,
                                      {
            coordinate.tap()
        }) { return outcome }
        let settled = await settleAfterMutation(settle, before: baseline,
                                                permit: permit, generation: generation)
        if let fence = settled.fence { return fence }
        let report = settled.report
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "The element tap was dispatched but the engine lifecycle changed; the effect is unknown.")
        }
        markControlled(located.bundleIdentifier)
        var result: [String: BridgeRPCJSONValue] = [
            "message": .string("Element tapped."),
            "screen": screenJSON(metrics),
            "bundle_id": .string(located.bundleIdentifier),
            "label": .string(located.match.candidate.label),
            "tap_dispatched": .bool(true),
        ]
        if let report, let value = settleJSON(report) { result["settle"] = value }
        return .success(.object(result))
    }

    func findAndTap(_ params: BridgeEngineParameters,
                    permit: BridgeRPCDispatchPermit,
                    generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        let settle = try BridgeEngineSettleParameters.parse(params)
        let query = try params.requiredString("element_id", maximumBytes: 4_096)
        guard !query.isEmpty else {
            throw BridgeEngineParameterError("Parameter 'element_id' must not be empty.")
        }
        let mode: BridgeEngineMatchMode = (try params.option("match",
                                                             allowed: ["exact", "contains"],
                                                             default: "exact") ?? "exact") == "exact" ? .exact : .contains
        let type = try params.string("element_type", maximumBytes: 128)
        let requestedBundle = try params.string("bundle_id", maximumBytes: 256)
        let fast = try params.bool("fast") ?? true
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        let located: LocatedElement
        switch locateUniqueElement(query: query,
                                   mode: mode,
                                   elementType: type,
                                   requestedBundle: requestedBundle,
                                   createRef: false,
                                   permit: permit,
                                   generation: generation) {
        case .success(let value): located = value
        case .failure(let outcome): return outcome
        }
        guard let metrics = sdk.screenMetrics(),
              let frame = appFrame(located.app) else {
            return failure(-32000, "The target app frame could not be read; no tap was performed.")
        }
        let center = BridgeEngineGeometry.center(of: located.match.candidate.frame)
        let baseline = settle.requested ? captureBaseline(permit: permit, generation: generation) : nil
        var usedNative = false
        if !fast,
           let live = sdk.liveElement(app: located.app,
                                      identifier: located.match.candidate.identifier,
                                      label: located.match.candidate.label,
                                      type: located.match.candidate.type),
           live.matchCount == 1 {
            guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
            let guarded = guardedCall(stage: "native-element-tap",
                                      targetBundle: located.bundleIdentifier,
                                      permit: permit,
                                      generation: generation,
                                      { sdk.call(stage: "native-element-tap") { live.element.tap() } })
            let result: BridgeEngineSDKCallResult
            switch guarded {
            case .denied(let outcome):
                return outcome
            case .value(let value):
                result = value
            }
            if result.error != nil || result.outcome.recordedIssueCount > 0 {
                return .sideEffectUnknown(code: "tap_outcome_unknown",
                                          message: "The native element tap was entered but did not return cleanly; the effect is unknown.")
            }
            usedNative = true
        } else {
            guard BridgeEngineGeometry.contains(frame, point: center, tolerance: 1),
                  let offset = BridgeEngineGeometry.normalizedOffset(point: center, in: frame) else {
                return failure(-32000, "The element has no usable on-screen frame; no tap was performed.")
            }
            let coordinate = located.app.coordinate(withNormalizedOffset: CGVector(dx: offset.dx, dy: offset.dy))
            if let outcome = performTouch(stage: "find-and-tap",
                                          targetBundle: located.bundleIdentifier,
                                          permit: permit,
                                          generation: generation,
                                          {
                coordinate.tap()
            }) { return outcome }
        }
        let settled = await settleAfterMutation(settle, before: baseline,
                                                permit: permit, generation: generation)
        if let fence = settled.fence { return fence }
        let report = settled.report
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "The element tap was dispatched but the engine lifecycle changed; the effect is unknown.")
        }
        markControlled(located.bundleIdentifier)
        var result: [String: BridgeRPCJSONValue] = [
            "message": .string(usedNative ? "Element tapped through the native element pipeline." : "Element tapped by resolved center point."),
            "matched": .bool(true),
            "frame": .object([
                "x": .double(located.match.candidate.frame.x),
                "y": .double(located.match.candidate.frame.y),
                "width": .double(located.match.candidate.frame.width),
                "height": .double(located.match.candidate.frame.height),
            ]),
            "screen": screenJSON(metrics),
            "bundle_id": .string(located.bundleIdentifier),
            "label": .string(located.match.candidate.label),
            "nativeTap": .bool(usedNative),
            "tap_dispatched": .bool(true),
        ]
        if let report, let value = settleJSON(report) { result["settle"] = value }
        return .success(.object(result))
    }
}

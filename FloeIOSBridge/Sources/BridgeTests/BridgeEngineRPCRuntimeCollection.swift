import Foundation
import UIKit
import XCTest
import BridgeCore

@MainActor
extension BridgeEngineRPCRuntime {

    // MARK: - collect

    func collect(_ params: BridgeEngineParameters,
                 permit: BridgeRPCDispatchPermit,
                 generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        let pages = try params.integer("pages", default: 3, range: 0...8)
        let direction = try params.option("direction", allowed: ["up", "down"], default: "down") ?? "down"
        let minimumLength = try params.integer("min_length", default: 0, range: 0...512)
        let fresh = try params.bool("fresh") ?? false
        let source = try params.option("source", allowed: ["auto", "tree", "ocr"], default: "auto") ?? "auto"
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        guard let app = targetApp(nil), let metrics = sdk.screenMetrics() else {
            return failure(-32000, "No foreground app or screen metrics; no collection was performed.")
        }
        if fresh { state.resetCollected() }
        let started = Date()
        var screensRead = 0
        var atEnd = false
        var newItems: [String] = []
        var rounds = 0
        while rounds <= pages {
            guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
            var labels = sdk.snapshot(of: app.app).map {
                Self.treeLabels(from: $0, minimumLength: minimumLength)
            } ?? []
            if source == "ocr" || (source == "auto" && labels.isEmpty) {
                if case .success(let value)? = ocrItems(bundle: app.bundle,
                                                        permit: permit,
                                                        generation: generation,
                                                        query: nil,
                                                        fast: false,
                                                        minimumConfidence: BridgeEngineOCRGeometry.defaultMinimumConfidence),
                   let items = value.arrayValue {
                    labels = items.compactMap { $0.objectValue?["label"]?.stringValue }
                        .filter { $0.count >= minimumLength }
                }
            }
            let collected = state.collect(existing: true, labels: labels)
            newItems.append(contentsOf: collected.new)
            screensRead += 1
            guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
            if rounds == pages { break }
            let before = sdk.captureScreen().flatMap { sdk.fingerprint($0.image) }
            if let outcome = pageOnce(direction: direction,
                                      metrics: metrics,
                                      app: app.app,
                                      bundle: app.bundle,
                                      permit: permit,
                                      generation: generation) {
                return outcome
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard stepAllowed(permit, generation: generation) else {
                return .sideEffectUnknown(code: "lifecycle_changed",
                                          message: "A collection page was dispatched before the lifecycle changed; the final position is unknown.")
            }
            if let before, let after = sdk.captureScreen().flatMap({ sdk.fingerprint($0.image) }),
               sdk.screenDifference(before, after) <= 0.02 {
                atEnd = true
                break
            }
            rounds += 1
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        markControlled(app.bundle)
        return .success(.object([
            "items": .array(newItems.map { .string($0) }),
            "new_count": .int(newItems.count),
            "screens_read": .int(screensRead),
            "at_end": .bool(atEnd),
            "elapsed_ms": .int(elapsed),
            "hint": .string(atEnd
                            ? "No visible screen change on the last page; this may be the end."
                            : "Collected visible labels across the requested pages."),
        ]))
    }

    static func treeLabels(from node: BridgeEngineTreeNode, minimumLength: Int) -> [String] {
        var output: Set<String> = []
        var stack: [BridgeEngineTreeNode] = [node]
        var visited = 0
        while let value = stack.popLast(), visited < 4_000 {
            visited += 1
            let label = value.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isSecure, label.count >= minimumLength, !label.isEmpty {
                output.insert(label)
            }
            stack.append(contentsOf: value.children)
        }
        return Array(output).sorted()
    }

    // MARK: - scroll_to_element

    func scrollToElement(_ params: BridgeEngineParameters,
                         permit: BridgeRPCDispatchPermit,
                         generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        let query = try params.requiredString("element_id", maximumBytes: 4_096)
        guard !query.isEmpty else {
            throw BridgeEngineParameterError("Parameter 'element_id' must not be empty.")
        }
        let mode: BridgeEngineMatchMode = (try params.option("match",
                                                             allowed: ["exact", "contains"],
                                                             default: "exact") ?? "exact") == "exact" ? .exact : .contains
        let type = try params.string("element_type", maximumBytes: 128)
        let direction = try params.option("direction", allowed: ["up", "down"], default: "down") ?? "down"
        let distance = try params.integer("distance", default: 5, range: 1...20)
        let requestedBundle = try params.string("bundle_id", maximumBytes: 256)
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        guard let target = targetApp(requestedBundle), let metrics = sdk.screenMetrics() else {
            return failure(-32000, "No target app or screen metrics; no element was searched.")
        }
        guard appStateName(target.bundle) == "runningForeground" else {
            return failure(-32000, "The target app is not in the foreground; no element was searched.")
        }
        var swipes = 0
        var sawOffscreenMatch = false
        for index in 0...distance {
            guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
            guard let root = sdk.snapshot(of: target.app) else {
                return failure(-32000, "The accessibility tree could not be read.")
            }
            let candidates = sdk.candidates(in: root, bundleIdentifier: target.bundle)
            let matches = BridgeEngineElementSelector.matches(
                candidates: candidates,
                query: query,
                mode: mode,
                elementType: type
            )
            if case .unique(let match) = BridgeEngineElementSelector.selectUnique(matches) {
                guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
                let frame = match.candidate.frame
                let visible = !frame.isEmpty && frame.intersectionArea(with: metrics.rect) > 0
                if visible {
                    let ref = refs.store(bundleIdentifier: target.bundle, candidate: match.candidate)
                    markControlled(target.bundle)
                    let visibility = frame.contains(metrics.rect) || metrics.rect.contains(frame)
                        ? "in_view" : "partial"
                    return .success(.object([
                        "found": .bool(true),
                        "swipes": .int(swipes),
                        "ref": .string(ref.id),
                        "x": .double(frame.x),
                        "y": .double(frame.y),
                        "width": .double(frame.width),
                        "height": .double(frame.height),
                        "center_x": .double(frame.midX),
                        "center_y": .double(frame.midY),
                        "label": .string(match.candidate.label),
                        "visibility": .string(visibility),
                        "hint": .string("Tap the returned ref to act on the live element."),
                    ]))
                }
                sawOffscreenMatch = true
            }
            if index == distance { break }
            if let outcome = pageOnce(direction: direction,
                                      metrics: metrics,
                                      app: target.app,
                                      bundle: target.bundle,
                                      permit: permit,
                                      generation: generation) {
                return outcome
            }
            swipes += 1
            try? await Task.sleep(for: .milliseconds(250))
            guard stepAllowed(permit, generation: generation) else {
                return .sideEffectUnknown(code: "lifecycle_changed",
                                          message: "A scroll was dispatched before the lifecycle changed; the final position is unknown.")
            }
        }
        return .success(.object([
            "found": .bool(false),
            "swipes": .int(swipes),
            "hint": .string(sawOffscreenMatch
                            ? "The element exists but did not become visible within the scroll budget."
                            : "The element was not uniquely found within the scroll budget."),
        ]))
    }
}

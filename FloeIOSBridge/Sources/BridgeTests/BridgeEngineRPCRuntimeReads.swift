import Foundation
import UIKit
import XCTest
import BridgeCore

@MainActor
extension BridgeEngineRPCRuntime {

    // MARK: - device_info

    func deviceInfo(_ params: BridgeEngineParameters,
                    permit: BridgeRPCDispatchPermit,
                    generation: UInt64) throws -> BridgeRPCExecutionOutcome {
        _ = params
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        guard let capture = sdk.captureScreen() else {
            return failure(-32000, "The screen metrics could not be read.")
        }
        let metrics = capture.metrics
        guard stepAllowed(permit, generation: generation) else {
            return .failure(.fenced)
        }
        let capabilities = BridgeRPCMethodRegistry.capabilities(
            supportedEngineMethods: supportedMethods,
            logsAvailable: false,
            streamAvailable: false,
            lanAvailable: false
        )
        return .success(.object([
            "point_width": .double(metrics.pointWidth),
            "point_height": .double(metrics.pointHeight),
            "pixel_width": .int(metrics.pixelWidth),
            "pixel_height": .int(metrics.pixelHeight),
            "scale": .double(metrics.scale),
            "server_version": .string(BridgeRPCVersion.serverVersion),
            "protocol_version": .int(BridgeRPCVersion.protocolVersion),
            "capabilities": .array(capabilities.map { .string($0) }),
            "coordinate_space": .string("points"),
            "hint": .string("Tap/swipe x,y are POINTS. Screenshot data is pixels; point = pixel / scale."),
        ]))
    }

    // MARK: - page_source

    func pageSource(_ params: BridgeEngineParameters,
                    permit: BridgeRPCDispatchPermit,
                    generation: UInt64) throws -> BridgeRPCExecutionOutcome {
        let requestedBundle = try params.string("bundle_id", maximumBytes: 256)
        let maxDepth = try params.integer("max_depth", default: 40, range: 1...64)
        let maxElements = try params.integer("max_elements", default: 2_000, range: 1...4_000)
        let maxChildren = try params.integer("max_children", default: 1_000, range: 1...5_000)
        let enhanced = try params.bool("enhanced") ?? false
        let visibleOnly = try params.bool("visible_only") ?? false
        let filterObject = try params.object("filter")
        let filter = filterObject.flatMap(BridgeEngineTreeFilter.parse)

        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        guard let target = targetApp(requestedBundle) else {
            return failure(-32000, "No foreground app was observed; pass bundle_id or activate an app first.")
        }
        guard appStateName(target.bundle) == "runningForeground" else {
            return failure(-32000, "The target app is not in the foreground; no tree was read.")
        }
        let metrics: BridgeEngineScreenMetrics?
        if visibleOnly {
            guard let captured = sdk.screenMetrics() else {
                return failure(-32000, "The screen metrics could not be read for visible_only.")
            }
            metrics = captured
        } else {
            metrics = nil
        }
        guard let root = sdk.snapshot(of: target.app,
                                      maxDepth: maxDepth,
                                      maxChildren: maxChildren,
                                      maxNodes: maxElements) else {
            return failure(-32000, "The accessibility tree could not be read.")
        }
        guard stepAllowed(permit, generation: generation) else {
            return .failure(.fenced)
        }
        let options = BridgeEngineTreeOptions(
            maxDepth: maxDepth,
            maxNodes: maxElements,
            maxChildren: maxChildren,
            maxStringBytes: 2_048,
            maxSourceBytes: 131_072,
            filter: filter,
            visibleOnly: visibleOnly,
            screen: metrics?.rect
        )
        let render = BridgeEngineTreeText.render(root: root, options: options)
        var result: [String: BridgeRPCJSONValue] = [
            "source": .string(render.source),
            "truncated": .bool(render.truncated),
            "total_returned": .int(render.totalReturned),
            "coordinate_space": .string("points"),
            "channel": .object([
                "ax_coverage": .string("public-snapshot-materialized-then-trimmed"),
                "recommended": .string("tree"),
                "why": .string("A read of the live accessibility tree; a public snapshot materializes the full tree before the bounded response trim."),
            ]),
            "hint": .string("Frames are points. Prefer find_element + tap(ref) over coordinate taps."),
            "bundle_id": .string(target.bundle),
            "truncated_depth": .bool(render.truncatedDepth),
            "truncated_nodes": .bool(render.truncatedNodes),
            "truncated_bytes": .bool(render.truncatedBytes),
        ]
        if enhanced,
           let ocr = ocrItems(
               bundle: target.bundle,
               permit: permit,
               generation: generation,
               query: nil,
               fast: false,
               minimumConfidence: BridgeEngineOCRGeometry.defaultMinimumConfidence
           ) {
            switch ocr {
            case .failure, .sideEffectUnknown:
                return ocr
            case .success(let value):
                if let items = value.arrayValue {
                    let sourceLower = render.source.lowercased()
                    let ocrOnly = items.filter { item in
                        guard let label = item.objectValue?["label"]?.stringValue else { return false }
                        return !sourceLower.contains(label.lowercased())
                    }
                    result["ocr_only"] = .array(Array(ocrOnly.prefix(40)))
                    result["ocr_count"] = .int(ocrOnly.count)
                }
            }
        }
        markControlled(target.bundle)
        return .success(.object(result))
    }

    // MARK: - screen_text

    func screenText(_ params: BridgeEngineParameters,
                    permit: BridgeRPCDispatchPermit,
                    generation: UInt64) throws -> BridgeRPCExecutionOutcome {
        let query = try params.string("element_id", maximumBytes: 1_024)
        let match = try params.option("match", allowed: ["fast", "accurate"], default: "accurate") ?? "accurate"
        let minimumConfidence = try params.number(
            "scale",
            default: BridgeEngineOCRGeometry.defaultMinimumConfidence,
            range: BridgeEngineOCRGeometry.minimumConfidence...BridgeEngineOCRGeometry.maximumConfidence
        )
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        guard let target = targetApp(nil) else {
            return failure(-32000, "No foreground app was observed; screen text was not read.")
        }
        guard let secureRects = sdk.secureFieldRects(app: target.app) else {
            return failure(-32000,
                           "Secure field regions could not be established, so OCR was refused rather than risking a password in the result.")
        }
        guard stepAllowed(permit, generation: generation) else {
            return .failure(.fenced)
        }
        let captureStarted = Date()
        guard let capture = sdk.captureScreen() else {
            return failure(-32000, "A fresh screen image could not be captured for OCR.")
        }
        let screenshotMilliseconds = Int(Date().timeIntervalSince(captureStarted) * 1_000)
        guard stepAllowed(permit, generation: generation) else {
            return .failure(.fenced)
        }
        let started = Date()
        guard let observations = BridgeEngineOCR.observations(
            image: capture.image,
            fast: match == "fast"
        ) else {
            return failure(-32000, "Vision OCR could not run on the screen image.")
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        let items = BridgeEngineOCRGeometry.items(
            from: observations,
            minimumConfidence: minimumConfidence,
            imagePointWidth: capture.metrics.pointWidth,
            imagePointHeight: capture.metrics.pointHeight,
            secureRects: secureRects,
            query: query
        )
        guard stepAllowed(permit, generation: generation) else {
            return .failure(.fenced)
        }
        markControlled(target.bundle)
        return .success(.object([
            "count": .int(items.count),
            "items": .array(items.map { itemJSON($0) }),
            "coordinate_space": .string("points"),
            "channel": .object([
                "ax_coverage": .string("ocr"),
                "recommended": .string(items.isEmpty ? "tree" : "ocr"),
                "why": .string("Vision text boxes from a fresh screen capture; secure regions are excluded."),
            ]),
            "timing": .object([
                "screenshot_ms": .int(screenshotMilliseconds),
                "ocr_ms": .int(elapsed),
            ]),
            "hint": .string("Tap item center_x/center_y in points; OCR coordinates go stale after scrolling."),
        ]))
    }

    func itemJSON(_ item: BridgeEngineOCRItem) -> BridgeRPCJSONValue {
        .object([
            "label": .string(item.label),
            "confidence": .double((item.confidence * 1_000).rounded() / 1_000),
            "x": .double(item.frame.x),
            "y": .double(item.frame.y),
            "width": .double(item.frame.width),
            "height": .double(item.frame.height),
            "center_x": .double(item.centerX),
            "center_y": .double(item.centerY),
            "element_type": .string("OCRText"),
            "is_text_input": .bool(false),
            "exists": .bool(true),
        ])
    }

    /// Runs the same OCR path used by screen_text. Returns an outcome so the
    /// caller can decide whether an OCR failure is fatal (screen_text) or
    /// merely omits an enhanced section (page_source).
    func ocrItems(bundle: String,
                  permit: BridgeRPCDispatchPermit,
                  generation: UInt64,
                  query: String?,
                  fast: Bool,
                  minimumConfidence: Double) -> BridgeRPCExecutionOutcome? {
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
        let app = XCUIApplication(bundleIdentifier: bundle)
        guard let secureRects = sdk.secureFieldRects(app: app) else { return nil }
        guard let capture = sdk.captureScreen() else { return nil }
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
        guard let observations = BridgeEngineOCR.observations(image: capture.image, fast: fast) else {
            return nil
        }
        let items = BridgeEngineOCRGeometry.items(
            from: observations,
            minimumConfidence: minimumConfidence,
            imagePointWidth: capture.metrics.pointWidth,
            imagePointHeight: capture.metrics.pointHeight,
            secureRects: secureRects,
            query: query
        )
        return .success(.array(items.map { itemJSON($0) }))
    }

    // MARK: - screenshot

    func screenshot(_ params: BridgeEngineParameters,
                    permit: BridgeRPCDispatchPermit,
                    generation: UInt64) throws -> BridgeRPCExecutionOutcome {
        let requestedBundle = try params.string("bundle_id", maximumBytes: 256)
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        var image: UIImage
        var scope = "screen"
        var scopedTo: String?
        if let requestedBundle, !requestedBundle.isEmpty {
            let app = XCUIApplication(bundleIdentifier: requestedBundle)
            guard appStateName(requestedBundle) == "runningForeground" else {
                return failure(-32000, "The app-scoped screenshot target is not in the foreground.")
            }
            var shot: XCUIScreenshot?
            let result = sdk.call(stage: "app-screenshot") { shot = app.screenshot() }
            guard result.error == nil,
                  result.outcome.recordedIssueCount == 0,
                  let appImage = shot?.image else {
                return failure(-32000, "The app-scoped screenshot could not be captured.")
            }
            image = appImage
            scope = "app"
            scopedTo = requestedBundle
            markControlled(requestedBundle)
        } else {
            guard let capture = sdk.captureScreen() else {
                return failure(-32000, "The screen screenshot could not be captured.")
            }
            image = capture.image
        }
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }

        let nativeScale = Double(image.cgImage?.width ?? Int(image.size.width * image.scale)) / Double(image.size.width)
        let policy = try BridgeEngineScreenshotPolicy.request(params, nativeScale: nativeScale)
        let targetScale = policy.requestedScale
        if abs(targetScale - nativeScale) > 0.01 {
            guard let resized = sdk.image(image, scaledTo: targetScale) else {
                return failure(-32000, "The screenshot could not be resized to the requested scale.")
            }
            image = resized
        }
        let imageData: Data?
        switch policy.format {
        case .jpeg:
            imageData = sdk.jpegData(image, quality: policy.quality)
        case .png:
            imageData = sdk.pngData(image)
        }
        guard let data = imageData, !data.isEmpty else {
            return failure(-32000, "The screenshot encoding produced no bytes.")
        }
        guard data.count <= BridgeEngineScreenshotPolicy.maximumEncodedBytes else {
            return .failure(.responseTooLarge)
        }
        let base64 = data.base64EncodedString()
        guard base64.utf8.count <= BridgeEngineScreenshotPolicy.maximumEncodedBytes else {
            return .failure(.responseTooLarge)
        }
        let pixelWidth = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let pixelHeight = image.cgImage?.height ?? Int(image.size.height * image.scale)
        let actualScale = Double(pixelWidth) / Double(image.size.width)
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
        var result: [String: BridgeRPCJSONValue] = [
            "data": .string(base64),
            "format": .string(policy.format.rawValue),
            "bytes": .int(data.count),
            "pixel_width": .int(pixelWidth),
            "pixel_height": .int(pixelHeight),
            "point_width": .double(Double(image.size.width)),
            "point_height": .double(Double(image.size.height)),
            "scale": .double(actualScale),
            "scope": .string(scope),
            "hint": .string("Tap coordinates are POINTS: point = pixel / scale. The image is not saved."),
        ]
        if let scopedTo { result["scoped_to"] = .string(scopedTo) }
        if policy.format == .jpeg { result["quality"] = .double(policy.quality) }
        return .success(.object(result))
    }

    // MARK: - reset

    func reset(permit: BridgeRPCDispatchPermit,
               generation: UInt64) throws -> BridgeRPCExecutionOutcome {
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        let cleared = refs.clear()
        state.reset()
        state.setLastControlled(nil)
        sdk.files.log("rpc_reset cleared_refs=\(cleared)")
        return .success(.object([
            "reset": .bool(true),
            "cleared_refs": .int(cleared),
            "hint": .string("Cached element refs and learned screen facts were cleared. XCTest was not initialized again."),
        ]))
    }

    // MARK: - find_element

    func findElement(_ params: BridgeEngineParameters,
                     permit: BridgeRPCDispatchPermit,
                     generation: UInt64) throws -> BridgeRPCExecutionOutcome {
        let query = try params.requiredString("element_id", maximumBytes: 4_096)
        guard !query.isEmpty else {
            throw BridgeEngineParameterError("Parameter 'element_id' must not be empty.")
        }
        let mode: BridgeEngineMatchMode = (try params.option("match", allowed: ["exact", "contains"], default: "exact") ?? "exact") == "exact" ? .exact : .contains
        let type = try params.string("element_type", maximumBytes: 128)
        let requestedBundle = try params.string("bundle_id", maximumBytes: 256)
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        guard let target = targetApp(requestedBundle) else {
            return failure(-32000, "No foreground app was observed; no element was searched.")
        }
        guard appStateName(target.bundle) == "runningForeground" else {
            return failure(-32000, "The target app is not in the foreground; no element was searched.")
        }
        guard let root = sdk.snapshot(of: target.app) else {
            return failure(-32000, "The accessibility tree could not be read.")
        }
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
        let candidates = sdk.candidates(in: root, bundleIdentifier: target.bundle)
        let matches = BridgeEngineElementSelector.matches(
            candidates: candidates,
            query: query,
            mode: mode,
            elementType: type
        )
        switch BridgeEngineElementSelector.selectUnique(matches) {
        case .missing:
            return .success(.object([
                "exists": .bool(false),
                "match_count": .int(0),
                "note": .string("No element matched the query."),
            ]))
        case .ambiguous(let count):
            return .success(.object([
                "exists": .bool(true),
                "match_count": .int(count),
                "note": .string("Multiple elements matched; no ref was created. Refine the query or element_type."),
            ]))
        case .unique(let match):
            markControlled(target.bundle)
            let candidate = match.candidate
            var hittable = false
            if let live = sdk.liveElement(app: target.app,
                                          identifier: candidate.identifier,
                                          label: candidate.label,
                                          type: candidate.type),
               live.matchCount == 1,
               let actual = sdk.isHittable(live.element) {
                hittable = actual
            }
            guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
            let ref = candidate.frame.isEmpty ? nil : refs.store(bundleIdentifier: target.bundle,
                                                                 candidate: candidate)
            var result: [String: BridgeRPCJSONValue] = [
                "exists": .bool(true),
                "hittable": .bool(hittable),
                "element_type": .string(candidate.type),
                "is_text_input": .bool(candidate.isTextInput),
                "x": .double(candidate.frame.x),
                "y": .double(candidate.frame.y),
                "width": .double(candidate.frame.width),
                "height": .double(candidate.frame.height),
                "center_x": .double(candidate.frame.midX),
                "center_y": .double(candidate.frame.midY),
                "label": .string(candidate.label),
                "match": .string(match.reason),
                "bundle_id": .string(target.bundle),
            ]
            if let ref { result["ref"] = .string(ref.id) } else {
                result["note"] = .string("The element has no usable frame, so no ref was created.")
            }
            if let value = candidate.value, !candidate.isSecure {
                result["value"] = .string(value)
            } else if candidate.isSecure {
                result["value"] = .string("<redacted>")
                result["note"] = .string("Secure text field value is redacted.")
            }
            return .success(.object(result))
        }
    }

    // MARK: - list_apps

    func listApps(_ params: BridgeEngineParameters,
                  permit: BridgeRPCDispatchPermit,
                  generation: UInt64) throws -> BridgeRPCExecutionOutcome {
        let filter = try params.string("text", maximumBytes: 512)
        let type = try params.string("element_type", maximumBytes: 32)
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        var source = "builtin-table"
        var apps: [[String: String]] = []
        if BRInstalledAppsAvailable(),
           let installed = BRInstalledApps(type != "all")?.compactMap({ item -> [String: String]? in
               guard let bundle = item["bundle_id"], !bundle.isEmpty else { return nil }
               return ["bundle_id": bundle, "name": item["name"] ?? ""]
           }) {
            apps = installed
            source = "installed-apps"
        } else {
            var fallback: [[String: String]] = []
            if let controlled = state.lastControlledBundleIdentifier {
                fallback.append(["bundle_id": controlled, "name": controlled])
            }
            if let foreground = currentForegroundBundleIdentifier() {
                fallback.append(["bundle_id": foreground, "name": foreground])
            }
            apps = fallback
            source = "opened-history"
        }
        if let filter, !filter.isEmpty {
            apps = apps.filter {
                ($0["name"] ?? "").localizedCaseInsensitiveContains(filter)
                    || ($0["bundle_id"] ?? "").localizedCaseInsensitiveContains(filter)
            }
        }
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
        return .success(.object([
            "count": .int(apps.count),
            "source": .string(source),
            "apps": .array(apps.map { app in
                .object([
                    "bundle_id": .string(app["bundle_id"] ?? ""),
                    "name": .string(app["name"] ?? ""),
                ])
            }),
            "hint": .string(source == "installed-apps"
                            ? "Installed apps read through LSApplicationWorkspace."
                            : "Full App enumeration is unavailable; only the opened-history fallback is reported."),
        ]))
    }

    // MARK: - resolve_app

    func resolveApp(_ params: BridgeEngineParameters,
                    permit: BridgeRPCDispatchPermit,
                    generation: UInt64) throws -> BridgeRPCExecutionOutcome {
        let term = try params.requiredString("text", maximumBytes: 512)
        let limit = try params.integer("distance", default: 5, range: 1...20)
        _ = try params.string("country", maximumBytes: 16)
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        var source = "builtin-table"
        var apps: [[String: String]] = []
        if BRInstalledAppsAvailable(),
           let installed = BRInstalledApps(true)?.compactMap({ item -> [String: String]? in
               guard let bundle = item["bundle_id"], !bundle.isEmpty else { return nil }
               return ["bundle_id": bundle, "name": item["name"] ?? ""]
           }) {
            apps = installed
            source = "installed-apps"
        }
        for entry in Self.builtinApps where !apps.contains(where: { $0["bundle_id"] == entry.bundleID }) {
            apps.append(["bundle_id": entry.bundleID, "name": entry.name])
        }
        let terms = term.split(separator: "|").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        var matched: [[String: String]] = []
        for app in apps {
            let name = (app["name"] ?? "").lowercased()
            let bundle = (app["bundle_id"] ?? "").lowercased()
            if terms.contains(where: { name.contains($0) || bundle.contains($0) }) {
                matched.append(app)
            }
            if matched.count >= limit { break }
        }
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
        return .success(.object([
            "count": .int(matched.count),
            "term": .string(term),
            "source": .string(source),
            "apps": .array(matched.map { app in
                .object([
                    "bundle_id": .string(app["bundle_id"] ?? ""),
                    "name": .string(app["name"] ?? ""),
                ])
            }),
            "hint": .string("Local app-name resolution only; no App Store search or network request is made."),
        ]))
    }

    // MARK: - open_url

    func openURL(_ params: BridgeEngineParameters,
                 permit: BridgeRPCDispatchPermit,
                 generation: UInt64) throws -> BridgeRPCExecutionOutcome {
        let raw = try params.requiredString("url", maximumBytes: 8_192)
        guard let url = URL(string: raw),
              let scheme = url.scheme,
              !scheme.isEmpty else {
            throw BridgeEngineParameterError("Parameter 'url' must be an absolute URL with a scheme.")
        }
        if let outcome = beginSDK(permit, generation: generation) { return outcome }
        guard BROpenURLAvailable() else {
            return methodNotAvailable("No safe URL-opening path is available in this XCTest runtime.")
        }
        guard stepAllowed(permit, generation: generation) else { return .failure(.fenced) }
        let opened = BROpenURL(url)
        guard opened else {
            return failure(-32000, "The URL was not accepted by the system URL opener.")
        }
        guard stepAllowed(permit, generation: generation) else {
            return .sideEffectUnknown(code: "lifecycle_changed",
                                      message: "The URL open was dispatched but the engine lifecycle changed before it returned; the destination is unknown.")
        }
        return .success(.object([
            "message": .string("URL open accepted by the system."),
            "note": .string("Dispatch accepted; the destination app or page is not verified by this call."),
        ]))
    }

    struct BuiltinApp {
        let name: String
        let bundleID: String
    }

    static let builtinApps: [BuiltinApp] = [
        BuiltinApp(name: "Settings", bundleID: "com.apple.Preferences"),
        BuiltinApp(name: "Safari", bundleID: "com.apple.mobilesafari"),
        BuiltinApp(name: "Calculator", bundleID: "com.apple.calculator"),
        BuiltinApp(name: "Messages", bundleID: "com.apple.MobileSMS"),
        BuiltinApp(name: "Photos", bundleID: "com.apple.mobileslideshow"),
        BuiltinApp(name: "Camera", bundleID: "com.apple.camera"),
        BuiltinApp(name: "Clock", bundleID: "com.apple.mobiletimer"),
        BuiltinApp(name: "Maps", bundleID: "com.apple.Maps"),
        BuiltinApp(name: "Calendar", bundleID: "com.apple.mobilecal"),
        BuiltinApp(name: "Notes", bundleID: "com.apple.mobilenotes"),
        BuiltinApp(name: "Files", bundleID: "com.apple.DocumentsApp"),
        BuiltinApp(name: "Music", bundleID: "com.apple.Music"),
        BuiltinApp(name: "App Store", bundleID: "com.apple.AppStore"),
        BuiltinApp(name: "Phone", bundleID: "com.apple.mobilephone"),
        BuiltinApp(name: "FaceTime", bundleID: "com.apple.facetime"),
        BuiltinApp(name: "Mail", bundleID: "com.apple.mobilemail"),
        BuiltinApp(name: "Reminders", bundleID: "com.apple.reminders"),
        BuiltinApp(name: "Shortcuts", bundleID: "com.apple.shortcuts"),
        BuiltinApp(name: "Home", bundleID: "com.apple.Home"),
        BuiltinApp(name: "SpringBoard", bundleID: "com.apple.springboard"),
    ]
}

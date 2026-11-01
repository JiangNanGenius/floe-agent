import Foundation
import UIKit
import XCTest
import BridgeCore

struct BridgeEngineSDKCallResult {
    var outcome: BridgeSDKCallOutcome
    var error: NSError?
}

/// Bounded XCTest/UIKit adapters for the RPC executor. Every real SDK call
/// goes through `call(...)`, which counts scoped XCTest issues and catches
/// Objective-C exceptions; a normal return with an issue is never treated as
/// a successful effect.
@MainActor
final class BridgeEngineSDKSupport {
    let files: BridgeTestFiles
    private(set) var issueCapture: BridgeEngineIssueCapture

    init(files: BridgeTestFiles, issueCapture: BridgeEngineIssueCapture) {
        self.files = files
        self.issueCapture = issueCapture
    }

    /// Rebinds the scoped issue counter after a repeated test entry in the same
    /// process. The registered executor stays the same object and gate.
    func rebind(issueCapture: BridgeEngineIssueCapture) {
        self.issueCapture = issueCapture
    }

    func call(stage: String,
              sensitive: Bool = false,
              detectFocusRefusal: Bool = false,
              _ body: @escaping () -> Void) -> BridgeEngineSDKCallResult {
        let token = issueCapture.begin()
        var error: NSError?
        let returned = BRCatchException(body, &error)
        let issues = issueCapture.end(token)
        if returned {
            return BridgeEngineSDKCallResult(
                outcome: BridgeSDKCallOutcome(entered: true,
                                              returned: true,
                                              recordedIssueCount: issues),
                error: nil
            )
        }
        let resolved = error ?? NSError(
            domain: "org.floeagent.iosbridge.engine",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "unknown Objective-C exception"]
        )
        files.log(BridgeEngineSafeDiagnostic.exceptionLine(stage: stage,
                                                           error: resolved,
                                                           sensitive: sensitive))
        let reason = (resolved.userInfo[NSLocalizedDescriptionKey] as? String) ?? ""
        let focusRefused = detectFocusRefusal &&
            (reason.contains("Neither element nor any descendant has keyboard focus") ||
             reason.contains("XCUITestingErrorElementNotFocused"))
        // Exception descriptions are never returned to a caller either: UIKit/
        // XCTest text can include element values. Only the numeric code is
        // retained for the scoped classification.
        let safeError = NSError(domain: "org.floeagent.iosbridge.engine",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "The automation call failed."])
        return BridgeEngineSDKCallResult(
            outcome: BridgeSDKCallOutcome(entered: true,
                                          returned: false,
                                          focusRefused: focusRefused,
                                          recordedIssueCount: issues),
            error: safeError
        )
    }

    // MARK: - Apps and state

    func stateName(_ state: XCUIApplication.State) -> String {
        switch state {
        case .unknown: return "unknown"
        case .notRunning: return "notRunning"
        case .runningBackgroundSuspended: return "runningBackgroundSuspended"
        case .runningBackground: return "runningBackground"
        case .runningForeground: return "runningForeground"
        @unknown default: return "unknown"
        }
    }

    func state(of app: XCUIApplication) -> String {
        stateObservation(of: app).state
    }

    func stateObservation(of app: XCUIApplication) -> (state: String, queryKnown: Bool) {
        var value = "unknown"
        let result = call(stage: "app-state") {
            value = self.stateName(app.state)
        }
        let known = result.error == nil && result.outcome.recordedIssueCount == 0
        return (known ? value : "unknown", known)
    }

    /// Read bounded alert visibility without copying labels or element values.
    /// A stale, non-hittable alert is not an interactive authorization surface;
    /// failed/oversized queries remain unknown and cannot authorize input.
    func systemAlertObservation(app: XCUIApplication) -> (known: Bool, count: Int, hittableCount: Int) {
        var count = 0
        var hittableCount = 0
        var bounded = true
        let result = call(stage: "system-alert-check") {
            let alerts = app.alerts.allElementsBoundByIndex
            count = alerts.count
            guard count <= 32 else { bounded = false; return }
            var remainingElements = 512
            for alert in alerts {
                if alert.isHittable { hittableCount += 1; continue }
                // Alert containers need not themselves accept a hit even when
                // their buttons/fields do. Check children before calling a
                // non-hittable container stale.
                let descendants = alert.descendants(matching: .any).allElementsBoundByIndex
                guard descendants.count <= remainingElements else { bounded = false; return }
                remainingElements -= descendants.count
                if descendants.contains(where: { $0.isHittable }) { hittableCount += 1 }
            }
        }
        return (result.error == nil && result.outcome.recordedIssueCount == 0 && bounded,
                count, hittableCount)
    }

    /// Actual frontmost app via the guarded private helper. Falls back to the
    /// host app only when its public state says it is in the foreground.
    func foregroundBundleIdentifier(lastControlled: String?) -> String? {
        if let bundle = BRCurrentForegroundBundleID(), !bundle.isEmpty {
            return bundle
        }
        if let lastControlled {
            let app = XCUIApplication(bundleIdentifier: lastControlled)
            let state = state(of: app)
            if state == "runningForeground" { return lastControlled }
        }
        let host = BridgeBuild.hostBundleIdentifier
        let hostApp = XCUIApplication(bundleIdentifier: host)
        if state(of: hostApp) == "runningForeground" { return host }
        return nil
    }

    func app(bundleIdentifier: String) -> XCUIApplication? {
        guard !bundleIdentifier.isEmpty else { return nil }
        return XCUIApplication(bundleIdentifier: bundleIdentifier)
    }

    // MARK: - Screen capture and metrics

    func captureScreen() -> (image: UIImage, metrics: BridgeEngineScreenMetrics)? {
        var shot: XCUIScreenshot?
        let result = call(stage: "screen-capture") {
            shot = XCUIScreen.main.screenshot()
        }
        guard result.error == nil,
              result.outcome.recordedIssueCount == 0,
              let image = shot?.image,
              image.size.width > 1,
              image.size.height > 1 else { return nil }
        let pixelWidth = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let pixelHeight = image.cgImage?.height ?? Int(image.size.height * image.scale)
        guard let metrics = BridgeEngineScreenMetrics(
            pointWidth: Double(image.size.width),
            pointHeight: Double(image.size.height),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        ) else { return nil }
        return (image, metrics)
    }

    func screenMetrics() -> BridgeEngineScreenMetrics? {
        captureScreen()?.metrics
    }

    func jpegData(_ image: UIImage, quality: Double) -> Data? {
        image.jpegData(compressionQuality: CGFloat(quality))
    }

    func pngData(_ image: UIImage) -> Data? {
        image.pngData()
    }

    /// Re-renders the screenshot at a requested pixel-per-point scale. The
    /// point size stays the same, so the result still describes the screen.
    func image(_ image: UIImage, scaledTo scale: Double) -> UIImage? {
        guard scale > 0, scale.isFinite else { return nil }
        let size = image.size
        guard size.width > 1, size.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = CGFloat(scale)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }


    /// A tiny 16x16 RGBA fingerprint used only for bounded screen-settle
    /// comparisons. The bytes are never returned or logged.
    func fingerprint(_ image: UIImage) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        let width = 16
        let height = 16
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo) else { return false }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// Fraction of fingerprint bytes that differ by more than a small
    /// quantization step. Not a perceptual hash, but enough to tell "nothing
    /// moved" from "the screen reacted" for settle reporting.
    func screenDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 1 }
        var changed = 0
        for index in lhs.indices {
            let a = Int(lhs[index])
            let b = Int(rhs[index])
            if abs(a - b) > 8 { changed += 1 }
        }
        return Double(changed) / Double(lhs.count)
    }

    // MARK: - Accessibility snapshot

    func snapshot(of app: XCUIApplication,
                  maxDepth: Int = 40,
                  maxChildren: Int = 1_000,
                  maxNodes: Int = 2_000) -> BridgeEngineTreeNode? {
        var root: XCUIElementSnapshot?
        let result = call(stage: "snapshot") {
            root = try? app.snapshot()
        }
        guard result.error == nil,
              result.outcome.recordedIssueCount == 0,
              let root else { return nil }
        var budget = SnapshotBudget(maxDepth: maxDepth,
                                    maxChildren: maxChildren,
                                    maxNodes: maxNodes)
        return snapshotNode(root, depth: 0, budget: &budget)
    }

    private struct SnapshotBudget {
        var maxDepth: Int
        var maxChildren: Int
        var maxNodes: Int
        var used = 0
    }

    private func snapshotNode(_ snapshot: XCUIElementSnapshot,
                              depth: Int,
                              budget: inout SnapshotBudget) -> BridgeEngineTreeNode? {
        guard depth <= budget.maxDepth, budget.used < budget.maxNodes else { return nil }
        budget.used += 1
        let type = Self.elementTypeName(snapshot.elementType)
        let frame = BridgeUIRect(
            x: Double(snapshot.frame.origin.x),
            y: Double(snapshot.frame.origin.y),
            width: Double(snapshot.frame.size.width),
            height: Double(snapshot.frame.size.height)
        )
        let secure = snapshot.elementType == .secureTextField
        var children: [BridgeEngineTreeNode] = []
        var adapterTruncated = false
        if depth < budget.maxDepth {
            let rawChildren = snapshot.children
            let limit = min(rawChildren.count, budget.maxChildren)
            var index = 0
            while index < limit, budget.used < budget.maxNodes {
                if let child = snapshotNode(rawChildren[index],
                                            depth: depth + 1,
                                            budget: &budget) {
                    children.append(child)
                }
                index += 1
            }
            if index < rawChildren.count {
                adapterTruncated = true
            }
        } else if !snapshot.children.isEmpty {
            adapterTruncated = true
        }
        return BridgeEngineTreeNode(
            type: type,
            typeRaw: Int(snapshot.elementType.rawValue),
            identifier: snapshot.identifier,
            label: snapshot.label,
            value: secure ? nil : snapshot.value.map { String(describing: $0) },
            placeholderValue: snapshot.placeholderValue,
            frame: frame,
            isEnabled: snapshot.isEnabled,
            isSelected: snapshot.isSelected,
            hasFocus: snapshot.hasFocus,
            isSecure: secure,
            children: children,
            adapterTruncated: adapterTruncated
        )
    }

    func candidates(in root: BridgeEngineTreeNode,
                    bundleIdentifier: String) -> [BridgeEngineElementCandidate] {
        var output: [BridgeEngineElementCandidate] = []
        var stack: [BridgeEngineTreeNode] = [root]
        var visited = 0
        while let node = stack.popLast(), visited < 4_000 {
            visited += 1
            output.append(BridgeEngineElementCandidate(
                identifier: node.identifier,
                label: node.label,
                value: node.value,
                type: node.type,
                typeRaw: node.typeRaw,
                frame: node.frame,
                isEnabled: node.isEnabled,
                isHittable: false,
                isSecure: node.isSecure,
                hasFocus: node.hasFocus,
                isTextInput: BridgeEngineElementType.isTextInput(node.type)
            ))
            stack.append(contentsOf: node.children.reversed())
        }
        _ = bundleIdentifier
        return output
    }

    /// Live element resolution for hittability/native taps. The identifier is
    /// preferred; a label-only match is accepted only when exactly one exists.
    func liveElement(app: XCUIApplication,
                     identifier: String,
                     label: String,
                     type: String) -> (element: XCUIElement, matchCount: Int)? {
        if !identifier.isEmpty {
            var identifierMatches: [XCUIElement] = []
            let identifierResult = call(stage: "live-identifier") {
                identifierMatches = app.descendants(matching: .any)
                    .matching(identifier: identifier)
                    .allElementsBoundByIndex
            }
            if identifierResult.error == nil,
               identifierResult.outcome.recordedIssueCount == 0,
               identifierMatches.count == 1 {
                return (identifierMatches[0], 1)
            }
            if identifierResult.error != nil || identifierResult.outcome.recordedIssueCount > 0 {
                return nil
            }
        }
        guard !label.isEmpty else { return nil }
        var labelMatches: [XCUIElement] = []
        let labelResult = call(stage: "live-label") {
            let predicate = NSPredicate(format: "label == %@", label)
            labelMatches = app.descendants(matching: .any)
                .matching(predicate)
                .allElementsBoundByIndex
        }
        guard labelResult.error == nil,
              labelResult.outcome.recordedIssueCount == 0 else { return nil }
        // A type filter, when supplied, is applied to the live elements.
        let filtered = labelMatches.filter { element in
            guard !type.isEmpty else { return true }
            return BridgeEngineElementType.matches(
                Self.elementTypeName(element.elementType),
                elementType: type
            )
        }
        guard let first = filtered.first else { return nil }
        return (first, filtered.count)
    }

    func isHittable(_ element: XCUIElement) -> Bool? {
        var value: Bool?
        let result = call(stage: "is-hittable") {
            value = element.isHittable
        }
        guard result.error == nil, result.outcome.recordedIssueCount == 0 else { return nil }
        return value
    }

    func secureFieldRects(app: XCUIApplication) -> [BridgeUIRect]? {
        var elements: [XCUIElement] = []
        let result = call(stage: "secure-fields") {
            elements = app.descendants(matching: .secureTextField).allElementsBoundByIndex
        }
        guard result.error == nil, result.outcome.recordedIssueCount == 0 else { return nil }
        var rects: [BridgeUIRect] = []
        for element in elements {
            var frame = CGRect.zero
            let frameCall = call(stage: "secure-frame") { frame = element.frame }
            guard frameCall.error == nil, frameCall.outcome.recordedIssueCount == 0 else {
                return nil
            }
            if frame.width > 0, frame.height > 0 {
                rects.append(BridgeUIRect(x: Double(frame.origin.x),
                                          y: Double(frame.origin.y),
                                          width: Double(frame.size.width),
                                          height: Double(frame.size.height)))
            }
        }
        return rects
    }

    struct FocusedField {
        var element: XCUIElement
        var candidate: BridgeEngineElementCandidate
        var placeholderValue: String?
    }

    /// Reads only actually focused text inputs through the pinned
    /// `hasKeyboardFocus` predicate. A failed query returns nil, never an
    /// invented focus state.
    func focusedFields(app: XCUIApplication) -> [FocusedField]? {
        let rawValues = [
            XCUIElement.ElementType.textField.rawValue,
            XCUIElement.ElementType.searchField.rawValue,
            XCUIElement.ElementType.textView.rawValue,
            XCUIElement.ElementType.secureTextField.rawValue,
        ]
        let predicate = NSPredicate(
            format: "hasKeyboardFocus == true AND elementType IN %@",
            rawValues
        )
        var elements: [XCUIElement] = []
        let result = call(stage: "focused-fields") {
            elements = app.descendants(matching: .any)
                .matching(predicate)
                .allElementsBoundByIndex
        }
        guard result.error == nil, result.outcome.recordedIssueCount == 0 else { return nil }
        var output: [FocusedField] = []
        for element in elements.prefix(16) {
            var identifier = ""
            var label = ""
            var frame = CGRect.zero
            var type: XCUIElement.ElementType = .any
            var placeholder: String?
            let read = call(stage: "focused-field-read") {
                identifier = element.identifier
                label = element.label
                frame = element.frame
                type = element.elementType
                placeholder = element.placeholderValue
            }
            guard read.error == nil, read.outcome.recordedIssueCount == 0 else { return nil }
            let secure = type == .secureTextField
            var value: Any?
            if !secure {
                let valueRead = call(stage: "focused-field-value", sensitive: true) {
                    value = element.value
                }
                guard valueRead.error == nil, valueRead.outcome.recordedIssueCount == 0 else {
                    return nil
                }
            }
            let candidate = BridgeEngineElementCandidate(
                identifier: identifier,
                label: label,
                value: secure ? nil : (value as? String),
                type: Self.elementTypeName(type),
                typeRaw: Int(type.rawValue),
                frame: BridgeUIRect(x: Double(frame.origin.x),
                                    y: Double(frame.origin.y),
                                    width: Double(frame.size.width),
                                    height: Double(frame.size.height)),
                isEnabled: true,
                isHittable: false,
                isSecure: secure,
                hasFocus: true,
                isTextInput: true
            )
            output.append(FocusedField(element: element,
                                       candidate: candidate,
                                       placeholderValue: placeholder))
        }
        return output
    }

    func value(of element: XCUIElement) -> String? {
        var raw: Any?
        let result = call(stage: "element-value", sensitive: true) {
            raw = element.value
        }
        guard result.error == nil, result.outcome.recordedIssueCount == 0 else { return nil }
        return raw as? String
    }

    /// True only when the app exposes the standard ten-digit passcode keypad
    /// (1...9 and 0). Apple's in-process passcode prompt can be a custom
    /// keypad rather than a secureTextField, so Settings uses this as a
    /// conservative second signal. A failed read returns nil (unknown).
    func passcodeKeypadPresent(app: XCUIApplication) -> Bool? {
        for label in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] {
            var exists = false
            let result = call(stage: "passcode-key-check", sensitive: true) {
                exists = app.buttons[label].exists
            }
            guard result.error == nil, result.outcome.recordedIssueCount == 0 else { return nil }
            if !exists { return false }
        }
        return true
    }

    /// Reads a value only while the focused-field state is known and contains
    /// no secure field. Unknown focus is not permission to read a secure
    /// value; the caller must treat nil as unverified evidence.
    func nonSecureValue(of element: XCUIElement, app: XCUIApplication) -> String? {
        guard let fields = focusedFields(app: app),
              !fields.contains(where: { $0.candidate.isSecure }) else { return nil }
        return value(of: element)
    }

    // MARK: - Element type names

    static func elementTypeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .application: return "Application"
        case .window: return "Window"
        case .other: return "Other"
        case .button: return "Button"
        case .staticText: return "StaticText"
        case .textField: return "TextField"
        case .secureTextField: return "SecureTextField"
        case .searchField: return "SearchField"
        case .textView: return "TextView"
        case .cell: return "Cell"
        case .table: return "Table"
        case .collectionView: return "CollectionView"
        case .image: return "Image"
        case .switch: return "Switch"
        case .link: return "Link"
        case .navigationBar: return "NavigationBar"
        case .tabBar: return "TabBar"
        case .toolbar: return "Toolbar"
        case .scrollView: return "ScrollView"
        case .slider: return "Slider"
        case .stepper: return "Stepper"
        case .picker: return "Picker"
        case .pickerWheel: return "PickerWheel"
        case .alert: return "Alert"
        case .sheet: return "Sheet"
        case .menu: return "Menu"
        case .menuItem: return "MenuItem"
        case .menuBar: return "MenuBar"
        case .menuBarItem: return "MenuBarItem"
        case .segmentedControl: return "SegmentedControl"
        case .pageIndicator: return "PageIndicator"
        case .progressIndicator: return "ProgressIndicator"
        case .activityIndicator: return "ActivityIndicator"
        case .datePicker: return "DatePicker"
        case .toggle: return "Toggle"
        case .webView: return "WebView"
        case .map: return "Map"
        case .tab: return "Tab"
        case .tabGroup: return "TabGroup"
        default: return String(describing: type)
        }
    }
}

import Foundation
import XCTest

import BridgeCore

struct EngineTestCase {
    let name: String
    let body: () async throws -> Void
}

func allEngineTests() -> [EngineTestCase] {
    [
        EngineTestCase(name: "parametersTypedAndBounded", body: parametersTypedAndBounded),
        EngineTestCase(name: "pointsArePointsAndClamped", body: pointsArePointsAndClamped),
        EngineTestCase(name: "screenshotPolicy", body: screenshotPolicy),
        EngineTestCase(name: "ocrGeometryAndSecureMasking", body: ocrGeometryAndSecureMasking),
        EngineTestCase(name: "treeRenderFilterAndRedaction", body: treeRenderFilterAndRedaction),
        EngineTestCase(name: "treeVisibleOnlyAndTruncation", body: treeVisibleOnlyAndTruncation),
        EngineTestCase(name: "selectorUniqueAndTypes", body: selectorUniqueAndTypes),
        EngineTestCase(name: "refStoreBounded", body: refStoreBounded),
        EngineTestCase(name: "inputPolicyMatrix", body: inputPolicyMatrix),
        EngineTestCase(name: "touchPolicyMatrix", body: touchPolicyMatrix),
        EngineTestCase(name: "touchGateNeverCallsDeniedBody", body: touchGateNeverCallsDeniedBody),
        EngineTestCase(name: "authorizationContextLifecycle", body: authorizationContextLifecycle),
        EngineTestCase(name: "lockStateClassifier", body: lockStateClassifier),
        EngineTestCase(name: "captureAdmissionPostStopLock", body: captureAdmissionPostStopLock),
        EngineTestCase(name: "safeDiagnosticLine", body: safeDiagnosticLine),
        EngineTestCase(name: "issueSanitizer", body: issueSanitizer),
        EngineTestCase(name: "issueCaptureCount", body: issueCaptureCount),
        EngineTestCase(name: "legacyFileLaneProductBoundary", body: legacyFileLaneProductBoundary),
        EngineTestCase(name: "serialGateSerializes", body: serialGateSerializes),
        EngineTestCase(name: "coordinatorFencesPreDispatch", body: coordinatorFencesPreDispatch),
        EngineTestCase(name: "coordinatorTimeoutNeverReplays", body: coordinatorTimeoutNeverReplays),
        EngineTestCase(name: "methodCatalogHonest", body: methodCatalogHonest),
        EngineTestCase(name: "registryFirstWins", body: registryFirstWins),
        EngineTestCase(name: "textEvidenceNoOpSemantics", body: textEvidenceNoOpSemantics),
        EngineTestCase(name: "placeholderBeforeValueEvidence", body: placeholderBeforeValueEvidence),
        EngineTestCase(name: "settleParameters", body: settleParameters),
    ]
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure(message: message)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) throws {
    if lhs != rhs {
        throw TestFailure(message: "\(message): expected \(rhs), got \(lhs)")
    }
}

func expectClose(_ lhs: Double, _ rhs: Double, _ message: String,
                 tolerance: Double = 0.000_001) throws {
    if abs(lhs - rhs) > tolerance {
        throw TestFailure(message: "\(message): expected \(rhs), got \(lhs)")
    }
}

// MARK: - Parameters

func parametersTypedAndBounded() throws {
    let params = try BridgeEngineParameters(.object([
        "text": .string("abc"),
        "flag": .bool(true),
        "count": .int(3),
        "ratio": .double(0.5),
    ]))
    try expectEqual(try params.requiredString("text"), "abc", "string")
    try expectEqual(try params.bool("flag"), true, "bool")
    try expectEqual(try params.int("count"), 3, "int")
    try expectEqual(try params.double("ratio"), 0.5, "double")
    try expectEqual(try params.integer("count", default: 1, range: 0...3), 3, "range")
    do {
        _ = try params.requiredString("missing")
        throw TestFailure(message: "missing string accepted")
    } catch let error as BridgeEngineParameterError {
        try expect(error.message.contains("Missing"), "missing string message")
    }
    do {
        _ = try params.integer("count", default: 1, range: 4...8)
        throw TestFailure(message: "out-of-range accepted")
    } catch let error as BridgeEngineParameterError {
        try expect(error.message.contains("between"), "range message")
    }
    do {
        _ = try BridgeEngineParameters(.string("no"))
        throw TestFailure(message: "non-object params accepted")
    } catch let error as BridgeEngineParameterError {
        try expect(error.message.contains("object"), "object message")
    }
}

// MARK: - Geometry

func pointsArePointsAndClamped() throws {
    let metrics = try unwrap(BridgeEngineScreenMetrics(pointWidth: 1_000,
                                                       pointHeight: 800,
                                                       pixelWidth: 2_000,
                                                       pixelHeight: 1_600))
    try expectEqual(metrics.scale, 2.0, "scale")
    switch BridgeEngineGeometry.resolvePoint(x: 10, y: 20, metrics: metrics) {
    case .resolved(let point):
        try expectEqual(point.x, 10, "x")
        try expectEqual(point.y, 20, "y")
    case .outOfRange:
        throw TestFailure(message: "valid point rejected")
    }
    switch BridgeEngineGeometry.resolvePoint(x: 1_000.5, y: 800.5, metrics: metrics) {
    case .resolved(let point):
        try expectEqual(point.x, 1_000, "clamped x")
        try expectEqual(point.y, 800, "clamped y")
    case .outOfRange:
        throw TestFailure(message: "rounding tolerance rejected")
    }
    switch BridgeEngineGeometry.resolvePoint(x: 1_200, y: 20, metrics: metrics) {
    case .resolved:
        throw TestFailure(message: "out-of-range x accepted")
    case .outOfRange(let validX, let validY):
        try expectEqual(validX.upperBound, 1_000, "valid x")
        try expectEqual(validY.upperBound, 800, "valid y")
    }
    switch BridgeEngineGeometry.resolvePoint(x: .nan, y: 0, metrics: metrics) {
    case .resolved:
        throw TestFailure(message: "NaN accepted")
    case .outOfRange:
        break
    }
    let clamped = try unwrap(BridgeEngineGeometry.clamped(
        BridgeEnginePoint(x: -10, y: 900),
        to: BridgeUIRect(x: 100, y: 50, width: 200, height: 100)
    ))
    try expectEqual(clamped.x, 101, "clamped x inside frame")
    try expectEqual(clamped.y, 149, "clamped y inside frame")
    let offset = try unwrap(BridgeEngineGeometry.normalizedOffset(
        point: BridgeEnginePoint(x: 150, y: 100),
        in: BridgeUIRect(x: 100, y: 50, width: 200, height: 100)
    ))
    try expectEqual(offset.dx, 0.25, "dx")
    try expectEqual(offset.dy, 0.5, "dy")
}

func screenshotPolicy() throws {
    let params = try BridgeEngineParameters(.object([
        "format": .string("png"),
        "quality": .double(0.2),
        "scale": .double(2.5),
    ]))
    let request = try BridgeEngineScreenshotPolicy.request(params, nativeScale: 2)
    try expectEqual(request.format, .png, "format")
    try expectEqual(request.quality, 0.2, "quality")
    try expectEqual(request.requestedScale, 2, "scale capped to native")
    let metrics = try unwrap(BridgeEngineScreenMetrics(pointWidth: 1_366,
                                                       pointHeight: 1_024,
                                                       pixelWidth: 2_732,
                                                       pixelHeight: 2_048))
    let dims = try unwrap(BridgeEngineScreenshotPolicy.pixelDimensions(metrics: metrics, scale: 2))
    try expectEqual(dims.width, 2_732, "pixel width")
    try expectEqual(dims.height, 2_048, "pixel height")
}

// MARK: - OCR

func ocrGeometryAndSecureMasking() throws {
    let observations = [
        BridgeEngineOCRTextObservation(text: "Second",
                                       confidence: 0.9,
                                       normalizedX: 0.1, normalizedY: 0.1,
                                       normalizedWidth: 0.2, normalizedHeight: 0.05),
        BridgeEngineOCRTextObservation(text: "First",
                                       confidence: 0.8,
                                       normalizedX: 0.1, normalizedY: 0.7,
                                       normalizedWidth: 0.2, normalizedHeight: 0.05),
        BridgeEngineOCRTextObservation(text: "Low",
                                       confidence: 0.1,
                                       normalizedX: 0.1, normalizedY: 0.5,
                                       normalizedWidth: 0.2, normalizedHeight: 0.05),
        BridgeEngineOCRTextObservation(text: "Secret",
                                       confidence: 0.99,
                                       normalizedX: 0.5, normalizedY: 0.2,
                                       normalizedWidth: 0.2, normalizedHeight: 0.1),
    ]
    let secure = BridgeUIRect(x: 400, y: 600, width: 300, height: 200)
    let items = BridgeEngineOCRGeometry.items(
        from: observations,
        minimumConfidence: 0.3,
        imagePointWidth: 1_000,
        imagePointHeight: 1_000,
        secureRects: [secure],
        query: nil
    )
    try expectEqual(items.map(\.label), ["First", "Second"], "reading order and filters")
    let first = try unwrap(items.first)
    try expectClose(first.frame.x, 100, "ocr x")
    try expectClose(first.frame.y, 250, "ocr y (bottom-left converted)")
    try expectClose(first.frame.width, 200, "ocr width")
    try expectClose(first.frame.height, 50, "ocr height")
    try expectClose(first.centerX, 200, "center x")
    try expectEqual(first.confidence, 0.8, "confidence")
    let filtered = BridgeEngineOCRGeometry.items(
        from: observations,
        minimumConfidence: 0.3,
        imagePointWidth: 1_000,
        imagePointHeight: 1_000,
        secureRects: [secure],
        query: "second"
    )
    try expectEqual(filtered.map(\.label), ["Second"], "query filter")
    let clamped = BridgeEngineOCRGeometry.items(
        from: observations,
        minimumConfidence: -1,
        imagePointWidth: 1_000,
        imagePointHeight: 1_000,
        secureRects: [secure],
        query: nil
    )
    try expectEqual(clamped.count, 3, "negative confidence clamps to the declared floor")
}

// MARK: - Tree

func node(_ type: String,
          label: String,
          identifier: String = "",
          value: String? = nil,
          secure: Bool = false,
          frame: BridgeUIRect = BridgeUIRect(x: 0, y: 0, width: 100, height: 40),
          children: [BridgeEngineTreeNode] = [],
          adapterTruncated: Bool = false) -> BridgeEngineTreeNode {
    BridgeEngineTreeNode(type: type,
                         typeRaw: 0,
                         identifier: identifier,
                         label: label,
                         value: value,
                         placeholderValue: nil,
                         frame: frame,
                         isEnabled: true,
                         isSelected: false,
                         hasFocus: false,
                         isSecure: secure,
                         children: children,
                         adapterTruncated: adapterTruncated)
}

func treeRenderFilterAndRedaction() throws {
    let root = node("Application", label: "App", children: [
        node("Window", label: "Window", children: [
            node("Button", label: "Save", identifier: "save"),
            node("SecureTextField", label: "Password", value: "hunter2", secure: true),
            node("StaticText", label: "Other", value: "visible"),
        ]),
    ])
    let full = BridgeEngineTreeText.render(root: root)
    try expect(full.source.contains("Button"), "button rendered")
    try expect(full.source.contains("Save"), "label rendered")
    try expect(full.source.contains("value: <redacted>"), "secure value redacted")
    try expect(!full.source.contains("hunter2"), "secure bytes never rendered")
    try expect(full.source.contains("visible"), "ordinary value rendered")
    try expectEqual(full.totalReturned, 5, "all nodes")

    let filter = BridgeEngineTreeFilter(field: .label, value: "save")
    let filtered = BridgeEngineTreeText.render(
        root: root,
        options: BridgeEngineTreeOptions(filter: filter)
    )
    try expect(filtered.source.contains("Button"), "matching node")
    try expect(filtered.source.contains("Application"), "root ancestor")
    try expect(filtered.source.contains("Window"), "parent ancestor")
    try expect(!filtered.source.contains("Password"), "non-matching sibling excluded")
    try expectEqual(filtered.totalReturned, 3, "filtered count")
}

func treeVisibleOnlyAndTruncation() throws {
    let root = node("Application", label: "App", frame: BridgeUIRect(x: 0, y: 0, width: 1_000, height: 1_000), children: [
        node("Button", label: "Visible", frame: BridgeUIRect(x: 10, y: 10, width: 100, height: 40)),
        node("Button", label: "Offscreen", frame: BridgeUIRect(x: 10, y: 2_000, width: 100, height: 40)),
    ])
    let visible = BridgeEngineTreeText.render(
        root: root,
        options: BridgeEngineTreeOptions(visibleOnly: true,
                                         screen: BridgeUIRect(x: 0, y: 0, width: 1_000, height: 1_000))
    )
    try expect(visible.source.contains("Visible"), "visible node")
    try expect(!visible.source.contains("Offscreen"), "offscreen node excluded")
    try expect(visible.source.contains("Application"), "root path kept")

    let limited = BridgeEngineTreeText.render(
        root: root,
        options: BridgeEngineTreeOptions(maxNodes: 1)
    )
    try expect(limited.truncatedNodes, "node truncation reported")
    try expectEqual(limited.totalReturned, 1, "one rendered node")

    let adapterLimited = BridgeEngineTreeText.render(
        root: node("Application", label: "App", adapterTruncated: true)
    )
    try expect(adapterLimited.truncated, "adapter truncation is reported")
}

// MARK: - Selector

func candidate(label: String,
               identifier: String = "",
               type: String = "Button",
               frame: BridgeUIRect = BridgeUIRect(x: 0, y: 0, width: 10, height: 10)) -> BridgeEngineElementCandidate {
    BridgeEngineElementCandidate(identifier: identifier,
                                 label: label,
                                 value: nil,
                                 type: type,
                                 typeRaw: 0,
                                 frame: frame,
                                 isHittable: true)
}

func selectorUniqueAndTypes() throws {
    let values = [
        candidate(label: "Save", identifier: "save"),
        candidate(label: "Save All", identifier: "save-all"),
        candidate(label: "Name", identifier: "name", type: "TextField"),
        candidate(label: "Search", identifier: "search", type: "SearchField"),
    ]
    let exact = BridgeEngineElementSelector.matches(candidates: values,
                                                    query: "save",
                                                    mode: .exact,
                                                    elementType: nil)
    try expectEqual(exact.count, 1, "exact count")
    if case .unique = BridgeEngineElementSelector.selectUnique(exact) {
    } else {
        throw TestFailure(message: "exact unique failed")
    }
    let contains = BridgeEngineElementSelector.matches(candidates: values,
                                                       query: "sav",
                                                       mode: .contains,
                                                       elementType: nil)
    try expectEqual(contains.count, 2, "contains count")
    if case .ambiguous = BridgeEngineElementSelector.selectUnique(contains) {
    } else {
        throw TestFailure(message: "tie not ambiguous")
    }
    let textFields = BridgeEngineElementSelector.matches(candidates: values,
                                                         query: "name",
                                                         mode: .exact,
                                                         elementType: "textfield")
    try expectEqual(textFields.count, 1, "textfield alias")
    let searchFields = BridgeEngineElementSelector.matches(candidates: values,
                                                           query: "search",
                                                           mode: .exact,
                                                           elementType: "TextField")
    try expectEqual(searchFields.count, 1, "searchfield matches textfield")
}

func refStoreBounded() throws {
    let store = BridgeEngineElementRefStore()
    for index in 0..<(BridgeEngineElementRefStore.maximumRefs + 5) {
        _ = store.store(bundleIdentifier: "b", candidate: candidate(label: "L\(index)"))
    }
    try expectEqual(store.count, BridgeEngineElementRefStore.maximumRefs, "ref cap")
    try expect(store.resolve("e1") == nil, "oldest evicted")
    try expect(store.resolve("e\(BridgeEngineElementRefStore.maximumRefs + 5)") != nil, "newest retained")
    try expectEqual(store.clear(), BridgeEngineElementRefStore.maximumRefs, "clear count")
}

// MARK: - Input policy

func inputPolicyMatrix() throws {
    let ordinary = BridgeEngineInputPolicy.decide(
        screenLocked: false,
        bundleIdentifier: "com.example.app",
        focusedEditable: true,
        focusedSecure: false,
        sensitiveInputGranted: false,
        redactedTypingAvailable: true
    )
    try expect(ordinary.allowed, "ordinary input allowed")
    let secure = BridgeEngineInputPolicy.decide(
        screenLocked: false,
        bundleIdentifier: "com.example.app",
        focusedEditable: true,
        focusedSecure: true,
        sensitiveInputGranted: false,
        redactedTypingAvailable: true
    )
    try expect(!secure.allowed && secure.requiresSensitiveGrant, "secure needs grant")
    let granted = BridgeEngineInputPolicy.decide(
        screenLocked: false,
        bundleIdentifier: "com.example.app",
        focusedEditable: true,
        focusedSecure: true,
        sensitiveInputGranted: true,
        redactedTypingAvailable: true
    )
    try expect(granted.allowed && granted.usesRedactedTyping, "granted secure allowed")
    let noRedaction = BridgeEngineInputPolicy.decide(
        screenLocked: false,
        bundleIdentifier: "com.example.app",
        focusedEditable: true,
        focusedSecure: true,
        sensitiveInputGranted: true,
        redactedTypingAvailable: false
    )
    try expect(!noRedaction.allowed, "no redaction path refused")
    let locked = BridgeEngineInputPolicy.decide(
        screenLocked: true,
        bundleIdentifier: "com.example.app",
        focusedEditable: true,
        focusedSecure: false,
        sensitiveInputGranted: true,
        redactedTypingAvailable: true
    )
    try expect(!locked.allowed, "locked refused")
    let system = BridgeEngineInputPolicy.decide(
        screenLocked: false,
        bundleIdentifier: "com.apple.springboard",
        focusedEditable: true,
        focusedSecure: false,
        sensitiveInputGranted: true,
        redactedTypingAvailable: true
    )
    try expect(!system.allowed, "system surface refused")
    let noFocus = BridgeEngineInputPolicy.decide(
        screenLocked: false,
        bundleIdentifier: "com.example.app",
        focusedEditable: false,
        focusedSecure: false,
        sensitiveInputGranted: true,
        redactedTypingAvailable: true
    )
    try expect(!noFocus.allowed, "no focus refused")

    // Ordinary Apple apps remain usable for non-secure text.
    for bundle in ["com.apple.Preferences", "com.apple.mobilesafari", "com.apple.Notes"] {
        let applesOrdinary = BridgeEngineInputPolicy.decide(
            screenLocked: false,
            bundleIdentifier: bundle,
            focusedEditable: true,
            focusedSecure: false,
            sensitiveInputGranted: false,
            redactedTypingAvailable: true
        )
        try expect(applesOrdinary.allowed, "ordinary Apple app text allowed: \(bundle)")
    }
    // Secure input in an Apple-owned app is outside the third-party grant.
    let appleSecureGranted = BridgeEngineInputPolicy.decide(
        screenLocked: false,
        bundleIdentifier: "com.apple.mobilesafari",
        focusedEditable: true,
        focusedSecure: true,
        sensitiveInputGranted: true,
        redactedTypingAvailable: true
    )
    try expect(!appleSecureGranted.allowed, "Apple app secure input refused even with grant")
    // Authorization overlays are refused even for non-secure text, with grant.
    for bundle in ["com.apple.AuthKitUI",
                   "com.apple.LocalAuthentication.RemoteUI",
                   "com.apple.AuthenticationServices.UI",
                   "com.apple.PasscodeSettings"] {
        let overlay = BridgeEngineInputPolicy.decide(
            screenLocked: false,
            bundleIdentifier: bundle,
            focusedEditable: true,
            focusedSecure: false,
            sensitiveInputGranted: true,
            redactedTypingAvailable: true
        )
        try expect(!overlay.allowed, "authorization overlay refused: \(bundle)")
    }
    try expect(BridgeEngineInputPolicy.isSystemOwnedApp(bundleIdentifier: "com.apple.Preferences"),
               "Apple app is system-owned")
    try expect(!BridgeEngineInputPolicy.isSystemOwnedApp(bundleIdentifier: "com.example.app"),
               "third-party app is not system-owned")
    try expect(BridgeEngineInputPolicy.isSystemSecureSettingsSurface(
        bundleIdentifier: "com.apple.Preferences"),
               "Settings is a secure-settings surface")
    try expect(!BridgeEngineInputPolicy.isSystemSecureSettingsSurface(
        bundleIdentifier: "com.apple.mobilesafari"),
               "Safari is not a passcode-settings surface")
}

// MARK: - Serial gate

func serialGateSerializes() async throws {
    let gate = BridgeEngineSerialGate()
    try expect(gate.tryAcquire(), "first acquire")
    try expect(!gate.tryAcquire(), "second tryAcquire refused")
    let waiter = Task {
        await gate.acquire()
        gate.release()
    }
    try await Task.sleep(for: .milliseconds(100))
    try expect(gate.hasWaiters, "waiter queued")
    gate.release()
    await waiter.value
    try expect(!gate.isBusy, "gate released")
}

// MARK: - Coordinator cancellation

final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var flag: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock(); value = true; lock.unlock()
    }
}

struct SlowPreDispatchExecutor: BridgeRPCExecutor {
    let readiness: BridgeRPCEngineReadiness
    let supportedMethods: Set<String>
    let acted: FlagBox

    func execute(_ invocation: BridgeRPCInvocation,
                 permit: BridgeRPCDispatchPermit) async -> BridgeRPCExecutionOutcome {
        try? await Task.sleep(for: .milliseconds(250))
        guard permit.authorizeDispatch() else {
            return .failure(.fenced)
        }
        acted.set()
        return .success(.bool(true))
    }
}

struct PublishedExecutor: BridgeRPCExecutor {
    let readiness: BridgeRPCEngineReadiness
    let supportedMethods: Set<String>
    let acted: FlagBox

    func execute(_ invocation: BridgeRPCInvocation,
                 permit: BridgeRPCDispatchPermit) async -> BridgeRPCExecutionOutcome {
        guard permit.authorizeDispatch() else { return .failure(.fenced) }
        acted.set()
        try? await Task.sleep(for: .milliseconds(250))
        guard permit.canContinueExecution else {
            return .sideEffectUnknown(code: "fenced", message: "entered call cannot be undone")
        }
        return .success(.bool(true))
    }
}

func makeInvocation(method: String) -> BridgeRPCInvocation {
    BridgeRPCInvocation(operationID: "op-1",
                        clientID: "client",
                        method: method,
                        params: .object([:]),
                        sensitiveInputGranted: false,
                        receivedAt: Date())
}

func makeFence() -> BridgeRPCExecutionFence {
    BridgeRPCExecutionFence(clientID: "client",
                            authEpoch: 1,
                            clientRevision: 1,
                            engineGeneration: 1,
                            serviceEpoch: 1)
}

func coordinatorFencesPreDispatch() async throws {
    let coordinator = BridgeRPCExecutionCoordinator(
        limits: BridgeRPCLimits(executionTimeout: 0.05)
    )
    let acted = FlagBox()
    let executor = SlowPreDispatchExecutor(
        readiness: .ready(generation: 1),
        supportedMethods: ["wait"],
        acted: acted
    )
    let result = await coordinator.submit(
        invocation: makeInvocation(method: "wait"),
        paramsDigest: "digest",
        executor: executor,
        fence: makeFence(),
        isCurrent: { true }
    )
    try expect(!result.dispatched, "pre-dispatch timeout is not dispatched")
    try expect(!acted.flag, "no SDK action after pre-dispatch timeout")
    if case .success = result.outcome {
        throw TestFailure(message: "pre-dispatch timeout reported success")
    }
    let repeatResult = await coordinator.submit(
        invocation: makeInvocation(method: "wait"),
        paramsDigest: "digest",
        executor: executor,
        fence: makeFence(),
        isCurrent: { true }
    )
    if case .success = repeatResult.outcome {
        throw TestFailure(message: "timed-out operation replayed")
    }
}

func coordinatorTimeoutNeverReplays() async throws {
    let coordinator = BridgeRPCExecutionCoordinator(
        limits: BridgeRPCLimits(executionTimeout: 0.05)
    )
    let acted = FlagBox()
    let executor = PublishedExecutor(
        readiness: .ready(generation: 1),
        supportedMethods: ["wait"],
        acted: acted
    )
    let result = await coordinator.submit(
        invocation: makeInvocation(method: "wait"),
        paramsDigest: "digest",
        executor: executor,
        fence: makeFence(),
        isCurrent: { true }
    )
    try expect(result.dispatched, "entered operation is dispatched")
    try expect(acted.flag, "entered operation actually ran")
    if case .success = result.outcome {
        throw TestFailure(message: "timed-out entered operation reported success")
    }
    // Let the executor return so its retained slot is released before the
    // suite exits.
    try await Task.sleep(for: .milliseconds(350))
}

// MARK: - Method catalog

func methodCatalogHonest() throws {
    let registryMethods = Set(BridgeRPCMethodRegistry.methods.map(\.name))
    let hostHandled: Set<String> = ["config", "logs", "stream_ticket"]
    try expectEqual(BridgeEngineMethodCatalog.implementedMethods,
                    registryMethods.subtracting(hostHandled),
                    "engine implements every non-host registry method exactly once")
    try expectEqual(BridgeEngineMethodCatalog.implementedMethods.count, 30, "30 engine methods")
    let all = BridgeEngineMethodCatalog.supportedMethods(capabilities: Set(BridgeEnginePrivateCapability.allCases))
    try expect(all.contains("tap"), "tap supported")
    try expect(all.contains("screen_text"), "ocr supported")
    try expect(all.contains("type"), "type with redaction")
    try expect(all.contains("lock"), "lock with button+state")
    try expect(!all.contains("config"), "host method absent")
    try expect(!all.contains("logs"), "host method absent")
    let noPrivate = BridgeEngineMethodCatalog.supportedMethods(capabilities: [])
    try expect(!noPrivate.contains("type"), "type removed without redaction")
    try expect(!noPrivate.contains("clear_text"), "clear removed without redaction")
    try expect(!noPrivate.contains("lock"), "lock removed without button")
    try expect(!noPrivate.contains("unlock"), "unlock removed without lock state")
    try expect(!noPrivate.contains("is_locked"), "is_locked removed without lock state")
    try expect(noPrivate.contains("tap"), "tap remains public")
    try expect(noPrivate.contains("home"), "home remains public")
}

// MARK: - Registry

struct FakeExecutor: BridgeRPCExecutor {
    var readiness: BridgeRPCEngineReadiness
    var supportedMethods: Set<String>

    func execute(_ invocation: BridgeRPCInvocation,
                 permit: BridgeRPCDispatchPermit) async -> BridgeRPCExecutionOutcome {
        .success(.bool(true))
    }
}

func registryFirstWins() throws {
    let registry = BridgeRPCEngineRegistry()
    let first = FakeExecutor(readiness: .ready(generation: 99), supportedMethods: ["tap"])
    switch registry.register(owner: "one", executor: first) {
    case .registered(let generation): try expectEqual(generation, 1, "first generation")
    default: throw TestFailure(message: "first registration failed")
    }
    switch registry.register(owner: "one", executor: first) {
    case .alreadyRegistered(let generation): try expectEqual(generation, 1, "idempotent")
    default: throw TestFailure(message: "same owner not idempotent")
    }
    let second = FakeExecutor(readiness: .ready(generation: 99), supportedMethods: ["swipe"])
    switch registry.register(owner: "two", executor: second) {
    case .rejected: break
    default: throw TestFailure(message: "replacement accepted")
    }
    let snapshot = registry.snapshot()
    try expectEqual(snapshot.generation, 1, "registry generation")
    try expectEqual(snapshot.readiness, .ready(generation: 1), "registry owns readiness generation")
    try expect(registry.unregister(owner: "one"), "unregister")
    switch registry.register(owner: "three", executor: second) {
    case .rejected: break
    default: throw TestFailure(message: "post-unregister replacement accepted")
    }
}

// MARK: - Touch authorization and lock state

private func touchDecision(
    authorization: BridgeEngineInvocationAuthorization? = nil,
    locked: Bool = false,
    authSurface: Bool = false,
    bundle: String? = "com.example.app",
    foreground: String? = "com.example.app",
    focusKnown: Bool = true,
    secure: Bool = false,
    grant: Bool = false,
    useNilAuthorization: Bool = false
) -> BridgeEngineTouchDecision {
    let context = useNilAuthorization ? nil : (authorization ?? BridgeEngineInvocationAuthorization(
        clientID: "client-a",
        operationID: "op-1",
        sensitiveInputGranted: grant
    ))
    return BridgeEngineTouchPolicy.decide(
        authorization: context,
        screenLocked: locked,
        authorizationSurfacePresent: authSurface,
        bundleIdentifier: bundle,
        foregroundBundleIdentifier: foreground,
        focusStateKnown: focusKnown,
        focusedSecure: secure
    )
}

func touchPolicyMatrix() throws {
    let ordinary = touchDecision()
    try expect(ordinary.allowed, "ordinary touch allowed")

    var secure = touchDecision(secure: true)
    try expect(!secure.allowed && secure.requiresSensitiveGrant, "secure touch needs grant")
    secure = touchDecision(secure: true, grant: true)
    try expect(secure.allowed, "granted third-party secure touch allowed")

    let granted = BridgeEngineInvocationAuthorization(clientID: "client-a",
                                                      operationID: "op-1",
                                                      sensitiveInputGranted: true)
    let appleSecure = touchDecision(authorization: granted, bundle: "com.apple.mobilesafari",
                                    foreground: "com.apple.mobilesafari", secure: true, grant: true)
    try expect(!appleSecure.allowed, "Apple app secure touch refused even with grant")

    let appleOrdinary = touchDecision(bundle: "com.apple.Preferences",
                                      foreground: "com.apple.Preferences")
    try expect(appleOrdinary.allowed, "ordinary Settings touch allowed")

    let locked = touchDecision(locked: true, secure: true, grant: true)
    try expect(!locked.allowed, "locked touch refused")

    let auth = touchDecision(authSurface: true, grant: true)
    try expect(!auth.allowed, "authorization overlay touch refused")

    for bundle in ["com.apple.springboard",
                   "com.apple.AuthKitUI",
                   "com.apple.LocalAuthentication.RemoteUI",
                   "com.apple.AuthenticationServices.UI",
                   "com.apple.PasscodeSettings"] {
        let surface = touchDecision(bundle: bundle, foreground: bundle,
                                    secure: true, grant: true)
        try expect(!surface.allowed, "system auth surface touch refused: \(bundle)")
    }
    let settingsSecure = touchDecision(bundle: "com.apple.Preferences",
                                       foreground: "com.apple.Preferences",
                                       secure: true, grant: true)
    try expect(!settingsSecure.allowed,
               "Apple Settings secure touch refused even with grant")

    let unknownFocus = touchDecision(focusKnown: false)
    try expect(!unknownFocus.allowed, "unknown focus refused")

    let notForeground = touchDecision(foreground: "com.example.other")
    try expect(!notForeground.allowed, "target not foreground refused")
    let noForeground = touchDecision(foreground: nil)
    try expect(!noForeground.allowed, "missing foreground refused")
    let noBundle = touchDecision(bundle: nil)
    try expect(!noBundle.allowed, "missing bundle refused")

    let noContext = touchDecision(useNilAuthorization: true)
    try expect(!noContext.allowed, "missing authorization context refused")

    let inactive = BridgeEngineInvocationAuthorization(clientID: "client-a",
                                                       operationID: "op-1",
                                                       sensitiveInputGranted: true)
    inactive.invalidate()
    let invalidated = touchDecision(authorization: inactive, secure: true, grant: true)
    try expect(!invalidated.allowed, "invalidated context refused even with grant")
}

func touchGateNeverCallsDeniedBody() throws {
    var touches = 0
    let denied: [BridgeEngineTouchDecision] = [
        touchDecision(secure: true),
        touchDecision(bundle: "com.apple.preferences",
                      foreground: "com.apple.preferences", secure: true, grant: true),
        touchDecision(bundle: "com.apple.springboard",
                      foreground: "com.apple.springboard", secure: true, grant: true),
        touchDecision(bundle: "com.apple.AuthKitUI",
                      foreground: "com.apple.AuthKitUI", secure: true, grant: true),
        touchDecision(locked: true, secure: true, grant: true),
        touchDecision(focusKnown: false, grant: true),
        touchDecision(foreground: "com.example.other", grant: true)
    ]
    for decision in denied {
        let result: Void? = BridgeEngineTouchPolicy.authorize(decision) { touches += 1 }
        try expect(result == nil, "denied gate returns nil")
    }
    try expectEqual(touches, 0, "no denied scenario calls the touch body")

    let allowed: [BridgeEngineTouchDecision] = [
        touchDecision(),
        touchDecision(secure: true, grant: true)
    ]
    for decision in allowed {
        let result: Void? = BridgeEngineTouchPolicy.authorize(decision) { touches += 1 }
        try expect(result != nil, "allowed gate runs the body")
    }
    try expectEqual(touches, allowed.count, "allowed decisions call the touch body")
}

func authorizationContextLifecycle() throws {
    let first = BridgeEngineInvocationAuthorization(clientID: "client-a",
                                                    operationID: "op-1",
                                                    sensitiveInputGranted: true)
    try expect(first.isActive, "new context active")
    let allowed = touchDecision(authorization: first, secure: true, grant: true)
    try expect(allowed.allowed, "active granted context allows secure touch")
    first.invalidate()
    try expect(!first.isActive, "invalidated context inactive")
    let afterInvalidate = touchDecision(authorization: first, secure: true, grant: true)
    try expect(!afterInvalidate.allowed, "invalidated context cannot authorize")

    // A second invocation is a separate object; the first cannot act through
    // it, and a no-grant context cannot borrow the earlier grant.
    let second = BridgeEngineInvocationAuthorization(clientID: "client-b",
                                                     operationID: "op-2",
                                                     sensitiveInputGranted: false)
    let secondDecision = touchDecision(authorization: second, secure: true)
    try expect(!secondDecision.allowed, "a different client context carries its own grant")
    try expectEqual(second.clientID, "client-b", "context client identity")
    try expectEqual(second.operationID, "op-2", "context operation identity")
}

func lockStateClassifier() throws {
    try expectEqual(BridgeEngineLockState.classify(available: false, known: false,
                                                   rawLocked: false),
                    .unavailable, "unavailable source")
    try expectEqual(BridgeEngineLockState.classify(available: true, known: false,
                                                   rawLocked: false),
                    .unknown, "registered but never read")
    try expectEqual(BridgeEngineLockState.classify(available: true, known: false,
                                                   rawLocked: true),
                    .unknown, "failed read is unknown even if raw bit is set")
    try expectEqual(BridgeEngineLockState.classify(available: true, known: true,
                                                   rawLocked: true),
                    .locked, "known locked")
    try expectEqual(BridgeEngineLockState.classify(available: true, known: true,
                                                   rawLocked: false),
                    .unlocked, "known unlocked")
    try expect(!BridgeEngineLockState.unavailable.permitsAutomation, "unavailable refuses")
    try expect(!BridgeEngineLockState.unknown.permitsAutomation, "unknown refuses")
    try expect(!BridgeEngineLockState.locked.permitsAutomation, "locked refuses")
    try expect(BridgeEngineLockState.unlocked.permitsAutomation, "unlocked permits")
}

func captureAdmissionPostStopLock() throws {
    func admission(entry: Bool = true,
                   running: Bool = true,
                   pid: Bool = true,
                   service: Bool = true,
                   ready: Bool = true,
                   generation: Bool = true,
                   lock: BridgeEngineLockState = .unlocked,
                   heartbeat: Bool = true) -> Bool {
        BridgeEngineCaptureAdmission.allows(entryAccepted: entry,
                                            engineRunning: running,
                                            enginePidMatches: pid,
                                            serviceRunning: service,
                                            phaseReady: ready,
                                            generationMatches: generation,
                                            lockState: lock,
                                            heartbeatCurrent: heartbeat)
    }
    try expect(admission(), "healthy capture admitted")
    try expect(!admission(running: false), "Stop refuses capture")
    try expect(!admission(entry: false), "unaccepted entry refuses capture")
    try expect(!admission(pid: false), "foreign pid refuses capture")
    try expect(!admission(service: false), "stopped service refuses capture")
    try expect(!admission(ready: false), "non-ready phase refuses capture")
    try expect(!admission(generation: false), "captured generation mismatch refuses late frame")
    try expect(!admission(lock: .locked), "lock refuses capture")
    try expect(!admission(lock: .unknown), "unknown lock refuses capture")
    try expect(!admission(lock: .unavailable), "unavailable lock refuses capture")
    try expect(!admission(heartbeat: false), "stale heartbeat refuses capture")
}

func safeDiagnosticLine() throws {
    let sentinel = "SENTINEL-PASSWORD-7731"
    let error = NSError(domain: "sensitive.example",
                        code: 42,
                        userInfo: [NSLocalizedDescriptionKey: sentinel])
    let line = BridgeEngineSafeDiagnostic.exceptionLine(stage: "tap",
                                                        error: error,
                                                        sensitive: false)
    try expect(!line.contains(sentinel), "exception description never reaches the log line")
    try expect(!line.contains("sensitive.example"), "exception domain never reaches the log line")
    try expect(line.contains("stage=tap"), "stage retained")
    try expect(line.contains("kind=objc"), "fixed kind retained")
    try expect(line.contains("code=42"), "numeric code retained")
    try expect(line.contains("sensitive=0"), "sensitivity flag retained")
    let injected = BridgeEngineSafeDiagnostic.exceptionLine(stage: "tap \(sentinel) /x",
                                                           error: nil,
                                                           sensitive: true)
    try expect(!injected.contains(sentinel), "stage filter removes injected text")
    try expect(injected.contains("sensitive=1"), "sensitive exception line")
}

func issueSanitizer() throws {
    let sentinel = "SENTINEL-TYPED-PASSWORD-99117"
    let error = NSError(domain: "sensitive.example",
                        code: 9,
                        userInfo: [NSLocalizedDescriptionKey: sentinel])
    let attachment = XCTAttachment(string: sentinel)
    let original = XCTIssue(type: .system,
                            compactDescription: "compact \(sentinel)",
                            detailedDescription: "detailed \(sentinel)",
                            sourceCodeContext: XCTSourceCodeContext(),
                            associatedError: error,
                            attachments: [attachment],
                            severity: .error)
    let safe = BridgeEngineIssueSanitizer.sanitized(original)
    try expectEqual(safe.type, original.type, "issue type preserved")
    try expectEqual(safe.severity, original.severity, "issue severity preserved")
    try expect(safe.sourceCodeContext === original.sourceCodeContext,
               "source context preserved")
    try expect(!safe.compactDescription.contains(sentinel),
               "compact description has no input text")
    try expect(safe.detailedDescription == nil,
               "detailed description removed")
    try expect(safe.associatedError == nil,
               "associated error removed")
    try expect(safe.attachments.isEmpty,
               "attachments removed")
}

func issueCaptureCount() throws {
    let capture = BridgeEngineIssueCapture()
    let token = capture.begin()
    capture.noteIssue()
    capture.noteIssue()
    try expectEqual(capture.end(token), 2, "issue count preserved")
    try expectEqual(capture.end(token), 0, "ended scope cannot be reused")
}

func legacyFileLaneProductBoundary() throws {
    // The shipped product flag is off. This is the negative release condition:
    // the embedded product engine must not claim/execute legacy file commands
    // or load-or-create the legacy install token.
    try expect(!BridgeBuild.prototypeDiagnostics,
               "product prototype diagnostic flag is off")

    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // EngineRPC
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // FloeIOSBridge
        .deletingLastPathComponent() // repository root
        .appendingPathComponent("FloeIOSBridge/Sources/BridgeTests/BridgeEngineTests.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    guard let functionStart = source.range(of: "private func processPendingCommands()")?.lowerBound else {
        throw TestFailure(message: "processPendingCommands source not found")
    }
    guard let functionEnd = source.range(of: "private func execute(_ command:",
                                         range: functionStart..<source.endIndex)?.lowerBound else {
        throw TestFailure(message: "processPendingCommands end not found")
    }
    let body = source[functionStart..<functionEnd]
    guard let guardRange = body.range(of: "guard BridgeBuild.prototypeDiagnostics else { return }") else {
        throw TestFailure(message: "product boundary guard missing")
    }
    let beforeGuard = body[..<guardRange.lowerBound]
    try expect(!beforeGuard.contains("BridgeFileChannel"),
               "no pending-file access before the product boundary guard")
    try expect(!beforeGuard.contains("BridgeInstallToken"),
               "no install-token access before the product boundary guard")
    try expect(!beforeGuard.contains("tryAcquire"),
               "no SDK gate acquisition before the product boundary guard")

    for marker in ["BridgeFileChannel.pending",
                   "sharedGate.tryAcquire",
                   "BridgeInstallToken.load",
                   "loadOrCreate",
                   "BridgeFileChannel.claim",
                   "BridgeFileChannel.writeResult"] {
        guard let index = body.range(of: marker)?.lowerBound else {
            throw TestFailure(message: "prototype canary marker missing: \(marker)")
        }
        try expect(index > guardRange.lowerBound,
                   "prototype canary marker must follow the product guard: \(marker)")
    }
}

// MARK: - Text evidence and settle

func textEvidenceNoOpSemantics() throws {
    let append = BridgeTextValueAssessor.assess(beforeValue: "abc",
                                                beforeTrusted: true,
                                                request: "def",
                                                afterValue: "abcdef")
    try expect(append.appendVerified, "append verified")
    let noOp = BridgeTextValueAssessor.assess(beforeValue: "Floe",
                                              beforeTrusted: true,
                                              request: "Floe",
                                              afterValue: "Floe")
    try expect(!noOp.appendVerified, "unchanged is not append")
    try expect(noOp.valueMatchesRequest, "request-equal is still a weaker match")
    let unavailable = BridgeTextValueAssessor.assess(beforeValue: nil,
                                                     beforeTrusted: false,
                                                     request: "x",
                                                     afterValue: "x")
    try expect(!unavailable.appendVerified, "unavailable before is not verified")
}

func placeholderBeforeValueEvidence() throws {
    // A non-empty placeholder returned as the accessibility value is not an
    // empty field and is not a trusted append base.
    let placeholder = BridgeTextBeforeValueClassifier.classify(rawValue: "Search",
                                                               placeholderValue: "Search",
                                                               secure: false)
    try expectEqual(placeholder.observation, .placeholderAsValueUntrusted,
                    "placeholder-as-value is untrusted")
    try expect(!placeholder.trusted && !placeholder.emptyVerified,
               "placeholder-as-value is neither trusted nor empty")
    let placeholderAppend = BridgeTextValueAssessor.assess(
        beforeValue: placeholder.value,
        beforeTrusted: placeholder.trusted,
        request: "Floe",
        afterValue: "Floe"
    )
    try expect(!placeholderAppend.appendVerified,
               "placeholder-as-value cannot prove an append")
    try expect(!placeholderAppend.beforeTrusted,
               "assessment carries the untrusted before fact")
    try expectEqual(placeholderAppend.observation, "matches-request-before-unavailable",
                    "request match without a trusted base is weaker evidence")

    // Only an explicitly empty value establishes a known-empty base.
    let empty = BridgeTextBeforeValueClassifier.classify(rawValue: "",
                                                          placeholderValue: "Search",
                                                          secure: false)
    try expect(empty.trusted && empty.emptyVerified, "explicit empty is trusted")
    let emptyAppend = BridgeTextValueAssessor.assess(beforeValue: empty.value,
                                                     beforeTrusted: empty.trusted,
                                                     request: "Floe",
                                                     afterValue: "Floe")
    try expect(emptyAppend.appendVerified, "explicit empty base append verified")

    let actual = BridgeTextBeforeValueClassifier.classify(rawValue: "abc",
                                                           placeholderValue: "Search",
                                                           secure: false)
    try expect(actual.trusted && !actual.emptyVerified, "real value is trusted, not empty")
    let actualAppend = BridgeTextValueAssessor.assess(beforeValue: actual.value,
                                                      beforeTrusted: actual.trusted,
                                                      request: "def",
                                                      afterValue: "abcdef")
    try expect(actualAppend.appendVerified, "real value append verified")

    let inaccessible = BridgeTextBeforeValueClassifier.classify(rawValue: nil,
                                                                 placeholderValue: "Search",
                                                                 secure: false)
    try expect(!inaccessible.trusted && !inaccessible.emptyVerified,
               "unreadable value is untrusted")
    let secure = BridgeTextBeforeValueClassifier.classify(rawValue: "Search",
                                                           placeholderValue: "Search",
                                                           secure: true)
    try expect(!secure.trusted && !secure.emptyVerified,
               "secure value is never trusted or marked empty")
}

func settleParameters() throws {
    let defaults = try BridgeEngineSettleParameters.parse(BridgeEngineParameters(object: [:]))
    try expect(defaults.requested, "settle default")
    try expectEqual(defaults.timeout, 2, "settle timeout default")
    let disabled = try BridgeEngineSettleParameters.parse(BridgeEngineParameters(object: [
        "settle": .bool(false),
        "settle_timeout": .double(1.5),
    ]))
    try expect(!disabled.requested, "settle disabled")
    try expectEqual(disabled.timeout, 1.5, "settle timeout")
}

// MARK: - Helpers

func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw TestFailure(message: "unexpected nil") }
    return value
}

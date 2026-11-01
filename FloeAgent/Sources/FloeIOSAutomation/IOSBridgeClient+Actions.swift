// FloeIOSAutomation — typed, source-compatible action wrappers.
//
// Argument names and meanings follow the released Bridge v1 schema. The
// primary-owned `ios.bridge.observe` and `ios.bridge.control` tools can map
// their JSON arguments directly onto these methods.

import Foundation

public struct IOSAutomationPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    var jsonValue: IOSBridgeJSONValue {
        .object(["x": .double(x), "y": .double(y)])
    }
}

private func parameters(_ pairs: (String, IOSBridgeJSONValue?)...) -> IOSBridgeJSONValue {
    var object: [String: IOSBridgeJSONValue] = [:]
    for (name, value) in pairs {
        if let value { object[name] = value }
    }
    return .object(object)
}

public extension IOSBridgeClient {
    // MARK: - Observe

    func deviceInfo(
        context: IOSAutomationCallContext,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        await perform(.deviceInfo, context: context, timeout: timeout)
    }

    func pageSource(
        context: IOSAutomationCallContext,
        bundleID: String? = nil,
        filter: IOSBridgeJSONValue? = nil,
        maxDepth: Int? = nil,
        maxElements: Int? = nil,
        maxChildren: Int? = nil,
        enhanced: Bool? = nil,
        visibleOnly: Bool? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("bundle_id", bundleID.map(IOSBridgeJSONValue.string)),
            ("filter", filter),
            ("max_depth", maxDepth.map(IOSBridgeJSONValue.int)),
            ("max_elements", maxElements.map(IOSBridgeJSONValue.int)),
            ("max_children", maxChildren.map(IOSBridgeJSONValue.int)),
            ("enhanced", enhanced.map(IOSBridgeJSONValue.bool)),
            ("visible_only", visibleOnly.map(IOSBridgeJSONValue.bool))
        )
        return await perform(
            .pageSource,
            params: params,
            target: bundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    func screenText(
        context: IOSAutomationCallContext,
        elementID: String? = nil,
        match: String? = nil,
        scale: Double? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("element_id", elementID.map(IOSBridgeJSONValue.string)),
            ("match", match.map(IOSBridgeJSONValue.string)),
            ("scale", scale.map(IOSBridgeJSONValue.double))
        )
        return await perform(.screenText, params: params, context: context, timeout: timeout)
    }

    func screenshot(
        context: IOSAutomationCallContext,
        scale: Double? = nil,
        bundleID: String? = nil,
        format: String? = nil,
        quality: Double? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("scale", scale.map(IOSBridgeJSONValue.double)),
            ("bundle_id", bundleID.map(IOSBridgeJSONValue.string)),
            ("format", format.map(IOSBridgeJSONValue.string)),
            ("quality", quality.map(IOSBridgeJSONValue.double))
        )
        return await perform(
            .screenshot,
            params: params,
            target: bundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    func findElement(
        context: IOSAutomationCallContext,
        elementID: String,
        match: String? = nil,
        elementType: String? = nil,
        bundleID: String? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("element_id", .string(elementID)),
            ("match", match.map(IOSBridgeJSONValue.string)),
            ("element_type", elementType.map(IOSBridgeJSONValue.string)),
            ("bundle_id", bundleID.map(IOSBridgeJSONValue.string))
        )
        return await perform(
            .findElement,
            params: params,
            target: bundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    func listApps(
        context: IOSAutomationCallContext,
        text: String? = nil,
        elementType: String? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("text", text.map(IOSBridgeJSONValue.string)),
            ("element_type", elementType.map(IOSBridgeJSONValue.string))
        )
        return await perform(.listApps, params: params, context: context, timeout: timeout)
    }

    func resolveApp(
        context: IOSAutomationCallContext,
        text: String,
        country: String? = nil,
        distance: Int? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("text", .string(text)),
            ("country", country.map(IOSBridgeJSONValue.string)),
            ("distance", distance.map(IOSBridgeJSONValue.int))
        )
        return await perform(.resolveApp, params: params, context: context, timeout: timeout)
    }

    func isLocked(
        context: IOSAutomationCallContext,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        await perform(.isLocked, context: context, timeout: timeout)
    }

    func wait(
        context: IOSAutomationCallContext,
        duration: Double? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(("duration", duration.map(IOSBridgeJSONValue.double)))
        return await perform(.wait, params: params, context: context, timeout: timeout)
    }

    // MARK: - Control

    func tap(
        context: IOSAutomationCallContext,
        targetBundleID: String? = nil,
        ref: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        settle: Bool? = nil,
        settleTimeout: Double? = nil,
        fast: Bool? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("ref", ref.map(IOSBridgeJSONValue.string)),
            ("x", x.map(IOSBridgeJSONValue.double)),
            ("y", y.map(IOSBridgeJSONValue.double)),
            ("settle", settle.map(IOSBridgeJSONValue.bool)),
            ("settle_timeout", settleTimeout.map(IOSBridgeJSONValue.double)),
            ("fast", fast.map(IOSBridgeJSONValue.bool))
        )
        return await perform(
            .tap,
            params: params,
            target: targetBundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    func doubleTap(
        context: IOSAutomationCallContext,
        targetBundleID: String? = nil,
        ref: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        settle: Bool? = nil,
        settleTimeout: Double? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("ref", ref.map(IOSBridgeJSONValue.string)),
            ("x", x.map(IOSBridgeJSONValue.double)),
            ("y", y.map(IOSBridgeJSONValue.double)),
            ("settle", settle.map(IOSBridgeJSONValue.bool)),
            ("settle_timeout", settleTimeout.map(IOSBridgeJSONValue.double))
        )
        return await perform(
            .doubleTap,
            params: params,
            target: targetBundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    func longPress(
        context: IOSAutomationCallContext,
        targetBundleID: String? = nil,
        ref: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        duration: Double? = nil,
        settle: Bool? = nil,
        settleTimeout: Double? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("ref", ref.map(IOSBridgeJSONValue.string)),
            ("x", x.map(IOSBridgeJSONValue.double)),
            ("y", y.map(IOSBridgeJSONValue.double)),
            ("duration", duration.map(IOSBridgeJSONValue.double)),
            ("settle", settle.map(IOSBridgeJSONValue.bool)),
            ("settle_timeout", settleTimeout.map(IOSBridgeJSONValue.double))
        )
        return await perform(
            .longPress,
            params: params,
            target: targetBundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    func swipe(
        context: IOSAutomationCallContext,
        targetBundleID: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        direction: String? = nil,
        distance: Double? = nil,
        velocity: String? = nil,
        fast: Bool? = nil,
        settle: Bool? = nil,
        settleTimeout: Double? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("x", x.map(IOSBridgeJSONValue.double)),
            ("y", y.map(IOSBridgeJSONValue.double)),
            ("direction", direction.map(IOSBridgeJSONValue.string)),
            ("distance", distance.map(IOSBridgeJSONValue.double)),
            ("velocity", velocity.map(IOSBridgeJSONValue.string)),
            ("fast", fast.map(IOSBridgeJSONValue.bool)),
            ("settle", settle.map(IOSBridgeJSONValue.bool)),
            ("settle_timeout", settleTimeout.map(IOSBridgeJSONValue.double))
        )
        return await perform(
            .swipe,
            params: params,
            target: targetBundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    func page(
        context: IOSAutomationCallContext,
        targetBundleID: String? = nil,
        direction: String? = nil,
        distance: Double? = nil,
        settle: Bool? = nil,
        settleTimeout: Double? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("direction", direction.map(IOSBridgeJSONValue.string)),
            ("distance", distance.map(IOSBridgeJSONValue.double)),
            ("settle", settle.map(IOSBridgeJSONValue.bool)),
            ("settle_timeout", settleTimeout.map(IOSBridgeJSONValue.double))
        )
        return await perform(
            .page,
            params: params,
            target: targetBundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    func scroll(
        context: IOSAutomationCallContext,
        targetBundleID: String? = nil,
        direction: String? = nil,
        settle: Bool? = nil,
        settleTimeout: Double? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("direction", direction.map(IOSBridgeJSONValue.string)),
            ("settle", settle.map(IOSBridgeJSONValue.bool)),
            ("settle_timeout", settleTimeout.map(IOSBridgeJSONValue.double))
        )
        return await perform(
            .scroll,
            params: params,
            target: targetBundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    /// `collect` pages the live UI. It is classified as mutating even though
    /// the released schema calls it read.
    func collect(
        context: IOSAutomationCallContext,
        targetBundleID: String? = nil,
        pages: Int? = nil,
        direction: String? = nil,
        minLength: Int? = nil,
        fresh: Bool? = nil,
        source: String? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("pages", pages.map(IOSBridgeJSONValue.int)),
            ("direction", direction.map(IOSBridgeJSONValue.string)),
            ("min_length", minLength.map(IOSBridgeJSONValue.int)),
            ("fresh", fresh.map(IOSBridgeJSONValue.bool)),
            ("source", source.map(IOSBridgeJSONValue.string))
        )
        return await perform(
            .collect,
            params: params,
            target: targetBundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    /// `scroll_to_element` scrolls the live UI. It is classified as mutating
    /// even though the released schema calls it read.
    func scrollToElement(
        context: IOSAutomationCallContext,
        targetBundleID: String? = nil,
        elementID: String,
        match: String? = nil,
        elementType: String? = nil,
        direction: String? = nil,
        distance: Double? = nil,
        bundleID: String? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("element_id", .string(elementID)),
            ("match", match.map(IOSBridgeJSONValue.string)),
            ("element_type", elementType.map(IOSBridgeJSONValue.string)),
            ("direction", direction.map(IOSBridgeJSONValue.string)),
            ("distance", distance.map(IOSBridgeJSONValue.double)),
            ("bundle_id", bundleID.map(IOSBridgeJSONValue.string))
        )
        return await perform(
            .scrollToElement,
            params: params,
            target: (targetBundleID ?? bundleID).map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    func type(
        context: IOSAutomationCallContext,
        targetBundleID: String? = nil,
        text: String,
        clear: Bool? = nil,
        submit: Bool? = nil,
        x: Double? = nil,
        y: Double? = nil,
        fast: Bool? = nil,
        via: String? = nil,
        settle: Bool? = nil,
        settleTimeout: Double? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("text", .string(text)),
            ("clear", clear.map(IOSBridgeJSONValue.bool)),
            ("submit", submit.map(IOSBridgeJSONValue.bool)),
            ("x", x.map(IOSBridgeJSONValue.double)),
            ("y", y.map(IOSBridgeJSONValue.double)),
            ("fast", fast.map(IOSBridgeJSONValue.bool)),
            ("via", via.map(IOSBridgeJSONValue.string)),
            ("settle", settle.map(IOSBridgeJSONValue.bool)),
            ("settle_timeout", settleTimeout.map(IOSBridgeJSONValue.double))
        )
        return await perform(
            .type,
            params: params,
            target: targetBundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    func clearText(
        context: IOSAutomationCallContext,
        targetBundleID: String? = nil,
        settle: Bool? = nil,
        settleTimeout: Double? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("settle", settle.map(IOSBridgeJSONValue.bool)),
            ("settle_timeout", settleTimeout.map(IOSBridgeJSONValue.double))
        )
        return await perform(
            .clearText,
            params: params,
            target: targetBundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    func home(
        context: IOSAutomationCallContext,
        targetBundleID: String? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        await perform(
            .home,
            target: targetBundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    func lock(
        context: IOSAutomationCallContext,
        targetBundleID: String? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        await perform(
            .lock,
            target: targetBundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    func unlock(
        context: IOSAutomationCallContext,
        targetBundleID: String? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        await perform(
            .unlock,
            target: targetBundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    func openURL(
        context: IOSAutomationCallContext,
        url: URL,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        await perform(
            .openURL,
            params: .object(["url": .string(url.absoluteString)]),
            target: IOSAutomationTarget(url: url),
            context: context,
            timeout: timeout
        )
    }

    func launchApp(
        context: IOSAutomationCallContext,
        bundleID: String,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        await perform(
            .launchApp,
            params: .object(["bundle_id": .string(bundleID)]),
            target: IOSAutomationTarget(bundleIdentifier: bundleID),
            context: context,
            timeout: timeout
        )
    }

    func activateApp(
        context: IOSAutomationCallContext,
        bundleID: String,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        await perform(
            .activateApp,
            params: .object(["bundle_id": .string(bundleID)]),
            target: IOSAutomationTarget(bundleIdentifier: bundleID),
            context: context,
            timeout: timeout
        )
    }

    func terminateApp(
        context: IOSAutomationCallContext,
        bundleID: String,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        await perform(
            .terminateApp,
            params: .object(["bundle_id": .string(bundleID)]),
            target: IOSAutomationTarget(bundleIdentifier: bundleID),
            context: context,
            timeout: timeout
        )
    }

    func tapElement(
        context: IOSAutomationCallContext,
        targetBundleID: String? = nil,
        elementID: String,
        match: String? = nil,
        elementType: String? = nil,
        settle: Bool? = nil,
        settleTimeout: Double? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("element_id", .string(elementID)),
            ("match", match.map(IOSBridgeJSONValue.string)),
            ("element_type", elementType.map(IOSBridgeJSONValue.string)),
            ("settle", settle.map(IOSBridgeJSONValue.bool)),
            ("settle_timeout", settleTimeout.map(IOSBridgeJSONValue.double))
        )
        return await perform(
            .tapElement,
            params: params,
            target: targetBundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    func findAndTap(
        context: IOSAutomationCallContext,
        targetBundleID: String? = nil,
        elementID: String,
        match: String? = nil,
        elementType: String? = nil,
        bundleID: String? = nil,
        fast: Bool? = nil,
        settle: Bool? = nil,
        settleTimeout: Double? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("element_id", .string(elementID)),
            ("match", match.map(IOSBridgeJSONValue.string)),
            ("element_type", elementType.map(IOSBridgeJSONValue.string)),
            ("bundle_id", bundleID.map(IOSBridgeJSONValue.string)),
            ("fast", fast.map(IOSBridgeJSONValue.bool)),
            ("settle", settle.map(IOSBridgeJSONValue.bool)),
            ("settle_timeout", settleTimeout.map(IOSBridgeJSONValue.double))
        )
        return await perform(
            .findAndTap,
            params: params,
            target: (targetBundleID ?? bundleID).map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }

    func drag(
        context: IOSAutomationCallContext,
        targetBundleID: String? = nil,
        points: [IOSAutomationPoint]? = nil,
        fromRef: String? = nil,
        toRef: String? = nil,
        fromX: Double? = nil,
        fromY: Double? = nil,
        toX: Double? = nil,
        toY: Double? = nil,
        duration: Double? = nil,
        settle: Bool? = nil,
        settleTimeout: Double? = nil,
        timeout: TimeInterval? = nil
    ) async -> IOSAutomationReceipt {
        let params = parameters(
            ("points", points.map { .array($0.map(\.jsonValue)) }),
            ("from_ref", fromRef.map(IOSBridgeJSONValue.string)),
            ("to_ref", toRef.map(IOSBridgeJSONValue.string)),
            ("from_x", fromX.map(IOSBridgeJSONValue.double)),
            ("from_y", fromY.map(IOSBridgeJSONValue.double)),
            ("to_x", toX.map(IOSBridgeJSONValue.double)),
            ("to_y", toY.map(IOSBridgeJSONValue.double)),
            ("duration", duration.map(IOSBridgeJSONValue.double)),
            ("settle", settle.map(IOSBridgeJSONValue.bool)),
            ("settle_timeout", settleTimeout.map(IOSBridgeJSONValue.double))
        )
        return await perform(
            .drag,
            params: params,
            target: targetBundleID.map { IOSAutomationTarget(bundleIdentifier: $0) },
            context: context,
            timeout: timeout
        )
    }
}

import Foundation

/// A screen-space rectangle carried by the pure UI-tree and text-target
/// helpers. The embedded driver converts `CGRect`/element snapshots into this
/// value so the bounded trimming and selector rules stay testable without
/// importing XCTest or UIKit into BridgeCore.
public struct BridgeUIRect: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public var area: Double {
        guard width > 0, height > 0 else { return 0 }
        return width * height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func contains(x pointX: Double, y pointY: Double) -> Bool {
        guard !isEmpty else { return false }
        return pointX >= x && pointX <= x + width &&
            pointY >= y && pointY <= y + height
    }

    public func contains(_ other: BridgeUIRect) -> Bool {
        guard !isEmpty, !other.isEmpty else { return false }
        return other.x >= x && other.y >= y &&
            other.x + other.width <= x + width &&
            other.y + other.height <= y + height
    }

    public func approximatelyEquals(_ other: BridgeUIRect,
                                    tolerance: Double = 0.5) -> Bool {
        abs(x - other.x) <= tolerance &&
            abs(y - other.y) <= tolerance &&
            abs(width - other.width) <= tolerance &&
            abs(height - other.height) <= tolerance
    }

    /// Overlapping area in square points. Used to decide whether a live
    /// element still describes the same field the snapshot selected.
    public func intersectionArea(with other: BridgeUIRect) -> Double {
        let left = max(x, other.x)
        let top = max(y, other.y)
        let right = min(x + width, other.x + other.width)
        let bottom = min(y + height, other.y + other.height)
        guard right > left, bottom > top else { return 0 }
        return (right - left) * (bottom - top)
    }
}

/// A read-only view of one accessibility node. The embedded driver adapts
/// `XCUIElementSnapshot`; SelfCheck uses synthetic nodes with the same shape so
/// the exact production trimming code is exercised on the host.
///
/// Children are exposed by index rather than as an array. The renderer asks
/// for a child only after the same depth/node/byte budget admits it, so the
/// production adapter never recursively copies the already-materialized SDK
/// tree and never constructs descendants beyond the response bounds.
///
/// The protocol is main-actor because the real `XCUIElementSnapshot`
/// attributes are main-actor-isolated. The embedded engine's inspection path
/// already runs on the main actor; no `MainActor.assumeIsolated` is used on an
/// unknown thread.
@MainActor
public protocol BridgeUIElementNode {
    var uiElementTypeName: String { get }
    var uiElementTypeRawValue: Int { get }
    var uiIdentifier: String { get }
    var uiLabel: String { get }
    var uiValue: String? { get }
    var uiPlaceholderValue: String? { get }
    var uiFrameDescription: String { get }
    var uiIsEnabled: Bool { get }
    var uiIsSelected: Bool { get }
    var uiHasFocus: Bool { get }
    var uiIsSecureTextField: Bool { get }
    var uiChildCount: Int { get }
    func uiChild(at index: Int) -> Self?
}

/// Bounds for one `inspect_ui` response.
///
/// The default depth follows the pinned iCTRL `page_source` default of 40,
/// which is deep enough for the structural wrappers real SwiftUI/UIKit apps
/// put above their controls. The byte and node caps still make the result
/// finite: public `XCUIElement.snapshot()` materializes the tree before this
/// code trims it, so these are response bounds, not an accessibility-fetch
/// bound.
public struct BridgeUITreeLimits: Equatable, Sendable {
    public static let defaultMaxDepth = 40
    public static let maximumMaxDepth = 64
    public static let defaultMaxNodes = 400
    public static let maximumMaxNodes = 800
    public static let defaultMaxStringBytes = 512
    public static let minimumMaxStringBytes = 32
    public static let maximumMaxStringBytes = 2_048
    public static let defaultMaxTotalBytes = 65_536
    public static let minimumMaxTotalBytes = 1_024
    public static let maximumMaxTotalBytes = 131_072

    public var maxDepth: Int
    public var maxNodes: Int
    public var maxStringBytes: Int
    public var maxTotalBytes: Int

    public init(maxDepth: Int = BridgeUITreeLimits.defaultMaxDepth,
                maxNodes: Int = BridgeUITreeLimits.defaultMaxNodes,
                maxStringBytes: Int = BridgeUITreeLimits.defaultMaxStringBytes,
                maxTotalBytes: Int = BridgeUITreeLimits.defaultMaxTotalBytes) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.maxStringBytes = maxStringBytes
        self.maxTotalBytes = maxTotalBytes
    }

    /// Leave bounded room for the JSON envelope around the node dictionaries.
    var serializedBudget: Int {
        max(512, maxTotalBytes - 1_024)
    }
}

public struct BridgeUITreeStatistics: Equatable, Sendable {
    public var returnedNodeCount: Int
    public var visitedNodeCount: Int
    public var maxDepthReached: Int
    public var truncatedDepth: Bool
    public var truncatedNodes: Bool
    public var truncatedBytes: Bool
    public var truncatedStrings: Int
    public var secureValueRedactions: Int

    public init(returnedNodeCount: Int = 0,
                visitedNodeCount: Int = 0,
                maxDepthReached: Int = 0,
                truncatedDepth: Bool = false,
                truncatedNodes: Bool = false,
                truncatedBytes: Bool = false,
                truncatedStrings: Int = 0,
                secureValueRedactions: Int = 0) {
        self.returnedNodeCount = returnedNodeCount
        self.visitedNodeCount = visitedNodeCount
        self.maxDepthReached = maxDepthReached
        self.truncatedDepth = truncatedDepth
        self.truncatedNodes = truncatedNodes
        self.truncatedBytes = truncatedBytes
        self.truncatedStrings = truncatedStrings
        self.secureValueRedactions = secureValueRedactions
    }
}

public struct BridgeUITreeRender: Equatable, Sendable {
    public var json: String
    public var utf8Bytes: Int
    public var statistics: BridgeUITreeStatistics

    public init(json: String, utf8Bytes: Int, statistics: BridgeUITreeStatistics) {
        self.json = json
        self.utf8Bytes = utf8Bytes
        self.statistics = statistics
    }
}

/// Renders one already-materialized accessibility tree into `floe-ui-tree-v1`.
/// Every node is depth-, count-, string- and serialized-byte-bounded. Secure
/// text-field values are replaced with `<redacted>`.
@MainActor
public enum BridgeUITreeRenderer {
    public static func render<Node: BridgeUIElementNode>(
        root: Node,
        limits: BridgeUITreeLimits = BridgeUITreeLimits()
    ) -> BridgeUITreeRender {
        var state = State(limits: limits)
        let tree = renderNode(root, depth: 0, state: &state) ?? [:]
        var data = serialize(tree)
        if data.count > limits.maxTotalBytes {
            // The per-node measurement reserves room for punctuation, but a
            // final independent check keeps the promised ceiling true even if
            // JSONSerialization accounts for an escaped string differently.
            state.truncatedBytes = true
            let fallback: [String: Any] = [
                "type": "application",
                "truncatedByBytes": true,
                "children": [],
            ]
            data = serialize(fallback)
        }
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return BridgeUITreeRender(
            json: json,
            utf8Bytes: data.count,
            statistics: state.statistics
        )
    }

    private struct State {
        let limits: BridgeUITreeLimits
        var visited = 0
        var returned = 0
        var bytes = 0
        var deepest = 0
        var truncatedDepth = false
        var truncatedNodes = false
        var truncatedBytes = false
        var truncatedStrings = 0
        var secureRedactions = 0

        init(limits: BridgeUITreeLimits) {
            self.limits = limits
        }

        var statistics: BridgeUITreeStatistics {
            BridgeUITreeStatistics(
                returnedNodeCount: returned,
                visitedNodeCount: visited,
                maxDepthReached: deepest,
                truncatedDepth: truncatedDepth,
                truncatedNodes: truncatedNodes,
                truncatedBytes: truncatedBytes,
                truncatedStrings: truncatedStrings,
                secureValueRedactions: secureRedactions
            )
        }
    }

    private static func renderNode<Node: BridgeUIElementNode>(
        _ node: Node,
        depth: Int,
        state: inout State
    ) -> [String: Any]? {
        guard depth <= state.limits.maxDepth else {
            state.truncatedDepth = true
            return nil
        }
        guard state.returned < state.limits.maxNodes else {
            state.truncatedNodes = true
            return nil
        }
        state.visited += 1
        if depth > state.deepest { state.deepest = depth }

        let identifier = bounded(node.uiIdentifier, state: &state)
        let label = bounded(node.uiLabel, state: &state)
        var placeholder: String?
        if let raw = node.uiPlaceholderValue {
            placeholder = bounded(raw, state: &state)
        }
        var value: String?
        if node.uiIsSecureTextField {
            value = "<redacted>"
            state.secureRedactions += 1
        } else if let raw = node.uiValue {
            value = bounded(raw, state: &state)
        }

        var dictionary: [String: Any] = [
            "type": node.uiElementTypeName,
            "typeRaw": node.uiElementTypeRawValue,
            "identifier": identifier,
            "label": label,
            "frame": node.uiFrameDescription,
            "enabled": node.uiIsEnabled,
            "selected": node.uiIsSelected,
            "hasFocus": node.uiHasFocus,
            "depth": depth,
        ]
        if let value { dictionary["value"] = value }
        if let placeholder { dictionary["placeholderValue"] = placeholder }

        guard let measured = try? JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        guard state.bytes + measured.count + 8 <= state.limits.serializedBudget else {
            state.truncatedBytes = true
            return nil
        }
        state.bytes += measured.count + 8
        state.returned += 1

        var children: [[String: Any]] = []
        if depth < state.limits.maxDepth {
            let childCount = node.uiChildCount
            var index = 0
            while index < childCount {
                if state.truncatedBytes { break }
                if state.returned >= state.limits.maxNodes {
                    state.truncatedNodes = true
                    break
                }
                guard let child = node.uiChild(at: index) else {
                    // A child disappeared between the count and the access.
                    // It is not a reason to keep walking or to claim a
                    // different subtree; skip it and retain the real count.
                    index += 1
                    continue
                }
                if let childDictionary = renderNode(child, depth: depth + 1, state: &state) {
                    children.append(childDictionary)
                }
                if state.truncatedBytes || state.truncatedNodes { break }
                index += 1
            }
        } else if node.uiChildCount > 0 {
            state.truncatedDepth = true
        }
        if !children.isEmpty { dictionary["children"] = children }
        return dictionary
    }

    private static func bounded(_ value: String, state: inout State) -> String {
        let maxBytes = state.limits.maxStringBytes
        guard value.utf8.count > maxBytes else { return value }
        state.truncatedStrings += 1
        var output = ""
        var used = 0
        for character in value {
            let piece = String(character)
            let count = piece.utf8.count
            if used + count > maxBytes { break }
            output.append(character)
            used += count
        }
        return output
    }

    private static func serialize(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
    }
}

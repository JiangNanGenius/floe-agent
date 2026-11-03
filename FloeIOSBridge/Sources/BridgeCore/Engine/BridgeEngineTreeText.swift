import Foundation

/// A pure, bounded accessibility snapshot node.
///
/// The test bundle converts `XCUIElementSnapshot` into this value once. All
/// filtering and text rendering happens here, so the exact output rules are
/// testable without XCTest or UIKit.
public struct BridgeEngineTreeNode: Equatable, Sendable {
    public var type: String
    public var typeRaw: Int
    public var identifier: String
    public var label: String
    public var value: String?
    public var placeholderValue: String?
    public var frame: BridgeUIRect
    public var isEnabled: Bool
    public var isSelected: Bool
    public var hasFocus: Bool
    public var isSecure: Bool
    public var children: [BridgeEngineTreeNode]
    /// Set by the XCTest adapter when it stopped copying children because of
    /// its own depth/children/node budget. The pure renderer cannot otherwise
    /// distinguish an actually leaf node from one whose children were dropped.
    public var adapterTruncated: Bool

    public init(type: String,
                typeRaw: Int,
                identifier: String,
                label: String,
                value: String?,
                placeholderValue: String?,
                frame: BridgeUIRect,
                isEnabled: Bool,
                isSelected: Bool,
                hasFocus: Bool,
                isSecure: Bool,
                children: [BridgeEngineTreeNode],
                adapterTruncated: Bool = false) {
        self.type = type
        self.typeRaw = typeRaw
        self.identifier = identifier
        self.label = label
        self.value = value
        self.placeholderValue = placeholderValue
        self.frame = frame
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.hasFocus = hasFocus
        self.isSecure = isSecure
        self.children = children
        self.adapterTruncated = adapterTruncated
    }
}

public struct BridgeEngineTreeFilter: Equatable, Sendable {
    public enum Field: String, Equatable, Sendable {
        case label
        case text
        case type
    }

    public var field: Field
    public var value: String

    public init(field: Field, value: String) {
        self.field = field
        self.value = value
    }

    public static func parse(_ object: [String: BridgeRPCJSONValue]) -> BridgeEngineTreeFilter? {
        if let label = object["label"]?.stringValue, !label.isEmpty {
            return BridgeEngineTreeFilter(field: .label, value: label)
        }
        if let text = object["text"]?.stringValue, !text.isEmpty {
            return BridgeEngineTreeFilter(field: .text, value: text)
        }
        if let type = object["type"]?.stringValue, !type.isEmpty {
            return BridgeEngineTreeFilter(field: .type, value: type)
        }
        return nil
    }

    func matches(_ node: BridgeEngineTreeNode) -> Bool {
        switch field {
        case .label:
            return node.label.localizedCaseInsensitiveContains(value)
                || (node.value?.localizedCaseInsensitiveContains(value) ?? false)
        case .text:
            return node.label.localizedCaseInsensitiveContains(value)
                || node.identifier.localizedCaseInsensitiveContains(value)
                || (node.value?.localizedCaseInsensitiveContains(value) ?? false)
        case .type:
            return BridgeEngineElementType.matches(node.type, elementType: value)
        }
    }
}

public struct BridgeEngineTreeOptions: Equatable, Sendable {
    public var maxDepth: Int
    public var maxNodes: Int
    public var maxChildren: Int
    public var maxStringBytes: Int
    public var maxSourceBytes: Int
    public var filter: BridgeEngineTreeFilter?
    public var visibleOnly: Bool
    public var screen: BridgeUIRect?

    public init(maxDepth: Int = 40,
                maxNodes: Int = 2_000,
                maxChildren: Int = 1_000,
                maxStringBytes: Int = 2_048,
                maxSourceBytes: Int = 65_536,
                filter: BridgeEngineTreeFilter? = nil,
                visibleOnly: Bool = false,
                screen: BridgeUIRect? = nil) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.maxChildren = maxChildren
        self.maxStringBytes = maxStringBytes
        self.maxSourceBytes = maxSourceBytes
        self.filter = filter
        self.visibleOnly = visibleOnly
        self.screen = screen
    }
}

public struct BridgeEngineTreeRender: Equatable, Sendable {
    public var source: String
    public var totalReturned: Int
    public var visited: Int
    public var truncated: Bool
    public var truncatedDepth: Bool
    public var truncatedNodes: Bool
    public var truncatedBytes: Bool

    public init(source: String,
                totalReturned: Int,
                visited: Int,
                truncated: Bool,
                truncatedDepth: Bool,
                truncatedNodes: Bool,
                truncatedBytes: Bool) {
        self.source = source
        self.totalReturned = totalReturned
        self.visited = visited
        self.truncated = truncated
        self.truncatedDepth = truncatedDepth
        self.truncatedNodes = truncatedNodes
        self.truncatedBytes = truncatedBytes
    }
}

public enum BridgeEngineTreeText {
    public static func render(root: BridgeEngineTreeNode,
                              options: BridgeEngineTreeOptions = BridgeEngineTreeOptions()) -> BridgeEngineTreeRender {
        var keepState = KeepState(options: options)
        let kept = keep(root, depth: 0, state: &keepState)
        var renderState = RenderState(options: options)
        if let kept {
            append(kept, depth: 0, state: &renderState)
        }
        let truncated = keepState.truncatedDepth || keepState.truncatedChildren
            || renderState.truncatedNodes || renderState.truncatedBytes
        return BridgeEngineTreeRender(
            source: renderState.lines.joined(separator: "\n"),
            totalReturned: renderState.returned,
            visited: keepState.visited,
            truncated: truncated,
            truncatedDepth: keepState.truncatedDepth || renderState.truncatedDepth,
            truncatedNodes: keepState.truncatedChildren || renderState.truncatedNodes,
            truncatedBytes: renderState.truncatedBytes
        )
    }

    private struct KeepState {
        let options: BridgeEngineTreeOptions
        var visited = 0
        var truncatedDepth = false
        var truncatedChildren = false

        init(options: BridgeEngineTreeOptions) {
            self.options = options
        }
    }

    private struct RenderState {
        let options: BridgeEngineTreeOptions
        var lines: [String] = []
        var bytes = 0
        var returned = 0
        var truncatedDepth = false
        var truncatedNodes = false
        var truncatedBytes = false

        init(options: BridgeEngineTreeOptions) {
            self.options = options
        }

        var remainingBytes: Int {
            max(0, options.maxSourceBytes - bytes)
        }
    }

    /// Keeps a node when it matches the filter or is an ancestor of a match,
    /// and (when `visible_only`) when it intersects the screen or is an
    /// ancestor of a visible match. A matching parent does not drag every
    /// unaffected descendant into the response.
    private static func keep(_ node: BridgeEngineTreeNode,
                             depth: Int,
                             state: inout KeepState) -> BridgeEngineTreeNode? {
        state.visited += 1
        if node.adapterTruncated {
            state.truncatedDepth = true
        }
        guard depth <= state.options.maxDepth else {
            state.truncatedDepth = true
            return nil
        }
        var children: [BridgeEngineTreeNode] = []
        var childKept = false
        if depth < state.options.maxDepth {
            var index = 0
            while index < node.children.count, children.count < state.options.maxChildren {
                if let child = keep(node.children[index], depth: depth + 1, state: &state) {
                    children.append(child)
                    childKept = true
                }
                index += 1
            }
            if index < node.children.count {
                state.truncatedChildren = true
            }
        } else if !node.children.isEmpty {
            state.truncatedDepth = true
        }

        let selfMatches = state.options.filter?.matches(node) ?? true
        if state.options.filter != nil, !selfMatches, !childKept {
            return nil
        }
        let intersects = state.options.screen.map {
            $0.intersectionArea(with: node.frame) > 0
        } ?? true
        let visible = !state.options.visibleOnly || intersects || childKept
        guard visible else { return nil }

        var copy = node
        copy.children = children
        copy.identifier = bounded(copy.identifier, maxBytes: state.options.maxStringBytes)
        copy.label = bounded(copy.label, maxBytes: state.options.maxStringBytes)
        copy.value = copy.isSecure
            ? nil
            : copy.value.map { bounded($0, maxBytes: state.options.maxStringBytes) }
        copy.placeholderValue = copy.placeholderValue.map {
            bounded($0, maxBytes: state.options.maxStringBytes)
        }
        return copy
    }

    private static func append(_ node: BridgeEngineTreeNode,
                               depth: Int,
                               state: inout RenderState) {
        if state.returned >= state.options.maxNodes {
            state.truncatedNodes = true
            return
        }
        let line = describe(node, depth: depth)
        let lineBytes = line.utf8.count + (state.lines.isEmpty ? 0 : 1)
        if lineBytes > state.remainingBytes {
            state.truncatedBytes = true
            return
        }
        state.lines.append(line)
        state.bytes += lineBytes
        state.returned += 1
        if depth >= state.options.maxDepth {
            if !node.children.isEmpty { state.truncatedDepth = true }
            return
        }
        for child in node.children {
            if state.truncatedBytes || state.truncatedNodes { return }
            append(child, depth: depth + 1, state: &state)
        }
    }

    private static func describe(_ node: BridgeEngineTreeNode, depth: Int) -> String {
        var parts = [
            "\(node.type)",
            "label: '\(escape(node.label))'",
            "identifier: '\(escape(node.identifier))'",
        ]
        if node.isSecure {
            parts.append("value: <redacted>")
        } else if let value = node.value, !value.isEmpty {
            parts.append("value: '\(escape(value))'")
        }
        if let placeholder = node.placeholderValue, !placeholder.isEmpty {
            parts.append("placeholder: '\(escape(placeholder))'")
        }
        parts.append(String(format: "frame: {%.1f, %.1f, %.1f, %.1f}",
                            node.frame.x, node.frame.y, node.frame.width, node.frame.height))
        if !node.isEnabled { parts.append("enabled: false") }
        if node.isSelected { parts.append("selected: true") }
        if node.hasFocus { parts.append("focus: true") }
        return String(repeating: "  ", count: depth) + parts.joined(separator: ", ")
    }

    private static func bounded(_ value: String, maxBytes: Int) -> String {
        guard value.utf8.count > maxBytes else { return value }
        var output = ""
        var used = 0
        for character in value {
            let piece = String(character)
            if used + piece.utf8.count > maxBytes { break }
            output.append(character)
            used += piece.utf8.count
        }
        return output
    }

    private static func escape(_ value: String) -> String {
        var output = ""
        for character in value {
            switch character {
            case "\\": output += "\\\\"
            case "'": output += "\\'"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default: output.append(character)
            }
        }
        return output
    }
}

/// Element-type names are compared without spacing or case so a client can use
/// `StaticText`, `static_text`, or `statictext` interchangeably.
public enum BridgeEngineElementType {
    public static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func matches(_ snapshotType: String, elementType: String) -> Bool {
        let expected = normalize(elementType)
        if expected.isEmpty || expected == "all" { return true }
        let actual = normalize(snapshotType)
        if actual == expected { return true }
        // TextField also matches search/secure text fields as pinned.
        if expected == "textfield" {
            return actual == "searchfield" || actual == "securetextfield"
        }
        return false
    }

    public static func isTextInput(_ snapshotType: String) -> Bool {
        let type = normalize(snapshotType)
        return type == "textfield" || type == "searchfield"
            || type == "textview" || type == "securetextfield"
    }

    public static func isSecure(_ snapshotType: String) -> Bool {
        normalize(snapshotType) == "securetextfield"
    }
}

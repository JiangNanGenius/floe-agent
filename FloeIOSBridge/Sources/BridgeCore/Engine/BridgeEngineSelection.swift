import Foundation

public enum BridgeEngineMatchMode: String, Equatable, Sendable {
    case exact
    case contains
}

/// One candidate read from a live accessibility snapshot.
public struct BridgeEngineElementCandidate: Equatable, Sendable {
    public var identifier: String
    public var label: String
    public var value: String?
    public var type: String
    public var typeRaw: Int
    public var frame: BridgeUIRect
    public var isEnabled: Bool
    public var isHittable: Bool
    public var isSecure: Bool
    public var hasFocus: Bool
    public var isTextInput: Bool

    public init(identifier: String,
                label: String,
                value: String?,
                type: String,
                typeRaw: Int,
                frame: BridgeUIRect,
                isEnabled: Bool = true,
                isHittable: Bool = false,
                isSecure: Bool = false,
                hasFocus: Bool = false,
                isTextInput: Bool = false) {
        self.identifier = identifier
        self.label = label
        self.value = value
        self.type = type
        self.typeRaw = typeRaw
        self.frame = frame
        self.isEnabled = isEnabled
        self.isHittable = isHittable
        self.isSecure = isSecure
        self.hasFocus = hasFocus
        self.isTextInput = isTextInput
    }
}

public struct BridgeEngineElementMatch: Equatable, Sendable {
    public var candidate: BridgeEngineElementCandidate
    public var score: Int
    public var reason: String

    public init(candidate: BridgeEngineElementCandidate, score: Int, reason: String) {
        self.candidate = candidate
        self.score = score
        self.reason = reason
    }
}

public enum BridgeEngineElementSelector {
    /// Ranks label/identifier matches ahead of value-only matches, and exact
    /// ahead of substring. A caller that needs a unique action target must
    /// still reject multiple equally ranked candidates.
    public static func matches(candidates: [BridgeEngineElementCandidate],
                               query: String,
                               mode: BridgeEngineMatchMode,
                               elementType: String?) -> [BridgeEngineElementMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let lowered = needle.lowercased()
        var output: [BridgeEngineElementMatch] = []
        for candidate in candidates {
            if let elementType,
               !BridgeEngineElementType.matches(candidate.type, elementType: elementType) {
                continue
            }
            var score = 0
            var reason = ""
            let label = candidate.label.lowercased()
            let identifier = candidate.identifier.lowercased()
            let value = candidate.value?.lowercased() ?? ""
            switch mode {
            case .exact:
                if label == lowered { score = 100; reason = "label-exact" }
                else if identifier == lowered { score = 90; reason = "identifier-exact" }
                else if !value.isEmpty, value == lowered { score = 70; reason = "value-exact" }
            case .contains:
                if label == lowered { score = 100; reason = "label-exact" }
                else if label.contains(lowered) { score = 80; reason = "label-contains" }
                else if identifier == lowered { score = 75; reason = "identifier-exact" }
                else if identifier.contains(lowered) { score = 60; reason = "identifier-contains" }
                else if !value.isEmpty, value.contains(lowered) { score = 40; reason = "value-contains" }
            }
            guard score > 0 else { continue }
            // Prefer a usable on-screen frame, then a hittable element.
            if !candidate.frame.isEmpty { score += 4 }
            if candidate.isHittable { score += 2 }
            output.append(BridgeEngineElementMatch(candidate: candidate, score: score, reason: reason))
        }
        return output.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.candidate.frame.y != rhs.candidate.frame.y {
                return lhs.candidate.frame.y < rhs.candidate.frame.y
            }
            return lhs.candidate.frame.x < rhs.candidate.frame.x
        }
    }

    public enum Selection: Equatable, Sendable {
        case unique(BridgeEngineElementMatch)
        case missing
        case ambiguous(count: Int)
    }

    /// Only an exactly-one best match is actionable. Ties at the top score are
    /// ambiguous even when the raw candidate count differs.
    public static func selectUnique(_ matches: [BridgeEngineElementMatch]) -> Selection {
        guard let first = matches.first else { return .missing }
        let top = matches.prefix { $0.score == first.score }
        guard top.count == 1 else { return .ambiguous(count: matches.count) }
        return .unique(first)
    }
}

/// A stable, process-local reference to an element. Resolution re-reads the
/// live snapshot and never assumes the old frame still points at the target.
public struct BridgeEngineElementRef: Equatable, Sendable {
    public var id: String
    public var bundleIdentifier: String
    public var identifier: String
    public var label: String
    public var type: String
    public var frame: BridgeUIRect
    public var createdAt: Date

    public init(id: String,
                bundleIdentifier: String,
                identifier: String,
                label: String,
                type: String,
                frame: BridgeUIRect,
                createdAt: Date = Date()) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.identifier = identifier
        self.label = label
        self.type = type
        self.frame = frame
        self.createdAt = createdAt
    }
}

public final class BridgeEngineElementRefStore: @unchecked Sendable {
    public static let maximumRefs = 128

    private let lock = NSLock()
    private var refs: [String: BridgeEngineElementRef] = [:]
    private var order: [String] = []
    private var next: UInt64 = 1

    public init() {}

    @discardableResult
    public func store(bundleIdentifier: String,
                      candidate: BridgeEngineElementCandidate) -> BridgeEngineElementRef {
        lock.lock()
        defer { lock.unlock() }
        let identifier = "e\(next)"
        next &+= 1
        let ref = BridgeEngineElementRef(
            id: identifier,
            bundleIdentifier: bundleIdentifier,
            identifier: candidate.identifier,
            label: candidate.label,
            type: candidate.type,
            frame: candidate.frame
        )
        refs[identifier] = ref
        order.append(identifier)
        while order.count > Self.maximumRefs {
            let oldest = order.removeFirst()
            refs.removeValue(forKey: oldest)
        }
        return ref
    }

    public func resolve(_ id: String) -> BridgeEngineElementRef? {
        lock.lock()
        defer { lock.unlock() }
        return refs[id]
    }

    @discardableResult
    public func clear() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let count = refs.count
        refs.removeAll()
        order.removeAll()
        return count
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return refs.count
    }
}

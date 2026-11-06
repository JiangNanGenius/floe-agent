import Foundation
import FloeCanvasCore

/// Bounded level-of-detail policy by zoom. Higher levels allow heavyweight
/// content; lower levels demand lightweight previews for heavy nodes and a
/// bounded representative set for overview/minimap work.
public enum CanvasLODLevel: String, Codable, Hashable, Sendable, Comparable, CaseIterable {
    case overview
    case preview
    case standard
    case full

    public static func < (lhs: CanvasLODLevel, rhs: CanvasLODLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .overview: return 0
        case .preview: return 1
        case .standard: return 2
        case .full: return 3
        }
    }

    /// Heavyweight content (media/PDF/web/3D surfaces) may be instantiated.
    public var allowsHeavyweightContent: Bool {
        self >= .standard
    }
}

/// What the UI should materialize for the currently visible nodes: preview
/// demand IDs for heavyweight nodes needing placeholders, and a deterministic
/// representative sample for overview/minimap/statistics. This is demand
/// description only — media loading stays the host's job.
public struct CanvasPreviewDemand: Sendable, Hashable {
    public var level: CanvasLODLevel
    public var allowsHeavyweightContent: Bool
    /// Heavyweight visible nodes that must show a lightweight placeholder at
    /// this level (empty when heavyweight content is allowed).
    public var previewDemandIDs: [UUID]
    /// Deterministic stride sample of visible node IDs, capped at
    /// `CanvasLODPolicy.representativeCap`, for overview rendering.
    public var representativeNodeIDs: [UUID]

    public init(
        level: CanvasLODLevel,
        allowsHeavyweightContent: Bool,
        previewDemandIDs: [UUID],
        representativeNodeIDs: [UUID]
    ) {
        self.level = level
        self.allowsHeavyweightContent = allowsHeavyweightContent
        self.previewDemandIDs = previewDemandIDs
        self.representativeNodeIDs = representativeNodeIDs
    }
}

public enum CanvasLODPolicy {
    /// Maximum number of representative nodes exposed at any level, keeping
    /// overview work bounded regardless of page size.
    public static let representativeCap = 240

    public static func level(forZoom zoom: Double) -> CanvasLODLevel {
        // Non-finite zoom degrades to the safest level instead of trapping:
        // NaN carries no magnitude information (overview), while +infinity
        // is beyond every threshold (full).
        guard zoom.isFinite else { return zoom > 0 ? .full : .overview }
        switch zoom {
        case ..<0.12: return .overview
        case ..<0.35: return .preview
        case ..<0.75: return .standard
        default: return .full
        }
    }

    /// Demand for a set of already-visible nodes (from
    /// `CanvasPageLayoutIndex.visibleNodes`) at the given zoom.
    public static func demand(
        for visibleNodes: [CanvasPreparedNode],
        zoom: Double
    ) -> CanvasPreviewDemand {
        let level = level(forZoom: zoom)
        let previewDemandIDs = level.allowsHeavyweightContent
            ? []
            : visibleNodes.filter(\.isHeavyweight).map(\.id)
        let representativeNodeIDs = strideSample(
            of: visibleNodes.map(\.id),
            cap: CanvasLODPolicy.representativeCap)
        return CanvasPreviewDemand(
            level: level,
            allowsHeavyweightContent: level.allowsHeavyweightContent,
            previewDemandIDs: previewDemandIDs,
            representativeNodeIDs: representativeNodeIDs)
    }

    /// Deterministic stride sample: first, middle and evenly spaced items,
    /// preserving render order, capped at `cap`.
    static func strideSample(of ids: [UUID], cap: Int) -> [UUID] {
        guard ids.count > cap, cap > 0 else { return ids }
        let stride = Double(ids.count) / Double(cap)
        var sampled: [UUID] = []
        sampled.reserveCapacity(cap)
        var index = 0.0
        while sampled.count < cap {
            let position = Int(index)
            guard ids.indices.contains(position) else { break }
            sampled.append(ids[position])
            index += stride
        }
        return sampled
    }
}

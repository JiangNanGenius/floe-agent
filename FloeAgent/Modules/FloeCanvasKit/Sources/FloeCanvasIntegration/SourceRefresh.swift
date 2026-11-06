import Foundation
import FloeCanvasCore

/// Result of one explicit source refresh.
public enum SourceRefreshOutcome: Hashable, Sendable {
    /// Source revision unchanged; snapshot untouched.
    case unchanged
    /// Node content was refreshed from the newer source revision;
    /// annotations and manual edits are preserved.
    case updated(nodeIDs: [UUID])
    /// Refreshing would overwrite manual edits. The original is kept and a
    /// recoverable alternative (a branched copy of the affected nodes) is
    /// produced instead; nothing is silently overwritten.
    case conflict(alternativeNodeIDs: [UUID], nodeIDs: [UUID])
}

public struct SourceRefreshResult: Hashable, Sendable {
    public var outcome: SourceRefreshOutcome
    public var snapshot: CanvasSnapshot

    public init(outcome: SourceRefreshOutcome, snapshot: CanvasSnapshot) {
        self.outcome = outcome
        self.snapshot = snapshot
    }
}

/// Explicit source refresh. Nothing here runs automatically: the host calls
/// `refresh` when the user asks (ICQA06). Policy precedence:
///
/// 1. An explicit per-call instruction always wins (e.g. the assistant was
///    told "replace this card with the latest").
/// 2. Otherwise a node with manual edits since the used revision keeps the
///    original and the fresh content lands on a new branch (recoverable).
/// 3. A node without manual edits is refreshed in place, preserving user
///    annotations anchored on it.
public struct CanvasSourceRefresher {
    public enum Instruction: String, Codable, Hashable, Sendable {
        /// Explicit order: overwrite in place even with manual edits.
        case replace
        /// Explicit order: keep original, add refreshed branch.
        case branch
        /// No explicit order: apply the default policy.
        case `default`
    }

    private let sourceService: any CanvasSourceService

    public init(sourceService: any CanvasSourceService) {
        self.sourceService = sourceService
    }

    /// Manual-edit marker recorded by hosts/assistant applications in node
    /// metadata when content is edited locally after import.
    public static let manualEditRevisionMetadataKey = "canvas.manualEditRevision"

    /// Coarse content classes used to decide whether a refresh can land in
    /// place. Same-class refreshes update in place; anything else produces a
    /// recoverable alternative branch so no structured content is silently
    /// flattened (shape inner text refreshes like plain text).
    enum RefreshKind: Hashable, Sendable {
        case textLike
        case richText
        case table
        case formula
        case media
        case pdf
        case web
        case editor
        case unknown
    }

    static func refreshKind(of content: CanvasContent) -> RefreshKind {
        switch content {
        case .text, .markdown, .code, .shape: return .textLike
        case .richText: return .richText
        case .table: return .table
        case .formula: return .formula
        case .media: return .media
        case .pdf: return .pdf
        case .web: return .web
        case .editor: return .editor
        case .unknown: return .unknown
        }
    }

    public func refresh(
        canvasID: UUID,
        in snapshot: CanvasSnapshot,
        pageID: UUID,
        nodeIDs: [UUID],
        instruction: Instruction = .default
    ) async throws -> SourceRefreshResult {
        var next = snapshot
        guard let pageIndex = next.pages.firstIndex(where: { $0.id == pageID }) else {
            throw CanvasKitError.missingEntity("page \(pageID)")
        }
        var page = next.pages[pageIndex]
        var updatedIDs: [UUID] = []
        var conflictAlternativeIDs: [UUID] = []
        var conflictOriginalIDs: [UUID] = []

        for nodeID in nodeIDs {
            guard let nodeIndex = page.nodes.firstIndex(where: { $0.id == nodeID }) else {
                throw CanvasKitError.missingEntity("node \(nodeID)")
            }
            var node = page.nodes[nodeIndex]
            guard let source = node.source else { continue }

            let liveRevision = try await sourceService.currentRevision(
                sourceID: source.sourceID)
            guard liveRevision > source.usedRevision else { continue }

            let content = try await sourceService.read(
                sourceID: source.sourceID, fragment: source.fragment)
            let refreshedContent = content.typedContent ?? .text(content.text)
            let manualEditRevision = node.metadata[
                Self.manualEditRevisionMetadataKey].flatMap(Int64.init)

            // A structured node (table/formula/rich text/media/pdf/web/
            // editor/unknown) may only be refreshed in place by a typed
            // payload of the SAME kind; a text-only read never silently
            // converts it to plain text — that lands on a recoverable
            // alternative branch instead.
            let compatible = Self.refreshKind(of: node.content)
                == Self.refreshKind(of: refreshedContent)

            let shouldBranch: Bool
            if instruction == .replace {
                shouldBranch = false
            } else if instruction == .branch {
                shouldBranch = true
            } else {
                // Default: branch when the user edited since the used
                // revision; otherwise refresh in place.
                shouldBranch = manualEditRevision.map { $0 > source.usedRevision } ?? false
            }

            if shouldBranch || !compatible {
                // Recoverable alternative: a fresh node holding the new
                // source content, linked back to the same source identity;
                // the original stays exactly as the user left it.
                var alternative = node
                alternative.id = UUID()
                alternative.frame.center = CanvasGeometry.Point(
                    x: node.frame.center.x + node.frame.size.width + 48,
                    y: node.frame.center.y
                )
                alternative.content = refreshedContent
                alternative.createdByRunID = nil
                var alternativeSource = source
                alternativeSource.usedRevision = liveRevision
                alternative.source = alternativeSource
                page.nodes.append(alternative)
                conflictAlternativeIDs.append(alternative.id)
                conflictOriginalIDs.append(node.id)
            } else {
                node.content = refreshedContent
                var refreshedSource = source
                refreshedSource.usedRevision = liveRevision
                // Annotations, layout and manual-edit markers are preserved
                // by construction: we only replace content + usedRevision.
                node.source = refreshedSource
                page.nodes[nodeIndex] = node
                updatedIDs.append(node.id)
            }
        }

        next.pages[pageIndex] = page
        let outcome: SourceRefreshOutcome
        if !conflictAlternativeIDs.isEmpty {
            outcome = .conflict(
                alternativeNodeIDs: conflictAlternativeIDs.sorted { $0.uuidString < $1.uuidString },
                nodeIDs: conflictOriginalIDs.sorted { $0.uuidString < $1.uuidString })
        } else if !updatedIDs.isEmpty {
            outcome = .updated(nodeIDs: updatedIDs.sorted { $0.uuidString < $1.uuidString })
        } else {
            outcome = .unchanged
        }
        return SourceRefreshResult(outcome: outcome, snapshot: next)
    }
}

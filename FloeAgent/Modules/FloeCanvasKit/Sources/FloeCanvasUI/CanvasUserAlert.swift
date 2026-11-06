import Foundation

/// User-facing alert/sheet state. Keeps copy concise per the brief;
/// diagnostics stay in details views, not in banners.
public struct CanvasUserAlert: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case saveFailed
        case revisionConflict
        case sourceUnavailable
        case missingResource
        case assistantUnavailable
        case environmentRequired
        case invalidFlow
        case draftRecovered
        case labActionFailed
        case labActionCompleted
        case runOutputsPlaced
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var message: String
    /// Optional primary action; alerts also always support dismissal.
    public var primaryActionTitle: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        message: String,
        primaryActionTitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.primaryActionTitle = primaryActionTitle
    }
}

extension CanvasUserAlert: Equatable {
    public static func == (lhs: CanvasUserAlert, rhs: CanvasUserAlert) -> Bool {
        lhs.id == rhs.id
    }
}

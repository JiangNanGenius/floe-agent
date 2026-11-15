import Foundation

/// Errors raised by the building records service before or instead of an
/// underlying SQLite error. Database constraint and I/O failures are not
/// flattened into a string: callers retain the concrete GRDB error.
public enum BuildingRecordsError: Error, Equatable, Sendable {
    case invalidProjectContainer(String)
    case projectAlreadyExists
    case projectNotFound
    case revisionConflict(expected: Int, actual: Int)
    case roomNotFound(RoomID)
    case sourceNotFound(SourceID)
    case sourceVersionNotFound(SourceVersionID)
    case observationNotFound(ObservationID)
    case adoptedValueNotFound(AdoptedValueID)
    case bomTargetNotFound(BOMTargetID)
    case bomDraftNotFound(BOMDraftID)
    case bomItemNotFound(BOMItemID)
    case invalidValue(field: String, reason: String)
    case emptyContent
    case contentTooLarge(limit: Int, actual: Int)
    case invalidOriginalName
    case invalidMediaType
    case invalidSourceLocator(String)
    case pathEscapesProject
    case sourceFileMissing(SourceVersionID)
    case sourceFileCorrupted(SourceVersionID)
    case idempotencyConflict(String)
    case unknownDraftRow(BOMDraftRowID)
    case emptySelection
    case draftTargetMismatch
}

extension BuildingRecordsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidProjectContainer(let reason):
            return "The project container is not usable: \(reason)"
        case .projectAlreadyExists:
            return "A project already exists in this container."
        case .projectNotFound:
            return "This container does not contain a building records project."
        case .revisionConflict(let expected, let actual):
            return "The project records changed (expected revision \(expected), actual \(actual))."
        case .roomNotFound:
            return "The room no longer exists in this project."
        case .sourceNotFound:
            return "The source no longer exists in this project."
        case .sourceVersionNotFound:
            return "The source version no longer exists in this project."
        case .observationNotFound:
            return "The observation no longer exists in this project."
        case .adoptedValueNotFound:
            return "The adopted value no longer exists in this project."
        case .bomTargetNotFound:
            return "The BOM target no longer exists in this project."
        case .bomDraftNotFound:
            return "The BOM draft no longer exists in this project."
        case .bomItemNotFound:
            return "The BOM item no longer exists in this project."
        case .invalidValue(let field, let reason):
            return "The value for \(field) is invalid: \(reason)"
        case .emptyContent:
            return "The source content is empty."
        case .contentTooLarge(let limit, let actual):
            return "The content is \(actual) bytes; the limit is \(limit) bytes."
        case .invalidOriginalName:
            return "The original file name is not usable."
        case .invalidMediaType:
            return "The media type is not usable."
        case .invalidSourceLocator(let reason):
            return "The source locator is invalid: \(reason)"
        case .pathEscapesProject:
            return "A source path escapes the project container."
        case .sourceFileMissing:
            return "The source content file is missing."
        case .sourceFileCorrupted:
            return "The source content does not match its recorded digest."
        case .idempotencyConflict(let key):
            return "The import key \(key) was reused with different content or metadata."
        case .unknownDraftRow:
            return "A selected BOM draft row does not belong to this draft."
        case .emptySelection:
            return "No BOM draft row was selected."
        case .draftTargetMismatch:
            return "The BOM draft is bound to a different target."
        }
    }
}

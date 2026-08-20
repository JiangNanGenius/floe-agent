// FloeCore — Unified error type.

import Foundation

/// Errors surfaced by Floe Agent modules. Provider-specific errors are
/// normalized into `AgentEvent.NormalizedError` at the provider boundary.
public enum FloeError: Error, Sendable, Hashable {
    case invalidConfiguration(String)
    case validationFailed(String)
    case unauthorized
    case notFound(String)
    case storageCorrupted(String)
    case syncUnavailable(String)
    case cancelled
    case internalError(String)
}

extension FloeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): "Invalid configuration: \(detail)"
        case .validationFailed(let detail): "Validation failed: \(detail)"
        case .unauthorized: "Unauthorized"
        case .notFound(let what): "Not found: \(what)"
        case .storageCorrupted(let detail): "Storage corrupted: \(detail)"
        case .syncUnavailable(let reason): "Sync unavailable: \(reason)"
        case .cancelled: "Cancelled"
        case .internalError(let detail): "Internal error: \(detail)"
        }
    }
}

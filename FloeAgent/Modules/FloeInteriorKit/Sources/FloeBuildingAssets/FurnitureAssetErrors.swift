// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum FurnitureAssetLibraryError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidValue(field: String, reason: String)
    case unsupportedFormat(String)
    case sourceRootUnavailable
    case sourceFileMissing(String)
    case sourceFileUnsafe(String)
    case sourceFileTooLarge(String, limit: Int)
    case budgetExceeded(String)
    case invalidOBJ(String)
    case invalidThumbnail(String)
    case invalidLicenseFile(String)
    case notAdmitted(assetID: String, version: String, issueCount: Int)
    case versionConflict(assetID: String, version: String)
    case notFound(assetID: String, version: String)
    case manifestCorrupt(String)
    case hashMismatch(String)
    case destinationExists(URL)
    case lockTimedOut
    case io(String)

    public var description: String {
        switch self {
        case let .invalidValue(field, reason):
            return "Invalid \(field): \(reason)"
        case let .unsupportedFormat(format):
            return "Unsupported furniture asset format: \(format)"
        case .sourceRootUnavailable:
            return "The selected source root is unavailable."
        case let .sourceFileMissing(path):
            return "The source file is missing: \(path)"
        case let .sourceFileUnsafe(path):
            return "The source path is not a safe regular file: \(path)"
        case let .sourceFileTooLarge(path, limit):
            return "The source file exceeds the \(limit)-byte limit: \(path)"
        case let .budgetExceeded(reason):
            return "The furniture asset exceeds its import budget: \(reason)"
        case let .invalidOBJ(reason):
            return "The OBJ source could not be admitted: \(reason)"
        case let .invalidThumbnail(reason):
            return "The thumbnail could not be admitted: \(reason)"
        case let .invalidLicenseFile(reason):
            return "The license evidence could not be admitted: \(reason)"
        case let .notAdmitted(assetID, version, issueCount):
            return "\(assetID) \(version) is not admitted (\(issueCount) issue(s) need repair)."
        case let .versionConflict(assetID, version):
            return "\(assetID) already has a different immutable version \(version)."
        case let .notFound(assetID, version):
            return "The furniture asset was not found: \(assetID) \(version)"
        case let .manifestCorrupt(reason):
            return "The furniture asset manifest is corrupt: \(reason)"
        case let .hashMismatch(path):
            return "The stored furniture asset content does not match its manifest hash: \(path)"
        case let .destinationExists(url):
            return "The offline copy destination already exists: \(url.lastPathComponent)"
        case .lockTimedOut:
            return "Timed out while waiting for the furniture asset version lock."
        case let .io(reason):
            return "Furniture asset file operation failed: \(reason)"
        }
    }
}

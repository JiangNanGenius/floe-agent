// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A bounded preview of the actual bytes committed by a native file writer.
/// Used when a complete, revision-bound before/after comparison is absent.
/// The preview never claims that an unknown baseline was an empty file.
public struct WorkspaceFileChangePreview: Codable, Sendable {
    public enum Comparison: String, Codable, Sendable { case baselineUnavailable, comparisonTooLarge, unchanged }
    public let version: Int
    public let path: String
    public let byteCount: Int
    public let sha256: String
    public let text: String
    public let truncated: Bool
    public let comparison: Comparison
    public init(version: Int, path: String, byteCount: Int, sha256: String, text: String,
                truncated: Bool, comparison: Comparison) {
        self.version = version; self.path = path; self.byteCount = byteCount; self.sha256 = sha256
        self.text = text; self.truncated = truncated; self.comparison = comparison
    }
}


// FloeApp — Workspace file presentation classification.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeWorkspace

/// Shared file classification for the inspector and the full workspace IDE.
/// Keeping this in one place prevents a file from opening as code in one
/// surface while falling back to an unnumbered text view in another.
///
/// The extension tables live in `WorkspaceTextPolicy` (FloeWorkspace) because
/// the IDE applies the same decision natively before any byte reaches the
/// editor. This type is only the App-facing spelling of that shared policy.
enum WorkspaceFileType {
    static func pathExtension(for relativePath: String) -> String {
        (relativePath as NSString).pathExtension.lowercased()
    }

    static func kind(for relativePath: String) -> WorkspaceFileKind {
        WorkspaceTextPolicy.kind(forPath: relativePath)
    }

    static func isText(_ relativePath: String) -> Bool {
        let kind = kind(for: relativePath)
        return kind == .text || kind == .code
    }

    static func isCode(_ relativePath: String) -> Bool {
        kind(for: relativePath) == .code
    }

    static func isOffice(_ relativePath: String) -> Bool {
        kind(for: relativePath) == .office
    }

    static func isPDF(_ relativePath: String) -> Bool {
        kind(for: relativePath) == .pdf
    }

    static func isCAD(_ relativePath: String) -> Bool {
        kind(for: relativePath) == .cad
    }

    static func isImage(_ relativePath: String) -> Bool {
        kind(for: relativePath) == .image
    }

    static func isMedia(_ relativePath: String) -> Bool {
        kind(for: relativePath) == .media
    }

    static func isArchive(_ relativePath: String) -> Bool {
        kind(for: relativePath) == .archive
    }

    /// The code workbench is the only editor allowed to read and write the
    /// bytes of this file as text.
    static func allowsCodeEditing(_ relativePath: String) -> Bool {
        switch kind(for: relativePath) {
        case .text, .code: true
        default: false
        }
    }

    static func isMarkdown(_ relativePath: String) -> Bool {
        ["md", "markdown"].contains(pathExtension(for: relativePath))
    }

    static func isHTML(_ relativePath: String) -> Bool {
        ["html", "htm"].contains(pathExtension(for: relativePath))
    }
}
#endif

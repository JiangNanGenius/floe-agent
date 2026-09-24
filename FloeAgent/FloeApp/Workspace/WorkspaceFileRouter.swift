// FloeApp — Workspace file open routing.
//
// SPDX-License-Identifier: MPL-2.0
//
// One typed decision for every entry point (inspector header, preview
// toolbar, file tree, full workspace IDE). A file type never opens in the
// wrong surface: text/code go to the code workbench, Office documents to the
// native Office editor, PDF/CAD/image/media to their viewer, everything else
// to Quick Look. The code workbench must never receive Office or binary bytes
// because it decodes and writes them as UTF-8 text.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeWorkspace

enum WorkspaceFileDestination: Equatable {
    /// Text/code editor surface: the IDE's native Swift/UIKit editor pane.
    case codeEditor
    /// Native Office engine (preview or fullscreen editing).
    case officeEditor
    /// PDF reader.
    case documentViewer
    /// Engineering drawing viewer (DXF/DWG/STEP).
    case cadViewer
    /// Image viewer / Quick Look image.
    case imageViewer
    /// Video/audio workbench.
    case mediaEditor
    /// Archive tree browser with bounded, on-demand extraction.
    case archiveBrowser
    /// Safe fallback for unknown binary documents.
    case quickLook

    var isNativeSurface: Bool { self != .codeEditor }
}

enum WorkspaceFileRouter {
    static func destination(for relativePath: String) -> WorkspaceFileDestination {
        switch WorkspaceTextPolicy.kind(forPath: relativePath) {
        case .text, .code, .unknown:
            // Unknown extensions stay text-previewable; the IDE bridge
            // additionally sniffs the bytes before any write.
            .codeEditor
        case .office:
            .officeEditor
        case .pdf:
            .documentViewer
        case .cad:
            .cadViewer
        case .image:
            .imageViewer
        case .media:
            .mediaEditor
        case .archive:
            // Archives browse as a tree and extract on demand; unknown
            // formats still reach the browser so they report why truthfully
            // instead of opening an opaque binary in Quick Look.
            .archiveBrowser
        case .binary:
            .quickLook
        }
    }

    /// The code workbench is the only IDE surface that may read/write bytes.
    static func allowsCodeEditor(_ relativePath: String) -> Bool {
        switch destination(for: relativePath) {
        case .codeEditor: true
        default: false
        }
    }

    /// A human-readable surface name for routing banners and errors. New
    /// strings are kept bilingual inline instead of editing the localization
    /// catalog (owned by another worker and out of this task's scope).
    static func surfaceName(for relativePath: String) -> String {
        switch destination(for: relativePath) {
        case .codeEditor: return OfficeInkText.t("代码编辑器", "code editor")
        case .officeEditor: return OfficeInkText.t("Office 编辑器", "Office editor")
        case .documentViewer: return OfficeInkText.t("PDF 阅读器", "PDF reader")
        case .cadViewer: return OfficeInkText.t("图纸查看器", "drawing viewer")
        case .imageViewer: return OfficeInkText.t("图片查看器", "image viewer")
        case .mediaEditor: return OfficeInkText.t("媒体工作台", "media workbench")
        case .archiveBrowser: return OfficeInkText.t("压缩包浏览器", "archive browser")
        case .quickLook: return OfficeInkText.t("快速查看", "Quick Look")
        }
    }
}
#endif

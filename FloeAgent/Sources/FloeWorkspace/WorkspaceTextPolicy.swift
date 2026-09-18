// FloeWorkspace — Typed file classification shared by the workspace IDE bridge,
// the inspector and the preview surfaces.
//
// SPDX-License-Identifier: MPL-2.0
//
// One place decides which surface may load a file. Text and code files are the
// only documents the Monaco/CodeBlitz workbench may read or write; Office,
// PDF, CAD, image, media and archive files must be routed to their native
// viewer/editor. The classifier is intentionally Foundation-only so both the
// FloeWorkspace package and the App target can depend on the same rules and so
// it stays directly unit-testable without the App toolchain.

import Foundation

/// Presentation class of a workspace file. Routing decisions (which surface
/// opens a file) are derived from this, never from a raw extension string at
/// the call site.
public enum WorkspaceFileKind: String, Sendable, CaseIterable {
    /// Plain text documents that may be edited as text (txt, md, log, csv, …).
    case text
    /// Source/configuration files that belong in the code workbench.
    case code
    /// Editable compound documents (docx/xlsx/pptx and ODF equivalents).
    case office
    /// Fixed-layout documents.
    case pdf
    /// Engineering drawings.
    case cad
    /// Raster/vector images.
    case image
    /// Time-based media (video/audio).
    case media
    /// Compressed containers.
    case archive
    /// Known binary formats that are never text.
    case binary
    /// Unrecognized extension: still allowed to open as text only when the
    /// bytes are valid UTF-8 without NUL control bytes.
    case unknown
}

public enum WorkspaceTextPolicyDecision: Equatable, Sendable {
    /// The bridge may read or write this file as UTF-8 text.
    case allowed
    /// The path extension belongs to a non-text surface; route it natively.
    case refusedNonTextPath(WorkspaceFileKind)
    /// The bytes are binary (NUL byte or invalid UTF-8); never coerce to text.
    case refusedBinaryContent
}

public enum WorkspaceTextPolicy {
    /// Extensions the code/text workbench owns. Mirrors the App's
    /// `WorkspaceFileType` so a file can never be text in one surface and
    /// binary in another.
    public static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "jsonc", "swift", "py",
        "js", "mjs", "cjs", "jsx", "ts", "tsx", "c", "h", "m",
        "mm", "cc", "cpp", "cxx", "hpp", "html", "htm", "css",
        "scss", "xml", "yaml", "yml", "toml", "sh", "bash", "zsh",
        "fish", "log", "csv", "rs", "go", "java", "kt", "kts",
        "sql", "rb", "php", "pl", "lua", "dart", "vue", "svelte",
        "gradle", "properties", "ini", "conf", "env", "gitignore",
        "dockerfile", "makefile", "patch", "diff"
    ]

    public static let codeExtensions: Set<String> = [
        "json", "jsonc", "swift", "py", "js", "mjs", "cjs", "jsx",
        "ts", "tsx", "c", "h", "m", "mm", "cc", "cpp", "cxx",
        "hpp", "html", "htm", "css", "scss", "xml", "yaml", "yml",
        "toml", "sh", "bash", "zsh", "fish", "rs", "go", "java",
        "kt", "kts", "sql", "rb", "php", "pl", "lua", "dart",
        "vue", "svelte", "gradle", "properties", "ini", "conf"
    ]

    public static let officeExtensions: Set<String> = [
        "docx", "docm", "xlsx", "xlsm", "pptx", "pptm", "doc", "xls",
        "ppt", "odt", "ods", "odp", "rtf"
    ]

    public static let cadExtensions: Set<String> = [
        "dxf", "dwg", "step", "stp", "iges", "igs", "stl", "obj"
    ]

    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff",
        "tif", "bmp", "svg", "pdf"
    ]

    public static let mediaExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "mp3", "m4a",
        "wav", "aac", "flac"
    ]

    public static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "jar",
        "war", "ipa", "deb", "dmg", "iso"
    ]

    public static let binaryExtensions: Set<String> = [
        "bin", "dat", "exe", "dll", "dylib", "so", "a", "o", "class",
        "pyc", "wasm", "sqlite", "db", "p12", "pfx", "cer", "der",
        "mobileprovision", "keystore", "ttf", "otf", "woff", "woff2"
    ]

    /// True when the workbench/editor may treat the path as text solely from
    /// its extension.
    public static func isTextualPath(_ relativePath: String) -> Bool {
        switch kind(forPath: relativePath) {
        case .text, .code, .unknown: true
        default: false
        }
    }

    public static func kind(forPath relativePath: String) -> WorkspaceFileKind {
        let name = (relativePath as NSString).lastPathComponent.lowercased()
        let ext = (relativePath as NSString).pathExtension.lowercased()
        // Extension-less well-known text files (Makefile, Dockerfile, …).
        if ext.isEmpty {
            switch name {
            case "makefile", "dockerfile", "license", "readme", "notice",
                 "changelog", "gitignore", "gitattributes", "editorconfig":
                return .text
            default:
                return .unknown
            }
        }
        if codeExtensions.contains(ext) { return .code }
        if textExtensions.contains(ext) { return .text }
        if officeExtensions.contains(ext) { return .office }
        if ext == "pdf" { return .pdf }
        if cadExtensions.contains(ext) { return .cad }
        if imageExtensions.contains(ext) { return .image }
        if mediaExtensions.contains(ext) { return .media }
        if archiveExtensions.contains(ext) { return .archive }
        if binaryExtensions.contains(ext) { return .binary }
        return .unknown
    }

    public static func isOfficePath(_ relativePath: String) -> Bool {
        kind(forPath: relativePath) == .office
    }

    public static func isPDFPath(_ relativePath: String) -> Bool {
        kind(forPath: relativePath) == .pdf
    }

    public static func isCADPath(_ relativePath: String) -> Bool {
        kind(forPath: relativePath) == .cad
    }

    public static func isImagePath(_ relativePath: String) -> Bool {
        kind(forPath: relativePath) == .image
    }

    public static func isMediaPath(_ relativePath: String) -> Bool {
        kind(forPath: relativePath) == .media
    }

    /// Binary detection for text surfaces. A NUL byte or invalid UTF-8 means
    /// the bytes must never be decoded as text or written back as text.
    public static func isUTF8Text(_ data: Data) -> Bool {
        if data.contains(0) { return false }
        return String(data: data, encoding: .utf8) != nil
    }

    /// The single decision the native IDE bridge consults before a read or a
    /// write. Path type wins over content: an xlsx whose bytes happen to be
    /// valid UTF-8 is still refused because its surface is the Office editor.
    public static func decision(forPath relativePath: String, data: Data) -> WorkspaceTextPolicyDecision {
        let kind = kind(forPath: relativePath)
        switch kind {
        case .office, .pdf, .cad, .image, .media, .archive, .binary:
            return .refusedNonTextPath(kind)
        case .text, .code, .unknown:
            return isUTF8Text(data) ? .allowed : .refusedBinaryContent
        }
    }
}

// FloeWorkspace — Typed file classification shared by the workspace IDE bridge,
// the inspector and the preview surfaces.
//
// SPDX-License-Identifier: MPL-2.0
//
// One place decides which surface may load a file. Text, code, extensionless
// and unknown-extension candidates are the only paths the text workbench may
// read or write, and their bytes are still probed before load/save; Office,
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
    /// Engineering drawings and read-only 3D mesh/scene assets.
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
    /// binary in another. The lists are deliberately broad but not exhaustive:
    /// an unlisted extension is still classified as `.unknown` and may open as
    /// text after the bounded UTF-8 content probe, so ordinary plain text is
    /// never excluded merely because its extension is uncommon.
    public static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "mdown", "mkd", "rst", "org",
        "adoc", "asciidoc", "textile", "log", "csv", "tsv", "psv",
        "srt", "vtt", "json", "jsonc", "json5", "jsonl", "ndjson",
        "geojson", "ipynb", "plist", "yaml", "yml", "toml", "ini",
        "cfg", "conf", "cnf", "properties", "env", "lock", "tex",
        "latex", "bib", "sty", "cls", "bst", "m3u", "m3u8",
        "xcconfig", "entitlements", "strings", "stringsdict",
        "pbxproj", "xcscheme", "xcworkspacedata", "storyboard", "xib",
        "patch", "diff", "desktop", "service", "reg", "inf", "spec"
    ]

    public static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "c", "h", "cc", "cpp", "cxx", "hpp",
        "hh", "hxx", "cs", "fs", "fsx", "vb", "java", "kt", "kts",
        "scala", "groovy", "gradle", "clj", "cljs", "cljc", "edn",
        "ex", "exs", "erl", "hrl", "hs", "lhs", "ml", "mli", "jl",
        "r", "rmd", "py", "pyi", "pyw", "rb", "php", "pl", "pm",
        "raku", "lua", "tcl", "sh", "bash", "zsh", "fish", "ps1",
        "psm1", "bat", "cmd", "awk", "sed", "js", "mjs", "cjs",
        "jsx", "ts", "tsx", "vue", "svelte", "astro", "html", "htm",
        "css", "scss", "sass", "less", "xml", "xsl", "xslt", "sql",
        "graphql", "gql", "proto", "go", "rs", "dart", "zig", "nim",
        "v", "sv", "svh", "vhd", "vhdl", "asm", "s", "f", "f90",
        "f95", "for", "pas", "lisp", "lsp", "scm", "ss", "rkt",
        "sol", "tf", "tfvars", "hcl", "nix", "cmake", "mk", "am",
        "ac", "m4", "vim", "el", "coffee", "purs", "properties",
        "ini", "conf", "json", "jsonc", "yaml", "yml", "toml"
    ]

    public static let officeExtensions: Set<String> = [
        "docx", "docm", "xlsx", "xlsm", "pptx", "pptm", "doc", "xls",
        "ppt", "odt", "ods", "odp", "rtf"
    ]

    public static let cadExtensions: Set<String> = [
        "dxf", "dwg", "step", "stp", "iges", "igs", "stl", "obj",
        // Read-only engineering mesh/scene formats share the controlled
        // engineering preview surface. They are binary/mesh documents and
        // must never fall through to the text/code workbench.
        "glb", "gltf", "ply", "off", "3ds", "dae", "fbx", "3mf",
        "amf", "wrl", "bim",
        // Native FloeCAD document package (directory): parametric history +
        // B-rep, opened by the FloeCAD workbench, never as text.
        "floecad"
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

    /// True when this kind may open in a text surface. Unknown extensions stay
    /// eligible and are accepted only after the bounded UTF-8 probe below; the
    /// path extension alone is never enough to decode or rewrite bytes.
    public static func isTextualKind(_ kind: WorkspaceFileKind) -> Bool {
        switch kind {
        case .text, .code, .unknown: true
        default: false
        }
    }

    /// True when the workbench/editor may treat the path as a text candidate
    /// from its extension. Unknown extensions are candidates; their bytes are
    /// still classified before load/save.
    public static func isTextualPath(_ relativePath: String) -> Bool {
        isTextualKind(kind(forPath: relativePath))
    }

    public static func kind(forPath relativePath: String) -> WorkspaceFileKind {
        let name = (relativePath as NSString).lastPathComponent.lowercased()
        let ext = (relativePath as NSString).pathExtension.lowercased()
        // Extension-less well-known text files (Makefile, Dockerfile, …).
        if ext.isEmpty {
            switch name {
            case "makefile", "dockerfile", "containerfile", "license",
                 "readme", "notice", "changelog", "authors", "contributors",
                 "copying", "install", ".gitignore", ".gitattributes",
                 ".editorconfig", ".babelrc", ".swiftformat", ".prettierrc",
                 ".eslintrc", "rakefile", "gemfile", "podfile", "brewfile",
                 "vagrantfile", "jenkinsfile", "procfile", "justfile",
                 "taskfile":
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

    /// The UTF-8 byte-order mark. Foundation's UTF-8 decoder consumes a
    /// leading BOM, so a decoding path that writes the returned String back
    /// would silently drop it. `decodeUTF8` re-attaches it as U+FEFF so a
    /// complete read/modify/write stays byte-exact.
    public static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    public static func startsWithUTF8BOM(_ data: Data) -> Bool {
        guard data.count >= utf8BOM.count else { return false }
        return data[data.startIndex] == utf8BOM[0]
            && data[data.startIndex + 1] == utf8BOM[1]
            && data[data.startIndex + 2] == utf8BOM[2]
    }

    /// Decodes a complete UTF-8 text sample. Returns nil for NUL-bearing or
    /// invalid UTF-8 bytes; these must never be silently coerced to text.
    /// A leading UTF-8 BOM is retained in the returned String so
    /// `Data(text.utf8)` reproduces the original bytes (BOM included) and
    /// UTF-8 readers can report an exact round-trip.
    public static func decodeUTF8(_ data: Data) -> String? {
        guard !data.contains(0),
              let text = String(data: data, encoding: .utf8) else { return nil }
        // Foundation consumes exactly one leading UTF-8 BOM. Re-attach it
        // unconditionally so even a second literal U+FEFF is preserved.
        return startsWithUTF8BOM(data) ? "\u{FEFF}" + text : text
    }

    /// Binary detection for text surfaces. A NUL byte, invalid UTF-8 or an
    /// otherwise undecodable byte sequence means the bytes must never be
    /// decoded as text or written back as text.
    public static func isUTF8Text(_ data: Data) -> Bool {
        decodeUTF8(data) != nil
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

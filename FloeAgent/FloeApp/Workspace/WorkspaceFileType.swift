// FloeApp — Workspace file presentation classification.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation

/// Shared file classification for the inspector and the full workspace IDE.
/// Keeping this in one place prevents a file from opening as code in one
/// surface while falling back to an unnumbered text view in another.
enum WorkspaceFileType {
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "jsonc", "swift", "py",
        "js", "mjs", "cjs", "jsx", "ts", "tsx", "c", "h", "m",
        "mm", "cc", "cpp", "cxx", "hpp", "html", "htm", "css",
        "scss", "xml", "yaml", "yml", "toml", "sh", "bash", "zsh",
        "fish", "log", "csv", "rs", "go", "java", "kt", "kts",
        "sql", "rb", "php", "pl", "lua", "dart", "vue", "svelte",
        "gradle", "properties", "ini", "conf"
    ]

    private static let codeExtensions: Set<String> = [
        "json", "jsonc", "swift", "py", "js", "mjs", "cjs", "jsx",
        "ts", "tsx", "c", "h", "m", "mm", "cc", "cpp", "cxx",
        "hpp", "html", "htm", "css", "scss", "xml", "yaml", "yml",
        "toml", "sh", "bash", "zsh", "fish", "rs", "go", "java",
        "kt", "kts", "sql", "rb", "php", "pl", "lua", "dart",
        "vue", "svelte", "gradle", "properties", "ini", "conf"
    ]

    static func pathExtension(for relativePath: String) -> String {
        (relativePath as NSString).pathExtension.lowercased()
    }

    static func isText(_ relativePath: String) -> Bool {
        textExtensions.contains(pathExtension(for: relativePath))
    }

    static func isCode(_ relativePath: String) -> Bool {
        codeExtensions.contains(pathExtension(for: relativePath))
    }

    static func isMarkdown(_ relativePath: String) -> Bool {
        ["md", "markdown"].contains(pathExtension(for: relativePath))
    }

    static func isHTML(_ relativePath: String) -> Bool {
        ["html", "htm"].contains(pathExtension(for: relativePath))
    }
}
#endif

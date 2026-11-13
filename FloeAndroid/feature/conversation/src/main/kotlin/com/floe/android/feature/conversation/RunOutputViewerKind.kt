// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

import java.util.Locale

/**
 * Owned run-output preview kinds for the App's own full-screen viewer lane
 * (text reading space plus bounded image/audio/video playback).
 *
 * Text is deliberately broader than the old MIME/extension pair table: every
 * sealed output whose type facts say plain text (a `text/*` or text
 * application MIME, or the Android publisher's `application/octet-stream`
 * fallback for an uncommon text/code extension) is a TEXT candidate. The
 * viewer performs the bounded UTF-8/NUL content probe before rendering, so an
 * unknown extension is a candidate, never an automatic binary decode.
 * Office/PDF/image/audio/video/archive/binary families keep their exact
 * MIME+extension agreement and never fall through to text.
 *
 * [UNSUPPORTED] is an honest answer, not a failure: such cards keep their
 * real Save Copy action and carry an explicit limitation note instead of a
 * fake preview affordance.
 */
enum class RunOutputViewerKind { TEXT, IMAGE, AUDIO, VIDEO, UNSUPPORTED }

/** The closed classification table shared by the card affordance gate and
 * the App-host open router (one table, two consumers, no drift). */
object RunOutputViewerSupport {

    /** Every extension the native lightweight text reader may treat as a
     * candidate. Mirrors FloeWorkspace `WorkspaceTextPolicy` text+code sets;
     * an unlisted extension is still a candidate and is decided by the
     * bounded content probe. */
    val TEXT_EXTENSIONS: Set<String> = setOf(
        "txt", "text", "md", "markdown", "mdown", "mkd", "rst", "org",
        "adoc", "asciidoc", "textile", "log", "csv", "tsv", "psv",
        "srt", "vtt", "json", "jsonc", "json5", "jsonl", "ndjson",
        "geojson", "ipynb", "plist", "yaml", "yml", "toml", "ini",
        "cfg", "conf", "cnf", "properties", "env", "lock", "tex",
        "latex", "bib", "sty", "cls", "bst", "m3u", "m3u8",
        "xcconfig", "entitlements", "strings", "stringsdict",
        "pbxproj", "xcscheme", "xcworkspacedata", "storyboard", "xib",
        "patch", "diff", "desktop", "service", "reg", "inf", "spec",
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
        "ac", "m4", "vim", "el", "coffee", "purs",
    )

    /** Sealed families owned by their native viewer/editor. A text MIME
     * over one of these names never becomes a text preview. */
    private val NON_TEXT_EXTENSIONS: Set<String> = setOf(
        "docx", "docm", "xlsx", "xlsm", "pptx", "pptm", "doc", "xls",
        "ppt", "odt", "ods", "odp", "rtf", "pdf",
        "dxf", "dwg", "step", "stp", "iges", "igs", "brep", "stl",
        "obj", "glb", "gltf", "3mf", "floecad",
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff",
        "tif", "bmp", "svg",
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "mp3", "m4a",
        "wav", "aac", "flac",
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "jar",
        "war", "ipa", "deb", "dmg", "iso",
        "bin", "dat", "exe", "dll", "dylib", "so", "a", "o", "class",
        "pyc", "wasm", "sqlite", "db", "p12", "pfx", "cer", "der",
        "mobileprovision", "keystore", "ttf", "otf", "woff", "woff2",
    )

    /** Non-`text/*` MIME families that are still plain-text source/config. */
    private val TEXT_APPLICATION_MIMES: Set<String> = setOf(
        "application/json",
        "application/x-ndjson",
        "application/geo+json",
        "application/x-ipynb+json",
        "application/x-plist",
        "application/yaml",
        "application/x-yaml",
        "application/toml",
        "application/javascript",
        "application/x-javascript",
        "application/ecmascript",
        "application/graphql",
        "application/x-sh",
        "application/sql",
        "application/x-tex",
        "application/x-latex",
        "application/x-httpd-php",
        "application/x-ruby",
        "application/x-perl",
        "application/x-python",
    )

    /** Decode-provable raster formats (BitmapFactory-bound). */
    private val IMAGE_MIME_TO_EXTENSIONS = mapOf(
        "image/png" to setOf("png"),
        "image/jpeg" to setOf("jpg", "jpeg"),
        "image/webp" to setOf("webp"),
        "image/gif" to setOf("gif"),
    )

    /** Platform MediaPlayer-playable audio containers. */
    private val AUDIO_MIME_TO_EXTENSIONS = mapOf(
        "audio/wav" to setOf("wav"),
        "audio/x-wav" to setOf("wav"),
        "audio/mpeg" to setOf("mp3"),
        "audio/mp3" to setOf("mp3"),
        // An audio-only MP4 keeps its audio container names; a `.mp4` name
        // stays the VIDEO agreement's territory — MIME alone never decides.
        "audio/mp4" to setOf("m4a", "aac"),
        "audio/x-m4a" to setOf("m4a"),
        "audio/aac" to setOf("aac", "m4a"),
        "audio/ogg" to setOf("ogg"),
        "application/ogg" to setOf("ogg"),
    )

    /** Platform MediaPlayer-playable video containers. */
    private val VIDEO_MIME_TO_EXTENSIONS = mapOf(
        "video/mp4" to setOf("mp4"),
        "video/webm" to setOf("webm"),
        "video/3gpp" to setOf("3gp"),
    )

    /** Every extension the App-owned viewer lane can stage for a family with
     * an exact agreement. TEXT candidates outside this set (an uncommon or
     * no extension) are still accepted by the stager's bounded text-candidate
     * gate, then content-probed by the reader. */
    val STAGED_EXTENSIONS: Set<String> = TEXT_EXTENSIONS
        .plus(IMAGE_MIME_TO_EXTENSIONS.values.flatten())
        .plus(AUDIO_MIME_TO_EXTENSIONS.values.flatten())
        .plus(VIDEO_MIME_TO_EXTENSIONS.values.flatten())
        .toSortedSet()

    fun classify(mimeType: String, displayName: String): RunOutputViewerKind {
        val mime = mimeType.substringBefore(';').trim().lowercase(Locale.ROOT)
        val extension = displayName.substringAfterLast('.', "").lowercase(Locale.ROOT)
        // A sealed receipt never has an empty MIME or display name; an
        // absent fact can never become a preview promise.
        if (mime.isEmpty() || displayName.isEmpty()) return RunOutputViewerKind.UNSUPPORTED
        // Families with an exact MIME+extension agreement keep it.
        if (IMAGE_MIME_TO_EXTENSIONS[mime]?.contains(extension) == true) {
            return RunOutputViewerKind.IMAGE
        }
        if (AUDIO_MIME_TO_EXTENSIONS[mime]?.contains(extension) == true) {
            return RunOutputViewerKind.AUDIO
        }
        if (VIDEO_MIME_TO_EXTENSIONS[mime]?.contains(extension) == true) {
            return RunOutputViewerKind.VIDEO
        }
        // Once an extension is known to belong to a native non-text family,
        // no text MIME or octet-stream fallback may reinterpret its bytes.
        if (extension.isNotEmpty() && extension in NON_TEXT_EXTENSIONS) {
            return RunOutputViewerKind.UNSUPPORTED
        }
        val textMime = mime.startsWith("text/") || mime in TEXT_APPLICATION_MIMES
        // Extensionless/unknown names stay candidates only for a text MIME
        // or the Android publisher's bounded octet-stream fallback. The
        // reader still refuses NUL/invalid UTF-8 bytes.
        if (textMime || mime == "application/octet-stream") {
            return RunOutputViewerKind.TEXT
        }
        return RunOutputViewerKind.UNSUPPORTED
    }

    /** True only when a real in-App route exists for these sealed facts
     * (the card Open affordance and the host router both consult THIS). */
    fun supportsPreview(mimeType: String, displayName: String): Boolean =
        classify(mimeType, displayName) != RunOutputViewerKind.UNSUPPORTED
}

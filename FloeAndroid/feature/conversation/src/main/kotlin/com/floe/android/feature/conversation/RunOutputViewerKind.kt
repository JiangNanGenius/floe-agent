// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.conversation

import java.util.Locale

/**
 * One sealed display name's three deliberately SEPARATE projections.
 *
 * [title] is ALWAYS the exact sealed display name. It stays the card caption,
 * the viewer/print title and the canonical sealed path tail
 * (`RunOutputs/<run>/<output>/<title>`) — it is never rewritten.
 *
 * [extension] is the real lowercase suffix after applying the legacy
 * trailing-annotation compatibility rule below; "" means the name carries no
 * usable ordinary suffix. It is a filename fact only: every consumer must
 * still prove its own MIME/format agreement before promising a preview.
 *
 * [transferName] is one safe single-component filename ending in
 * [extension] when a real extension was proven. Ordinary names map to the
 * exact title. A legacy annotated name keeps its human label but places the
 * one trailing annotation group beside the basename instead of after the
 * extension (`poster.png（海报）` -> `poster（海报）.png`), so a system
 * CREATE_DOCUMENT picker, decoder or suffix-gated stager sees the actual
 * type without losing the label.
 */
data class RunOutputNameFacts(
    val title: String,
    val extension: String,
    val transferName: String,
    val annotated: Boolean,
)

/**
 * Compatibility projection for sealed run-output display names.
 *
 * Old receipts (and current producers that echo a human label) may append
 * one annotation group AFTER the real extension, for example
 * `sydney_creator_meetup_poster.png（海报）` or
 * `teaser.mp4（12秒预告）`. The sealed string must stay untouched — it is
 * both the title and the canonical path tail — but the real extension is
 * still needed by the existing MIME+extension agreement tables, the PDF
 * magic/stager gates and Save Copy's suggested filename.
 *
 * The rule is deliberately narrow:
 *  - the name is a valid single component (already enforced by the native
 *    receipt; rechecked by each consumer);
 *  - a name already ending in an ordinary dotted ASCII extension token is
 *    returned byte-identically;
 *  - otherwise the name must end with exactly ONE balanced bracket group
 *    (`（）`, `()`, `[]`, `【】`, `《》`, `「」` or `『』`), instantly preceded
 *    by an ASCII extension token (0..1 ASCII space allowed), itself
 *    preceded by a dot; the annotation body is 1..64 characters with no
 *    bracket, path separator or control character;
 *  - the token is 1..16 ASCII letters/digits/`_`/`-`; a second group or any
 *    trailing text keeps the old opaque name.
 *
 * That means ordinary parentheses in a basename (`report (final).png`) are
 * untouched, while `report (final).png（海报）` projects the real `png`.
 * This object never authorizes a type by itself: MIME agreement, full-byte
 * digest and content/magic checks remain exactly where they were.
 */
object RunOutputDisplayName {

    private const val MAX_EXTENSION_CHARS = 16
    private const val MAX_ANNOTATION_CHARS = 64

    /** Closed set of balanced annotation wrappers seen in human labels.
     * Every other trailing form stays an opaque name (old behaviour). */
    private val ANNOTATION_CLOSERS = mapOf(
        '（' to '）',
        '(' to ')',
        '[' to ']',
        '【' to '】',
        '《' to '》',
        '「' to '」',
        '『' to '』',
    )

    /** The legacy last-dot derivation, lowercased (no annotation handling). */
    private fun rawExtension(displayName: String): String =
        displayName.substringAfterLast('.', "").lowercase(Locale.ROOT)

    fun facts(displayName: String): RunOutputNameFacts {
        val unchanged = RunOutputNameFacts(
            title = displayName,
            extension = rawExtension(displayName),
            transferName = displayName,
            annotated = false,
        )
        if (displayName.isEmpty()) return unchanged
        // Ordinary `name.ext` (including uppercase extensions and legitimate
        // parentheses earlier in the basename) is byte-identical.
        if (displayName.lastIndexOf('.') > 0 && isSafeExtensionToken(unchanged.extension)) {
            return unchanged
        }
        // Legacy annotation form: one balanced group at the very END. Look
        // backwards so a dot inside the label (`（v1.2）`) can never be
        // mistaken for the real extension.
        val close = displayName.last()
        val open = ANNOTATION_CLOSERS.entries.firstOrNull { it.value == close }?.key
            ?: return unchanged
        val annotationStart = displayName.lastIndexOf(open, displayName.length - 2)
        if (annotationStart <= 0) return unchanged
        val body = displayName.substring(annotationStart + 1, displayName.length - 1)
        if (body.isEmpty() || body.length > MAX_ANNOTATION_CHARS || body.isBlank()) {
            return unchanged
        }
        if (body.any { it in ANNOTATION_CLOSERS.keys || it in ANNOTATION_CLOSERS.values ||
                it == '/' || it == '\\' || it.code < 0x20 || it.code == 0x7f }
        ) {
            return unchanged
        }
        // The extension token must sit immediately before the group (one
        // optional ASCII space) and be preceded by the last real dot.
        var extensionEnd = annotationStart
        if (extensionEnd > 0 && displayName[extensionEnd - 1] == ' ') extensionEnd--
        var extensionStart = extensionEnd
        while (extensionStart > 0 && isExtensionChar(displayName[extensionStart - 1])) {
            extensionStart--
        }
        if (extensionStart == extensionEnd ||
            extensionEnd - extensionStart > MAX_EXTENSION_CHARS
        ) {
            return unchanged
        }
        val dot = extensionStart - 1
        if (dot <= 0 || displayName[dot] != '.') return unchanged

        val extension = displayName.substring(extensionStart, extensionEnd)
            .lowercase(Locale.ROOT)
        // Keep the human annotation, but put it before the real suffix so the
        // transfer name ends in a decodable extension. Same characters as the
        // sealed title (only the position of the dot + suffix changes).
        val annotationSuffix = displayName.substring(extensionEnd)
        val transferName = displayName.substring(0, dot) + annotationSuffix + "." + extension
        return RunOutputNameFacts(
            title = displayName,
            extension = extension,
            transferName = transferName,
            annotated = true,
        )
    }

    private fun isExtensionChar(char: Char): Boolean =
        char in 'a'..'z' || char in 'A'..'Z' || char in '0'..'9' ||
            char == '_' || char == '-'

    private fun isSafeExtensionToken(extension: String): Boolean =
        extension.isNotEmpty() && extension.length <= MAX_EXTENSION_CHARS &&
            extension.all(::isExtensionChar)
}

/**
 * Owned run-output preview kinds for the App's own full-screen viewer lane
 * (text reading space plus bounded image/audio/video playback).
 *
 * Text is deliberately broader than the old MIME/extension pair table: every
 * sealed output whose type facts say plain text (a text MIME family or text
 * application MIME, or the Android publisher's `application/octet-stream`
 * fallback for an uncommon text/code extension) is a TEXT candidate. The
 * viewer performs the bounded UTF-8/NUL content probe before rendering, so an
 * unknown extension is a candidate, never an automatic binary decode.
 * Office/PDF/image/audio/video/archive/binary families keep their exact
 * MIME+extension agreement and never fall through to text.
 *
 * Legacy sealed names with ONE trailing human annotation
 * (`poster.png（海报）`) use [RunOutputDisplayName]'s conservative projection
 * for the extension fact while the exact sealed string stays the display
 * title and path tail. The MIME/format agreement, digest and content decode
 * checks are unchanged.
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

    /** Application MIME families that are still plain-text source/config. */
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
        // The real extension, including the explicit legacy trailing-
        // annotation projection. The MIME agreement below still decides the
        // family: this value is never a type promise on its own.
        val extension = RunOutputDisplayName.facts(displayName).extension
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

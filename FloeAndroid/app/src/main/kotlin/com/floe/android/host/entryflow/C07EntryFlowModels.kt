// SPDX-License-Identifier: MPL-2.0
//
// C07 App-entry contracts shared by the platform host and its JVM regressions.
//
// These types are deliberately Android-framework free: Intents, ContentResolver,
// NotesService and RuntimeHost stay in the host/adapter files. Everything here
// is bounded, closed and content-free in toString() except the explicitly
// user-visible display metadata used by the chooser.
package com.floe.android.host.entryflow

import com.floe.android.feature.entryflow.EntryReviewAvailability
import java.security.MessageDigest
import java.util.UUID

internal const val ENTRY_MAX_ITEMS = 5
internal const val ENTRY_MAX_TEXT_BYTES = 1_048_576L
internal const val ENTRY_MAX_ITEM_BYTES = 64L * 1024L * 1024L
internal const val ENTRY_MAX_TOTAL_BYTES = 128L * 1024L * 1024L
internal const val ENTRY_MAX_URL_BYTES = 8_192
internal const val ENTRY_DEDUP_WINDOW_MS = 10L * 60L * 1_000L
internal const val ENTRY_DISCARD_WINDOW_MS = 5L * 1_000L
internal const val ENTRY_INTAKE_TTL_MS = 10L * 60L * 1_000L
internal const val ENTRY_MAX_FEEDBACK_CHARS = 8_000
internal const val ENTRY_MAX_DIAGNOSTIC_BYTES = 128 * 1024

/** A parsed supported entry route. IDs are canonical lowercase UUIDs. */
internal sealed interface C07EntryRoute {
    data object NewTask : C07EntryRoute
    data class Task(val conversationID: String) : C07EntryRoute
    data class Schedule(val scheduleID: String) : C07EntryRoute
    data class Share(val intakeID: String?) : C07EntryRoute
}

internal sealed interface C07RouteParse {
    data class Parsed(val route: C07EntryRoute) : C07RouteParse
    data class Refused(val code: String) : C07RouteParse
}

/**
 * Strict `floe://` parser (the Android executable counterpart of
 * `C07AppEntryRoute` in the shared core).
 *
 * The link is only a navigation/intake request. It can never carry a prompt,
 * approval, permission, command, path or task target that has not been
 * re-read from the existing store.
 */
internal object C07EntryRouteParser {
    private val hosts = setOf("new", "task", "schedule", "share")

    fun parse(raw: String): C07RouteParse {
        if (raw.isEmpty() || raw.toByteArray(Charsets.UTF_8).size > ENTRY_MAX_URL_BYTES) {
            return C07RouteParse.Refused("tooLong")
        }
        if (raw.any { it.code < 0x21 || it.code == 0x7F }) {
            return C07RouteParse.Refused("malformed")
        }
        if (!raw.startsWith("floe://", ignoreCase = true)) {
            return C07RouteParse.Refused("unsupportedScheme")
        }
        val uri = runCatching { java.net.URI(raw) }.getOrNull()
            ?: return C07RouteParse.Refused("malformed")
        if (!uri.scheme.equals("floe", ignoreCase = true)) {
            return C07RouteParse.Refused("unsupportedScheme")
        }
        if (uri.userInfo != null || uri.port != -1 || uri.fragment != null) {
            return C07RouteParse.Refused("malformed")
        }
        val host = uri.host?.lowercase() ?: return C07RouteParse.Refused("malformed")
        val rawPath = uri.rawPath.orEmpty()
        if (rawPath.contains('%') || rawPath.contains('\\') || rawPath.contains("..")) {
            return C07RouteParse.Refused("malformed")
        }
        if (host !in hosts) return C07RouteParse.Refused("unsupportedAction")
        val query = uri.rawQuery
        return when (host) {
            "new" -> {
                if (rawPath.isNotEmpty() && rawPath != "/") {
                    C07RouteParse.Refused("malformed")
                } else if (query != null) {
                    C07RouteParse.Refused("unexpectedParameters")
                } else {
                    C07RouteParse.Parsed(C07EntryRoute.NewTask)
                }
            }
            "task" -> parseIdRoute(rawPath, query)?.let {
                C07RouteParse.Parsed(C07EntryRoute.Task(it))
            } ?: C07RouteParse.Refused("invalidTarget")
            "schedule" -> parseIdRoute(rawPath, query)?.let {
                C07RouteParse.Parsed(C07EntryRoute.Schedule(it))
            } ?: C07RouteParse.Refused("invalidTarget")
            "share" -> parseShare(rawPath, query)
            else -> C07RouteParse.Refused("unsupportedAction")
        }
    }

    private fun parseIdRoute(rawPath: String, query: String?): String? {
        if (query != null) return null
        if (!rawPath.startsWith("/") || rawPath.length != 37) return null
        return canonicalUuid(rawPath.substring(1))
    }

    private fun parseShare(rawPath: String, query: String?): C07RouteParse {
        if (rawPath.isNotEmpty() && rawPath != "/") {
            return C07RouteParse.Refused("malformed")
        }
        if (query == null) return C07RouteParse.Parsed(C07EntryRoute.Share(null))
        if (query.contains('&') || query.count { it == '=' } != 1) {
            return C07RouteParse.Refused("unexpectedParameters")
        }
        val name = query.substringBefore('=')
        val value = query.substringAfter('=')
        if (name != "intake") return C07RouteParse.Refused("unexpectedParameters")
        val id = canonicalUuid(value) ?: return C07RouteParse.Refused("invalidTarget")
        return C07RouteParse.Parsed(C07EntryRoute.Share(id))
    }

    private fun canonicalUuid(value: String): String? = C07EntryIds.canonicalUuid(value)
}

/** Strict canonical UUID identity used by links and notification payloads. */
internal object C07EntryIds {
    fun canonicalUuid(value: String?): String? {
        if (value == null || value.length != 36) return null
        if (value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-') return null
        if (value.any { ch ->
                !(ch in '0'..'9' || ch in 'a'..'f' || ch in 'A'..'F' || ch == '-')
            }
        ) {
            return null
        }
        val parsed = runCatching { UUID.fromString(value) }.getOrNull() ?: return null
        return parsed.toString().takeIf { it.equals(value, ignoreCase = true) }
    }
}

internal enum class C07EntryItemKind { TEXT, FILE }

/**
 * What the admitted bytes ARE for routing to a real consumer. It is admission
 * metadata only: it grants no execution, rendering, upload or tool authority,
 * and it never asserts a verified preview. A SOURCE/DATA/CAD item is stored as
 * bounded opaque data by the existing Task staging or Notes resource importer.
 */
internal enum class C07EntryContentClass {
    TEXT,
    IMAGE,
    AUDIO,
    VIDEO,
    PDF,
    OFFICE,
    CAD,
    SOURCE,
    DATA,
    PACKAGE,
}

/**
 * Existing Floe package owners. A package is handed to the owner that already
 * implements inspection/review; the entry flow never restores, remaps or
 * auto-imports one. `wire` is the exact `restoreKind` the Data Exchange owner
 * already understands (`beginRestore(uri, restoreKind)`).
 */
internal enum class C07EntryPackageKind(val wire: String) {
    NONE(""),
    NOTE("note"),
    CANVAS("canvas"),
    BACKUP("backup"),
    CAD("cad"),
    ;

    val isPackage: Boolean get() = this != NONE

    companion object {
        fun ofExtension(extension: String): C07EntryPackageKind = when (extension) {
            "floenote" -> NOTE
            "flocanvas" -> CANVAS
            "floebackup" -> BACKUP
            "floecad" -> CAD
            else -> NONE
        }
    }
}

/**
 * One admitted share/open item. The content URI and text stay internals of
 * the host: [toString] exposes only the bounded display metadata, so this
 * value is safe in diagnostics and test failures.
 */
internal class C07EntryCapturedItem(
    val index: Int,
    val kind: C07EntryItemKind,
    val uriString: String?,
    val mimeType: String,
    val displayName: String,
    val declaredBytes: Long,
    val text: String?,
    /** Consumer routing class. Defaults keep older fixtures source-compatible. */
    val contentClass: C07EntryContentClass = C07EntryContentClass.DATA,
    val packageKind: C07EntryPackageKind = C07EntryPackageKind.NONE,
    /** The exact format resolved at admission. Null keeps the pure lookup path
     * used by direct fixtures; the host always supplies the resolved format so
     * a recognised opaque container keeps its real admission identity. */
    val format: C07EntryFormat? = null,
) {
    override fun toString(): String =
        "C07EntryCapturedItem(index=$index, kind=$kind, mime=$mimeType, " +
            "bytes=$declaredBytes, nameChars=${displayName.length}, " +
            "class=$contentClass, package=$packageKind)"
}

internal sealed interface C07ShareValidation {
    data class Accepted(
        val totalKnownBytes: Long,
        val textBytes: Long,
        /** Both existing destinations accept bounded opaque data files. */
        val taskAvailable: Boolean = true,
        val notesAvailable: Boolean = true,
        /** Non-NONE only when the single admitted item is a Floe package. */
        val packageKind: C07EntryPackageKind = C07EntryPackageKind.NONE,
    ) : C07ShareValidation

    data class Refused(val code: C07EntryRefusal) : C07ShareValidation
}

internal enum class C07EntryRefusal {
    EMPTY,
    ITEM_LIMIT,
    TEXT_TOO_LARGE,
    ITEM_TOO_LARGE,
    TOTAL_TOO_LARGE,
    UNSUPPORTED,
    CONTENT_MISMATCH,
    PACKAGE_MIXED,
    INVALID_URI,
    GRANT_REVOKED,
    UNREADABLE,
    TOO_LARGE,
    FAILED,
    POLICY_UNAVAILABLE,
    BUSY,
    STALE,
    NOTES_UNAVAILABLE,
    STAGING_UNAVAILABLE,
    TARGET_UNAVAILABLE,
}

/**
 * One admitted content format. `probes` is the exact magic family the actual
 * bytes must show; `null` means the format is extension-routed and content is
 * proved later by the real pinned reader (CAD files), never by this policy.
 * `opaqueWhenUnrecognized` allows an extension-proved data/CAD file whose
 * container has no portable magic to continue as bounded opaque DATA instead
 * of inventing a verified preview.
 */
internal data class C07EntryFormat(
    val mimeType: String,
    val contentClass: C07EntryContentClass,
    val extensions: Set<String>,
    val probes: Set<C07ProbeKind>?,
    val opaqueWhenUnrecognized: Boolean = false,
    val canTask: Boolean = true,
    val canNotes: Boolean = true,
    val packageKind: C07EntryPackageKind = C07EntryPackageKind.NONE,
)

/**
 * Bounded, consumer-aware share/open policy.
 *
 * Admission is about whether a REAL existing consumer can take bounded opaque
 * bytes, not whether Floe can execute, render or preview them. The existing
 * Task attachment producer stages any admitted content as data (no send), and
 * the existing Notes resource/file-note importer stores it as an immutable
 * resource (no execution, no invented page/preview). Executable installers
 * (`apk`, `dex`, `exe`, ...) remain refused: no existing consumer opens them
 * and admitting them would invite an install/run flow that must not exist.
 */
internal object C07SharePolicy {
    val packageMimeNote = "application/vnd.floe.package.note"
    val packageMimeCanvas = "application/vnd.floe.package.canvas"
    val packageMimeBackup = "application/vnd.floe.package.backup"

    /** Text/source/config extensions admitted as SOURCE data. They are stored
     * as bytes only; nothing is rendered, parsed or executed. */
    private val textExtensions = setOf(
        "txt", "text", "log", "csv", "tsv", "md", "markdown", "mdx", "rst", "org",
        "json", "jsonl", "ndjson", "json5", "xml", "yaml", "yml", "toml", "ini",
        "cfg", "conf", "config", "properties", "env", "lock", "sql", "sh", "bash",
        "zsh", "fish", "py", "pyw", "pyi", "js", "mjs", "cjs", "jsx", "ts", "mts",
        "cts", "tsx", "kt", "kts", "java", "scala", "groovy", "gradle", "c", "h",
        "cc", "cpp", "cxx", "hpp", "hh", "hxx", "m", "mm", "cs", "fs", "vb", "rs",
        "go", "rb", "php", "pl", "pm", "lua", "r", "swift", "dart", "ex", "exs",
        "erl", "hrl", "hs", "lhs", "clj", "cljs", "sol", "vue", "svelte", "astro",
        "html", "htm", "xhtml", "css", "scss", "sass", "less", "tex", "bib",
        "diff", "patch", "srt", "vtt", "asm", "s", "proto", "graphql", "gql",
        "cmake", "mk", "ninja", "plist",
    )

    /** Extra source-data MIME declarations providers commonly use. */
    private val sourceMimes = setOf(
        "application/json",
        "application/xml",
        "application/javascript",
        "application/x-javascript",
        "application/typescript",
        "application/x-sh",
        "application/x-yaml",
        "application/yaml",
        "application/sql",
        "application/toml",
        "application/x-httpd-php",
        "application/x-python-code",
    )

    /**
     * Installable executable containers. None has an existing in-App consumer,
     * so they stay refused by name instead of being staged and mistaken for
     * something Floe could run.
     */
    private val refusedExtensions = setOf(
        "apk", "apks", "xapk", "aab", "dex", "odex", "vdex", "oat", "art",
        "elf", "exe", "dll", "msi", "dmg", "pkg", "deb", "rpm", "ipa", "jar",
        "class", "wasm",
    )

    private val cadFormats: List<C07EntryFormat> = listOf(
        C07EntryFormat("application/dxf", C07EntryContentClass.CAD, setOf("dxf"), null, opaqueWhenUnrecognized = true),
        C07EntryFormat("application/acad", C07EntryContentClass.CAD, setOf("dwg"), null, opaqueWhenUnrecognized = true),
        C07EntryFormat("application/step", C07EntryContentClass.CAD, setOf("step", "stp"), null, opaqueWhenUnrecognized = true),
        C07EntryFormat("model/iges", C07EntryContentClass.CAD, setOf("iges", "igs"), null, opaqueWhenUnrecognized = true),
        C07EntryFormat("application/octet-stream", C07EntryContentClass.CAD, setOf("brep"), null, opaqueWhenUnrecognized = true),
        C07EntryFormat("model/gltf-binary", C07EntryContentClass.CAD, setOf("glb"), setOf(C07ProbeKind.GLB)),
        C07EntryFormat("text/plain", C07EntryContentClass.CAD, setOf("gltf", "obj"), setOf(C07ProbeKind.TEXT)),
        C07EntryFormat("model/stl", C07EntryContentClass.CAD, setOf("stl"), null, opaqueWhenUnrecognized = true),
        C07EntryFormat("model/3mf", C07EntryContentClass.CAD, setOf("3mf"), setOf(C07ProbeKind.ZIP)),
    )

    private val formats: List<C07EntryFormat> = listOf(
        C07EntryFormat("text/plain", C07EntryContentClass.SOURCE, textExtensions, setOf(C07ProbeKind.TEXT)),
        C07EntryFormat("application/pdf", C07EntryContentClass.PDF, setOf("pdf"), setOf(C07ProbeKind.PDF)),
        C07EntryFormat("image/png", C07EntryContentClass.IMAGE, setOf("png"), setOf(C07ProbeKind.PNG)),
        C07EntryFormat("image/jpeg", C07EntryContentClass.IMAGE, setOf("jpg", "jpeg"), setOf(C07ProbeKind.JPEG)),
        C07EntryFormat("image/webp", C07EntryContentClass.IMAGE, setOf("webp"), setOf(C07ProbeKind.WEBP)),
        C07EntryFormat("image/gif", C07EntryContentClass.IMAGE, setOf("gif"), setOf(C07ProbeKind.GIF)),
        C07EntryFormat("image/heic", C07EntryContentClass.IMAGE, setOf("heic"), setOf(C07ProbeKind.HEIC)),
        C07EntryFormat("image/heif", C07EntryContentClass.IMAGE, setOf("heif"), setOf(C07ProbeKind.HEIC)),
        C07EntryFormat("image/avif", C07EntryContentClass.IMAGE, setOf("avif"), setOf(C07ProbeKind.AVIF)),
        C07EntryFormat("image/bmp", C07EntryContentClass.IMAGE, setOf("bmp"), setOf(C07ProbeKind.BMP)),
        C07EntryFormat("image/x-ms-bmp", C07EntryContentClass.IMAGE, setOf("bmp"), setOf(C07ProbeKind.BMP)),
        C07EntryFormat("audio/mpeg", C07EntryContentClass.AUDIO, setOf("mp3"), setOf(C07ProbeKind.MP3)),
        C07EntryFormat("audio/x-m4a", C07EntryContentClass.AUDIO, setOf("m4a"), setOf(C07ProbeKind.ISO_BMFF)),
        C07EntryFormat("audio/aac", C07EntryContentClass.AUDIO, setOf("aac"), setOf(C07ProbeKind.AAC)),
        C07EntryFormat("audio/wav", C07EntryContentClass.AUDIO, setOf("wav"), setOf(C07ProbeKind.WAV)),
        C07EntryFormat("audio/x-wav", C07EntryContentClass.AUDIO, setOf("wav"), setOf(C07ProbeKind.WAV)),
        C07EntryFormat("audio/flac", C07EntryContentClass.AUDIO, setOf("flac"), setOf(C07ProbeKind.FLAC)),
        C07EntryFormat("audio/ogg", C07EntryContentClass.AUDIO, setOf("ogg", "oga", "opus"), setOf(C07ProbeKind.OGG)),
        C07EntryFormat("audio/opus", C07EntryContentClass.AUDIO, setOf("opus"), setOf(C07ProbeKind.OGG)),
        C07EntryFormat("audio/webm", C07EntryContentClass.AUDIO, setOf("webm"), setOf(C07ProbeKind.WEBM)),
        C07EntryFormat("video/mp4", C07EntryContentClass.VIDEO, setOf("mp4", "m4v"), setOf(C07ProbeKind.ISO_BMFF)),
        C07EntryFormat("audio/mp4", C07EntryContentClass.AUDIO, setOf("m4a", "mp4", "aac"), setOf(C07ProbeKind.ISO_BMFF)),
        C07EntryFormat("video/quicktime", C07EntryContentClass.VIDEO, setOf("mov"), setOf(C07ProbeKind.ISO_BMFF)),
        C07EntryFormat("video/x-m4v", C07EntryContentClass.VIDEO, setOf("m4v"), setOf(C07ProbeKind.ISO_BMFF)),
        C07EntryFormat("video/3gpp", C07EntryContentClass.VIDEO, setOf("3gp"), setOf(C07ProbeKind.ISO_BMFF)),
        C07EntryFormat("video/webm", C07EntryContentClass.VIDEO, setOf("webm"), setOf(C07ProbeKind.WEBM)),
        C07EntryFormat("video/x-matroska", C07EntryContentClass.VIDEO, setOf("mkv"), setOf(C07ProbeKind.WEBM)),
        C07EntryFormat("application/zip", C07EntryContentClass.DATA, setOf("zip"), setOf(C07ProbeKind.ZIP)),
        C07EntryFormat(
            "application/x-zip-compressed",
            C07EntryContentClass.DATA,
            setOf("zip"),
            setOf(C07ProbeKind.ZIP),
        ),
        C07EntryFormat(
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            C07EntryContentClass.OFFICE, setOf("docx"), setOf(C07ProbeKind.ZIP),
        ),
        C07EntryFormat(
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            C07EntryContentClass.OFFICE, setOf("xlsx"), setOf(C07ProbeKind.ZIP),
        ),
        C07EntryFormat(
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            C07EntryContentClass.OFFICE, setOf("pptx"), setOf(C07ProbeKind.ZIP),
        ),
    )

    private val packageFormats: List<C07EntryFormat> = listOf(
        C07EntryFormat(
            packageMimeNote, C07EntryContentClass.PACKAGE, setOf("floenote"),
            setOf(C07ProbeKind.ZIP), canTask = false, canNotes = false,
            packageKind = C07EntryPackageKind.NOTE,
        ),
        C07EntryFormat(
            packageMimeCanvas, C07EntryContentClass.PACKAGE, setOf("flocanvas"),
            setOf(C07ProbeKind.ZIP), canTask = false, canNotes = false,
            packageKind = C07EntryPackageKind.CANVAS,
        ),
        C07EntryFormat(
            packageMimeBackup, C07EntryContentClass.PACKAGE, setOf("floebackup"),
            setOf(C07ProbeKind.ZIP), canTask = false, canNotes = false,
            packageKind = C07EntryPackageKind.BACKUP,
        ),
        C07EntryFormat(
            "application/vnd.floe.cad.package", C07EntryContentClass.PACKAGE,
            setOf("floecad"), null, opaqueWhenUnrecognized = true,
            canTask = false, canNotes = false,
            packageKind = C07EntryPackageKind.CAD,
        ),
    )

    private val allFormats: List<C07EntryFormat> = packageFormats + cadFormats + formats

    fun normalizeMime(raw: String?): String =
        raw.orEmpty().substringBefore(';').trim().lowercase()

    fun extension(displayName: String): String =
        displayName.substringAfterLast('.', "").trim().lowercase()

    fun isRefusedExecutable(extension: String): Boolean = extension in refusedExtensions

    /**
     * Resolves the declared provider hint and the file name to one admitted
     * format. Package and CAD extensions are authoritative identity, not
     * content claims; everything else must also pass [probeMatches].
     */
    fun formatFor(declaredMime: String, displayName: String): C07EntryFormat? {
        val mime = normalizeMime(declaredMime)
        val fileExtension = extension(displayName)
        if (isRefusedExecutable(fileExtension)) return null
        packageFormats.firstOrNull { fileExtension in it.extensions }?.let { return it }
        cadFormats.firstOrNull { fileExtension in it.extensions }?.let { return it }
        if (mime.isEmpty() || mime == "application/octet-stream") {
            formats.firstOrNull { fileExtension in it.extensions }?.let { return it }
            if (fileExtension in textExtensions) return textFormat()
            return null
        }
        formats.firstOrNull { it.mimeType == mime && fileExtension in it.extensions }?.let { return it }
        // A provider-declared Office/ZIP MIME refines only through the family
        // extension; a ZIP renamed .pdf never resolves to a PDF format here.
        if (mime == "application/zip" || mime == "application/x-zip-compressed") {
            return formats.firstOrNull {
                it.contentClass == C07EntryContentClass.OFFICE && fileExtension in it.extensions
            }
        }
        if (mime.startsWith("text/") || mime in sourceMimes) return textFormat()
        return null
    }

    private fun textFormat(): C07EntryFormat =
        C07EntryFormat("text/plain", C07EntryContentClass.SOURCE, textExtensions, setOf(C07ProbeKind.TEXT))

    fun isKnownFormatMime(mime: String): Boolean {
        val normalized = normalizeMime(mime)
        return normalized.startsWith("text/") ||
            normalized in sourceMimes ||
            allFormats.any { it.mimeType == normalized }
    }

    fun isKnownFormatExtension(extension: String): Boolean =
        extension in textExtensions || allFormats.any { extension in it.extensions }

    val executableExtensions: Set<String> get() = refusedExtensions
    val knownTextExtensions: Set<String> get() = textExtensions

    fun isSupported(mimeType: String, displayName: String): Boolean =
        formatFor(mimeType, displayName) != null

    /**
     * Honest reconciliation of the provider MIME with the actual container.
     * `format` came from the declared hint; [probe] is what the bytes show.
     */
    fun probeMatches(format: C07EntryFormat, probe: C07ProbeKind): Boolean {
        val expected = format.probes ?: return true
        if (probe in expected) return true
        return format.opaqueWhenUnrecognized && probe == C07ProbeKind.UNKNOWN
    }

    /**
     * Resolves a format from bytes when the provider declared no concrete type
     * (empty or `application/octet-stream`). Known magic wins; an
     * extension-proved data/CAD file may continue as opaque data without any
     * preview claim. A recognizable media container with no declared subtype
     * stays opaque DATA: the container is proved, the codec/preview is not.
     */
    fun formatForProbe(probe: C07ProbeKind, displayName: String): C07EntryFormat? {
        val fileExtension = extension(displayName)
        if (isRefusedExecutable(fileExtension)) return null
        packageFormats.firstOrNull { fileExtension in it.extensions }?.let { return it }
        cadFormats.firstOrNull { fileExtension in it.extensions }?.let { return it }
        val direct = when (probe) {
            C07ProbeKind.PDF -> "application/pdf"
            C07ProbeKind.PNG -> "image/png"
            C07ProbeKind.JPEG -> "image/jpeg"
            C07ProbeKind.WEBP -> "image/webp"
            C07ProbeKind.GIF -> "image/gif"
            C07ProbeKind.HEIC -> "image/heic"
            C07ProbeKind.AVIF -> "image/avif"
            C07ProbeKind.BMP -> "image/bmp"
            C07ProbeKind.MP3 -> "audio/mpeg"
            C07ProbeKind.WAV -> "audio/wav"
            C07ProbeKind.FLAC -> "audio/flac"
            C07ProbeKind.AAC -> "audio/aac"
            C07ProbeKind.OGG -> "audio/ogg"
            C07ProbeKind.ISO_BMFF -> when (fileExtension) {
                "mov" -> "video/quicktime"
                "m4v" -> "video/x-m4v"
                "3gp" -> "video/3gpp"
                "m4a" -> "audio/x-m4a"
                "aac" -> "audio/aac"
                "mp4" -> "video/mp4"
                else -> return opaqueFormat(probe)
            }
            C07ProbeKind.WEBM -> when (fileExtension) {
                "mkv" -> "video/x-matroska"
                "webm" -> "video/webm"
                else -> return opaqueFormat(probe)
            }
            C07ProbeKind.GLB -> "model/gltf-binary"
            C07ProbeKind.ZIP -> when (fileExtension) {
                "docx", "xlsx", "pptx" -> formats.first {
                    it.contentClass == C07EntryContentClass.OFFICE && fileExtension in it.extensions
                }.mimeType
                else -> "application/zip"
            }
            C07ProbeKind.TEXT -> "text/plain"
            C07ProbeKind.UNKNOWN -> return null
        }
        return formats.firstOrNull { it.mimeType == direct }
    }

    private fun opaqueFormat(probe: C07ProbeKind): C07EntryFormat =
        C07EntryFormat(
            "application/octet-stream",
            C07EntryContentClass.DATA,
            emptySet(),
            setOf(probe),
            opaqueWhenUnrecognized = true,
        )

    /** Bytes are recognized as a container, but the name does not identify the
     * concrete type: keep routing as opaque data instead of claiming a preview. */
    fun opaqueData(probe: C07ProbeKind): C07EntryFormat = opaqueFormat(probe)

    fun validate(items: List<C07EntryCapturedItem>): C07ShareValidation {
        if (items.isEmpty()) return C07ShareValidation.Refused(C07EntryRefusal.EMPTY)
        if (items.size > ENTRY_MAX_ITEMS) {
            return C07ShareValidation.Refused(C07EntryRefusal.ITEM_LIMIT)
        }
        var textBytes = 0L
        var totalKnown = 0L
        var packages = 0
        var packageKind = C07EntryPackageKind.NONE
        var taskAvailable = true
        var notesAvailable = true
        for (item in items) {
            when (item.kind) {
                C07EntryItemKind.TEXT -> {
                    val bytes = item.text?.toByteArray(Charsets.UTF_8)?.size?.toLong() ?: 0L
                    if (bytes <= 0L) return C07ShareValidation.Refused(C07EntryRefusal.EMPTY)
                    textBytes += bytes
                    if (textBytes > ENTRY_MAX_TEXT_BYTES) {
                        return C07ShareValidation.Refused(C07EntryRefusal.TEXT_TOO_LARGE)
                    }
                }
                C07EntryItemKind.FILE -> {
                    val format = item.format ?: formatFor(item.mimeType, item.displayName)
                        ?: return C07ShareValidation.Refused(C07EntryRefusal.UNSUPPORTED)
                    if (format.packageKind.isPackage) {
                        packages += 1
                        packageKind = format.packageKind
                    }
                    if (!format.canTask) taskAvailable = false
                    if (!format.canNotes) notesAvailable = false
                    if (item.declaredBytes < -1L) {
                        return C07ShareValidation.Refused(C07EntryRefusal.UNREADABLE)
                    }
                    if (!format.packageKind.isPackage) {
                        // Package bytes are streamed by the EXISTING review
                        // owner under its own budget; the entry owner never
                        // copies them, so the attachment cap does not apply.
                        if (item.declaredBytes > ENTRY_MAX_ITEM_BYTES) {
                            return C07ShareValidation.Refused(C07EntryRefusal.ITEM_TOO_LARGE)
                        }
                        if (item.declaredBytes > 0L) totalKnown += item.declaredBytes
                    }
                }
            }
        }
        if (totalKnown > ENTRY_MAX_TOTAL_BYTES) {
            return C07ShareValidation.Refused(C07EntryRefusal.TOTAL_TOO_LARGE)
        }
        if (packages > 0) {
            // A Floe package has ONE owner that inspects/reviews the archive.
            // Mixing it with other items would silently split or re-bundle it.
            if (packages != 1 || items.size != 1 || items.single().kind != C07EntryItemKind.FILE) {
                return C07ShareValidation.Refused(C07EntryRefusal.PACKAGE_MIXED)
            }
            taskAvailable = false
            notesAvailable = false
        }
        return C07ShareValidation.Accepted(
            totalKnownBytes = totalKnown,
            textBytes = textBytes,
            taskAvailable = taskAvailable,
            notesAvailable = notesAvailable,
            packageKind = packageKind,
        )
    }

    /**
     * Metadata-only name. It is never used as a path; the native notes and
     * attachment stores validate their own file-name hints again.
     */
    fun sanitizeDisplayName(raw: String?): String {
        val leaf = raw.orEmpty()
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .filter { it.code >= 0x20 && it.code != 0x7F }
            .trim()
        return leaf.take(120).ifBlank { "attachment" }
    }

    fun noteTitle(displayName: String): String {
        val stem = displayName.substringBeforeLast('.', displayName).trim()
        return stem.take(120).ifBlank { displayName.take(120) }
    }
}

/**
 * Pure destination gate used by both the host and its JVM regressions. A
 * genuinely unsupported item is refused at admission; a package whose review
 * owner is not wired (or a `.floecad` directory with no folder importer) is a
 * disabled destination with a PRECISE missing-wiring reason.
 */
internal object C07EntryDestinationGate {
    fun review(
        packageKind: C07EntryPackageKind,
        ownerInstalled: Boolean,
        supportsDirectoryPackages: Boolean,
    ): EntryReviewAvailability = when {
        !packageKind.isPackage -> EntryReviewAvailability.NOT_APPLICABLE
        !ownerInstalled -> EntryReviewAvailability.MISSING_OWNER
        packageKind == C07EntryPackageKind.CAD && !supportsDirectoryPackages ->
            EntryReviewAvailability.DIRECTORY_UNAVAILABLE
        else -> EntryReviewAvailability.AVAILABLE
    }

    fun offersTask(canTask: Boolean, packageKind: C07EntryPackageKind): Boolean =
        canTask && !packageKind.isPackage

    fun offersNotes(canNotes: Boolean, packageKind: C07EntryPackageKind): Boolean =
        canNotes && !packageKind.isPackage
}

/** Stable duplicate-suppression key. Only a digest is persisted. */
internal object C07EntryFingerprint {
    fun of(
        action: String,
        subject: String?,
        items: List<C07EntryCapturedItem>,
    ): String {
        val digest = MessageDigest.getInstance("SHA-256")
        fun field(value: String) {
            val bytes = value.toByteArray(Charsets.UTF_8)
            digest.update((bytes.size ushr 24).toByte())
            digest.update((bytes.size ushr 16).toByte())
            digest.update((bytes.size ushr 8).toByte())
            digest.update(bytes.size.toByte())
            digest.update(bytes)
        }
        field(action)
        field(subject.orEmpty())
        field(items.size.toString())
        for (item in items) {
            field(item.kind.name)
            when (item.kind) {
                C07EntryItemKind.TEXT -> field(sha256(item.text.orEmpty()))
                C07EntryItemKind.FILE -> {
                    field(item.uriString.orEmpty())
                    field(item.mimeType)
                    field(item.declaredBytes.toString())
                    field(item.displayName)
                }
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun sha256(value: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
}

internal object C07EntryCopy {
    fun textPreview(items: List<C07EntryCapturedItem>): String? {
        val text = items.filter { it.kind == C07EntryItemKind.TEXT }
            .mapNotNull { it.text }
            .firstOrNull { it.isNotBlank() }
            ?: return null
        return text.take(4_096)
            .split(Regex("\\s+"))
            .filter { it.isNotEmpty() }
            .joinToString(" ")
            .take(200)
    }
}

/** Identifier-only notification payload constants. */
internal object C07EntryNotification {
    const val ACTION_QUESTION = "com.floe.android.entry.QUESTION"
    const val ACTION_SCHEDULE = "com.floe.android.entry.SCHEDULE"
    const val EXTRA_CONVERSATION_ID = "floe.entry.conversationID"
    const val EXTRA_REQUEST_ID = "floe.entry.requestID"
    const val EXTRA_QUESTION_ID = "floe.entry.questionID"
    const val EXTRA_SCHEDULE_ID = "floe.entry.scheduleID"

    fun validQuestionId(value: String?): String? =
        value?.takeIf { it.length in 1..128 && it.all { ch -> ch.code in 0x21..0x7E } }

    fun validQuestionTextId(value: String?): String? =
        value?.takeIf { it.length in 1..160 && it.all { ch -> ch.code in 0x21..0x7E } }
}

internal sealed interface C07EntryNavigation {
    data class OpenTask(val conversationID: String) : C07EntryNavigation
    data class OpenSchedule(val scheduleID: String) : C07EntryNavigation
    data class OpenNewTask(val intakeID: String?) : C07EntryNavigation
    data object OpenNotes : C07EntryNavigation
}

internal data class C07HomeDraftAdoption(
    val revision: Long,
    val text: String,
)

internal data class C07ScheduleFocus(
    val requestID: Long,
    val scheduleID: String,
)

internal enum class C07SetupStep(val key: String) {
    WELCOME("welcome"),
    MODELS("models"),
    VOICE("voice"),
    FILES("files"),
    NOTIFICATIONS("notifications"),
    DONE("done");

    companion object {
        fun fromKey(key: String?): C07SetupStep =
            entries.firstOrNull { it.key == key } ?: WELCOME
    }
}

internal data class C07SetupState(
    val step: C07SetupStep = C07SetupStep.WELCOME,
    val seen: Boolean = false,
    val finished: Boolean = false,
    val skipped: Boolean = false,
    val updatedAt: Long = 0L,
)

internal enum class C07EntryJournalStatus { ADMITTED, COMPLETED, DISCARDED, FAILED }

internal data class C07JournalRecord(
    val fingerprint: String,
    val intakeID: String,
    val status: C07EntryJournalStatus,
    val updatedAt: Long,
    val expiresAt: Long,
)

/** Pure duplicate policy shared by the store and its JVM regressions. */
internal object C07EntryDedup {
    fun blocks(
        record: C07JournalRecord?,
        fingerprint: String,
        liveIntakeID: String?,
        now: Long,
    ): Boolean {
        if (record == null || record.fingerprint != fingerprint) return false
        if (record.expiresAt <= now) return false
        return when (record.status) {
            C07EntryJournalStatus.ADMITTED -> record.intakeID == liveIntakeID
            C07EntryJournalStatus.COMPLETED,
            C07EntryJournalStatus.DISCARDED,
            C07EntryJournalStatus.FAILED -> true
        }
    }
}

/** Pure, side-effect-free setup-guide navigation. It never reads or writes a
 * provider, model, voice, account or credential choice. */
internal object C07SetupMachine {
    fun next(state: C07SetupState, now: Long): C07SetupState {
        val next = C07SetupStep.entries.getOrNull(state.step.ordinal + 1)
            ?: return state
        return state.copy(step = next, seen = true, updatedAt = now)
    }

    fun previous(state: C07SetupState, now: Long): C07SetupState {
        val previous = C07SetupStep.entries.getOrNull(state.step.ordinal - 1)
            ?: return state
        return state.copy(step = previous, seen = true, updatedAt = now)
    }

    fun dismiss(state: C07SetupState, now: Long): C07SetupState =
        state.copy(seen = true, updatedAt = now)

    fun skip(state: C07SetupState, now: Long): C07SetupState =
        state.copy(seen = true, skipped = true, updatedAt = now)

    fun finish(state: C07SetupState, now: Long): C07SetupState =
        state.copy(seen = true, finished = true, updatedAt = now)

    fun offerOnce(state: C07SetupState, now: Long): Pair<C07SetupState, Boolean> {
        if (state.seen) return state to false
        return state.copy(seen = true, updatedAt = now) to true
    }
}

/** Bounded in-process replay guard for Activity/notification redelivery. */
internal class C07EntryReplayGuard(
    private val windowMillis: Long = 30_000L,
    private val limit: Int = 12,
) {
    private val seen = LinkedHashMap<String, Long>()

    fun admit(key: String, now: Long): Boolean {
        val prior = seen[key]
        if (prior != null && now - prior < windowMillis) return false
        seen[key] = now
        while (seen.size > limit) {
            val first = seen.keys.firstOrNull() ?: break
            seen.remove(first)
        }
        return true
    }
}

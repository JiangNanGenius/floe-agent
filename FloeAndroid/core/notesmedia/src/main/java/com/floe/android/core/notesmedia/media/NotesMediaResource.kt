// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.media

/**
 * Media identity for one Notes page resource.
 *
 * Rules encoded here (G06 media contract, 2026-10-29):
 *  - an Android-editable ink resource is a Floe-owned, versioned binary
 *    format ([InkFormat.CURRENT]); its `mediaType` is explicit and must never
 *    be inferred from a file name or from the producing platform;
 *  - an Apple PencilKit drawing is a FOREIGN, opaque, NON-editable resource.
 *    This module preserves its bytes untouched and refuses to open it in the
 *    Android editor. There is no conversion, no "best effort" decode and no
 *    claim of cross-platform PencilKit interoperability;
 *  - a PDF page background is a verified source snapshot
 *    ([com.floe.android.core.notesmedia.source.VerifiedMediaSnapshot]), never
 *    a raw path handed in by a model or a caller that did not prove the bytes;
 *  - every resource that is displayed must carry a digest and length that the
 *    owner computed; previews are derived artefacts and never authority.
 *
 * The constants are the SHARED contract with the Notes authority/UI. Adding a
 * media type requires a new binding, not a change of meaning for an old one.
 */
object NotesMediaType {
    /** Floe-editable Android ink document (see [InkFormat]). */
    const val FLOE_INK: String = "application/vnd.floe.notes.ink"

    /** Apple PencilKit `PKDrawing` bytes. Opaque here: preserve only. */
    const val APPLE_PENCILKIT: String = "application/vnd.apple.pencilkit.drawing"

    /** Verified PDF background source. */
    const val PDF: String = "application/pdf"

    /** Raster preview (PNG only; lossless, deterministic). */
    const val PREVIEW_PNG: String = "image/png"
}

/**
 * Version binding for the editable Android ink document format.
 *
 * `CURRENT` is the only version this module writes. `MIN_READABLE` is the
 * oldest version it can still decode. A decoded document of an unknown/newer
 * version is REFUSED with [InkDecodeRefusal.UNSUPPORTED_VERSION] and the
 * original bytes are left untouched (never rewritten to a blank document).
 */
object InkFormat {
    const val MAGIC: String = "FLOEINK1"
    const val CURRENT: Int = 1
    const val MIN_READABLE: Int = 1

    /** Hard bounds shared by the writer, the reader and the store. */
    const val MAX_DOCUMENT_BYTES: Long = 32L shl 20
    const val MAX_STROKES: Int = 20_000
    const val MAX_INPUT_BYTES_PER_STROKE: Int = 1 shl 20
    const val MAX_GROUPS: Int = 2_000
    const val MAX_STRING_CHARS: Int = 128
    const val MAX_PAGE_POINTS: Float = 100_000f

    fun readable(version: Int): Boolean = version in MIN_READABLE..CURRENT
}

/** How the module may treat a resource it was asked to open. */
enum class MediaEditability {
    /** Fully editable/decodable by this module (Floe ink v1..current). */
    EDITABLE,

    /** Read-only bytes: displayable/exportable only if a renderer exists. */
    READ_ONLY,

    /** Foreign editor format (Apple PencilKit). Preserve, never decode/edit. */
    PRESERVE_ONLY,
}

/**
 * One immutable descriptor of a stored resource. It is a HANDFUL OF FACTS the
 * owner proved; it is never path authority and never a capability grant.
 *
 * IDENTITY RULE (corrected 2026-10-30): [resourceId] is the Notes authority's
 * opaque resource identity — the same value as
 * `ImportedResource.resourceID` / `NoteResourceRecord` id, normally a UUID.
 * It is **NOT** the content-addressed `sha256`. [sha256] exists only to prove
 * the bytes the descriptor describes; it must never be copied into
 * `NotePage.drawingResourceID`, `backgroundResourceID` or
 * `officeResourceID`. Likewise the digest is not accepted as a path or lookup
 * key by this module.
 *
 * [formatVersion] versions the MEDIA CONTAINER only: Floe ink uses
 * [InkFormat.CURRENT], foreign/read-only resources use 0 (an ink version must
 * never be stamped onto a PDF or PencilKit resource).
 */
data class MediaResourceDescriptor(
    val resourceId: String,
    val mediaType: String,
    val formatVersion: Int,
    val byteCount: Long,
    val sha256: String,
    val editable: MediaEditability,
    val previewMediaType: String? = null,
    val previewSha256: String? = null,
) {
    init {
        require(ResourceIdPolicy.isValid(resourceId)) { "Invalid Notes media resource id" }
        require(Sha256.isValid(sha256)) { "Resource digest must be 64 lowercase hex" }
        require(byteCount in 1L..InkFormat.MAX_DOCUMENT_BYTES) { "Resource size outside module bounds" }
        previewSha256?.let { require(Sha256.isValid(it)) { "Preview digest must be 64 lowercase hex" } }
    }
}

/**
 * Stable resource-id grammar for the Notes authority's opaque IDs (UUIDs
 * included). This module only validates shape (no path separators, no
 * traversal, bounded length) so a resource id can never be smuggled into a
 * filesystem path. A 64-hex string is syntactically accepted because IDs are
 * opaque, but it is still an ID, never a CAS digest: use
 * `ImportedResource.resourceID` for resource references and keep [Sha256]
 * facts separate.
 */
object ResourceIdPolicy {
    const val MAX_CHARS: Int = 96
    private val PATTERN = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")

    fun isValid(id: String?): Boolean =
        id != null && id.length in 1..MAX_CHARS && PATTERN.matches(id) &&
            !id.contains("..") && id != "." && id != ".."
}

/** Lowercase SHA-256 grammar + digest hex shared by every descriptor and snapshot. */
object Sha256 {
    private val PATTERN = Regex("^[0-9a-f]{64}$")

    fun isValid(value: String?): Boolean = value != null && PATTERN.matches(value)

    fun hex(bytes: ByteArray): String {
        val md = java.security.MessageDigest.getInstance("SHA-256")
        return Sha256Hex.encode(md.digest(bytes))
    }
}

/**
 * The explicit media/format binding table. [bindingFor] is the ONLY way the
 * module decides whether bytes are editable; callers cannot opt into editing a
 * foreign format by passing a flag.
 */
object MediaBindings {
    private val bindings: Map<String, MediaEditability> = mapOf(
        NotesMediaType.FLOE_INK to MediaEditability.EDITABLE,
        NotesMediaType.APPLE_PENCILKIT to MediaEditability.PRESERVE_ONLY,
        NotesMediaType.PDF to MediaEditability.READ_ONLY,
        NotesMediaType.PREVIEW_PNG to MediaEditability.READ_ONLY,
    )

    fun editabilityOf(mediaType: String?): MediaEditability? = bindings[mediaType]

    /**
     * Resolves the editability of one declared resource. Unknown media types
     * are NOT assumed editable and are NOT silently accepted as read-only
     * either: the caller gets null and must refuse/preserve explicitly.
     */
    fun resolve(mediaType: String?, formatVersion: Int): MediaEditability? {
        val editability = editabilityOf(mediaType) ?: return null
        return when (editability) {
            MediaEditability.EDITABLE -> if (InkFormat.readable(formatVersion)) editability else null
            else -> editability
        }
    }
}

/**
 * Typed refusal when a caller asks to edit something this module must not
 * touch. Every value is path-free and safe to show in a diagnostic view.
 */
enum class InkEditRefusal {
    /** Apple PencilKit (or another foreign editor's) drawing. Preserved only. */
    FOREIGN_INK_FORMAT,

    /** Declared version newer/older than this module can read. */
    UNSUPPORTED_VERSION,

    /** Bytes did not pass the ink decoder/validator. */
    INVALID_DOCUMENT,

    /** The descriptor's digest/length do not match the actual bytes. */
    IDENTITY_MISMATCH,

    /** The requested operation is outside the module (e.g. OCR backend absent). */
    NOT_SUPPORTED,
}

/**
 * Opaque foreign drawing that must be preserved byte-for-byte.
 *
 * Deliberately contains NO decode/convert function and no `toFloeInk`: the
 * only operations are copy-to-destination (digest verified) and refusal of
 * editing. This makes "no destructive format conversion to blank" structural.
 */
class ForeignInkResource(
    val descriptor: MediaResourceDescriptor,
    private val bytes: ByteArray,
) {
    init {
        require(descriptor.editable != MediaEditability.EDITABLE) {
            "ForeignInkResource must not be constructed for an editable resource"
        }
        require(bytes.size.toLong() == descriptor.byteCount) { "Foreign ink bytes disagree with descriptor length" }
    }

    /** True only when the held bytes still hash to the declared digest. */
    fun identityHolds(): Boolean = Sha256.hex(bytes) == descriptor.sha256

    /**
     * Copies the ORIGINAL bytes to a caller-owned output sink. The caller is
     * responsible for its own atomic commit; nothing here rewrites the bytes.
     */
    fun copyTo(openOutput: () -> java.io.OutputStream) {
        check(identityHolds()) { "Foreign ink identity changed since load; refusing to copy" }
        openOutput().use { out -> out.write(bytes) }
    }

    /** The only supported "edit": an explicit refusal. */
    fun requestEdit(): InkEditRefusal? = when (descriptor.mediaType) {
        NotesMediaType.APPLE_PENCILKIT -> InkEditRefusal.FOREIGN_INK_FORMAT
        else -> InkEditRefusal.FOREIGN_INK_FORMAT
    }
}

/** Small hex helper kept dependency-free so JVM tests can use it directly. */
internal object Sha256Hex {
    fun encode(digest: ByteArray): String {
        val out = StringBuilder(digest.size * 2)
        for (b in digest) {
            val v = b.toInt() and 0xff
            out.append(HEX[v ushr 4]).append(HEX[v and 0x0f])
        }
        return out.toString()
    }

    private val HEX = "0123456789abcdef".toCharArray()
}

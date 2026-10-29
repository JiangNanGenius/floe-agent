// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.api

/**
 * Optional, additive Office full-text indexing capability.
 *
 * An Office document's body lives in an immutable Notes resource; the note
 * itself carries only an editable resource reference. Search and the assistant
 * read the native `officeExtractedText` cache, so after an import, an in-place
 * edit or a replace-file the cache must be rebuilt from the NEW exact resource
 * or the user would keep querying stale bytes.
 *
 * This port is deliberately separate from [NotesOfficePort]: the editor still
 * only needs viewer/save-copy behaviour, while a real platform host may expose
 * the extraction capability by additionally implementing this interface on its
 * Office port (`ports.office is NotesOfficeIndexingPort`). A host without it
 * keeps today's behaviour; the UI never invents an index.
 *
 * Honesty rules every implementation must keep:
 *  * extraction reads the exact immutable resource and writes ONLY through the
 *    native `document.cacheOfficeText` path, which revalidates
 *    `(document, sourceResource, revision)` inside its own transaction; a stale
 *    late result is [NotesOfficeIndexOutcome.Stale] and writes nothing;
 *  * the original file and the user's saved resource are never modified;
 *  * an unsupported/encrypted package produces a typed [NoText]/[Failed],
 *    never a fake empty success and never stale text;
 *  * indexing failure never turns a real successful file save into a failed
 *    document write.
 */
public sealed interface NotesOfficeIndexOutcome {
    public val documentID: String

    /** The exact immutable resource this outcome describes. */
    public val sourceResourceID: String

    /** True only when the native cache now holds text for this source. */
    public val indexed: Boolean get() = this is Indexed

    public data class Indexed(
        override val documentID: String,
        override val sourceResourceID: String,
        /** Document revision the cache write observed. */
        public val revision: Int,
        public val textLength: Int,
        /**
         * True when the bounded extractor stopped at its own text cap. The
         * index then says so explicitly; the document body is untouched.
         */
        public val truncated: Boolean,
    ) : NotesOfficeIndexOutcome

    /** The cache already described this exact source and revision. */
    public data class UpToDate(
        override val documentID: String,
        override val sourceResourceID: String,
        public val revision: Int,
        public val textLength: Int,
    ) : NotesOfficeIndexOutcome

    /**
     * The package opened and parsed, but contains no extractable text (for
     * example an image-only deck). The native cache records the typed reason
     * for this exact source; it never keeps another source's text.
     */
    public data class NoText(
        override val documentID: String,
        override val sourceResourceID: String,
        public val revision: Int,
        public val reason: String,
    ) : NotesOfficeIndexOutcome

    /**
     * The document no longer references [sourceResourceID] (the note was
     * replaced/edited again while extraction ran, or the revision moved). No
     * index write happened and no retry can help for THIS source.
     */
    public data class Stale(
        override val documentID: String,
        override val sourceResourceID: String,
        public val reason: String,
    ) : NotesOfficeIndexOutcome

    /** Legacy binary (.doc/.xls/.ppt), encrypted or otherwise unreadable format. */
    public data class Unsupported(
        override val documentID: String,
        override val sourceResourceID: String,
        public val reason: String,
    ) : NotesOfficeIndexOutcome

    /** Retryable means re-running extraction for the same source may succeed. */
    public data class Failed(
        override val documentID: String,
        override val sourceResourceID: String,
        public val failure: NotesPortFailure,
        public val retryable: Boolean,
    ) : NotesOfficeIndexOutcome
}

/** Optional capability implemented by the real Office port. */
public interface NotesOfficeIndexingPort {
    /**
     * Cheap, non-suspending format admission for the actual file name/MIME.
     * False means no index attempt is scheduled at all.
     */
    public fun supports(fileName: String?, mediaType: String?): Boolean

    /**
     * Rebuild the native Office text index for one document from its exact
     * immutable resource. [expectedRevision] is the revision the caller
     * observed when it confirmed the saved resource; the native cache rejects
     * a mismatched revision as stale instead of labelling newer content.
     *
     * Safe to call repeatedly: an already-current cache returns [UpToDate]
     * without reading the resource bytes.
     */
    public suspend fun index(
        documentID: String,
        sourceResourceID: String,
        expectedRevision: Int,
    ): NotesOfficeIndexOutcome
}

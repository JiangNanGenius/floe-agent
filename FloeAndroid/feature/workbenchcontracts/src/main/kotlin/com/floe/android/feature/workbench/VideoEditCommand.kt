// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

/**
 * Closed R2 video-edit vocabulary.
 *
 * Each variant maps one-to-one to an existing case of the shared Swift
 * `MediaEditCommand` transaction engine (`MediaEditCommands.swift`). The host
 * serializes the variant to the SAME `type` name and field names the engine
 * already validates; `R2` does not introduce a second transaction engine and
 * never rewrites the whole project JSON from Kotlin.
 *
 * R1 `MediaEditCommand` (image-only) stays frozen. `SetCanvas` is repeated
 * here because a video editor may change the output canvas in the SAME
 * transactional batch as the timeline command; the host maps both to the one
 * shared engine.
 *
 * Every apply is one transaction: one revision advance, one undo step, one
 * stable `opID`. Unknown command types are rejected; null vs absent keeps the
 * explicit [OptionalUpdate] three-way meaning for nullable clip crop.
 */
sealed interface VideoEditCommand {
    /** Exact Swift `MediaEditCommand` case name on the R2 wire. */
    fun wireType(): String

    data class AppendClip(val clip: VideoClip) : VideoEditCommand {
        override fun wireType(): String = "appendClip"
    }

    data class UpdateClip(
        val id: String,
        val trimStart: Double? = null,
        val trimEnd: Double? = null,
        val speed: Double? = null,
        val volume: Double? = null,
        val isMuted: Boolean? = null,
        val rotationDegrees: Double? = null,
        val crop: OptionalUpdate<NormalizedRect> = OptionalUpdate.Unchanged,
        val leadingTransition: VideoTransitionKind? = null,
        val transitionDuration: Double? = null,
    ) : VideoEditCommand {
        override fun wireType(): String = "updateClip"
    }

    data class ReorderClips(val orderedIDs: List<String>) : VideoEditCommand {
        override fun wireType(): String = "reorderClips"
    }

    data class SplitClip(
        val id: String,
        val atTimelineSeconds: Double,
    ) : VideoEditCommand {
        override fun wireType(): String = "splitClip"
    }

    data class DuplicateClip(val id: String) : VideoEditCommand {
        override fun wireType(): String = "duplicateClip"
    }

    data class RemoveClip(val id: String) : VideoEditCommand {
        override fun wireType(): String = "removeClip"
    }

    data class SetPrimaryAudio(
        val volume: Double? = null,
        val muted: Boolean? = null,
    ) : VideoEditCommand {
        override fun wireType(): String = "setPrimaryAudio"
    }

    /** Explicit cover frame in timeline seconds; null derives the first frame. */
    data class SetCover(val time: Double?) : VideoEditCommand {
        override fun wireType(): String = "setCover"
    }

    /** Batch time correction for every caption; bounded by the shared engine. */
    data class ShiftCaptions(val bySeconds: Double) : VideoEditCommand {
        override fun wireType(): String = "shiftCaptions"
    }

    data class AddMusic(val music: MusicClip) : VideoEditCommand {
        override fun wireType(): String = "addMusic"
    }

    data class UpdateMusic(
        val id: String,
        val offsetSeconds: Double? = null,
        val trimStart: Double? = null,
        val lengthSeconds: Double? = null,
        val volume: Double? = null,
        val fadeInSeconds: Double? = null,
        val fadeOutSeconds: Double? = null,
    ) : VideoEditCommand {
        override fun wireType(): String = "updateMusic"
    }

    data class RemoveMusic(val id: String) : VideoEditCommand {
        override fun wireType(): String = "removeMusic"
    }

    data class AddCaption(val caption: CaptionSegment) : VideoEditCommand {
        override fun wireType(): String = "addCaption"
    }

    data class UpdateCaption(
        val id: String,
        val start: Double? = null,
        val end: Double? = null,
        val text: String? = null,
    ) : VideoEditCommand {
        override fun wireType(): String = "updateCaption"
    }

    data class RemoveCaption(val id: String) : VideoEditCommand {
        override fun wireType(): String = "removeCaption"
    }

    /** Subtitle style, including safe-area behavior, applied locally on export. */
    data class SetCaptionStyle(val style: CaptionStyle) : VideoEditCommand {
        override fun wireType(): String = "setCaptionStyle"
    }

    /** Output canvas change in the same transaction; maps to Swift `setCanvas`. */
    data class SetCanvas(
        val width: Int,
        val height: Int,
        val frameRate: Double? = null,
    ) : VideoEditCommand {
        override fun wireType(): String = "setCanvas"
    }
}

/**
 * Frozen `type`/field vocabulary for the R2 video command wire. The field set
 * lists every key the host may emit; absent optional fields are omitted (not
 * sent as null) except `crop`, whose explicit `state` object distinguishes
 * unchanged/clear/set.
 */
object VideoCommandWire {
    const val APPEND_CLIP = "appendClip"
    const val UPDATE_CLIP = "updateClip"
    const val REORDER_CLIPS = "reorderClips"
    const val SPLIT_CLIP = "splitClip"
    const val DUPLICATE_CLIP = "duplicateClip"
    const val REMOVE_CLIP = "removeClip"
    const val SET_PRIMARY_AUDIO = "setPrimaryAudio"
    const val SET_COVER = "setCover"
    const val SHIFT_CAPTIONS = "shiftCaptions"
    const val ADD_MUSIC = "addMusic"
    const val UPDATE_MUSIC = "updateMusic"
    const val REMOVE_MUSIC = "removeMusic"
    const val ADD_CAPTION = "addCaption"
    const val UPDATE_CAPTION = "updateCaption"
    const val REMOVE_CAPTION = "removeCaption"
    const val SET_CAPTION_STYLE = "setCaptionStyle"
    const val SET_CANVAS = "setCanvas"

    val ALL_TYPES: List<String> = listOf(
        APPEND_CLIP, UPDATE_CLIP, REORDER_CLIPS, SPLIT_CLIP, DUPLICATE_CLIP, REMOVE_CLIP,
        SET_PRIMARY_AUDIO, SET_COVER, SHIFT_CAPTIONS, ADD_MUSIC, UPDATE_MUSIC, REMOVE_MUSIC,
        ADD_CAPTION, UPDATE_CAPTION, REMOVE_CAPTION, SET_CAPTION_STYLE, SET_CANVAS)

    /** Allowed keys per `type`; `type` itself is added by the host encoder. */
    val FIELDS: Map<String, Set<String>> = mapOf(
        APPEND_CLIP to setOf("clip"),
        UPDATE_CLIP to setOf(
            "id", "trimStart", "trimEnd", "speed", "volume", "isMuted",
            "rotationDegrees", "crop", "leadingTransition", "transitionDuration"),
        REORDER_CLIPS to setOf("orderedIDs"),
        SPLIT_CLIP to setOf("id", "atTimelineSeconds"),
        DUPLICATE_CLIP to setOf("id"),
        REMOVE_CLIP to setOf("id"),
        SET_PRIMARY_AUDIO to setOf("volume", "muted"),
        SET_COVER to setOf("time"),
        SHIFT_CAPTIONS to setOf("bySeconds"),
        ADD_MUSIC to setOf("music"),
        UPDATE_MUSIC to setOf(
            "id", "offsetSeconds", "trimStart", "lengthSeconds", "volume",
            "fadeInSeconds", "fadeOutSeconds"),
        REMOVE_MUSIC to setOf("id"),
        ADD_CAPTION to setOf("caption"),
        UPDATE_CAPTION to setOf("id", "start", "end", "text"),
        REMOVE_CAPTION to setOf("id"),
        SET_CAPTION_STYLE to setOf("style"),
        SET_CANVAS to setOf("width", "height", "frameRate"),
    )
}

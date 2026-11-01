// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

/**
 * Typed read projection of the shared Swift `VideoTimeline`
 * (`FloeAndroidWorkbench/MediaProjectModel.swift`).
 *
 * Field names and value types mirror that model exactly; this is a projection,
 * not a second project store. R1 keeps `MediaProject.videoTimeline` opaque, and
 * an R2 write still commands the native transaction engine instead of
 * rewriting the whole project JSON from Kotlin. Unknown timeline subtrees are
 * therefore preserved by the native model.
 *
 * IDs are UUID strings on the wire. Times are seconds. `crop` is normalized
 * to the unit square.
 */
enum class VideoTransitionKind(val wire: String) {
    NONE("none"),
    CROSS_DISSOLVE("crossDissolve"),
}

enum class CaptionSource(val wire: String) {
    MANUAL("manual"),
    TRANSCRIPTION("transcription"),
}

enum class CaptionAlignment(val wire: String) {
    LEADING("leading"),
    CENTER("center"),
    TRAILING("trailing"),
}

data class VideoClip(
    val id: String,
    val assetID: String,
    /** Source range in seconds within the asset. */
    val trimStart: Double,
    val trimEnd: Double,
    /** 0.1...16 in the shared engine. */
    val speed: Double = 1.0,
    /** Per-clip volume 0...4. */
    val volume: Double = 1.0,
    val isMuted: Boolean = false,
    /** 0/90/180/270 (negative equivalents accepted by the shared engine). */
    val rotationDegrees: Double = 0.0,
    val crop: NormalizedRect? = null,
    val leadingTransition: VideoTransitionKind = VideoTransitionKind.NONE,
    val transitionDuration: Double = 0.4,
)

data class MusicClip(
    val id: String,
    val assetID: String,
    val offsetSeconds: Double,
    val trimStart: Double,
    val lengthSeconds: Double,
    val volume: Double = 1.0,
    val fadeInSeconds: Double = 0.0,
    val fadeOutSeconds: Double = 0.0,
)

data class CaptionSegment(
    val id: String,
    /** Timeline seconds, already retimed for clip speed. */
    val start: Double,
    val end: Double,
    val text: String,
    val source: CaptionSource = CaptionSource.MANUAL,
)

data class CaptionStyle(
    val fontSize: Double = 36.0,
    val colorHex: String = "#FFFFFF",
    val backgroundHex: String? = "#000000",
    /** Vertical center position, normalized 0...1. */
    val positionY: Double = 0.88,
    val alignment: CaptionAlignment? = null,
    val respectsSafeArea: Boolean? = null,
)

/**
 * Exact typed shape of the Swift `VideoTimeline`. `coverTime` is an explicit
 * user choice (nil derives the first visual frame). `primaryVolume`/
 * `primaryMuted` govern the clips' original audio; music is mixed alongside.
 *
 * R2 subtitle scope: manual add/update/remove, shift, style and local burn-in
 * are supported through the existing transaction engine. Cloud transcription
 * is a documented follow-up gap (no ASR source yet); there is no Whisper or
 * local model path. A `transcription` caption source is preserved when it
 * exists, never invented.
 */
data class VideoTimeline(
    val clips: List<VideoClip> = emptyList(),
    val music: List<MusicClip> = emptyList(),
    val captions: List<CaptionSegment> = emptyList(),
    val captionStyle: CaptionStyle = CaptionStyle(),
    val coverTime: Double? = null,
    val primaryVolume: Double = 1.0,
    val primaryMuted: Boolean = false,
)

/**
 * Frozen JSON field names from the ACTUAL Swift Codable model. Do not derive
 * these from a discovery proposal; the native decoder/encoder is the authority
 * and unknown subtrees are preserved natively.
 */
object VideoTimelineWire {
    const val CLIPS = "clips"
    const val MUSIC = "music"
    const val CAPTIONS = "captions"
    const val CAPTION_STYLE = "captionStyle"
    const val COVER_TIME = "coverTime"
    const val PRIMARY_VOLUME = "primaryVolume"
    const val PRIMARY_MUTED = "primaryMuted"

    const val CLIP_ID = "id"
    const val CLIP_ASSET_ID = "assetID"
    const val CLIP_TRIM_START = "trimStart"
    const val CLIP_TRIM_END = "trimEnd"
    const val CLIP_SPEED = "speed"
    const val CLIP_VOLUME = "volume"
    const val CLIP_IS_MUTED = "isMuted"
    const val CLIP_ROTATION_DEGREES = "rotationDegrees"
    const val CLIP_CROP = "crop"
    const val CLIP_LEADING_TRANSITION = "leadingTransition"
    const val CLIP_TRANSITION_DURATION = "transitionDuration"

    const val MUSIC_ID = "id"
    const val MUSIC_ASSET_ID = "assetID"
    const val MUSIC_OFFSET_SECONDS = "offsetSeconds"
    const val MUSIC_TRIM_START = "trimStart"
    const val MUSIC_LENGTH_SECONDS = "lengthSeconds"
    const val MUSIC_VOLUME = "volume"
    const val MUSIC_FADE_IN_SECONDS = "fadeInSeconds"
    const val MUSIC_FADE_OUT_SECONDS = "fadeOutSeconds"

    const val CAPTION_ID = "id"
    const val CAPTION_START = "start"
    const val CAPTION_END = "end"
    const val CAPTION_TEXT = "text"
    const val CAPTION_SOURCE = "source"

    const val CAPTION_STYLE_FONT_SIZE = "fontSize"
    const val CAPTION_STYLE_COLOR_HEX = "colorHex"
    const val CAPTION_STYLE_BACKGROUND_HEX = "backgroundHex"
    const val CAPTION_STYLE_POSITION_Y = "positionY"
    const val CAPTION_STYLE_ALIGNMENT = "alignment"
    const val CAPTION_STYLE_RESPECTS_SAFE_AREA = "respectsSafeArea"

    val TIMELINE_KEYS: List<String> = listOf(
        CLIPS, MUSIC, CAPTIONS, CAPTION_STYLE, COVER_TIME, PRIMARY_VOLUME, PRIMARY_MUTED)
    val CLIP_KEYS: List<String> = listOf(
        CLIP_ID, CLIP_ASSET_ID, CLIP_TRIM_START, CLIP_TRIM_END, CLIP_SPEED, CLIP_VOLUME,
        CLIP_IS_MUTED, CLIP_ROTATION_DEGREES, CLIP_CROP, CLIP_LEADING_TRANSITION,
        CLIP_TRANSITION_DURATION)
    val MUSIC_KEYS: List<String> = listOf(
        MUSIC_ID, MUSIC_ASSET_ID, MUSIC_OFFSET_SECONDS, MUSIC_TRIM_START,
        MUSIC_LENGTH_SECONDS, MUSIC_VOLUME, MUSIC_FADE_IN_SECONDS, MUSIC_FADE_OUT_SECONDS)
    val CAPTION_KEYS: List<String> = listOf(
        CAPTION_ID, CAPTION_START, CAPTION_END, CAPTION_TEXT, CAPTION_SOURCE)
    val CAPTION_STYLE_KEYS: List<String> = listOf(
        CAPTION_STYLE_FONT_SIZE, CAPTION_STYLE_COLOR_HEX, CAPTION_STYLE_BACKGROUND_HEX,
        CAPTION_STYLE_POSITION_Y, CAPTION_STYLE_ALIGNMENT, CAPTION_STYLE_RESPECTS_SAFE_AREA)
}

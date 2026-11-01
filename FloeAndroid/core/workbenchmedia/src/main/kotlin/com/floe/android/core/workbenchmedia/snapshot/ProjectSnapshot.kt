// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.snapshot

import com.floe.android.feature.workbench.CaptionAlignment
import com.floe.android.feature.workbench.CaptionSegment
import com.floe.android.feature.workbench.CaptionSource
import com.floe.android.feature.workbench.CaptionStyle
import com.floe.android.feature.workbench.ImageFreehandContent
import com.floe.android.feature.workbench.ImageFreehandPoint
import com.floe.android.feature.workbench.ImageFreehandStroke
import com.floe.android.feature.workbench.ImageLayer
import com.floe.android.feature.workbench.ImageLayerAdjustment
import com.floe.android.feature.workbench.ImageLayerTransform
import com.floe.android.feature.workbench.ImageTextContent
import com.floe.android.feature.workbench.ImageTextShadow
import com.floe.android.feature.workbench.MediaAssetMetadata
import com.floe.android.feature.workbench.MediaAssetReference
import com.floe.android.feature.workbench.MediaCanvas
import com.floe.android.feature.workbench.MediaProject
import com.floe.android.feature.workbench.MusicClip
import com.floe.android.feature.workbench.NormalizedRect
import com.floe.android.feature.workbench.VideoClip
import com.floe.android.feature.workbench.VideoTimeline
import com.floe.android.feature.workbench.VideoTransitionKind
import com.floe.android.core.workbenchmedia.util.UNSUPPORTED_SOURCE_FORMAT
import com.floe.android.core.workbenchmedia.util.refusal
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Read-only projection of one verified media schema-1 snapshot. It reuses the
 * frozen R1 DTOs (`MediaProject`, `ImageLayer`, `VideoTimeline`); it is NOT a
 * second canonical project model and it never writes JSON.
 *
 * Unknown top-level project keys are forward-compatible and ignored, but any
 * unknown ACTIVE layer/adjustment/mask/text key is reported so the renderer
 * can refuse instead of silently dropping an effect.
 */
internal data class ProjectedLayer(
    val layer: ImageLayer,
    val unknownLayerKeys: Set<String>,
    val unknownAdjustmentKeys: Set<String>,
    val unknownTextKeys: Set<String>,
    val unknownFreehandKeys: Set<String>,
    val unknownMaskKeys: Set<String>,
    val unknownSelectionKeys: Set<String>,
)

internal data class SnapshotProjection(
    val project: MediaProject,
    val timeline: VideoTimeline,
    val layers: List<ProjectedLayer>,
    val unknownCanvasAdjustmentKeys: Set<String>,
    val canonicalJson: String,
)

internal object ProjectSnapshotParser {
    private val LAYER_KEYS = setOf(
        "id", "kind", "name", "assetID", "transform", "opacity", "isHidden", "isLocked",
        "text", "freehand", "crop", "mask", "selectionMask", "fillColorHex", "adjustment",
    )
    private val TRANSFORM_KEYS = setOf("centerX", "centerY", "scale", "rotationDegrees", "flipX", "flipY")
    private val TEXT_KEYS = setOf(
        "text", "fontSize", "colorHex", "fontName", "tracking", "leading", "alignment",
        "strokeColorHex", "strokeWidth", "shadow",
    )
    private val SHADOW_KEYS = setOf("colorHex", "blur", "offsetX", "offsetY")
    private val FREEHAND_KEYS = setOf("strokes")
    private val STROKE_KEYS = setOf("points", "width", "colorHex", "hardness", "opacity")
    private val POINT_KEYS = setOf("x", "y", "pressure")
    private val MASK_KEYS = setOf("strokes")
    private val MASK_STROKE_KEYS = setOf("points", "width", "hardness", "restore", "region")
    private val SELECTION_KEYS = setOf("shapes", "feather", "inverted")
    private val SELECTION_SHAPE_KEYS = setOf("kind", "operation", "points")
    private val ADJUSTMENT_KEYS = setOf(
        "saturation", "contrast", "brightness", "exposureEV", "blurRadius", "sharpenRadius",
        "temperature", "hueDegrees", "levels", "mosaicBlockSize", "filterID",
    )
    private val LEVELS_KEYS = setOf("black", "white", "gamma")
    private val ASSET_KEYS = setOf(
        "id", "kind", "relativePath", "originalName", "byteCount", "contentHash", "metadata",
    )
    private val METADATA_KEYS = setOf(
        "width", "height", "durationSeconds", "frameRate", "audioTracks", "rotationDegrees", "hasAlpha",
    )
    private val CANVAS_KEYS = setOf("width", "height", "frameRate")
    private val CLIP_KEYS = setOf(
        "id", "assetID", "trimStart", "trimEnd", "speed", "volume", "isMuted", "rotationDegrees",
        "crop", "leadingTransition", "transitionDuration",
    )
    private val MUSIC_KEYS = setOf(
        "id", "assetID", "offsetSeconds", "trimStart", "lengthSeconds", "volume",
        "fadeInSeconds", "fadeOutSeconds",
    )
    private val CAPTION_KEYS = setOf("id", "start", "end", "text", "source")
    private val CAPTION_STYLE_KEYS = setOf(
        "fontSize", "colorHex", "backgroundHex", "positionY", "alignment", "respectsSafeArea",
    )
    private val TIMELINE_KEYS = setOf(
        "clips", "music", "captions", "captionStyle", "coverTime", "primaryVolume", "primaryMuted",
    )

    fun parse(text: String): SnapshotProjection {
        val root = try {
            Json.parseToJsonElement(text)
        } catch (failure: Exception) {
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Snapshot is not valid JSON: ${failure.message}")
        }
        val obj = root as? JsonObject
            ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Snapshot root is not an object")
        val schema = obj.long("schemaVersion") ?: 1L
        if (schema != 1L) {
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Unsupported media snapshot schema $schema")
        }
        val id = obj.string("id") ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Snapshot has no project id")
        val kind = obj.string("kind") ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Snapshot has no project kind")
        if (kind != "image" && kind != "video") {
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Unsupported project kind $kind")
        }
        val revision = obj.long("revision")
            ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Snapshot has no revision")
        val canvasObj = obj.obj("canvas")
        val canvas = canvasObj?.let(::parseCanvas)
        val assets = obj.arr("assets").map { element ->
            parseAsset(element as? JsonObject
                ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Asset entry is not an object"))
        }
        val duplicate = assets.groupBy { it.id }.entries.firstOrNull { it.value.size > 1 }
        if (duplicate != null) {
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Duplicate asset id ${duplicate.key}")
        }
        val rawLayers = obj.arr("imageLayers")
        val layers = rawLayers.map { element ->
            parseLayer(element as? JsonObject
                ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Image layer entry is not an object"))
        }
        val canvasAdjustmentObj = obj.obj("canvasAdjustment")
        val canvasAdjustment = parseAdjustment(canvasAdjustmentObj)
        val timelineObj = obj.obj("videoTimeline")
        val timeline = parseTimeline(timelineObj)
        val project = MediaProject(
            id = id,
            schemaVersion = 1,
            kind = kind,
            name = obj.string("name") ?: "",
            createdAt = obj.string("createdAt") ?: "",
            updatedAt = obj.string("updatedAt") ?: "",
            revision = revision,
            canvas = canvas,
            assets = assets,
            sourceAssetID = obj.string("sourceAssetID"),
            imageLayers = layers.map { it.layer },
            canvasAdjustment = canvasAdjustment,
            videoTimeline = timelineObj,
            lastImageExport = obj.obj("lastImageExport"),
            lastVideoExport = obj.obj("lastVideoExport"),
            ownerKind = obj.string("ownerKind") ?: "standalone",
            ownerID = obj.string("ownerID"),
            environmentID = obj.string("environmentID"),
            taskWorkspacePath = obj.string("taskWorkspacePath"),
            unknownOperations = obj.arr("unknownOperations").mapNotNull { it as? JsonObject },
            recoveryWarnings = obj.arr("recoveryWarnings").mapNotNull { (it as? JsonPrimitive)?.content },
            canUndo = obj.bool("canUndo") ?: false,
            canRedo = obj.bool("canRedo") ?: false,
            parentProjectID = obj.string("parentProjectID"),
            imageSelection = obj.obj("imageSelection"),
        )
        return SnapshotProjection(
            project = project,
            timeline = timeline,
            layers = layers,
            unknownCanvasAdjustmentKeys = unknown(canvasAdjustmentObj, ADJUSTMENT_KEYS),
            canonicalJson = text,
        )
    }

    private fun parseCanvas(obj: JsonObject): MediaCanvas {
        val width = obj.int("width") ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Canvas has no width")
        val height = obj.int("height") ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Canvas has no height")
        return MediaCanvas(width, height, obj.double("frameRate"))
    }

    private fun parseAsset(obj: JsonObject): MediaAssetReference {
        unknown(obj, ASSET_KEYS).takeIf { it.isNotEmpty() }?.let {
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Unknown asset fields ${it.joinToString()}")
        }
        val id = obj.string("id") ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Asset has no id")
        val kind = obj.string("kind") ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Asset has no kind")
        val relative = obj.string("relativePath")
            ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Asset $id has no relativePath")
        val metadataObj = obj.obj("metadata")
        unknown(metadataObj, METADATA_KEYS).takeIf { it.isNotEmpty() }?.let {
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Unknown asset metadata fields ${it.joinToString()}")
        }
        val metadata = metadataObj?.let {
            MediaAssetMetadata(
                width = it.int("width"),
                height = it.int("height"),
                durationSeconds = it.double("durationSeconds"),
                frameRate = it.double("frameRate"),
                audioTracks = it.int("audioTracks"),
                rotationDegrees = it.double("rotationDegrees"),
                hasAlpha = it.bool("hasAlpha"),
            )
        }
        return MediaAssetReference(
            id = id,
            kind = kind,
            relativePath = relative,
            originalName = obj.string("originalName") ?: "",
            byteCount = obj.long("byteCount"),
            contentHash = obj.string("contentHash"),
            metadata = metadata,
        )
    }

    private fun parseLayer(obj: JsonObject): ProjectedLayer {
        val unknownLayer = unknown(obj, LAYER_KEYS)
        val id = obj.string("id") ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Layer has no id")
        val kind = obj.string("kind") ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Layer $id has no kind")
        val transformObj = obj.obj("transform")
        unknown(transformObj, TRANSFORM_KEYS).takeIf { it.isNotEmpty() }?.let {
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Unknown layer transform fields ${it.joinToString()}")
        }
        val transform = ImageLayerTransform(
            centerX = transformObj?.double("centerX") ?: 0.5,
            centerY = transformObj?.double("centerY") ?: 0.5,
            scale = transformObj?.double("scale") ?: 1.0,
            rotationDegrees = transformObj?.double("rotationDegrees") ?: 0.0,
            flipX = transformObj?.bool("flipX"),
            flipY = transformObj?.bool("flipY"),
        )
        val textObj = obj.obj("text")
        val unknownText = unknown(textObj, TEXT_KEYS)
        val text = textObj?.let(::parseText)
        val freehandObj = obj.obj("freehand")
        val unknownFreehand = unknown(freehandObj, FREEHAND_KEYS).let { outer ->
            var inner = emptySet<String>()
            freehandObj?.arr("strokes")?.forEach { element ->
                val stroke = element as? JsonObject ?: return@forEach
                inner = inner + unknown(stroke, STROKE_KEYS)
                stroke.arr("points").forEach { point ->
                    inner = inner + unknown(point as? JsonObject, POINT_KEYS)
                }
            }
            outer + inner
        }
        val freehand = freehandObj?.let(::parseFreehand)
        val maskObj = obj.obj("mask")
        val unknownMask = unknown(maskObj, MASK_KEYS) +
            (maskObj?.arr("strokes")?.flatMap { element -> unknown(element as? JsonObject, MASK_STROKE_KEYS) } ?: emptyList())
        val selectionObj = obj.obj("selectionMask")
        val unknownSelection = unknown(selectionObj, SELECTION_KEYS) +
            (selectionObj?.arr("shapes")?.flatMap { element ->
                unknown(element as? JsonObject, SELECTION_SHAPE_KEYS)
            } ?: emptyList())
        val adjustmentObj = obj.obj("adjustment")
        return ProjectedLayer(
            layer = ImageLayer(
                id = id,
                kind = kind,
                name = obj.string("name") ?: "",
                assetID = obj.string("assetID"),
                transform = transform,
                opacity = obj.double("opacity") ?: 1.0,
                isHidden = obj.bool("isHidden") ?: false,
                isLocked = obj.bool("isLocked") ?: false,
                text = text,
                freehand = freehand,
                crop = parseRect(obj.obj("crop")),
                mask = maskObj,
                selectionMask = selectionObj,
                fillColorHex = obj.string("fillColorHex"),
                adjustment = parseAdjustment(adjustmentObj),
            ),
            unknownLayerKeys = unknownLayer,
            unknownAdjustmentKeys = unknown(adjustmentObj, ADJUSTMENT_KEYS),
            unknownTextKeys = unknownText,
            unknownFreehandKeys = unknownFreehand,
            unknownMaskKeys = unknownMask,
            unknownSelectionKeys = unknownSelection,
        )
    }

    private fun parseText(obj: JsonObject): ImageTextContent {
        val shadowObj = obj.obj("shadow")
        unknown(shadowObj, SHADOW_KEYS).takeIf { it.isNotEmpty() }?.let {
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Unknown text shadow fields ${it.joinToString()}")
        }
        val shadow = shadowObj?.let {
            ImageTextShadow(
                colorHex = it.string("colorHex") ?: "#00000080",
                blur = it.double("blur") ?: 4.0,
                offsetX = it.double("offsetX") ?: 2.0,
                offsetY = it.double("offsetY") ?: 2.0,
            )
        }
        return ImageTextContent(
            text = obj.string("text") ?: "",
            fontSize = obj.double("fontSize") ?: 48.0,
            colorHex = obj.string("colorHex") ?: "#000000",
            fontName = obj.string("fontName"),
            tracking = obj.double("tracking"),
            leading = obj.double("leading"),
            alignment = obj.string("alignment"),
            strokeColorHex = obj.string("strokeColorHex"),
            strokeWidth = obj.double("strokeWidth"),
            shadow = shadow,
        )
    }

    private fun parseFreehand(obj: JsonObject): ImageFreehandContent = ImageFreehandContent(
        strokes = obj.arr("strokes").map { element ->
            val stroke = element as? JsonObject
                ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Freehand stroke is not an object")
            ImageFreehandStroke(
                points = stroke.arr("points").map { pointElement ->
                    val point = pointElement as? JsonObject
                        ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Freehand point is not an object")
                    ImageFreehandPoint(
                        x = point.double("x") ?: 0.0,
                        y = point.double("y") ?: 0.0,
                        pressure = point.double("pressure"),
                    )
                },
                width = stroke.double("width") ?: 4.0,
                colorHex = stroke.string("colorHex") ?: "#000000",
                hardness = stroke.double("hardness"),
                opacity = stroke.double("opacity"),
            )
        },
    )

    private fun parseAdjustment(obj: JsonObject?): ImageLayerAdjustment {
        if (obj == null) return ImageLayerAdjustment()
        val levels = obj.obj("levels")
        unknown(levels, LEVELS_KEYS).takeIf { it.isNotEmpty() }?.let {
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Unknown levels fields ${it.joinToString()}")
        }
        if (levels != null) {
            levels.double("black") ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Levels has no black")
            levels.double("white") ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Levels has no white")
        }
        return ImageLayerAdjustment(
            saturation = obj.double("saturation"),
            contrast = obj.double("contrast"),
            brightness = obj.double("brightness"),
            exposureEV = obj.double("exposureEV"),
            blurRadius = obj.double("blurRadius"),
            sharpenRadius = obj.double("sharpenRadius"),
            temperature = obj.double("temperature"),
            hueDegrees = obj.double("hueDegrees"),
            levels = levels,
            mosaicBlockSize = obj.int("mosaicBlockSize"),
            filterID = obj.string("filterID"),
        )
    }

    private fun parseTimeline(obj: JsonObject?): VideoTimeline {
        if (obj == null) return VideoTimeline()
        unknown(obj, TIMELINE_KEYS).takeIf { it.isNotEmpty() }?.let {
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Unknown video timeline fields ${it.joinToString()}")
        }
        val clips = obj.arr("clips").map { element ->
            val clip = element as? JsonObject
                ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Video clip is not an object")
            unknown(clip, CLIP_KEYS).takeIf { it.isNotEmpty() }?.let {
                throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Unknown clip fields ${it.joinToString()}")
            }
            VideoClip(
                id = clip.string("id") ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Clip has no id"),
                assetID = clip.string("assetID")
                    ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Clip has no assetID"),
                trimStart = clip.double("trimStart") ?: 0.0,
                trimEnd = clip.double("trimEnd") ?: 0.0,
                speed = clip.double("speed") ?: 1.0,
                volume = clip.double("volume") ?: 1.0,
                isMuted = clip.bool("isMuted") ?: false,
                rotationDegrees = clip.double("rotationDegrees") ?: 0.0,
                crop = parseRect(clip.obj("crop")),
                leadingTransition = when (clip.string("leadingTransition") ?: "none") {
                    "none" -> VideoTransitionKind.NONE
                    "crossDissolve" -> VideoTransitionKind.CROSS_DISSOLVE
                    else -> throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Unknown transition")
                },
                transitionDuration = clip.double("transitionDuration") ?: 0.4,
            )
        }
        val music = obj.arr("music").map { element ->
            val item = element as? JsonObject
                ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Music entry is not an object")
            unknown(item, MUSIC_KEYS).takeIf { it.isNotEmpty() }?.let {
                throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Unknown music fields ${it.joinToString()}")
            }
            MusicClip(
                id = item.string("id") ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Music has no id"),
                assetID = item.string("assetID")
                    ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Music has no assetID"),
                offsetSeconds = item.double("offsetSeconds") ?: 0.0,
                trimStart = item.double("trimStart") ?: 0.0,
                lengthSeconds = item.double("lengthSeconds") ?: 0.0,
                volume = item.double("volume") ?: 1.0,
                fadeInSeconds = item.double("fadeInSeconds") ?: 0.0,
                fadeOutSeconds = item.double("fadeOutSeconds") ?: 0.0,
            )
        }
        val captions = obj.arr("captions").map { element ->
            val item = element as? JsonObject
                ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Caption is not an object")
            unknown(item, CAPTION_KEYS).takeIf { it.isNotEmpty() }?.let {
                throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Unknown caption fields ${it.joinToString()}")
            }
            CaptionSegment(
                id = item.string("id") ?: throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Caption has no id"),
                start = item.double("start") ?: 0.0,
                end = item.double("end") ?: 0.0,
                text = item.string("text") ?: "",
                source = when (item.string("source") ?: "manual") {
                    "manual" -> CaptionSource.MANUAL
                    "transcription" -> CaptionSource.TRANSCRIPTION
                    else -> throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Unknown caption source")
                },
            )
        }
        val styleObj = obj.obj("captionStyle")
        unknown(styleObj, CAPTION_STYLE_KEYS).takeIf { it.isNotEmpty() }?.let {
            throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Unknown caption style fields ${it.joinToString()}")
        }
        val style = CaptionStyle(
            fontSize = styleObj?.double("fontSize") ?: 36.0,
            colorHex = styleObj?.string("colorHex") ?: "#FFFFFF",
            backgroundHex = styleObj?.string("backgroundHex") ?: "#000000",
            positionY = styleObj?.double("positionY") ?: 0.88,
            alignment = when (styleObj?.string("alignment")) {
                null -> null
                "leading" -> CaptionAlignment.LEADING
                "center" -> CaptionAlignment.CENTER
                "trailing" -> CaptionAlignment.TRAILING
                else -> throw refusal(UNSUPPORTED_SOURCE_FORMAT, "Unknown caption alignment")
            },
            respectsSafeArea = styleObj?.bool("respectsSafeArea"),
        )
        return VideoTimeline(
            clips = clips,
            music = music,
            captions = captions,
            captionStyle = style,
            coverTime = obj.double("coverTime"),
            primaryVolume = obj.double("primaryVolume") ?: 1.0,
            primaryMuted = obj.bool("primaryMuted") ?: false,
        )
    }

    private fun parseRect(obj: JsonObject?): NormalizedRect? {
        if (obj == null) return null
        return NormalizedRect(
            x = obj.double("x") ?: 0.0,
            y = obj.double("y") ?: 0.0,
            width = obj.double("width") ?: 1.0,
            height = obj.double("height") ?: 1.0,
        )
    }

    private fun unknown(obj: JsonObject?, known: Set<String>): Set<String> =
        obj?.keys?.filterNot { it in known }?.toSet() ?: emptySet()

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonObject.double(key: String): Double? =
        (this[key] as? JsonPrimitive)?.content?.toDoubleOrNull()

    private fun JsonObject.int(key: String): Int? =
        (this[key] as? JsonPrimitive)?.content?.toIntOrNull()

    private fun JsonObject.long(key: String): Long? =
        (this[key] as? JsonPrimitive)?.content?.toLongOrNull()

    private fun JsonObject.bool(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.content?.toBooleanStrictOrNull()

    private fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject

    private fun JsonObject.arr(key: String): List<JsonElement> =
        (this[key] as? JsonArray)?.toList() ?: emptyList()
}

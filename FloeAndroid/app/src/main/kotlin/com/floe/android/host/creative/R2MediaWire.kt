// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.workbench.CaptionAlignment
import com.floe.android.feature.workbench.CaptionSegment
import com.floe.android.feature.workbench.CaptionSource
import com.floe.android.feature.workbench.CaptionStyle
import com.floe.android.feature.workbench.ClaimedRenderTicket
import com.floe.android.feature.workbench.CreativeProjectContext
import com.floe.android.feature.workbench.ExportVerification
import com.floe.android.feature.workbench.ImageExportSettings
import com.floe.android.feature.workbench.LargeImportJobHandle
import com.floe.android.feature.workbench.LargeImportRequest
import com.floe.android.feature.workbench.LargeImportState
import com.floe.android.feature.workbench.LargeImportStatus
import com.floe.android.feature.workbench.MediaExportKind
import com.floe.android.feature.workbench.MediaExportReceipt
import com.floe.android.feature.workbench.MediaExportReceiptBinding
import com.floe.android.feature.workbench.MusicClip
import com.floe.android.feature.workbench.NormalizedRect
import com.floe.android.feature.workbench.OptionalUpdate
import com.floe.android.feature.workbench.PreviewWindow
import com.floe.android.feature.workbench.RenderSnapshotLease
import com.floe.android.feature.workbench.RenderTicketDescriptor
import com.floe.android.feature.workbench.RenderTicketReply
import com.floe.android.feature.workbench.RenderTicketReplyStatus
import com.floe.android.feature.workbench.RenderTicketStats
import com.floe.android.feature.workbench.StagedImportMetadata
import com.floe.android.feature.workbench.VideoClip
import com.floe.android.feature.workbench.VideoEditCommand
import com.floe.android.feature.workbench.VideoExportSettings
import com.floe.android.feature.workbench.VideoTimeline
import com.floe.android.feature.workbench.VideoTransitionKind
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * Exact `floe.creative/6` wire projection for the App host foundation.
 *
 * Hand-written on purpose: the frozen contract modules stay dependency-free
 * and the native Codable model is the authority. Video writes only carry the
 * closed command vocabulary; Kotlin never writes a whole project JSON.
 */
internal object R2MediaWire {
    const val VERSION = 6
    const val SCHEMA = "floe.creative/6"

    private val json = Json { isLenient = false; ignoreUnknownKeys = true }
    private val iso: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC)

    fun isoNow(): String = iso.format(Instant.now())

    // MARK: - Envelope

    fun request(
        operation: String,
        requestID: String,
        epoch: Long? = null,
        action: String? = null,
        payload: JsonObject? = null,
    ): JsonObject = buildJsonObject {
        put("version", VERSION)
        put("operation", operation)
        put("requestID", requestID)
        if (epoch != null) put("epoch", epoch)
        if (action != null) put("action", action)
        if (payload != null) put("payload", payload)
    }

    fun response(raw: String): JsonObject {
        val objectValue = try {
            json.parseToJsonElement(raw) as? JsonObject
        } catch (_: Throwable) {
            null
        } ?: throw CreativeException("invalidCoreResponse", "malformedJSON")
        val version = objectValue.long("version")?.toInt() ?: 0
        if (version != VERSION) {
            val error = objectValue.string("error")
            if (version < VERSION || error == "unsupportedVersion") {
                throw CreativeException(
                    "needsCoreUpdate", "creativeBridgeV6Unsupported", retryable = false)
            }
            if (version > VERSION) {
                throw CreativeException(
                    "coreTooNew", "creativeBridgeVersionUnsupported", retryable = false)
            }
            throw CreativeException("invalidCoreResponse", "missingVersion")
        }
        if (objectValue.string("schema") != SCHEMA &&
            objectValue.bool("ok") != true) {
            throw CreativeException("invalidCoreResponse", "schemaMismatch")
        }
        if (objectValue.bool("ok") != true) {
            throw CreativeException(
                code = objectValue.string("error") ?: "unknownError",
                reason = objectValue.string("reason"),
                retryable = objectValue.bool("retryable") ?: false,
            )
        }
        return objectValue
    }

    // MARK: - Context

    fun encodeContext(context: CreativeProjectContext): JsonObject = buildJsonObject {
        put("projectID", context.projectID)
        put("sessionToken", context.sessionToken)
        put("storage", encodeStorage(context.storage))
        context.origin?.let { put("origin", encodeOrigin(it)) }
    }

    fun encodeStorage(storage: CreativeStorageLayer): JsonObject = buildJsonObject {
        when (storage) {
            CreativeStorageLayer.AppOwned -> put("kind", "appOwned")
            is CreativeStorageLayer.Workspace -> {
                put("kind", "workspace")
                put("workspaceID", storage.workspaceID)
            }
        }
    }

    fun decodeStorage(element: JsonElement?): CreativeStorageLayer {
        val value = element as? JsonObject
            ?: return CreativeStorageLayer.AppOwned
        return when (value.string("kind")) {
            "workspace" -> CreativeStorageLayer.Workspace(
                value.string("workspaceID")
                    ?: throw CreativeException("invalidResponse", "missingWorkspaceID"))
            else -> CreativeStorageLayer.AppOwned
        }
    }

    fun encodeOrigin(origin: CreativeOriginContext): JsonObject = buildJsonObject {
        put("kind", origin.kind)
        origin.ownerID?.let { put("ownerID", it) }
        origin.environmentID?.let { put("environmentID", it) }
    }

    fun decodeOrigin(element: JsonElement?): CreativeOriginContext? {
        val value = element as? JsonObject ?: return null
        return CreativeOriginContext(
            kind = value.string("kind") ?: return null,
            ownerID = value.string("ownerID"),
            environmentID = value.string("environmentID"))
    }

    // MARK: - Video commands

    fun encodeVideoCommand(command: VideoEditCommand): JsonObject = when (command) {
        is VideoEditCommand.AppendClip -> buildJsonObject {
            put("type", command.wireType())
            put("clip", encodeClip(command.clip))
        }
        is VideoEditCommand.UpdateClip -> buildJsonObject {
            put("type", command.wireType())
            put("id", command.id)
            command.trimStart?.let { put("trimStart", it) }
            command.trimEnd?.let { put("trimEnd", it) }
            command.speed?.let { put("speed", it) }
            command.volume?.let { put("volume", it) }
            command.isMuted?.let { put("isMuted", it) }
            command.rotationDegrees?.let { put("rotationDegrees", it) }
            put("crop", encodeCrop(command.crop))
            command.leadingTransition?.let { put("leadingTransition", it.wire) }
            command.transitionDuration?.let { put("transitionDuration", it) }
        }
        is VideoEditCommand.ReorderClips -> buildJsonObject {
            put("type", command.wireType())
            putJsonArray("orderedIDs") { command.orderedIDs.forEach { add(JsonPrimitive(it)) } }
        }
        is VideoEditCommand.SplitClip -> buildJsonObject {
            put("type", command.wireType())
            put("id", command.id)
            put("atTimelineSeconds", command.atTimelineSeconds)
        }
        is VideoEditCommand.DuplicateClip -> buildJsonObject {
            put("type", command.wireType())
            put("id", command.id)
        }
        is VideoEditCommand.RemoveClip -> buildJsonObject {
            put("type", command.wireType())
            put("id", command.id)
        }
        is VideoEditCommand.SetPrimaryAudio -> buildJsonObject {
            put("type", command.wireType())
            command.volume?.let { put("volume", it) }
            command.muted?.let { put("muted", it) }
        }
        is VideoEditCommand.SetCover -> buildJsonObject {
            put("type", command.wireType())
            put("time", command.time)
        }
        is VideoEditCommand.ShiftCaptions -> buildJsonObject {
            put("type", command.wireType())
            put("bySeconds", command.bySeconds)
        }
        is VideoEditCommand.AddMusic -> buildJsonObject {
            put("type", command.wireType())
            put("music", encodeMusic(command.music))
        }
        is VideoEditCommand.UpdateMusic -> buildJsonObject {
            put("type", command.wireType())
            put("id", command.id)
            command.offsetSeconds?.let { put("offsetSeconds", it) }
            command.trimStart?.let { put("trimStart", it) }
            command.lengthSeconds?.let { put("lengthSeconds", it) }
            command.volume?.let { put("volume", it) }
            command.fadeInSeconds?.let { put("fadeInSeconds", it) }
            command.fadeOutSeconds?.let { put("fadeOutSeconds", it) }
        }
        is VideoEditCommand.RemoveMusic -> buildJsonObject {
            put("type", command.wireType())
            put("id", command.id)
        }
        is VideoEditCommand.AddCaption -> buildJsonObject {
            put("type", command.wireType())
            put("caption", encodeCaption(command.caption))
        }
        is VideoEditCommand.UpdateCaption -> buildJsonObject {
            put("type", command.wireType())
            put("id", command.id)
            command.start?.let { put("start", it) }
            command.end?.let { put("end", it) }
            command.text?.let { put("text", it) }
        }
        is VideoEditCommand.RemoveCaption -> buildJsonObject {
            put("type", command.wireType())
            put("id", command.id)
        }
        is VideoEditCommand.SetCaptionStyle -> buildJsonObject {
            put("type", command.wireType())
            put("style", encodeCaptionStyle(command.style))
        }
        is VideoEditCommand.SetCanvas -> buildJsonObject {
            put("type", command.wireType())
            put("width", command.width)
            put("height", command.height)
            command.frameRate?.let { put("frameRate", it) }
        }
    }

    private fun encodeCrop(crop: OptionalUpdate<NormalizedRect>): JsonObject =
        when (crop) {
            OptionalUpdate.Unchanged -> buildJsonObject { put("state", "unchanged") }
            OptionalUpdate.Clear -> buildJsonObject { put("state", "clear") }
            is OptionalUpdate.Set -> buildJsonObject {
                put("state", "set")
                put("value", buildJsonObject {
                    put("x", crop.value.x)
                    put("y", crop.value.y)
                    put("width", crop.value.width)
                    put("height", crop.value.height)
                })
            }
        }

    fun encodeClip(clip: VideoClip): JsonObject = buildJsonObject {
        put("id", clip.id)
        put("assetID", clip.assetID)
        put("trimStart", clip.trimStart)
        put("trimEnd", clip.trimEnd)
        put("speed", clip.speed)
        put("volume", clip.volume)
        put("isMuted", clip.isMuted)
        put("rotationDegrees", clip.rotationDegrees)
        clip.crop?.let {
            put("crop", buildJsonObject {
                put("x", it.x); put("y", it.y)
                put("width", it.width); put("height", it.height)
            })
        }
        put("leadingTransition", clip.leadingTransition.wire)
        put("transitionDuration", clip.transitionDuration)
    }

    fun encodeMusic(music: MusicClip): JsonObject = buildJsonObject {
        put("id", music.id)
        put("assetID", music.assetID)
        put("offsetSeconds", music.offsetSeconds)
        put("trimStart", music.trimStart)
        put("lengthSeconds", music.lengthSeconds)
        put("volume", music.volume)
        put("fadeInSeconds", music.fadeInSeconds)
        put("fadeOutSeconds", music.fadeOutSeconds)
    }

    fun encodeCaption(caption: CaptionSegment): JsonObject = buildJsonObject {
        put("id", caption.id)
        put("start", caption.start)
        put("end", caption.end)
        put("text", caption.text)
        put("source", caption.source.wire)
    }

    fun encodeCaptionStyle(style: CaptionStyle): JsonObject = buildJsonObject {
        put("fontSize", style.fontSize)
        put("colorHex", style.colorHex)
        put("backgroundHex", style.backgroundHex)
        put("positionY", style.positionY)
        put("alignment", style.alignment?.wire)
        put("respectsSafeArea", style.respectsSafeArea)
    }

    // MARK: - Video timeline decode

    fun decodeTimeline(value: JsonObject?): VideoTimeline {
        if (value == null) return VideoTimeline()
        return VideoTimeline(
            clips = value.array("clips")?.mapNotNull { element ->
                (element as? JsonObject)?.let(::decodeClip)
            }.orEmpty(),
            music = value.array("music")?.mapNotNull { element ->
                (element as? JsonObject)?.let(::decodeMusic)
            }.orEmpty(),
            captions = value.array("captions")?.mapNotNull { element ->
                (element as? JsonObject)?.let(::decodeCaption)
            }.orEmpty(),
            captionStyle = (value["captionStyle"] as? JsonObject)
                ?.let(::decodeCaptionStyle) ?: CaptionStyle(),
            coverTime = value.double("coverTime"),
            primaryVolume = value.double("primaryVolume") ?: 1.0,
            primaryMuted = value.bool("primaryMuted") ?: false,
        )
    }

    private fun decodeClip(value: JsonObject): VideoClip = VideoClip(
        id = value.string("id") ?: throw CreativeException("invalidResponse", "clipID"),
        assetID = value.string("assetID")
            ?: throw CreativeException("invalidResponse", "clipAssetID"),
        trimStart = value.double("trimStart") ?: 0.0,
        trimEnd = value.double("trimEnd") ?: 0.0,
        speed = value.double("speed") ?: 1.0,
        volume = value.double("volume") ?: 1.0,
        isMuted = value.bool("isMuted") ?: false,
        rotationDegrees = value.double("rotationDegrees") ?: 0.0,
        crop = (value["crop"] as? JsonObject)?.let {
            NormalizedRect(
                x = it.double("x") ?: 0.0, y = it.double("y") ?: 0.0,
                width = it.double("width") ?: 1.0,
                height = it.double("height") ?: 1.0)
        },
        leadingTransition = when (value.string("leadingTransition")) {
            "crossDissolve" -> VideoTransitionKind.CROSS_DISSOLVE
            else -> VideoTransitionKind.NONE
        },
        transitionDuration = value.double("transitionDuration") ?: 0.4,
    )

    private fun decodeMusic(value: JsonObject): MusicClip = MusicClip(
        id = value.string("id") ?: throw CreativeException("invalidResponse", "musicID"),
        assetID = value.string("assetID")
            ?: throw CreativeException("invalidResponse", "musicAssetID"),
        offsetSeconds = value.double("offsetSeconds") ?: 0.0,
        trimStart = value.double("trimStart") ?: 0.0,
        lengthSeconds = value.double("lengthSeconds") ?: 0.0,
        volume = value.double("volume") ?: 1.0,
        fadeInSeconds = value.double("fadeInSeconds") ?: 0.0,
        fadeOutSeconds = value.double("fadeOutSeconds") ?: 0.0,
    )

    private fun decodeCaption(value: JsonObject): CaptionSegment = CaptionSegment(
        id = value.string("id") ?: throw CreativeException("invalidResponse", "captionID"),
        start = value.double("start") ?: 0.0,
        end = value.double("end") ?: 0.0,
        text = value.string("text").orEmpty(),
        source = when (value.string("source")) {
            "transcription" -> CaptionSource.TRANSCRIPTION
            else -> CaptionSource.MANUAL
        },
    )

    private fun decodeCaptionStyle(value: JsonObject): CaptionStyle = CaptionStyle(
        fontSize = value.double("fontSize") ?: 36.0,
        colorHex = value.string("colorHex") ?: "#FFFFFF",
        backgroundHex = value.string("backgroundHex"),
        positionY = value.double("positionY") ?: 0.88,
        alignment = when (value.string("alignment")) {
            "leading" -> CaptionAlignment.LEADING
            "center" -> CaptionAlignment.CENTER
            "trailing" -> CaptionAlignment.TRAILING
            else -> null
        },
        respectsSafeArea = value.bool("respectsSafeArea"),
    )

    // MARK: - Render ticket transport

    fun decodeDescriptor(value: JsonObject): RenderTicketDescriptor = RenderTicketDescriptor(
        ticketID = value.string("ticketID")
            ?: throw CreativeException("invalidResponse", "missingTicketID"),
        descriptorVersion = value.int("descriptorVersion") ?: 0,
        kind = decodeKind(value.string("kind")),
        projectID = value.string("projectID")
            ?: throw CreativeException("invalidResponse", "missingProjectID"),
        attemptID = value.string("attemptID")
            ?: throw CreativeException("invalidResponse", "missingAttemptID"),
        mediaRootPath = value.string("mediaRootPath")
            ?: throw CreativeException("invalidResponse", "missingMediaRoot"),
        storage = decodeStorage(value["storage"]),
        origin = decodeOrigin(value["origin"]),
        projectRevision = value.long("projectRevision") ?: 0,
        timelineDigest = value.string("timelineDigest")
            ?: throw CreativeException("invalidResponse", "missingTimelineDigest"),
        leaseID = value.string("leaseID")
            ?: throw CreativeException("invalidResponse", "missingLeaseID"),
        ownerReference = value.string("ownerReference").orEmpty(),
        epoch = value.long("epoch") ?: 0,
        snapshotRelativePath = value.string("snapshotRelativePath")
            ?: throw CreativeException("invalidResponse", "missingSnapshotPath"),
        snapshotSHA256 = value.string("snapshotSHA256").orEmpty(),
        snapshotByteCount = value.long("snapshotByteCount") ?: 0,
        snapshotLeaseExpiresAt = value.string("snapshotLeaseExpiresAt")
            ?: throw CreativeException("invalidResponse", "missingLeaseExpiry"),
        outputRelativePath = value.string("outputRelativePath")
            ?: throw CreativeException("invalidResponse", "missingOutputPath"),
        videoSettings = (value["videoSettings"] as? JsonObject)?.let(::decodeVideoSettings),
        imageSettings = (value["imageSettings"] as? JsonObject)?.let(::decodeImageSettings),
        previewWindow = (value["previewWindow"] as? JsonObject)?.let {
            PreviewWindow(
                startSeconds = it.double("startSeconds") ?: 0.0,
                durationSeconds = it.double("durationSeconds") ?: 0.0)
        },
        expiresAt = value.string("expiresAt").orEmpty(),
        descriptorByteCount = value.int("descriptorByteCount") ?: 0,
    )

    private fun decodeKind(raw: String?): MediaExportKind = when (raw) {
        "video" -> MediaExportKind.VIDEO
        "image" -> MediaExportKind.IMAGE
        else -> MediaExportKind.PREVIEW
    }

    private fun decodeVideoSettings(value: JsonObject): VideoExportSettings =
        VideoExportSettings(
            codecMime = value.string("codecMime").orEmpty(),
            width = value.int("width") ?: 0,
            height = value.int("height") ?: 0,
            frameRate = value.double("frameRate") ?: 0.0,
            quality = value.double("quality") ?: 1.0,
            fileName = value.string("fileName").orEmpty())

    private fun decodeImageSettings(value: JsonObject): ImageExportSettings =
        ImageExportSettings(
            format = value.string("format").orEmpty(),
            width = value.int("width"),
            height = value.int("height"),
            quality = value.double("quality") ?: 1.0,
            preserveTransparency = value.bool("preserveTransparency") ?: true,
            stripMetadata = value.bool("stripMetadata") ?: true,
            fileName = value.string("fileName").orEmpty())

    fun decodeClaimed(bytes: ByteArray): ClaimedRenderTicket {
        val value = try {
            json.parseToJsonElement(bytes.toString(Charsets.UTF_8)) as? JsonObject
        } catch (_: Throwable) {
            null
        } ?: throw CreativeException("invalidResponse", "malformedClaim")
        val descriptor = value["descriptor"] as? JsonObject
            ?: throw CreativeException("invalidResponse", "missingDescriptor")
        return ClaimedRenderTicket(
            descriptor = decodeDescriptor(descriptor),
            claimToken = value.string("claimToken")
                ?: throw CreativeException("invalidResponse", "missingClaimToken"),
            claimedAt = value.string("claimedAt").orEmpty(),
            leaseExpiresAt = value.string("leaseExpiresAt").orEmpty(),
        )
    }

    fun decodeDescriptorBytes(bytes: ByteArray): RenderTicketDescriptor {
        val value = try {
            json.parseToJsonElement(bytes.toString(Charsets.UTF_8)) as? JsonObject
        } catch (_: Throwable) {
            null
        } ?: throw CreativeException("invalidResponse", "malformedDescriptor")
        return decodeDescriptor(value)
    }

    fun decodeStats(bytes: ByteArray): RenderTicketStats {
        val value = try {
            json.parseToJsonElement(bytes.toString(Charsets.UTF_8)) as? JsonObject
        } catch (_: Throwable) {
            null
        } ?: throw CreativeException("invalidResponse", "malformedStats")
        return RenderTicketStats(
            live = value.int("live") ?: 0,
            claimed = value.int("claimed") ?: 0,
            completed = value.int("completed") ?: 0,
            cancelled = value.int("cancelled") ?: 0,
            failed = value.int("failed") ?: 0,
            lastErrorCode = value.string("lastErrorCode"))
    }

    /**
     * Encodes exactly `G09R2RenderTicketReplyDTO`. `replyByteCount` is the
     * final UTF-8 byte size (native verifies it equals the received body).
     */
    fun encodeReply(reply: RenderTicketReply): ByteArray {
        var counted = reply.copy(replyByteCount = 0)
        var bytes = encodeReplyObject(counted).toString().toByteArray(Charsets.UTF_8)
        repeat(3) {
            if (counted.replyByteCount == bytes.size) return bytes
            counted = counted.copy(replyByteCount = bytes.size)
            bytes = encodeReplyObject(counted).toString().toByteArray(Charsets.UTF_8)
        }
        return bytes
    }

    private fun encodeReplyObject(reply: RenderTicketReply): JsonObject = buildJsonObject {
        put("ticketID", reply.ticketID)
        put("status", reply.status.wire)
        reply.receipt?.let { put("receipt", encodeReceipt(it)) }
        reply.errorCode?.let { put("errorCode", it) }
        put("completedAt", reply.completedAt)
        put("replyByteCount", reply.replyByteCount)
    }

    // MARK: - Snapshot lease / prepared binding / authority proofs

    fun encodeSnapshotLease(lease: RenderSnapshotLease): JsonObject = buildJsonObject {
        put("leaseID", lease.leaseID)
        put("mediaRootPath", lease.mediaRootPath)
        put("relativePath", lease.relativePath)
        put("sha256", lease.sha256)
        put("byteCount", lease.byteCount)
        put("expiresAt", lease.expiresAt)
    }

    fun decodeSnapshotLease(value: JsonObject): RenderSnapshotLease =
        RenderSnapshotLease(
            leaseID = value.string("leaseID")
                ?: throw CreativeException("invalidResponse", "missingLeaseID"),
            mediaRootPath = value.string("mediaRootPath")
                ?: throw CreativeException("invalidResponse", "missingMediaRoot"),
            relativePath = value.string("relativePath")
                ?: throw CreativeException("invalidResponse", "missingRelativePath"),
            sha256 = value.string("sha256").orEmpty(),
            byteCount = value.long("byteCount") ?: 0,
            expiresAt = value.string("expiresAt").orEmpty())

    fun encodePreparedBinding(binding: R2PreparedRenderBinding): JsonObject =
        buildJsonObject {
            put("context", encodeContext(binding.context))
            put("mediaRootPath", binding.mediaRootPath)
            put("projectRevision", binding.projectRevision)
            put("timelineDigest", binding.timelineDigest)
            put("attemptID", binding.attemptID)
            put("snapshot", encodeSnapshotLease(binding.snapshot))
        }

    fun decodePreparedBinding(
        value: JsonObject,
        context: CreativeProjectContext,
    ): R2PreparedRenderBinding = R2PreparedRenderBinding(
        context = context,
        mediaRootPath = value.string("mediaRootPath")
            ?: throw CreativeException("invalidResponse", "missingMediaRoot"),
        projectRevision = value.long("projectRevision") ?: 0,
        timelineDigest = value.string("timelineDigest")
            ?: throw CreativeException("invalidResponse", "missingTimelineDigest"),
        attemptID = value.string("attemptID")
            ?: throw CreativeException("invalidResponse", "missingAttemptID"),
        snapshot = decodeSnapshotLease(
            value.objectValue("snapshot")
                ?: throw CreativeException("invalidResponse", "missingSnapshotLease")))

    fun encodeDescriptor(descriptor: RenderTicketDescriptor): JsonObject =
        buildJsonObject {
            put("ticketID", descriptor.ticketID)
            put("descriptorVersion", descriptor.descriptorVersion)
            put("kind", descriptor.kind.wire)
            put("projectID", descriptor.projectID)
            put("attemptID", descriptor.attemptID)
            put("mediaRootPath", descriptor.mediaRootPath)
            put("storage", encodeStorage(descriptor.storage))
            descriptor.origin?.let { put("origin", encodeOrigin(it)) }
            put("projectRevision", descriptor.projectRevision)
            put("timelineDigest", descriptor.timelineDigest)
            put("leaseID", descriptor.leaseID)
            put("ownerReference", descriptor.ownerReference)
            put("epoch", descriptor.epoch)
            put("snapshotRelativePath", descriptor.snapshotRelativePath)
            put("snapshotSHA256", descriptor.snapshotSHA256)
            put("snapshotByteCount", descriptor.snapshotByteCount)
            put("snapshotLeaseExpiresAt", descriptor.snapshotLeaseExpiresAt)
            put("outputRelativePath", descriptor.outputRelativePath)
            descriptor.videoSettings?.let { settings ->
                put("videoSettings", buildJsonObject {
                    put("codecMime", settings.codecMime)
                    put("width", settings.width)
                    put("height", settings.height)
                    put("frameRate", settings.frameRate)
                    put("quality", settings.quality)
                    put("fileName", settings.fileName)
                })
            }
            descriptor.imageSettings?.let { settings ->
                put("imageSettings", buildJsonObject {
                    put("format", settings.format)
                    settings.width?.let { put("width", it) }
                    settings.height?.let { put("height", it) }
                    put("quality", settings.quality)
                    put("preserveTransparency", settings.preserveTransparency)
                    put("stripMetadata", settings.stripMetadata)
                    put("fileName", settings.fileName)
                })
            }
            descriptor.previewWindow?.let { window ->
                put("previewWindow", buildJsonObject {
                    put("startSeconds", window.startSeconds)
                    put("durationSeconds", window.durationSeconds)
                })
            }
            put("expiresAt", descriptor.expiresAt)
            put("descriptorByteCount", descriptor.descriptorByteCount)
        }

    fun decodeAuthorityGrant(value: JsonObject?): R2AuthorityGrant? {
        val grant = value ?: return null
        return R2AuthorityGrant(
            epoch = grant.long("epoch") ?: 0,
            mediaRootPath = grant.string("mediaRootPath").orEmpty(),
            projectID = grant.string("projectID"),
            revision = grant.long("revision"),
            timelineDigest = grant.string("timelineDigest"))
    }

    fun decodeAuthorityDecision(value: JsonObject): R2AuthorityDecision =
        R2AuthorityDecision(
            accepted = value.bool("accepted") ?: false,
            grant = decodeAuthorityGrant(value.objectValue("grant")),
            code = value.string("error"),
            reason = value.string("reason"),
            retryable = value.bool("retryable") ?: false)

    fun decodeRenderBindingPin(value: JsonObject): R2RenderBindingPin =
        R2RenderBindingPin(
            pinHandle = value.string("pinHandle")
                ?: throw CreativeException("invalidResponse", "missingPinHandle"),
            epoch = value.long("epoch") ?: 0,
            leaseID = value.string("leaseID").orEmpty(),
            mediaRootPath = value.string("mediaRootPath").orEmpty(),
            projectID = value.string("projectID").orEmpty(),
            revision = value.long("revision") ?: 0,
            timelineDigest = value.string("timelineDigest").orEmpty(),
            expiresAt = value.string("expiresAt").orEmpty(),
            attemptID = value.string("attemptID").orEmpty(),
            kind = value.string("kind") ?: "operation")

    fun decodeProjectMediaRoot(value: JsonObject): R2ProjectMediaRoot =
        R2ProjectMediaRoot(
            epoch = value.long("epoch") ?: 0,
            mediaRootPath = value.string("mediaRootPath")
                ?: throw CreativeException("invalidResponse", "missingMediaRoot"),
            projectID = value.string("projectID").orEmpty(),
            revision = value.long("revision") ?: 0,
            timelineDigest = value.string("timelineDigest").orEmpty(),
            storage = decodeStorage(value["storage"]),
            ownerKind = value.string("ownerKind").orEmpty(),
            ownerID = value.string("ownerID"),
            ownerProof = value.string("ownerProof").orEmpty(),
            storageKey = value.string("storageKey").orEmpty(),
            originKey = value.string("originKey"),
            writable = value.bool("writable") ?: false)

    // MARK: - Large import wire

    fun encodeLargeImportMetadata(metadata: StagedImportMetadata): JsonObject =
        buildJsonObject {
            put("token", metadata.token)
            put("kind", metadata.kind.wire)
            put("fileName", metadata.fileName)
            metadata.mimeType?.let { put("mimeType", it) }
            put("byteCount", metadata.byteCount)
            put("sha256", metadata.sha256)
            metadata.mediaMetadata?.let { media ->
                put("mediaMetadata", buildJsonObject {
                    media.width?.let { put("width", it) }
                    media.height?.let { put("height", it) }
                    media.durationSeconds?.let { put("durationSeconds", it) }
                    media.frameRate?.let { put("frameRate", it) }
                    media.rotationDegrees?.let { put("rotationDegrees", it) }
                })
            }
        }

    fun encodeLargeImportSubmit(request: LargeImportRequest): JsonObject =
        buildJsonObject {
            put("opID", request.opID)
            put("metadata", encodeLargeImportMetadata(request.metadata))
            when (request) {
                is LargeImportRequest.ExistingProject -> {
                    put("context", encodeContext(request.context))
                    put("expectedRevision", request.expectedRevision)
                }
                is LargeImportRequest.NewProject -> {
                    put("storage", encodeStorage(request.storage))
                    put("origin", encodeOrigin(request.origin))
                    put("name", request.name)
                    put("kind", request.kind.wire)
                    put("sessionToken", request.sessionToken)
                    request.preparedIntentToken?.let {
                        put("preparedIntentToken", it)
                    }
                }
            }
        }

    fun decodeLargeImportHandle(value: JsonObject): LargeImportJobHandle =
        LargeImportJobHandle(
            jobID = value.string("jobID")
                ?: throw CreativeException("invalidResponse", "missingImportJobID"),
            state = decodeLargeImportState(value.string("state")),
            acceptedAt = value.string("acceptedAt").orEmpty())

    fun decodeLargeImportStatus(value: JsonObject): LargeImportStatus =
        LargeImportStatus(
            jobID = value.string("jobID").orEmpty(),
            state = decodeLargeImportState(value.string("state")),
            updatedAt = value.string("updatedAt").orEmpty(),
            progress = value.double("progress"),
            createdProjectID = value.string("createdProjectID"),
            createdRevision = value.long("createdRevision"),
            asset = value["asset"]?.let { CreativeWire.decodeMediaAssetReceipt(it) },
            errorCode = value.string("errorCode"),
            retryable = value.bool("retryable") ?: false)

    fun decodeLargeImportState(raw: String?): LargeImportState = when (raw) {
        "queued" -> LargeImportState.QUEUED
        "staging" -> LargeImportState.STAGING
        "verifying" -> LargeImportState.VERIFYING
        "importing" -> LargeImportState.IMPORTING
        "committing" -> LargeImportState.COMMITTING
        "completed" -> LargeImportState.COMPLETED
        "cancelled" -> LargeImportState.CANCELLED
        "failed" -> LargeImportState.FAILED
        else -> LargeImportState.INTERRUPTED
    }

    fun encodeReceipt(receipt: MediaExportReceipt): JsonObject = buildJsonObject {
        put("binding", buildJsonObject {
            put("projectID", receipt.binding.projectID)
            put("mediaRootPath", receipt.binding.mediaRootPath)
            put("projectRevision", receipt.binding.projectRevision)
            put("timelineDigest", receipt.binding.timelineDigest)
            put("attemptID", receipt.binding.attemptID)
        })
        put("kind", receipt.kind.wire)
        put("outputRelativePath", receipt.outputRelativePath)
        put("mimeType", receipt.mimeType)
        put("byteCount", receipt.byteCount)
        put("sha256", receipt.sha256)
        put("verification", buildJsonObject {
            put("playable", receipt.verification.playable)
            put("decodedDurationSeconds", receipt.verification.decodedDurationSeconds)
            put("width", receipt.verification.width)
            put("height", receipt.verification.height)
            put("audioTrackCount", receipt.verification.audioTrackCount)
            put("container", receipt.verification.container)
            put("codec", receipt.verification.codec)
        })
        put("completedAt", receipt.completedAt)
    }
}

// MARK: - Small JSON helpers (file-local, no new dependency)

internal fun JsonObject.string(key: String): String? =
    (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

internal fun JsonObject.bool(key: String): Boolean? =
    (this[key] as? JsonPrimitive)?.content?.toBooleanStrictOrNull()

internal fun JsonObject.int(key: String): Int? =
    (this[key] as? JsonPrimitive)?.content?.toIntOrNull()

internal fun JsonObject.long(key: String): Long? =
    (this[key] as? JsonPrimitive)?.content?.toLongOrNull()

internal fun JsonObject.double(key: String): Double? =
    (this[key] as? JsonPrimitive)?.content?.toDoubleOrNull()

internal fun JsonObject.objectValue(key: String): JsonObject? = this[key] as? JsonObject

internal fun JsonObject.array(key: String): JsonArray? = this[key] as? JsonArray
